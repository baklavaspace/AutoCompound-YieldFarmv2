// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IBRT is IERC20Upgradeable {

    function mint(address to) external returns (uint liquidity);
    function liquidateCollateral(address userAccount, uint256 amount) external;
    function poolInfo() external view returns (
        IERC20Upgradeable lpToken,
        uint256 depositAmount,
        bool deposits_enabled
    );
    function userInfo(address account) external view returns (
        uint256 receiptAmount,
        uint256 rewardDebt,
        uint256 rewardDebtAtBlock,
		uint256 lastWithdrawBlock,
		uint256 firstDepositBlock,
		uint256 blockdelta,
		uint256 lastDepositBlock
    );
}