// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "./interface/ISystemCoin.sol";
import "./interface/IUSBSwapLocker.sol";

contract USBLiquidityPool is Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {

    using SafeERC20Upgradeable for ISystemCoin;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 internal DEV_FEE_BIPS;
    uint256 internal BIPS_DIVISOR;
    address internal reservePool;
    uint256 internal debtLimit;
    ISystemCoin internal systemCoin;
    IUSBSwapLocker internal swapLocker;
    uint256 internal USPeggedCoinsLength;
    uint256 internal totalLendingDebt;

    mapping(uint256 => USPeggedCoinInfo) internal USPeggedCoins;
    mapping(address => uint256) public coinId1;
    mapping(address => uint256) public debt;
    mapping(address => bool) internal authorized;
    mapping(address => uint256) public liquidityAmount;     // in USB amount

    event BuyUSB(address indexed user, uint usbAmount, uint usPeggedAmount);
    event SellUSB(address indexed user, uint usbAmount, uint usPeggedAmount);
    event Borrow(address indexed borrower, uint usbAmount);
    event Payback(address indexed payer, address indexed borrower,uint usPeggedAmount);

    struct USPeggedCoinInfo {
        ISystemCoin coinAddress;
        uint256 vestingDuration;
        bool swapEnabled;
    }

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function buyUSB(uint256 usPeggedTokenIndex, uint256 inputUSPeggedAmount) external {
        require(inputUSPeggedAmount > 0, "P.A!=0");
        USPeggedCoinInfo storage usPegCoinInfo = USPeggedCoins[usPeggedTokenIndex];
        ISystemCoin usPegCoin = usPegCoinInfo.coinAddress;
        require(address(usPegCoin) != address(0),'Add!=0');
        require(usPegCoinInfo.swapEnabled == true, "same state");

        uint256 usbDecimal = systemCoin.decimals();
        uint256 usPeggedDecimal = usPegCoin.decimals();
        uint256 buyingFees = inputUSPeggedAmount * DEV_FEE_BIPS / BIPS_DIVISOR;
        uint256 usbAmount = (inputUSPeggedAmount - buyingFees) * 10 ** (usbDecimal - usPeggedDecimal);

        usPegCoin.safeTransferFrom(msg.sender, address(this), inputUSPeggedAmount);
        if(buyingFees > 0) {
            usPegCoin.safeTransfer(reservePool,buyingFees);
        }
        systemCoin.mint(msg.sender,usbAmount);

        emit BuyUSB(msg.sender, usbAmount, inputUSPeggedAmount);
    }

    function sellUSB(uint256 usPeggedTokenIndex, uint256 inputUSBAmount) external {
        require(inputUSBAmount > 0, "A!=0");
        USPeggedCoinInfo storage usPegCoinInfo = USPeggedCoins[usPeggedTokenIndex];
        require(address(usPegCoinInfo.coinAddress) != address(0),'Add!=0');
        require(usPegCoinInfo.swapEnabled == true, "same state");

        uint256 usbDecimal = systemCoin.decimals();
        uint256 usPeggedDecimal = usPegCoinInfo.coinAddress.decimals();
        uint256 sellingFees = inputUSBAmount * DEV_FEE_BIPS / BIPS_DIVISOR;
        uint256 usPeggedAmount = (inputUSBAmount- sellingFees) / (10 ** (usbDecimal - usPeggedDecimal));
        require(usPeggedAmount > 0, "P.A!=0");

        systemCoin.transferFrom(msg.sender, address(this), inputUSBAmount);
        systemCoin.burn(inputUSBAmount - sellingFees);
        if(sellingFees > 0) {
            systemCoin.safeTransfer(reservePool,sellingFees);
        }

        _lockReward(usPegCoinInfo.coinAddress, msg.sender, usPeggedAmount, usPegCoinInfo.vestingDuration);

        emit SellUSB(msg.sender, inputUSBAmount, usPeggedAmount);
    }

    /**
    * @dev Call locker contract to lock rewards
    */
    function _lockReward(IERC20Upgradeable token, address _account, uint256 _amount, uint256 _vestingDuration) internal {
        require(address(token) != address(0),'A!=0');
        swapLocker.lock(token, _account, _amount, uint32(_vestingDuration));
    }

    /**************************************** Only Authorized/Admin FUNCTIONS ****************************************/

    function provideLiquidity(uint256 usPeggedTokenIndex, uint256 usPeggedAmount) external onlyAuthorized {
        require(usPeggedAmount > 0, "P.A!=0");
        USPeggedCoinInfo storage usPegCoinInfo = USPeggedCoins[usPeggedTokenIndex];
        require(address(usPegCoinInfo.coinAddress) != address(0),'Add!=0');

        uint256 usbDecimal = systemCoin.decimals();
        uint256 usPeggedDecimal = usPegCoinInfo.coinAddress.decimals();
        uint256 usbAmount = (usPeggedAmount) * 10 ** (usbDecimal - usPeggedDecimal);

        usPegCoinInfo.coinAddress.safeTransferFrom(msg.sender, address(this), usPeggedAmount);
        systemCoin.mint(msg.sender,usbAmount);
        liquidityAmount[msg.sender] += usbAmount;

        emit BuyUSB(msg.sender, usbAmount, usPeggedAmount);
    }

    function withdrawLiquidity(uint256 usPeggedTokenIndex, uint256 inputUSBAmount) external onlyAuthorized {
        require(inputUSBAmount > 0, "A!=0");
        USPeggedCoinInfo storage usPegCoinInfo = USPeggedCoins[usPeggedTokenIndex];
        require(address(usPegCoinInfo.coinAddress) != address(0),'Add!=0');

        uint256 usbDecimal = systemCoin.decimals();
        uint256 usPeggedDecimal = usPegCoinInfo.coinAddress.decimals();
        uint256 usPeggedAmount = inputUSBAmount / (10 ** (usbDecimal - usPeggedDecimal));
        require(usPeggedAmount > 0, "P.A!=0");
        
        liquidityAmount[msg.sender] -= inputUSBAmount;
        systemCoin.transferFrom(msg.sender, address(this), inputUSBAmount);
        systemCoin.burn(inputUSBAmount);
        usPegCoinInfo.coinAddress.safeTransfer(msg.sender, usPeggedAmount);

        emit SellUSB(msg.sender, inputUSBAmount, usPeggedAmount);
    }

    function borrowUSB(uint256 usbAmount) external onlyAuthorized {
        require(usbAmount > 0, "A!=0");
        require(debt[msg.sender] + usbAmount <= debtLimit,"debt overflow");
        debt[msg.sender] += usbAmount;
        totalLendingDebt += usbAmount;
        systemCoin.mint(msg.sender,usbAmount);

        emit Borrow(msg.sender, usbAmount);
    }

    function paybackUSB(address account, uint256 usbAmount) external {
        require(usbAmount > 0, "A!=0");
        require(debt[account] > 0, "D!=0");
        require(debt[account] >= usbAmount,"overflow");

        systemCoin.transferFrom(msg.sender, address(this), usbAmount);
        systemCoin.burn(usbAmount);
        debt[account] -= usbAmount;
        totalLendingDebt -= usbAmount;

        emit Payback(msg.sender, account, usbAmount);
    }

    // Function to be enabled for swap locker auto transferFrom USB liquidity pool
    function approveLockerAllowance(uint256 usPeggedTokenIndex) external onlyAuthorized {
        ISystemCoin usPegCoin = USPeggedCoins[usPeggedTokenIndex].coinAddress;
        require(address(usPegCoin) != address(0),'Add!=0');
        usPegCoin.safeApprove(address(swapLocker), type(uint256).max);
    }

    /**************************************** View FUNCTIONS ****************************************/

    function getDEV_FEE_BIPS() external view returns (uint256) {
        return DEV_FEE_BIPS;
    }

    function getReservePool() external view returns (address) {
        return reservePool;
    }

    function getDebtLimit() external view returns (uint256) {
        return debtLimit;
    }

    function getLendingDebt() external view returns (uint256) {
        return totalLendingDebt;
    }

    function getSystemCoin() external view returns (address) {
        return address(systemCoin);
    }

    function getSwapLocker() external view returns (address) {
        return address(swapLocker);
    }

    function getUSPeggedCoinsLength() external view returns (uint256) {
        return USPeggedCoinsLength;
    }

    function getUSPeggedCoin(uint256 usPeggedTokenIndex) external view returns (USPeggedCoinInfo memory) {
        return USPeggedCoins[usPeggedTokenIndex];
    }

    function getAuthorized(address adminAddress) external view returns (bool) {
        return authorized[adminAddress];
    }

    /**************************
     * @dev OnlyOwner function
     *************************/
    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0) , "0Addr");
        ISystemCoin(token).safeTransfer(_to, amount);
    }

    function fundSwapLocker(address token, uint256 amount) external onlyOwner {
        require(amount > 0 , "!=0");
        ISystemCoin(token).safeTransfer(address(swapLocker), amount);
    }

    function addAuthorized(address _toAdd) external onlyOwner {
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) external onlyOwner {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    function setdebtLimit(uint256 newLimit) external onlyOwner {
        require(newLimit > 0, "!=0");
        require(newLimit != debtLimit, "NE");
        debtLimit = newLimit;
    }

    function setdevFee(uint256 newDevFee) external onlyOwner {
        require(newDevFee != DEV_FEE_BIPS, "NE");
        require(newDevFee <= BIPS_DIVISOR, ">100%");
        DEV_FEE_BIPS = newDevFee;
    }

    function setReservePool(address newReservePool) external onlyOwner {
        require(newReservePool != address(0),"A!=0");
        require(newReservePool != reservePool,"SameAdd");
        reservePool = newReservePool;
    }

    function addUSPeggedCoin(ISystemCoin _USPeggedCoin, uint256 _vestingDuration) external onlyOwner {
        require(address(_USPeggedCoin) != address(0),"A!=0");
        require(coinId1[address(_USPeggedCoin)] == 0, "coinContract is in pool");
        uint256 usPegCoinLength = USPeggedCoinsLength;
        coinId1[address(_USPeggedCoin)] = usPegCoinLength + 1;
        USPeggedCoins[usPegCoinLength].coinAddress = _USPeggedCoin;
        USPeggedCoins[usPegCoinLength].vestingDuration = _vestingDuration;
        USPeggedCoins[usPegCoinLength].swapEnabled = true;
        USPeggedCoinsLength += 1;
    }

    function setVestingDuration(uint256 usPeggedTokenIndex, uint256 _vestingDuration) external onlyOwner {
        USPeggedCoinInfo storage usPegCoin = USPeggedCoins[usPeggedTokenIndex];
        usPegCoin.vestingDuration = _vestingDuration;
    }

    function setUSPeggedCoinSwap(uint256 usPeggedTokenIndex, bool _enabled) external onlyOwner {
        USPeggedCoinInfo storage usPegCoin = USPeggedCoins[usPeggedTokenIndex];
        require(usPegCoin.swapEnabled != _enabled, "same state");
        usPegCoin.swapEnabled = _enabled;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize(address _systemCoin, IUSBSwapLocker _swapLocker, address _reservePool, uint256 _devFee) public initializer {
        BIPS_DIVISOR = 10000;
        systemCoin = ISystemCoin(_systemCoin);
        reservePool = _reservePool;
        DEV_FEE_BIPS = _devFee;
        swapLocker = _swapLocker;

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}