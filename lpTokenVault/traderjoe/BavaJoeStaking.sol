// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title YY Staking
 * @author Yield Yak
 * @notice BavaStaking is a contract that allows ERC20 dpeosits and receives rewards from token balances which may be
 * transferred in without an additional function call. The contract is based on StableJoeStaking from Trader Joe.
 * Users deposit X and receive a share of what has been sent based on their participation of the total deposits.
 * It is similar to a MasterChef, but we allow for claiming of different reward tokens.
 * Every time `updateReward(token)` is called, We distribute the balance of that tokens as rewards to users that are
 * currently staking inside this contract, and they can claim it using `withdraw(0)`
 */
contract BavaJoeStaking is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @notice Info of each user
    struct UserInfo {
        uint256 amount;
        mapping(IERC20Upgradeable => uint256) rewardDebt;
        /**
         * @notice We do some fancy math here. Basically, any point in time, the amount of deposit tokens
         * entitled to a user but is pending to be distributed is:
         *
         *   pending reward = (user.amount * accRewardPerShare) - user.rewardDebt[token]
         *
         * Whenever a user deposits or withdraws. Here's what happens:
         *   1. accRewardPerShare (and `lastRewardBalance`) gets updated
         *   2. User receives the pending reward sent to his/her address
         *   3. User's `amount` gets updated
         *   4. User's `rewardDebt[token]` gets updated
         */
    }

    /// @notice Farm deposit token
    IERC20Upgradeable public depositToken;

    /// @dev Internal balance of depositToken, this gets updated on user deposits / withdrawals
    /// this allows to reward users with depositToken
    uint256 public internalBalance;

    /// @notice Array of tokens that users can claim
    IERC20Upgradeable[] public rewardTokens;
    mapping(IERC20Upgradeable => bool) public isRewardToken;

    /// @notice Last reward balance of `token`
    mapping(IERC20Upgradeable => uint256) public lastRewardBalance;

    address public feeCollector;

    /// @notice The deposit fee, scaled to `DEPOSIT_FEE_PERCENT_PRECISION`
    uint256 public depositFeePercent;

    /// @dev The precision of `depositFeePercent`
    uint256 constant internal DEPOSIT_FEE_PERCENT_PRECISION = 10000;

    /// @notice Accumulated `token` rewards per share, scaled to `ACC_REWARD_PER_SHARE_PRECISION`
    mapping(IERC20Upgradeable => uint256) public accRewardPerShare;
    /// @notice The precision of `accRewardPerShare`
    uint256 public ACC_REWARD_PER_SHARE_PRECISION;

    /// @dev Info of each user that stakes
    mapping(address => UserInfo) private userInfo;

    /// @notice Emitted when a user deposits
    event Deposit(address indexed user, uint256 amount, uint256 fee);

    /// @notice Emitted when feeCollector changes the fee collector
    event FeeCollectorChanged(address newFeeCollector, address oldFeeCollector);

    /// @notice Emitted when owner changes the deposit fee percentage
    event DepositFeeChanged(uint256 newFee, uint256 oldFee);

    /// @notice Emitted when a user withdraws
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Emitted when a user claims reward
    event ClaimReward(address indexed user, address indexed rewardToken, uint256 amount);

    /// @notice Emitted when a user emergency withdraws
    event EmergencyWithdraw(address indexed user, uint256 amount);

    /// @notice Emitted when owner adds a token to the reward tokens list
    event RewardTokenAdded(address token);

    /// @notice Emitted when owner removes a token from the reward tokens list
    event RewardTokenRemoved(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Deposit for reward token allocation
     * @param amount The amount of depositToken to deposit
     */
    function deposit(uint256 amount) external {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Deposit on behalf of another account
     * @param account Account to deposit for
     * @param amount The amount of depositToken to deposit
     */
    function depositFor(address account, uint256 amount) external {
        _deposit(account, amount);
    }

    function _deposit(address _account, uint256 _amount) internal {
        UserInfo storage user = userInfo[_account];

        uint256 _fee = _amount * (depositFeePercent) / (DEPOSIT_FEE_PERCENT_PRECISION);
        uint256 _amountMinusFee = _amount - (_fee);

        uint256 _previousAmount = user.amount;
        uint256 _newAmount = user.amount + (_amountMinusFee);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20Upgradeable _token = rewardTokens[i];
            updateReward(_token);

            uint256 _previousRewardDebt = user.rewardDebt[_token];
            user.rewardDebt[_token] = _newAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION;

            if (_previousAmount != 0) {
                uint256 _pending = _previousAmount * accRewardPerShare[_token] / ACC_REWARD_PER_SHARE_PRECISION - _previousRewardDebt;
                if (_pending != 0) {
                    safeTokenTransfer(_token, _account, _pending);
                    emit ClaimReward(_account, address(_token), _pending);
                }
            }
        }

        internalBalance = internalBalance + _amountMinusFee;
        depositToken.safeTransferFrom(msg.sender, feeCollector, _fee);
        depositToken.safeTransferFrom(msg.sender, address(this), _amountMinusFee);
        emit Deposit(_account, _amountMinusFee, _fee);
    }

    /**
     * @notice Get user info
     * @param _user The address of the user
     * @param _rewardToken The address of the reward token
     * @return The amount of depositToken user has deposited
     * @return The reward debt for the chosen token
     */
    function getUserInfo(address _user, IERC20Upgradeable _rewardToken) external view returns (uint256, uint256) {
        UserInfo storage user = userInfo[_user];
        return (user.amount, user.rewardDebt[_rewardToken]);
    }

    /**
     * @notice Get the number of reward tokens
     * @return The length of the array
     */
    function rewardTokensLength() external view returns (uint256) {
        return rewardTokens.length;
    }

    /**
     * @notice Add a reward token
     * @param _rewardToken The address of the reward token
     */
    function addRewardToken(IERC20Upgradeable _rewardToken) external onlyOwner {
        require(
            !isRewardToken[_rewardToken] && address(_rewardToken) != address(0),
            "BavaStaking::rewardToken can't be added"
        );
        require(rewardTokens.length < 25, "BavaStaking::list of rewardTokens too big");
        rewardTokens.push(_rewardToken);
        isRewardToken[_rewardToken] = true;
        updateReward(_rewardToken);
        emit RewardTokenAdded(address(_rewardToken));
    }

    /**
     * @notice Remove a reward token
     * @param _rewardToken The address of the reward token
     */
    function removeRewardToken(IERC20Upgradeable _rewardToken) external onlyOwner {
        require(isRewardToken[_rewardToken], "BavaStaking::rewardToken can't be removed");
        updateReward(_rewardToken);
        isRewardToken[_rewardToken] = false;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            if (rewardTokens[i] == _rewardToken) {
                rewardTokens[i] = rewardTokens[_len - 1];
                rewardTokens.pop();
                break;
            }
        }
        emit RewardTokenRemoved(address(_rewardToken));
    }

    /**
     * @notice Set the deposit fee percent
     * @param _depositFeePercent The new deposit fee percent
     */
    function setDepositFeePercent(uint256 _depositFeePercent) external onlyOwner {
        require(_depositFeePercent <= DEPOSIT_FEE_PERCENT_PRECISION, "BavaStaking::deposit fee too high");
        emit DepositFeeChanged(_depositFeePercent, depositFeePercent);
        depositFeePercent = _depositFeePercent;
    }

    /**
     * @notice View function to see pending reward token on frontend
     * @param _user The address of the user
     * @param _token The address of the token
     * @return `_user`'s pending reward token
     */
    function pendingReward(address _user, IERC20Upgradeable _token) external view returns (uint256) {
        if (!isRewardToken[_token]) {
            return 0;
        }

        UserInfo storage user = userInfo[_user];
        uint256 _totalDepositTokens = internalBalance;
        uint256 _accRewardTokenPerShare = accRewardPerShare[_token];

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == depositToken ? _currRewardBalance - (_totalDepositTokens) : _currRewardBalance;

        if (_rewardBalance != lastRewardBalance[_token] && _totalDepositTokens != 0) {
            uint256 _accruedReward = _rewardBalance - (lastRewardBalance[_token]);
            _accRewardTokenPerShare = _accRewardTokenPerShare + (_accruedReward * (ACC_REWARD_PER_SHARE_PRECISION) / (_totalDepositTokens));
        }
        return
            user.amount * (_accRewardTokenPerShare) / (ACC_REWARD_PER_SHARE_PRECISION) - (user.rewardDebt[_token]);
    }

    /**
     * @notice Withdraw and harvest the rewards
     * @param _amount The amount to withdraw
     */
    function withdraw(uint256 _amount) external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 _previousAmount = user.amount;
        require(_amount <= _previousAmount, "BavaStaking::withdraw amount exceeds balance");
        uint256 _newAmount = user.amount - (_amount);
        user.amount = _newAmount;

        uint256 _len = rewardTokens.length;
        if (_previousAmount != 0) {
            for (uint256 i; i < _len; i++) {
                IERC20Upgradeable _token = rewardTokens[i];
                updateReward(_token);

                uint256 _pending = _previousAmount * (accRewardPerShare[_token]) / (ACC_REWARD_PER_SHARE_PRECISION) - (user.rewardDebt[_token]);
                user.rewardDebt[_token] = _newAmount * (accRewardPerShare[_token]) / (ACC_REWARD_PER_SHARE_PRECISION);

                if (_pending != 0) {
                    safeTokenTransfer(_token, msg.sender, _pending);
                    emit ClaimReward(msg.sender, address(_token), _pending);
                }
            }
        }

        internalBalance = internalBalance - (_amount);
        depositToken.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @notice Withdraw without caring about rewards. EMERGENCY ONLY
     */
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];

        uint256 _amount = user.amount;
        user.amount = 0;
        uint256 _len = rewardTokens.length;
        for (uint256 i; i < _len; i++) {
            IERC20Upgradeable _token = rewardTokens[i];
            user.rewardDebt[_token] = 0;
        }
        internalBalance = internalBalance - (_amount);
        depositToken.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _amount);
    }

    /**
     * @notice Update reward variables
     * @param _token The address of the reward token
     * @dev Needs to be called before any deposit or withdrawal
     */
    function updateReward(IERC20Upgradeable _token) public {
        require(isRewardToken[_token], "BavaStaking::wrong reward token");

        uint256 _totalDepositTokens = internalBalance;

        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == depositToken ? _currRewardBalance - (_totalDepositTokens) : _currRewardBalance;

        // Did BavaStaking receive any token
        if (_rewardBalance == lastRewardBalance[_token] || _totalDepositTokens == 0) {
            return;
        }

        uint256 _accruedReward = _rewardBalance - (lastRewardBalance[_token]);

        accRewardPerShare[_token] = accRewardPerShare[_token] + (_accruedReward * (ACC_REWARD_PER_SHARE_PRECISION) / (_totalDepositTokens));
        lastRewardBalance[_token] = _rewardBalance;
    }

    /**
     * @notice Update fee collector
     * @dev Restricted to existing fee collector
     * @param _newFeeCollector The address of the new fee collector
     */
    function updateFeeCollector(address _newFeeCollector) external {
        require(msg.sender == feeCollector, "BavaStaking::only feeCollector");
        emit FeeCollectorChanged(_newFeeCollector, feeCollector);
        feeCollector = _newFeeCollector;
    }

    /**
     * @notice Safe token transfer function, just in case if rounding error
     * causes pool to not have enough reward tokens
     * @param _token The address of then token to transfer
     * @param _to The address that will receive `_amount` `rewardToken`
     * @param _amount The amount to send to `_to`
     */
    function safeTokenTransfer(
        IERC20Upgradeable _token,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _currRewardBalance = _token.balanceOf(address(this));
        uint256 _rewardBalance = _token == depositToken ? _currRewardBalance - (internalBalance) : _currRewardBalance;

        if (_amount > _rewardBalance) {
            lastRewardBalance[_token] = lastRewardBalance[_token] - (_rewardBalance);
            _token.safeTransfer(_to, _rewardBalance);
        } else {
            lastRewardBalance[_token] = lastRewardBalance[_token] - (_amount);
            _token.safeTransfer(_to, _amount);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(
        IERC20Upgradeable _depositToken,
        IERC20Upgradeable _rewardToken,
        address _feeCollector
    ) public initializer {
        require(address(_depositToken) != address(0), "BavaStaking::depositToken can't be address(0)");
        require(address(_rewardToken) != address(0), "BavaStaking::rewardToken can't be address(0)");
        require(_feeCollector != address(0), "BavaStaking::feeCollector can't be address(0)");

        depositToken = _depositToken;
        feeCollector = _feeCollector;

        isRewardToken[_rewardToken] = true;
        rewardTokens.push(_rewardToken);
        ACC_REWARD_PER_SHARE_PRECISION = 1e24;

        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}

