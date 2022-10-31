// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IDMMRouter.sol";
import "./interfaces/IRouter.sol";
import "./interfaces/IPair.sol";

contract BavaConvertLPToUSDC is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SafeERC20Upgradeable for IPair;

    IERC20Upgradeable private WAVAX;
    IERC20Upgradeable private USDCE;
    IERC20Upgradeable private USDC;
    uint256 internal BIPS_DIVISOR;

    IDMMRouter public router2;                              // Kyber Router for future usage
    address public liqaddr;                                 // Liquidate address(USB liq Pool)
    uint256 internal lpTokenLength;

    mapping(uint256 => LPTokenInfo) public lpTokenInfo;     // Info of each lpToken.
    mapping(address => uint256) public lpTokenId1;          // poolId1 count from 1, subtraction 1 before using with poolInfo
    mapping(address => bool) public authorized;             // authorized user for liquidate function

    // Info of pool.
    struct LPTokenInfo {
        IPair lpToken;                          // Address of LP token contract.
        IRouter router;                         // Router(Pangolin / TraderJoe)
        uint256 routerType;                     // 0/1, 0 = Pangolin / TraderJoe, 1 = KyberDMM 
        uint256 liqPenalty;                     // New variable
    }

    event LiquidateLP(IPair indexed lpToken, address indexed account, uint256 lpAmount, uint256 usdcAmount);

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /********************************* INITIAL SETUP *********************************/
    /**
     * @notice Approve tokens for use in Strategy, Restricted to avoid griefing attacks
     */
    function setlpTokenAllowancesRouter(uint256 lpTokenId, uint256 _amount) external onlyOwner {   
        LPTokenInfo storage lpTokenPair = lpTokenInfo[lpTokenId];
        if (address(lpTokenPair.router) != address(0)) {
            IERC20Upgradeable(lpTokenPair.lpToken.token0()).approve(address(lpTokenPair.router), _amount);
            IERC20Upgradeable(lpTokenPair.lpToken.token1()).approve(address(lpTokenPair.router), _amount);
            if(lpTokenPair.routerType == 0) {
                lpTokenPair.lpToken.approve(address(lpTokenPair.router), _amount);
            } else {
                lpTokenPair.lpToken.approve(address(router2), _amount);
            }
        }
    }

    function addLPToken(IPair _lpToken , IRouter _router, uint256 _routerType, uint256 _liqPenalty) external onlyOwner {        
        require(address(_lpToken) != address(0), "0Addr");
        require(address(_router) != address(0), "0Addr");
        require(_routerType == 0 || _routerType == 1, "!0!1");
        require(lpTokenId1[address(_lpToken)] == 0, "id!=0");

        lpTokenId1[address(_lpToken)] = lpTokenLength + 1;

        lpTokenInfo[lpTokenLength] = (LPTokenInfo({
            lpToken: _lpToken,
            router: _router,
            routerType: _routerType,
            liqPenalty: _liqPenalty
        }));
        lpTokenLength++;
    }


    // Remove lpToken Liquidity and swap token to WAVAX and to USDC.E token
    function liquidateLpToken(address lpToken) external onlyAuthorized {
        uint256 _lpTokenId1 = lpTokenId1[lpToken];
        require(_lpTokenId1 != 0, "!=0");
        uint256 lpTokenId = _lpTokenId1 - 1;

        _liquidateLpToken(lpTokenId);
    }

    // Liquidate user collateral when user LP token value lower than user borrowed fund.
    function _liquidateLpToken(uint256 lpTokenId) private {
        LPTokenInfo memory lpTokenPair = lpTokenInfo[lpTokenId];
        uint256 lpAmount = lpTokenPair.lpToken.balanceOf(address(this));
        if(lpAmount > 0) {
            uint balance0 = IERC20(IPair(address(lpTokenPair.lpToken)).token0()).balanceOf(address(lpTokenPair.lpToken));
            uint balance1 = IERC20(IPair(address(lpTokenPair.lpToken)).token1()).balanceOf(address(lpTokenPair.lpToken));

            uint _totalSupply = IPair(address(lpTokenPair.lpToken)).totalSupply();     // gas savings, must be defined here since totalSupply can update in _mintFee

            uint amount0 = lpAmount * (balance0) / _totalSupply * 8/10;   // using balances ensures pro-rata distribution
            uint amount1 = lpAmount * (balance1) / _totalSupply * 8/10;   // using balances ensures pro-rata distribution

            uint amountA;
            uint amountB;

            // swap to original Tokens
            if (lpTokenPair.routerType == 0) {
                (amountA, amountB) = lpTokenPair.router.removeLiquidity(lpTokenPair.lpToken.token0(), lpTokenPair.lpToken.token1(), lpAmount, amount0, amount1, address(this), block.timestamp+1200);
            } else {
                (amountA, amountB) = router2.removeLiquidity(lpTokenPair.lpToken.token0(), lpTokenPair.lpToken.token1(), address(lpTokenPair.lpToken), lpAmount, amount0, amount1, address(this), block.timestamp+1200);
            }

            uint liquidateAmountA = _convertTokentoUSDC(lpTokenId, amountA, 0);
            uint liquidateAmountB = _convertTokentoUSDC(lpTokenId, amountB, 1);
            uint256 penaltyAmount = (liquidateAmountA + liquidateAmountB) * lpTokenPair.liqPenalty / BIPS_DIVISOR;
            uint256 liquidationAmount = (liquidateAmountA + liquidateAmountB) - penaltyAmount;

            USDC.safeTransfer(address(liqaddr), liquidationAmount);

            emit LiquidateLP(lpTokenPair.lpToken, msg.sender, lpAmount, (liquidateAmountA + liquidateAmountB));
        }
    }

    function _convertTokentoUSDC(uint256 lpTokenId, uint amount, uint token) private returns (uint) {
        LPTokenInfo memory lpTokenPair = lpTokenInfo[lpTokenId];
        address oriToken;
        if (token == 0) {
            oriToken = IPair(address(lpTokenPair.lpToken)).token0();
        } else if (token == 1) {
            oriToken = IPair(address(lpTokenPair.lpToken)).token1();
        }
        // swap tokenA to USDC
        uint amountUSDC;
        if (oriToken == address(USDC)) {
            amountUSDC = amount;
        } else {
            address[] memory path;
            if (oriToken == address(WAVAX)) {
                uint pathLength = 2;
                path = new address[](pathLength);
                path[0] = address(WAVAX);
                path[1] = address(USDC);
            } else {
                uint pathLength = 3;
                path = new address[](pathLength);
                path[0] = oriToken;
                path[1] = address(WAVAX);
                path[2] = address(USDC);
            }
            amountUSDC = _convertExactTokentoToken(lpTokenId, path, amount);
        }
        return amountUSDC;
    }

    function _convertExactTokentoToken(uint256 lpTokenId, address[] memory path, uint amount) private returns (uint) {
        LPTokenInfo storage lpTokenPair = lpTokenInfo[lpTokenId];
        uint[] memory amountsOutToken = lpTokenPair.router.getAmountsOut(amount, path);
        uint amountOutToken = amountsOutToken[amountsOutToken.length - 1];
        uint[] memory amountOut = lpTokenPair.router.swapExactTokensForTokens(amount, amountOutToken, path, address(this), block.timestamp+600);
        uint swapAmount = amountOut[amountOut.length - 1];

        return swapAmount;
    }

    /**************************************** VIEW FUNCTIONS ****************************************/

    function getlpTokenLength() public view returns (uint) {
        return lpTokenLength;
    }

    /**************************************** ONLY OWNER FUNCTIONS ****************************************/
    // Rescue any token function by owner.
    function rescueFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "0Addr");
        IERC20Upgradeable(token).safeTransfer(_to, amount);
    }

    function lpTokenInfoUpdate(IPair _lpToken , IRouter _router, uint256 _routerType, uint256 _liqPenalty) external onlyOwner {        
        require(address(_lpToken) != address(0), "0Addr");
        require(address(_router) != address(0), "0Addr");
        require(_routerType == 0 || _routerType == 1, "!0!1");
        require(lpTokenId1[address(_lpToken)] != 0, "id!=0");
        
        uint256 _lpTokenId1 = lpTokenId1[address(_lpToken)];
        require(_lpTokenId1 != 0, "!=0");
        uint256 lpTokenId = _lpTokenId1 - 1;

        lpTokenInfo[lpTokenId] = (LPTokenInfo({
            lpToken: _lpToken,
            router: _router,
            routerType: _routerType,
            liqPenalty: _liqPenalty
        }));
    }

    function liqAddrUpdate(address _liqaddr) public onlyOwner {
        require(_liqaddr != address(0), "A!=0");
        liqaddr = _liqaddr;
    }

    function setDMMRouter(address _DMMRouter) public onlyOwner {
        require(_DMMRouter != address(0), "A!=0");
        router2 = IDMMRouter(_DMMRouter);
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0), "A!=0");
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(address _liqaddr) public initializer {
        require(_liqaddr != address(0), "A!=0");
        liqaddr = _liqaddr;
        WAVAX = IERC20Upgradeable(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);  // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
        USDCE = IERC20Upgradeable(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664);  // 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664
        USDC = IERC20Upgradeable(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);   // 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
        BIPS_DIVISOR = 10000;

        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}