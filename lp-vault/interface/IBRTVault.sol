// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IBRTVault {
    function vaultInfo() external view returns (
        IERC20Upgradeable lpToken,
        uint256 depositAmount,
        bool deposits_enabled
    );

    function totalSupply() external view returns(uint256 totalSupply);

    function vaultRestakingInfo() external view returns (
        address restakingContract,
        uint256 restakingFarmID
    );
}