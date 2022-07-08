// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interface/IAggregatorV3.sol";
import "./interface/IPair.sol";
import "./interface/IBRTVault.sol";

interface IERC20 {
    function decimals() external view returns (uint8);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}

contract AvaxChainLinkOracle is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    uint256 internal BIPS_DIVISOR;                         // Constant 10000(denominator)

    mapping(address => IPair) public lpToken;               // Underlying LPToken to check oracle price
    mapping(address => uint256) internal decimalsMap;       // Token price decimals
    mapping(address => IAggregatorV3) public assetsMap;     // Oracle (Chainlink) 

    event SetAssetsAggregator(address indexed sender, address asset, address aggregator);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function setAssetsAggregator(address asset,address aggregator) public onlyOwner {
        _setAssetsAggregator(asset,aggregator);
    }

    function _setAssetsAggregator(address asset, address aggregator) internal {
        assetsMap[address(asset)] = IAggregatorV3(aggregator);
        uint8 _decimals = 18;
        if (asset != address(0)){
            _decimals = IERC20(asset).decimals();
        }
        uint8 priceDecimals = IAggregatorV3(aggregator).decimals();
        decimalsMap[address(asset)] = 36-priceDecimals-_decimals;
        emit SetAssetsAggregator(msg.sender,address(asset),aggregator);
    }

    function getPriceInfo(address token) public view returns (bool,uint256) {
        (bool success,) = token.staticcall(abi.encodeWithSignature("getReserves()"));
        if(success){
            return getLpPairPrice(token);
        } else {
            return _getPrice(address(token));
        }
    }
    
    // Price return in 18 decimals:price/token[ether]
    function getLpPairPrice(address pair) public view returns (bool,uint256) {
        IPair lpPair = IPair(pair);
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        (bool have0,uint256 price0) = _getPrice(address(lpPair.token0()));
        (bool have1,uint256 price1) = _getPrice(address(lpPair.token1()));
        uint256 totalAssets = 0;
        if(have0 && have1) {
            price0 *= reserve0;  
            price1 *= reserve1;
            uint256 tol = price1/20;  
            bool inTol = (price0 < price1+tol && price0 > price1-tol);
            totalAssets = price0+price1;
            uint256 total = lpPair.totalSupply();
            if (total == 0) {
                return (false,0);
            }
            return (inTol,totalAssets/total);
        } else {
            return (false,0);
        }
    }

    function getBRTPrice(address BRTToken) external view returns (bool, uint) {
        (IERC20Upgradeable _lpToken, , , ,) = IBRTVault(BRTToken).vaultInfo();
        require(address(_lpToken) != address(0), "N/A");

        if(address(_lpToken) != address(0)) {
            uint256 BRTTotalSupply = IBRTVault(BRTToken).totalSupply();
            ( , , uint256 lpTokenInPool, ,) = IBRTVault(BRTToken).vaultInfo();
            uint256 BRTRatio = lpTokenInPool * BIPS_DIVISOR / BRTTotalSupply;
            require(BRTRatio >= 10000, "RR<1");

            (bool inTol, uint256 lpPrice) = getLpPairPrice(address(_lpToken));

            uint256 price = 0;
            if(inTol){
                price = lpPrice * BRTRatio / BIPS_DIVISOR;

                return (inTol,price);
            } else {
                return (false,0);
            }
        } else {
            return (false,0);
        }
    }

    function _getPrice(address underlying) internal view returns (bool,uint256) {
        IAggregatorV3 assetsPrice = assetsMap[underlying];
        
        if (address(assetsPrice) != address(0)){
            (, int price,,,) = assetsPrice.latestRoundData();
            uint256 tokenDecimals = decimalsMap[underlying];
            return (true,uint256(price)*(10**tokenDecimals));
        } else {
            return (false,0);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function initialize() public initializer {
        BIPS_DIVISOR = 10000;

        __Ownable_init();
        __UUPSUpgradeable_init();

        // Mainnet
        _setAssetsAggregator(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7, 0x0A77230d17318075983913bC2145DB16C7366156);//wavax
        _setAssetsAggregator(0x63a72806098Bd3D9520cC43356dD78afe5D386D9, 0x3CA13391E9fb38a75330fb28f8cc2eB3D9ceceED);//aave.e
        _setAssetsAggregator(0x50b7545627a5162F82A992c33b87aDc75187B218, 0x2779D32d5166BAaa2B2b658333bA7e6Ec0C65743);//wbtc.e
        _setAssetsAggregator(0xc7198437980c041c805A1EDcbA50c1Ce5db95118, 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a);//usdt.e
        _setAssetsAggregator(0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664, 0xF096872672F44d6EBA71458D74fe67F9a77a23B9);//usdc.e
        //Tesnnet
        // _setAssetsAggregator(0x52B654763F016dAF087d163c9EB6c7F486261019, 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD);//wAVAX
        // _setAssetsAggregator(0xCeaCE9eBaF8AB6CF5324f0725292bf8776BAB22b, 0x7898AcCC83587C3C55116c5230C17a6Cd9C71bad);//usdt
        // _setAssetsAggregator(0x056e7f6c7bf70F25cd3E51F4fc3a153204D6Df5c, 0x7898AcCC83587C3C55116c5230C17a6Cd9C71bad);//usdc
        // _setAssetsAggregator(0xc73aFB31cFfb8BbB1551ad32C1A68eD16c6942Fc, 0x7898AcCC83587C3C55116c5230C17a6Cd9C71bad);//ust   
    }
}
