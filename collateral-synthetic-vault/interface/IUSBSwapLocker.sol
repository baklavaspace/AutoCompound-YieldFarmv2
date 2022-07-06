// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IUSBSwapLocker {
  struct VestingSchedule {
    uint64 startTime;
    uint64 endTime;
    uint128 quantity;
    uint128 vestedQuantity;
  }

  /**
   * @dev queue a vesting schedule starting from now
   */
  function lock(
    IERC20Upgradeable token,
    address account,
    uint256 amount,
    uint32 vestingDuration
  ) external;

  /**
   * @dev queue a vesting schedule
   */
  function lockWithStartTime(
    IERC20Upgradeable token,
    address account,
    uint256 quantity,
    uint256 startTime,
    uint32 vestingDuration
  ) external;

  /**
   * @dev vest all completed schedules for multiple tokens
   */
  function vestCompletedSchedulesForMultipleTokens(IERC20Upgradeable[] calldata tokens)
    external
    returns (uint256[] memory vestedAmounts);

  /**
   * @dev claim multiple tokens for specific vesting schedule,
   *      if schedule has not ended yet, claiming amounts are linear with vesting times
   */
  function vestScheduleForMultipleTokensAtIndices(
    IERC20Upgradeable[] calldata tokens,
    uint256[][] calldata indices
  ) external returns (uint256[] memory vestedAmounts);

  /**
   * @dev for all completed schedule, claim token
   */
  function vestCompletedSchedules(IERC20Upgradeable token) external returns (uint256);

  /**
   * @dev claim token for specific vesting schedule,
   * @dev if schedule has not ended yet, claiming amount is linear with vesting times
   */
  function vestScheduleAtIndices(IERC20Upgradeable token, uint256[] calldata indexes)
    external
    returns (uint256);

  /**
   * @dev claim token for specific vesting schedule from startIndex to endIndex
   */
  function vestSchedulesInRange(
    IERC20Upgradeable token,
    uint256 startIndex,
    uint256 endIndex
  ) external returns (uint256);

  /**
   * @dev length of vesting schedules array
   */
  function numVestingSchedules(address account, IERC20Upgradeable token) external view returns (uint256);

  /**
   * @dev get detailed of each vesting schedule
   */
  function getVestingScheduleAtIndex(
    address account,
    IERC20Upgradeable token,
    uint256 index
  ) external view returns (VestingSchedule memory);

  /**
   * @dev get vesting shedules array
   */
  function getVestingSchedules(address account, IERC20Upgradeable token)
    external
    view
    returns (VestingSchedule[] memory schedules);
}