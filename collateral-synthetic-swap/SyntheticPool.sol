// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./interface/IAggregatorV3.sol";
import "./interface/ISynthetic.sol";
import "./interface/ISystemCoin.sol";
import "./interface/IUSBLiquidityPool.sol";

contract SyntheticPool is Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {

    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for ISynthetic;
    using SafeERC20Upgradeable for ISystemCoin;

    uint256 internal BIPS_DIVISOR;                          // Constant 10000(denominator)
    uint256 internal txFee;
    address internal reservePool;
    ISystemCoin internal systemCoin;
    IUSBLiquidityPool internal USBLiquidityPool;

    uint256 internal poolLength;
    mapping(uint256 => uint256) internal poolOrderLength;                                       // PoolId => orderLength
    mapping(uint256 => mapping(address => uint256)) internal userOrderLength;                   // PoolId => userAddress => userOrderLength

    uint256 internal totalTxAmount;
    uint256 internal minSystemCoinTxAmount;                                                     // min system Coin amount for order 
    mapping(address => bool) public authorized;
    mapping(uint256 => mapping(uint256 => OrderInfo)) public orderInfo;                         // PoolId => PoolOrderId => OrderInfo
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) public userOrderId;     // PoolId => UserAddress => userOrderLength => PoolOrderId
    mapping(uint256 => PoolInfo) public poolInfo;                                               // PoolId => PoolInfo
    mapping(address => uint256) public poolId1;                                                 // poolId1 count from 1, subtraction 1 before using with poolInfo
    uint256 internal poolTradingHourStartTime;                                                  // Pool trading start timestamp(match with stock market hour)

    struct OrderInfo {
        address account;
        uint256 systemCoinAmount;       // System stable coin
        uint256 synTokenAmount;
        uint256 synTokenPrice;          // 18 decimals
        uint32 orderId;
        uint64 openTime;
        uint64 closeTime;
        uint8 orderType;                // only accept 0/1, 0 = buy, 1 = sell
        uint8 status;                   // 0 = open, 1 = close, 2 = cancel
    }

    struct PoolInfo {
        ISynthetic syntheticToken;          // Synthetic stock token address
        IAggregatorV3 oracleChainlink;      // oracle stock price
        uint256 slippage;
        uint256 txAmount;                   // Transaction amount
        uint256 tradingHours;
        bool openOrderEnabled;
        bool mintsEnabled;
        bool burnsEnabled;
    }

    event SetEmergency(address indexed sender, uint256 emergencyStart);
    event OpenOrder(uint256 indexed pid, uint256 indexed orderType, uint256 orderId, address indexed account, uint256 systemCoinAmount , uint256 synTokenAmount , uint256 synTokenPrice);
    event MintSynToken(uint256 indexed pid, uint256 orderId, address indexed sender, address indexed account, uint256 systemCoinAmount, uint256 synTokenAmount, uint256 synTokenPrice);
    event BurnSynToken(uint256 indexed pid, uint256 orderId, address indexed sender, address indexed account, uint256 systemCoinAmount, uint256 synTokenAmount, uint256 synTokenPrice);
    event CancelOrder(uint256 pid, uint256 orderId, address account);
    event UpdateOrder(uint256 pid, uint256 orderId, uint256 systemCoinAmount, uint256 synTokenAmount);
    event PoolsEnabled(uint256 pid, bool newMintsEnabled, bool newBurnsEnabled);

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /******************************************* INITIAL SETUP START ******************************************/
    // Init the contract. Can only be called by the owner. 
    function initContract(address _reservePool, address _systemCoin, address _USBLiquidityPool, uint256 _minSystemCoinTxAmount , uint256 _txFee) external onlyOwner{
        require(_reservePool != address(0),"RP!=0");
        require(_systemCoin != address(0),"SC!=0");
        require(_USBLiquidityPool != address(0),"USB!=0");
        reservePool = _reservePool;
        systemCoin = ISystemCoin(_systemCoin);
        USBLiquidityPool = IUSBLiquidityPool(_USBLiquidityPool);
        minSystemCoinTxAmount = _minSystemCoinTxAmount;
        txFee = _txFee;
    }

    function add(address _synToken, address _oracle, uint256 _slippage, uint256 _tradingHours) external onlyOwner {
        require(address(_synToken) != address(0), "ST!=0");
        require(poolId1[address(_synToken)] == 0, "coll.Token is in list");
        poolId1[address(_synToken)] = poolLength + 1;
        poolInfo[poolLength] = PoolInfo({
            syntheticToken : ISynthetic(_synToken),
            oracleChainlink : IAggregatorV3(_oracle), 
            slippage : _slippage,
            txAmount : 0,
            tradingHours : _tradingHours,
            openOrderEnabled: true,
            mintsEnabled : true,
            burnsEnabled : true
        });
        poolLength++;
    }

    /****************************************** Synthetic CORE FUNCTION ******************************************/
    function openMarketOrder(uint256 pid, uint8 orderType, uint256 synTokenAmount) whenNotPaused external{
        require(synTokenAmount >= 0, "<0");
        PoolInfo memory pool = poolInfo[pid];
        require(pool.openOrderEnabled == true,"N/BE");

        uint256 synTokenDecimal = pool.syntheticToken.decimals();
        uint256 estSystemCoinAmount;
        uint256 slippageTokenPrice;

        (bool status, uint256 _synTokenPrice) = _getPrice(pid);
        require(status == true, "oracle not available");

        if(orderType == 0) {
            slippageTokenPrice = _synTokenPrice + (_synTokenPrice * pool.slippage / BIPS_DIVISOR);
            estSystemCoinAmount = synTokenAmount * slippageTokenPrice / (10 ** synTokenDecimal);
            require(estSystemCoinAmount >= minSystemCoinTxAmount, "<minTxSysCoinAmount");
            _openBuyOrder(pid, msg.sender, estSystemCoinAmount, synTokenAmount, slippageTokenPrice);
            _mintSynToken(pid, poolOrderLength[pid]-1);
        } else if(orderType ==1) {
            slippageTokenPrice = _synTokenPrice - (_synTokenPrice * pool.slippage / BIPS_DIVISOR);
            estSystemCoinAmount = synTokenAmount * slippageTokenPrice / (10 ** synTokenDecimal);
            require(estSystemCoinAmount >= minSystemCoinTxAmount, "<minTxSysCoinAmount");
            _openSellOrder(pid, msg.sender, estSystemCoinAmount, synTokenAmount, _synTokenPrice);
            _burnSynToken(pid, poolOrderLength[pid]-1);
        }
    }

    /** 
    * @dev synTokenPrice in 18 decimals, synTokenAmount in 3 decimals
    */
    function openLimitOrder(uint256 pid, uint8 orderType, uint256 synTokenAmount, uint256 _synTokenLimitPrice) whenNotPaused external {
        require(orderType == 0 || orderType == 1, "WrongOT");
        require(synTokenAmount > 0, "Invalid input");
        PoolInfo memory pool = poolInfo[pid];
        require(pool.openOrderEnabled == true,"N/BE");

        uint256 synTokenDecimal = pool.syntheticToken.decimals();
        uint256 estSystemCoinAmount;

        (bool status, uint256 _synTokenPrice) = _getPrice(pid);
        require(status == true, "oracle not available");

        if(orderType == 0) {
            require(_synTokenLimitPrice < _synTokenPrice && _synTokenLimitPrice > 0, 'Invalid buy limit price');
            estSystemCoinAmount = (synTokenAmount * _synTokenLimitPrice) / (10 ** synTokenDecimal);
            require(estSystemCoinAmount >= minSystemCoinTxAmount, "<minTxSysCoinAmount");
            _openBuyOrder(pid, msg.sender, estSystemCoinAmount, synTokenAmount, _synTokenLimitPrice);
        } else if(orderType ==1) {
            require(_synTokenLimitPrice > _synTokenPrice, 'Invalid sell limit price');
            estSystemCoinAmount = synTokenAmount * _synTokenLimitPrice / (10 ** synTokenDecimal);
            require(estSystemCoinAmount >= minSystemCoinTxAmount, "<minTxSysCoinAmount");
            _openSellOrder(pid, msg.sender, estSystemCoinAmount, synTokenAmount, _synTokenLimitPrice);
        }
    }

    function closeOrder(uint256 pid, uint256 _orderId) onlyAuthorized whenNotPaused external {
        require(_orderId < poolOrderLength[pid], "Invalid orderId");
        OrderInfo storage order = orderInfo[pid][_orderId];
        require(order.status == 0, "Order not open");
        
        PoolInfo storage pool = poolInfo[pid];
        uint256 slippageTokenPrice;

       (bool status, uint256 _synTokenPrice) = _getPrice(pid);
        require(status == true, "oracle not available");

        if(order.orderType == 0) {
            slippageTokenPrice = order.synTokenPrice - (order.synTokenPrice * pool.slippage / BIPS_DIVISOR);
            require(_synTokenPrice <= slippageTokenPrice,"< token limit price");
            _mintSynToken(pid, _orderId);
        } else if(order.orderType == 1) {
            slippageTokenPrice = order.synTokenPrice + (order.synTokenPrice * pool.slippage / BIPS_DIVISOR);
            require(_synTokenPrice >= slippageTokenPrice,"< token limit price");
            _burnSynToken(pid, _orderId);
        }
    }

    function cancelOrder(uint256 pid, uint256 _orderId) whenNotPaused external {
        require(_orderId < poolOrderLength[pid],"N/A");
        OrderInfo memory order = orderInfo[pid][_orderId];
        require(order.status == 0, "order not open");
        require(msg.sender == order.account, "Wrong User");
        _cancelOrder(pid, _orderId);
    }

    function cancelAllOrders(uint256 pid) whenNotPaused external {
        uint256 _userOrderLength = userOrderLength[pid][msg.sender];
        for (uint256 i = 0; i < _userOrderLength; i++) {
            uint256 _userOrderId = userOrderId[pid][msg.sender][i];
            OrderInfo memory order = orderInfo[pid][_userOrderId];
            if (order.status == 0) {
                require(order.status == 0, "order not open");
                require(msg.sender == order.account, "Wrong User");
                _cancelOrder(pid, _userOrderId);
            }
        }
    }

    /**************************************** Internal FUNCTIONS ****************************************/
    function _getPrice(uint256 pid) internal view returns (bool,uint256) {
        PoolInfo memory pool = poolInfo[pid];
        IAggregatorV3 assetsPrice = pool.oracleChainlink;

        if (address(assetsPrice) != address(0)){
            uint8 priceDecimals = assetsPrice.decimals();
            uint8 decimalsMap = 18-priceDecimals;
            (, int price,,,) = assetsPrice.latestRoundData();
            return (true,uint256(price)*(10**decimalsMap));
        } else {
            return (false,0);
        }
    }

    function _openBuyOrder(uint256 pid, address account, uint256 _systemCoinAmount, uint256 _synTokenAmount, uint256 _synTokenPrice) internal {
        PoolInfo memory pool = poolInfo[pid];
        require(pool.mintsEnabled == true, "N/ME");

        systemCoin.safeTransferFrom(msg.sender, address(this), _systemCoinAmount + txFee);
        systemCoin.safeTransfer(reservePool, txFee);

        orderInfo[pid][poolOrderLength[pid]] = OrderInfo({
            account: account,
            systemCoinAmount: _systemCoinAmount,
            synTokenAmount: _synTokenAmount,
            synTokenPrice: _synTokenPrice,
            orderId: uint32(poolOrderLength[pid]),
            openTime: uint64(block.timestamp),
            closeTime: 0,
            orderType: 0,
            status: 0
        });
        
        userOrderId[pid][account][userOrderLength[pid][account]] = poolOrderLength[pid];
        emit OpenOrder(pid, 0, poolOrderLength[pid], account, _systemCoinAmount, _synTokenAmount, _synTokenPrice);

        userOrderLength[pid][account]++;
        poolOrderLength[pid]++;
    }

    function _openSellOrder(uint256 pid, address account, uint256 _systemCoinAmount, uint256 _synTokenAmount, uint256 _synTokenPrice) internal{
        PoolInfo memory pool = poolInfo[pid];
        require(pool.burnsEnabled == true, "N/BE");
        
        pool.syntheticToken.safeTransferFrom(account, address(this), _synTokenAmount);
        systemCoin.safeTransferFrom(msg.sender, address(this), txFee);
        systemCoin.safeTransfer(reservePool, txFee);

        orderInfo[pid][poolOrderLength[pid]] = OrderInfo({
            account: account,
            systemCoinAmount: _systemCoinAmount,
            synTokenAmount: _synTokenAmount,
            synTokenPrice: _synTokenPrice,
            orderId: uint32(poolOrderLength[pid]),
            openTime: uint64(block.timestamp),
            closeTime: 0,
            orderType: 1,
            status: 0
        });

        userOrderId[pid][account][userOrderLength[pid][account]] = poolOrderLength[pid];
        emit OpenOrder(pid, 1, poolOrderLength[pid], account, _systemCoinAmount, _synTokenAmount, _synTokenPrice);

        userOrderLength[pid][account]++;
        poolOrderLength[pid]++;
    }

    function _mintSynToken(uint256 pid, uint256 _orderId) internal {
        OrderInfo storage order = orderInfo[pid][_orderId];
        PoolInfo storage pool = poolInfo[pid];

        order.status = 1;
        order.closeTime = uint64(block.timestamp);

        pool.txAmount += order.systemCoinAmount;
        totalTxAmount += order.systemCoinAmount;
        pool.syntheticToken.mint(order.account, order.synTokenAmount);

        emit MintSynToken(pid, order.orderId, msg.sender, order.account, order.systemCoinAmount ,order.synTokenAmount, order.synTokenPrice);
    }

    function _burnSynToken(uint256 pid, uint256 _orderId) internal {
        PoolInfo storage pool = poolInfo[pid];
        OrderInfo storage order = orderInfo[pid][_orderId];

        order.status = 1;
        order.closeTime = uint64(block.timestamp);

        pool.txAmount += order.systemCoinAmount;
        totalTxAmount += order.systemCoinAmount;
        pool.syntheticToken.burn(order.synTokenAmount);
        
        uint256 systemCoinBalance = systemCoin.balanceOf(address(this));

        if (systemCoinBalance >= order.systemCoinAmount) {
            systemCoin.safeTransfer(order.account, order.systemCoinAmount);
        } else {
            USBLiquidityPool.borrowUSB(order.systemCoinAmount - systemCoinBalance);
            systemCoin.safeTransfer(order.account, order.systemCoinAmount);
        }
        emit BurnSynToken(pid, order.orderId, msg.sender, order.account, order.systemCoinAmount, order.synTokenAmount, order.synTokenPrice);
    }
    
    function _cancelOrder(uint256 pid, uint256 _orderId) internal {
        OrderInfo storage order = orderInfo[pid][_orderId];
        PoolInfo memory pool = poolInfo[pid];

        order.status = 2;
        order.closeTime = uint64(block.timestamp);
        if(order.orderType == 0) {
            uint256 systemCoinBalance = systemCoin.balanceOf(address(this));
            if (systemCoinBalance >= order.systemCoinAmount) {
                systemCoin.safeTransfer(order.account, order.systemCoinAmount);
            } else {
                USBLiquidityPool.borrowUSB(order.systemCoinAmount - systemCoinBalance);
                systemCoin.safeTransfer(order.account, order.systemCoinAmount);
            }
        } else if(order.orderType == 1) {
            pool.syntheticToken.safeTransfer(order.account, order.synTokenAmount);
        }
        emit CancelOrder(pid, _orderId, msg.sender);
    }

    /**************************************** View FUNCTIONS ****************************************/

    function getSystemCoin() external view returns (address) {
        return address(systemCoin);
    }

    function getUSBLiquidityPool() external view returns (address) {
        return address(USBLiquidityPool);
    }

    function getReservePool() external view returns (address) {
        return address(reservePool);
    }

    function getPoolLength() external view returns (uint256) {
        return poolLength;
    }

    function getPoolOrderLength(uint256 pid) external view returns (uint256) {
        return poolOrderLength[pid];
    }

    function getUserOrderLength(uint256 pid, address account) external view returns (uint256) {
        return userOrderLength[pid][account];
    }

    function getTotalTxAmount() external view returns (uint256) {
        return totalTxAmount;
    }

    function getMinTxAmount() external view returns (uint256) {
        return (minSystemCoinTxAmount);
    }

    function getPoolPrice(uint256 pid) external view returns (bool, uint256) {
        (bool status, uint256 _synTokenPrice) = _getPrice(pid);
        return (status, _synTokenPrice);
    }

    function getTradingHourStartTime() external view returns (uint256) {
        return poolTradingHourStartTime;
    }

    // For future restrited trading hour usage
    function _calculateDays(uint256 pid, uint256 currentTimestamp) view internal returns(uint256, uint256) {
        PoolInfo memory pool = poolInfo[pid];
        uint256 numberOfDays = (currentTimestamp - poolTradingHourStartTime)/ (1 days);
        uint256 openingTime = poolTradingHourStartTime * numberOfDays * (1 days);
        uint256 closingTime = openingTime + pool.tradingHours;
        return (openingTime, closingTime);
    }

    /**
    * @dev Get all orders for an account.
    */
    function getUserOrders(uint256 pid, address account) external view returns (OrderInfo[] memory orders) {
        uint256 ordersLength = userOrderLength[pid][account];
        orders = new OrderInfo[](ordersLength);
        for (uint256 i = 0; i < ordersLength; i++) {
            orders[i] = orderInfo[pid][userOrderId[pid][account][i]];
        }
    }

    /**************************************** ONLY OWNER FUNCTIONS ****************************************/

    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "0A");
        IERC20Upgradeable(token) .safeTransfer(_to, amount);
    }

    function cancelOrderOwner(uint256 pid, uint256 _orderId) onlyOwner whenNotPaused external {
        require(_orderId < poolOrderLength[pid],"N/A");
        OrderInfo storage order = orderInfo[pid][_orderId];
        require(order.status == 0, "order Closed");
        _cancelOrder(pid, _orderId);
    }

    function addAuthorized(address _toAdd) onlyOwner external {
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner external {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    function setReservePool(address newReservePool) external onlyOwner {
        require(newReservePool != address(0));
        reservePool = newReservePool;
    }

    function setUSBLiquidityPool(address newUSBLiquidityPool) external onlyOwner {
        require(newUSBLiquidityPool != address(0));
        USBLiquidityPool = IUSBLiquidityPool(newUSBLiquidityPool);
    }

    function setPoolsMinTx(uint128 newSystemCoinTxFloor) external onlyOwner {
        minSystemCoinTxAmount = newSystemCoinTxFloor;
    }

    function setPoolsEnabled(uint256 pid, bool newOpenOrderEnabled, bool newMintsEnabled, bool newBurnsEnabled) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        pool.openOrderEnabled = newOpenOrderEnabled;
        pool.mintsEnabled = newMintsEnabled;
        pool.burnsEnabled = newBurnsEnabled;
        
        emit PoolsEnabled(pid, newMintsEnabled, newBurnsEnabled);
    }
    
    function setPoolSlippage(uint256 pid, uint256 _slippage) external onlyOwner {
        PoolInfo storage pool = poolInfo[pid];
        require(_slippage != pool.slippage, "same number");
        pool.slippage = _slippage;
    }

    /**
    * @notice For owner update SyntheticToken oracle address
    */
    function updatePoolOracleAdd(uint256 pid, address oracle) external onlyOwner {
        require(address(oracle) != address(0), "A!=0");
        PoolInfo storage pool = poolInfo[pid];
        pool.oracleChainlink = IAggregatorV3(oracle);
    }

    function updateStartTime(uint256 newStartTimeStamp) external onlyOwner {
        require(newStartTimeStamp > poolTradingHourStartTime, "< current startDate");
        poolTradingHourStartTime = newStartTimeStamp;
    }

    function updatePoolTradingHours(uint256 pid, uint256 newTradingHours) external onlyOwner {
        require(newTradingHours > 0, "<0");
        PoolInfo storage pool = poolInfo[pid];
        pool.tradingHours = newTradingHours;
    }

    function updateTxFee(uint256 newTxFee) external onlyOwner {
        txFee = newTxFee;
    }

    function updateOrderInfo(uint256 pid, uint256 _orderId, uint128 systemCoinAmount, uint128 synTokenAmount) external onlyOwner {
        OrderInfo storage order = orderInfo[pid][_orderId];
        require(order.status == 1, "order not close");
        order.systemCoinAmount = systemCoinAmount;
        order.synTokenAmount = synTokenAmount;

        emit UpdateOrder(pid, _orderId, order.systemCoinAmount, order.synTokenAmount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize() external initializer {
        BIPS_DIVISOR = 10000;

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}