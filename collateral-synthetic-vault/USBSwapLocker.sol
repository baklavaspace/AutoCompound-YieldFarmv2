// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

contract USBSwapLocker is Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    mapping(address => bool) public authorized;

    struct VestingSchedule {
        uint64 startTime;
        uint64 endTime;
        uint128 quantity;
        uint128 vestedQuantity;
    }

    struct VestingSchedules {
        uint256 length;
        mapping(uint256 => VestingSchedule) data;
    }

    uint256 private constant MAX_SWAP_CONTRACTS_SIZE = 100;

    /// @dev whitelist of swap contracts
    mapping(IERC20Upgradeable => EnumerableSetUpgradeable.AddressSet) internal swapContractsPerToken;

    /// @dev vesting schedule of an account
    mapping(address => mapping(IERC20Upgradeable => VestingSchedules)) private accountVestingSchedules;

    /// @dev An account's total escrowed balance per token to save recomputing this for fee extraction purposes
    mapping(address => mapping(IERC20Upgradeable => uint256)) public accountEscrowedBalance;

    /// @dev An account's total vested swap per token
    mapping(address => mapping(IERC20Upgradeable => uint256)) public accountVestedBalance;

    /* ========== EVENTS ========== */
    event VestingEntryCreated(IERC20Upgradeable indexed token, address indexed beneficiary, uint256 startTime, uint256 endTime, uint256 quantity, uint256 index);
    event VestingEntryQueued(uint256 indexed index, IERC20Upgradeable indexed token, address indexed beneficiary, uint256 quantity);
    event Vested(IERC20Upgradeable indexed token, address indexed beneficiary, uint256 vestedQuantity, uint256 index);
    event SwapContractAdded(address indexed swapContract, IERC20Upgradeable indexed token, bool isAdded);

    /* ========== MODIFIERS ========== */

    modifier onlySwapContract(IERC20Upgradeable token) {
        require(swapContractsPerToken[token].contains(msg.sender), 'only swap contract');
        _;
    }

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
    * @notice Add a whitelisted swap contract
    */
    function addSwapContract(IERC20Upgradeable token, address _swapContract) external onlyAuthorized {
        require(
            swapContractsPerToken[token].length() < MAX_SWAP_CONTRACTS_SIZE,
            'swapContracts is too long'
        );
        require(swapContractsPerToken[token].add(_swapContract), '_swapContract is added');

        emit SwapContractAdded(_swapContract, token, true);
    }

    /**
    * @notice Remove a whitelisted swaps contract
    */
    function removeSwapContract(IERC20Upgradeable token, address _swapContract) external onlyAuthorized {
        require(swapContractsPerToken[token].remove(_swapContract), '_swapContract is removed');

        emit SwapContractAdded(_swapContract, token, false);
    }

    function lock(IERC20Upgradeable token, address account, uint256 quantity, uint32 vestingDuration ) external onlySwapContract(token) {
        lockWithStartTime(token, account, quantity, vestingDuration);
    }

    /**
    * @dev vest all completed schedules for multiple tokens
    */
    function vestCompletedSchedulesForMultipleTokens(IERC20Upgradeable[] calldata tokens) external returns (uint256[] memory vestedAmounts) {
        vestedAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            vestedAmounts[i] = vestCompletedSchedules(tokens[i]);
        }
    }

    /**
    * @dev claim multiple tokens for specific vesting schedule,
    *      if schedule has not ended yet, claiming amounts are linear with vesting times
    */
    function vestScheduleForMultipleTokensAtIndices(IERC20Upgradeable[] calldata tokens, uint256[][] calldata indices) external returns (uint256[] memory vestedAmounts) {
        require(tokens.length == indices.length, 'tokens.length != indices.length');
        vestedAmounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            vestedAmounts[i] = vestScheduleAtIndices(tokens[i], indices[i]);
        }
    }

    function lockWithStartTime(IERC20Upgradeable token, address account, uint256 quantity, uint32 vestingDuration) public onlySwapContract(token) {
        require(quantity > 0, '0 quantity');
        require(address(token) != address(0), 'address!=0');

        // transfer token from swap contract to lock contract
        token.safeTransferFrom(msg.sender, address(this), quantity);

        VestingSchedules storage schedules = accountVestingSchedules[account][token];
        uint256 schedulesLength = schedules.length;
        uint256 endTime = block.timestamp + (vestingDuration);

        // append new schedule
        schedules.data[schedulesLength] = VestingSchedule({
            startTime: uint64(block.timestamp),
            endTime: uint64(endTime),
            quantity: uint64(quantity),
            vestedQuantity: 0
        });
        schedules.length = schedulesLength + 1;
        // record total vesting balance of user
        accountEscrowedBalance[account][token] = accountEscrowedBalance[account][token] + (quantity);

        emit VestingEntryCreated(token, account, block.timestamp, endTime, quantity, schedulesLength);
    }

    /**
    * @dev Allow a user to vest all ended schedules
    */
    function vestCompletedSchedules(IERC20Upgradeable token) public returns (uint256) {
        VestingSchedules storage schedules = accountVestingSchedules[msg.sender][token];
        uint256 schedulesLength = schedules.length;

        uint256 totalVesting = 0;
        for (uint256 i = 0; i < schedulesLength; i++) {
            VestingSchedule memory schedule = schedules.data[i];
            if (_getBlockTime() < schedule.endTime) {
            continue;
            }
            uint256 vestQuantity = uint256(schedule.quantity) - (schedule.vestedQuantity);
            if (vestQuantity == 0) {
            continue;
            }
            schedules.data[i].vestedQuantity = schedule.quantity;
            totalVesting = totalVesting + (vestQuantity);

            emit Vested(token, msg.sender, vestQuantity, i);
        }
        _completeVesting(token, totalVesting);

        return totalVesting;
    }

    /**
    * @notice Allow a user to vest with specific schedule
    */
    function vestScheduleAtIndices(IERC20Upgradeable token, uint256[] memory indexes) public returns (uint256) {
        VestingSchedules storage schedules = accountVestingSchedules[msg.sender][token];
        uint256 schedulesLength = schedules.length;
        uint256 totalVesting = 0;
        for (uint256 i = 0; i < indexes.length; i++) {
            require(indexes[i] < schedulesLength, 'invalid schedule index');
            VestingSchedule memory schedule = schedules.data[indexes[i]];
            uint256 vestQuantity = _getVestingQuantity(schedule);
            if (vestQuantity == 0) {
            continue;
            }
            schedules.data[indexes[i]].vestedQuantity = uint128(uint256(schedule.vestedQuantity) + (vestQuantity));

            totalVesting = totalVesting + (vestQuantity);

            emit Vested(token, msg.sender, vestQuantity, indexes[i]);
        }
        _completeVesting(token, totalVesting);
        return totalVesting;
    }

    function vestSchedulesInRange(IERC20Upgradeable token, uint256 startIndex, uint256 endIndex) public returns (uint256) {
        require(startIndex <= endIndex, 'startIndex > endIndex');
        uint256[] memory indexes = new uint256[](endIndex - startIndex + 1);
        for (uint256 index = startIndex; index <= endIndex; index++) {
            indexes[index - startIndex] = index;
        }
        return vestScheduleAtIndices(token, indexes);
    }


    /* ==================== VIEW FUNCTIONS ==================== */

    /**
    * @notice The number of vesting dates in an account's schedule.
    */
    function numVestingSchedules(address account, IERC20Upgradeable token) external view returns (uint256) {
        return accountVestingSchedules[account][token].length;
    }

    /**
    * @dev manually get vesting schedule at index
    */
    function getVestingScheduleAtIndex(address account, IERC20Upgradeable token, uint256 index) external view returns (VestingSchedule memory) {
        return accountVestingSchedules[account][token].data[index];
    }

    /**
    * @dev Get all schedules for an account.
    */
    function getVestingSchedules(address account, IERC20Upgradeable token) external view returns (VestingSchedule[] memory schedules) {
        uint256 schedulesLength = accountVestingSchedules[account][token].length;
        schedules = new VestingSchedule[](schedulesLength);
        for (uint256 i = 0; i < schedulesLength; i++) {
            schedules[i] = accountVestingSchedules[account][token].data[i];
        }
    }

    function getSwapContractsPerToken(IERC20Upgradeable token) external view returns (address[] memory swapContracts) {
        swapContracts = new address[](swapContractsPerToken[token].length());
        for (uint256 i = 0; i < swapContracts.length; i++) {
            swapContracts[i] = swapContractsPerToken[token].at(i);
        }
    }

    /* ==================== INTERNAL FUNCTIONS ==================== */

    function _completeVesting(IERC20Upgradeable token, uint256 totalVesting) internal {
        require(totalVesting != 0, '0 vesting amount');
        require(address(token) != address(0), 'address!=0');
        accountEscrowedBalance[msg.sender][token] = accountEscrowedBalance[msg.sender][token] - (totalVesting);
        accountVestedBalance[msg.sender][token] = accountVestedBalance[msg.sender][token] + (totalVesting);

        token.safeTransfer(msg.sender, totalVesting);
    }

    /**
    * @dev implements linear vesting mechanism
    */
    function _getVestingQuantity(VestingSchedule memory schedule) internal view returns (uint256) {
        if (_getBlockTime() >= uint256(schedule.endTime)) {
            return uint256(schedule.quantity) - (schedule.vestedQuantity);
        }
        if (_getBlockTime() <= uint256(schedule.startTime)) {
            return 0;
        }
        uint256 lockDuration = uint256(schedule.endTime) - (schedule.startTime);
        uint256 passedDuration = _getBlockTime() - uint256(schedule.startTime);
        return (passedDuration*(schedule.quantity)/(lockDuration)) - (schedule.vestedQuantity);
    }

    /**
    * @dev wrap block.timestamp so we can easily mock it
    */
    function _getBlockTime() internal virtual view returns (uint32) {
        return uint32(block.timestamp);
    }

    /* ==================== ONLY OWNER FUNCTIONS ==================== */

    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "0A");
        IERC20Upgradeable(token) .safeTransfer(_to, amount);
    }

    function addAuthorized(address _toAdd) onlyOwner external {
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner external {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize() public initializer {

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}