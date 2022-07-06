// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDSOracle {
    function getPriceInfo(address token) external view returns (bool,uint256);

    function getBRTPrice(address token) external view returns (bool,uint256);

    function getPrices(address[]calldata assets) external view returns (uint256[]memory);
}