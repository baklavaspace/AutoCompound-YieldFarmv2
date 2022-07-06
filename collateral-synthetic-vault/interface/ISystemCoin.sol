// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ISystemCoin is IERC20Upgradeable {
    function decimals() external view returns (uint256);
    function mint(address,uint256) external;
    function burn(address,uint256) external;
}