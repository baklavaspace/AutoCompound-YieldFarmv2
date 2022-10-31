// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBoostedJoeStrategyForLP {
    function vaultInfo() external returns (        
        address lpToken,
        address stakingContract,
        uint256 depositAmount,
        uint256 restakingFarmID,
        bool deposits_enabled,
        bool restaking_enabled);
}