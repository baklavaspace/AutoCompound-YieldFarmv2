// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface ISynthetic is IERC20Upgradeable {
    function mint(address to, uint tokens) external;
    function burn(uint tokens) external;
    function decimals() external view returns (uint256);
    function tokenStockSplitIndex() external view returns (uint);
    function stockSplitRatio(uint256 index) external view returns (uint);
    function userStockSplitIndex(address user) external view returns (uint);
}