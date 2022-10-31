// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "../interfaces/IWAVAX.sol";
import "./interfaces/IVeJoeStaking.sol";
import "./interfaces/IJoeVoter.sol";

/**
 * @notice JoeVoter manages deposits for other strategies
 * using a proxy pattern. It also directly accepts deposits
 * in exchange for bJOE token.
 */
contract JoeVoter is IJoeVoter, OwnableUpgradeable, ERC20Upgradeable, UUPSUpgradeable, ERC20BurnableUpgradeable {
    IWAVAX private WAVAX;
    address public JOE;
    IERC20Upgradeable public veJOE;
    IVeJoeStaking public stakingContract;

    address public voterProxy;
    bool public override depositsEnabled;
    bool public override withdrawEnabled;

    modifier onlyJoeVoterProxy() {
        require(msg.sender == voterProxy, "JoeVoter::onlyJoeVoterProxy");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    receive() external payable {}

    /**
     * @notice veJOE balance
     * @return uint256 balance
     */
    function veJOEBalance() external view override returns (uint256) {
        return veJOE.balanceOf(address(this));
    }

    /**
     * @notice Enable/disable deposits
     * @dev Restricted to owner
     * @param newValue bool
     */
    function updateDepositsEnabled(bool newValue) external onlyOwner {
        require(depositsEnabled != newValue);
        depositsEnabled = newValue;
    }

    function updateWithdrawsEnabled(bool newValue) external onlyOwner {
        require(withdrawEnabled != newValue);
        withdrawEnabled = newValue;
    }

    /**
     * @notice External deposit function for JOE
     * @param _amount to deposit
     */
    function deposit(uint256 _amount) external {
        require(depositsEnabled == true, "JoeVoter::deposits disabled");
        require(IERC20Upgradeable(JOE).transferFrom(msg.sender, address(this), _amount), "JoeVoter::transfer failed");
        _deposit(_amount);
    }

    /**
     * @notice Update VeJoeStaking address
     * @param _stakingContract new address
     */
    function setStakingContract(address _stakingContract) external override onlyOwner {
        stakingContract = IVeJoeStaking(_stakingContract);
    }

    /**
     * @notice Update proxy address
     * @dev Very sensitive, restricted to owner
     * @param _voterProxy new address
     */
    function setVoterProxy(address _voterProxy) external override onlyOwner {
        voterProxy = _voterProxy;
    }
 
    /**
     * @notice Update veJOE balance
     * @dev Any one may call this
     */
    function claimVeJOE() external override {
        stakingContract.claim();
    }

    /**
     * @notice Deposit function for JOE
     * @dev Restricted to proxy
     * @param _amount to deposit
     */
    function depositFromBalance(uint256 _amount) external override onlyJoeVoterProxy {
        require(depositsEnabled == true, "JoeVoter:deposits disabled");
        _deposit(_amount);
    }

    /**
     * @notice Deposits JOE and mints bJOE at 1:1 ratio
     * @param _amount to deposit
     */
    function _deposit(uint256 _amount) internal {
        IERC20Upgradeable(JOE).approve(address(stakingContract), _amount);
        _mint(msg.sender, _amount);
        stakingContract.deposit(_amount);
        IERC20Upgradeable(JOE).approve(address(stakingContract), 0);
    }

    function withdrawFromVeJoeStaking(uint256 _amount) external {
        require(withdrawEnabled == true, "JoeVoter:withdraw disabled");
        _withdraw(_amount);
    }

    /**
     * @notice Withdraw JOE and burn bJOE at 1:1 ratio
     * @param _amount to deposit
     */
    function _withdraw(uint256 _amount) internal {
        _burn(msg.sender, _amount);
        stakingContract.withdraw(_amount);
    }

    /**
     * @notice Helper function to wrap AVAX
     * @return amount wrapped to WAVAX
     */
    function wrapAvaxBalance() external override onlyJoeVoterProxy returns (uint256) {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            WAVAX.deposit{value: balance}();
        }
        return balance;
    }

    /**
     * @notice Open-ended execute function
     * @dev Very sensitive, restricted to proxy
     * @param target address
     * @param value value to transfer
     * @param data calldata
     * @return bool success
     * @return bytes result
     */
    function execute(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyJoeVoterProxy returns (bool, bytes memory) {
        (bool success, bytes memory result) = target.call{value: value}(data);

        return (success, result);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(
        address _stakingContract
    ) public initializer {
        stakingContract = IVeJoeStaking(_stakingContract);
        WAVAX = IWAVAX(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);             // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
        JOE = address(0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd);              // 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd
        veJOE = IERC20Upgradeable(0x3cabf341943Bc8466245e4d6F1ae0f8D071a1456);  // 0x3cabf341943Bc8466245e4d6F1ae0f8D071a1456
        depositsEnabled = true;
        withdrawEnabled = false;

        __ERC20_init("Baklava JOE", "bJOE");
        __ERC20Burnable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}