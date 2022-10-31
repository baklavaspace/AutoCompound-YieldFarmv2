// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../BRTERC20Upgradeable.sol";
import "./interfaces/IRouter.sol";
import "../interfaces/IBavaMasterFarm.sol";
import "../interfaces/IBavaToken.sol";
import "./interfaces/IStakingRewards.sol";

// BavaCompoundVault is the compoundVault of BavaMasterFarmer. It will autocompound user LP.
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Bava is sufficiently
// distributed and the community can show to govern itself.

contract BavaCompoundVault_PngUpgradeable is
    Initializable,
    UUPSUpgradeable,
    BRTERC20Upgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable private WAVAX; // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
    uint256 public MIN_TOKENS_TO_REINVEST;
    uint256 public DEV_FEE_BIPS;
    uint256 public REINVEST_REWARD_BIPS;
    uint256 internal BIPS_DIVISOR;

    IRouter public router; // Router
    IBAVAMasterFarm public BavaMasterFarm; // MasterFarm to mint BAVA token.
    IBavaToken public Bava; // The Bava TOKEN!
    uint256 public bavaPid; // BAVA Master Farm Vault Id
    address public devaddr; // Developer/Employee address.
    address public liqaddr; // Liquidate address

    IERC20Upgradeable public rewardToken;
    IERC20Upgradeable[] public bonusRewardTokens;
    uint256[] public blockDeltaStartStage;
    uint256[] public blockDeltaEndStage;
    uint256[] public userFeeStage;
    uint256 public userDepFee;
    uint256 public PERCENT_LOCK_BONUS_REWARD; // lock xx% of bounus reward in 3 year

    VaultInfo public vaultInfo; // Info of each vault.
    mapping(address => UserInfo) public userInfo; // Info of each user that stakes LP tokens. pid => user address => info
    mapping(address => bool) public authorized;

    // Info of each user.
    struct UserInfo {
        uint256 receiptAmount; // user receipt tokens.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 blockdelta; // time passed since withdrawals
        uint256 lastDepositBlock; // the last block a user deposited at.
    }

    // Info of vault.
    struct VaultInfo {
        IERC20Upgradeable lpToken; // Address of LP token contract.
        IStakingRewards stakingContract; // PNG Staking contract
        uint256 depositAmount; // Total deposit amount
        uint256 restakingFarmID; // Dummy data to standardize Vault data structure 
        bool deposits_enabled;
        bool restaking_enabled;
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 devAmount
    );
    event SendBavaReward(
        address indexed user,
        uint256 indexed pid,
        uint256 amount,
        uint256 lockAmount
    );
    event DepositsEnabled(bool newValue);
    event RestakingEnabled(bool newValue);
    event Liquidate(address indexed userAccount, uint256 amount);

    modifier onlyAuthorized() {
        require(authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /******************************************* INITIAL SETUP START ******************************************/
    // Init the vault. Can only be called by the owner. Support LP from pangolin png staking.
    function initVault(
        IERC20Upgradeable _lpToken,
        IStakingRewards _stakingPglContract,
        IERC20Upgradeable _rewardToken,
        IERC20Upgradeable[] memory _bonusRewardTokens,
        IRouter _router,
        uint256 _MIN_TOKENS_TO_REINVEST,
        uint256 _DEV_FEE_BIPS,
        uint256 _REINVEST_REWARD_BIPS
    ) external onlyOwner {
        require(address(_lpToken) != address(0), "0Addr");
        require(address(_stakingPglContract) != address(0), "0Addr");

        vaultInfo.lpToken = _lpToken;
        vaultInfo.stakingContract = _stakingPglContract;
        vaultInfo.depositAmount = 0;
        vaultInfo.restakingFarmID = 0; 
        vaultInfo.deposits_enabled = true;
        vaultInfo.restaking_enabled = true;

        rewardToken = _rewardToken;
        bonusRewardTokens = _bonusRewardTokens;
        router = _router;
        MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
        DEV_FEE_BIPS = _DEV_FEE_BIPS;
        REINVEST_REWARD_BIPS = _REINVEST_REWARD_BIPS;
    }

    /**
     * @notice Approve tokens for use in Strategy, Restricted to avoid griefing attacks
     */
    function setAllowances(uint256 _amount) external onlyOwner {
        if (address(vaultInfo.stakingContract) != address(0)) {
            vaultInfo.lpToken.approve(
                address(vaultInfo.stakingContract),
                _amount
            );
        }

        if (address(router) != address(0)) {
            WAVAX.approve(address(router), _amount);
            vaultInfo.lpToken.approve(address(router), _amount);
            if (address(vaultInfo.lpToken) != address(rewardToken)) {
                rewardToken.approve(address(router), _amount);
            }
            uint256 rewardLength = bonusRewardTokens.length;
            for (uint256 i; i < rewardLength; i++) {
                bonusRewardTokens[i].approve(address(router), _amount);
            }
        }
    }

    /****************************************** FARMING CORE FUNCTION ******************************************/
    // Update reward variables of the given vault to be up-to-date.
    function updatePool() public {
        (, , , uint256 lastRewardBlock, ) = BavaMasterFarm.poolInfo(bavaPid);
        if (block.number <= lastRewardBlock) {
            return;
        }
        BavaMasterFarm.updatePool(bavaPid);
    }

    function claimReward() public {
        updatePool();
        _harvest(msg.sender);
    }

    // lock 95% of reward
    function _harvest(address account) private {
        UserInfo storage user = userInfo[account];
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);
        if (user.receiptAmount > 0) {
            uint256 pending = (user.receiptAmount * (accBavaPerShare)) /
                (1e12) -
                (user.rewardDebt);
            uint256 masterBal = Bava.balanceOf(address(this));

            if (pending > masterBal) {
                pending = masterBal;
            }

            if (pending > 0) {
                Bava.transfer(account, pending);
                uint256 lockAmount = 0;
                lockAmount = (pending * (PERCENT_LOCK_BONUS_REWARD)) / (100);
                Bava.lock(account, lockAmount);

                emit SendBavaReward(account, bavaPid, pending, lockAmount);
            }
            user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);
        }
    }

    // Deposit LP tokens to BavaMasterFarmer for $Bava allocation.
    function deposit(uint256 _amount) public {
        require(_amount > 0, "#<0");
        require(vaultInfo.deposits_enabled == true, "False");

        UserInfo storage user = userInfo[msg.sender];
        UserInfo storage devr = userInfo[devaddr];

        uint256 estimatedTotalReward = checkReward();
        if (estimatedTotalReward > MIN_TOKENS_TO_REINVEST) {
            _reinvest();
        }

        updatePool();
        _harvest(msg.sender);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        vaultInfo.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        uint256 vaultReceiptAmount = getSharesForDepositTokens(_amount);
        vaultInfo.depositAmount += _amount;

        uint256 userReceiptAmount = vaultReceiptAmount -
            ((vaultReceiptAmount * userDepFee) / 10000);
        uint256 devrReceiptAmount = vaultReceiptAmount - userReceiptAmount;

        user.receiptAmount += userReceiptAmount;
        user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);
        devr.receiptAmount += devrReceiptAmount;
        devr.rewardDebt = (devr.receiptAmount * (accBavaPerShare)) / (1e12);
        _mint(msg.sender, userReceiptAmount);
        _mint(devaddr, devrReceiptAmount);

        if (vaultInfo.restaking_enabled == true) {
            uint256 restakeAmount = vaultInfo.lpToken.balanceOf(address(this));
            vaultInfo.stakingContract.stake(restakeAmount);
        }

        emit Deposit(msg.sender, bavaPid, _amount);
        user.lastDepositBlock = block.number;
    }

    // Withdraw LP tokens from BavaMasterFarmer. argument "_amount" is receipt amount.
    function withdraw(uint256 _amount) public {
        UserInfo storage user = userInfo[msg.sender];
        require(user.receiptAmount >= _amount, "#>Stake");
        uint256 depositTokenAmount = getDepositTokensForShares(_amount);
        require(vaultInfo.depositAmount >= depositTokenAmount, "#>Bal");
        updatePool();
        _harvest(msg.sender);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        if (depositTokenAmount > 0) {
            _withdrawDepositTokens(depositTokenAmount);
            user.receiptAmount = user.receiptAmount - (_amount);
            _burn(msg.sender, _amount);

            user.blockdelta = uint128(block.number - user.lastDepositBlock);
            vaultInfo.depositAmount -= depositTokenAmount;
            user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);

            if (
                user.blockdelta == blockDeltaStartStage[0] ||
                block.number == user.lastDepositBlock
            ) {
                //25% fee for withdrawals of LP tokens in the same block this is to prevent abuse from flashloans
                _withdrawLPTokens(depositTokenAmount, userFeeStage[0]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[1] &&
                user.blockdelta <= blockDeltaEndStage[0]
            ) {
                //8% fee if a user deposits and withdraws in under between same block and 59 minutes.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[1]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[2] &&
                user.blockdelta <= blockDeltaEndStage[1]
            ) {
                //4% fee if a user deposits and withdraws after 1 hour but before 1 day.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[2]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[3] &&
                user.blockdelta <= blockDeltaEndStage[2]
            ) {
                //2% fee if a user deposits and withdraws between after 1 day but before 3 days.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[3]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[4] &&
                user.blockdelta <= blockDeltaEndStage[3]
            ) {
                //1% fee if a user deposits and withdraws after 3 days but before 5 days.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[4]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[5] &&
                user.blockdelta <= blockDeltaEndStage[4]
            ) {
                //0.5% fee if a user deposits and withdraws after 5 days but before 2 weeks.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[5]);
            } else if (
                user.blockdelta >= blockDeltaStartStage[6] &&
                user.blockdelta <= blockDeltaEndStage[5]
            ) {
                //0.25% fee if a user deposits and withdraws after 2 weeks.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[6]);
            } else if (user.blockdelta > blockDeltaStartStage[7]) {
                //0.1% fee if a user deposits and withdraws after 4 weeks.
                _withdrawLPTokens(depositTokenAmount, userFeeStage[7]);
            }
            emit Withdraw(msg.sender, bavaPid, depositTokenAmount);
        }
    }

    // EMERGENCY ONLY. Withdraw without caring about rewards.
    // This has the same 25% fee as same block withdrawals and ucer receipt record set to 0 to prevent abuse of thisfunction.
    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];
        uint256 userBRTAmount = balanceOf(msg.sender);
        uint256 depositTokenAmount = getDepositTokensForShares(userBRTAmount);

        require(vaultInfo.depositAmount >= depositTokenAmount, "#>Bal"); //  vault.lpToken.balanceOf(address(this))
        _withdrawDepositTokens(depositTokenAmount);
        _burn(msg.sender, userBRTAmount);
        // Reordered from Sushi function to prevent risk of reentrancy
        uint256 amountToSend = (depositTokenAmount * (75)) / (100);
        uint256 devToSend = depositTokenAmount - amountToSend; //25% penalty
        user.receiptAmount = 0;
        user.rewardDebt = 0;
        vaultInfo.depositAmount -= depositTokenAmount;
        vaultInfo.lpToken.safeTransfer(address(msg.sender), amountToSend);
        vaultInfo.lpToken.safeTransfer(address(devaddr), devToSend);

        emit EmergencyWithdraw(msg.sender, bavaPid, amountToSend, devToSend);
    }

    function reinvest() external {
        uint256 estimatedTotalReward = checkReward();
        require(estimatedTotalReward >= MIN_TOKENS_TO_REINVEST, "#<MinInvest");

        uint256 liquidity = _reinvest();
        if (vaultInfo.restaking_enabled == true) {
            vaultInfo.stakingContract.stake(liquidity);
        }
    }

    function liquidateCollateral(address userAccount, uint256 amount)
        external
        onlyAuthorized
    {
        require(amount > 0, "#<0");
        _liquidateCollateral(userAccount, amount);
    }

    // Withdraw LP token from this farm
    function _withdrawLPTokens(
        uint256 _depositTokenAmount,
        uint256 _userFeeStage
    ) private {
        uint256 userWithdrawFee = (_depositTokenAmount * _userFeeStage) /
            BIPS_DIVISOR;
        vaultInfo.lpToken.safeTransfer(address(msg.sender), userWithdrawFee);
        vaultInfo.lpToken.safeTransfer(
            address(devaddr),
            _depositTokenAmount - userWithdrawFee
        );
    }

    /**************************************** Internal restaking FUNCTIONS ****************************************/
    // Withdraw LP token to 3rd party restaking farm
    function _withdrawDepositTokens(uint256 amount) private {
        require(amount > 0, "#<0");
        uint256 depositAmount = vaultInfo.stakingContract.balanceOf(
            address(this)
        );

        if (depositAmount > 0) {
            if (depositAmount >= amount) {
                vaultInfo.stakingContract.withdraw(amount);
            } else {
                vaultInfo.stakingContract.withdraw(depositAmount);
            }
        }
    }

    // Claim LP restaking reward from 3rd party restaking contract
    function _getReinvestReward() private {
        uint256 pendingRewardAmount = vaultInfo.stakingContract.earned(
            address(this)
        );
        if (pendingRewardAmount > 0) {
            vaultInfo.stakingContract.getReward();
        }
    }

    /**************************************** VIEW FUNCTIONS ****************************************/
    /**
     * @notice Calculate receipt tokens for a given amount of deposit tokens
     * @dev Could return zero shares for very low amounts of deposit tokens
     * @param amount deposit tokens
     */
    function getSharesForDepositTokens(uint256 amount)
        public
        view
        returns (uint256)
    {
        if (totalSupply() * vaultInfo.depositAmount == 0) {
            return amount;
        }
        return ((amount * totalSupply()) / vaultInfo.depositAmount);
    }

    /**
     * @notice Calculate deposit tokens for a given amount of receipt tokens
     * @param amount receipt tokens
     * @return deposit tokens
     */
    function getDepositTokensForShares(uint256 amount)
        public
        view
        returns (uint256)
    {
        if (totalSupply() * vaultInfo.depositAmount == 0) {
            return 0;
        }
        return ((amount * vaultInfo.depositAmount) / totalSupply());
    }

    // View function to see pending Bavas on frontend.
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        (
            ,
            ,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 accBavaPerShare
        ) = BavaMasterFarm.poolInfo(bavaPid);
        uint256 lpSupply = totalSupply();

        if (block.number > lastRewardBlock && lpSupply > 0) {
            uint256 BavaForFarmer;
            (, BavaForFarmer, , , ) = BavaMasterFarm.getPoolReward(
                lastRewardBlock,
                block.number,
                allocPoint
            );
            accBavaPerShare =
                accBavaPerShare +
                ((BavaForFarmer * (1e12)) / (lpSupply));
        }
        return
            (user.receiptAmount * (accBavaPerShare)) /
            (1e12) -
            (user.rewardDebt);
    }

    // View function to see pending 3rd party reward. Ignore bonus reward view to reduce code error due to 3rd party contract changes
    function checkReward() public view returns (uint256) {
        uint256 pendingRewardAmount = vaultInfo.stakingContract.earned(
            address(this)
        );
        uint256 rewardBalance = rewardToken.balanceOf(address(this));

        return (pendingRewardAmount + rewardBalance);
    }

    /**************************************** ONLY OWNER FUNCTIONS ****************************************/
    // Rescue any token function, just in case if any user not able to withdraw token from the smart contract.
    function rescueDeployedFunds(
        address token,
        uint256 amount,
        address _to
    ) external onlyOwner {
        require(_to != address(0), "0Addr");
        IERC20Upgradeable(token).safeTransfer(_to, amount);
    }

    // Emergency withdraw LP token from 3rd party restaking contract
    function emergencyWithdrawDepositTokens(bool disableDeposits)
        external
        onlyOwner
    {
        vaultInfo.stakingContract.exit();
        setFeeBips(0, 0);

        if (vaultInfo.deposits_enabled == true && disableDeposits == true) {
            updateDepositsEnabled(false);
        }
    }

    // Update the given vault's Bava restaking contract. Can only be called by the owner.
    function setVaultInfo(
        IStakingRewards _stakingPglContract,
        IERC20Upgradeable _rewardToken,
        IERC20Upgradeable[] memory _bonusRewardTokens,
        bool _withUpdate
    ) external onlyOwner {
        require(address(_stakingPglContract) != address(0), "0Addr");
        if (_withUpdate) {
            updatePool();
        }
        vaultInfo.stakingContract = _stakingPglContract;
        rewardToken = _rewardToken;
        bonusRewardTokens = _bonusRewardTokens;
    }

    function setBavaMasterFarm(
        IBAVAMasterFarm _BavaMasterFarm,
        uint256 _bavaPid
    ) external onlyOwner {
        BavaMasterFarm = _BavaMasterFarm;
        bavaPid = _bavaPid;
    }

    function devAddrUpdate(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }

    function liqAddrUpdate(address _liqaddr) public onlyOwner {
        liqaddr = _liqaddr;
    }

    function addAuthorized(address _toAdd) public onlyOwner {
        authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) public onlyOwner {
        require(_toRemove != msg.sender);
        authorized[_toRemove] = false;
    }

    // @notice Enable/disable deposits
    function updateDepositsEnabled(bool newValue) public onlyOwner {
        require(vaultInfo.deposits_enabled != newValue);
        vaultInfo.deposits_enabled = newValue;
        emit DepositsEnabled(newValue);
    }

    function updateRestakingEnabled(bool newValue) public onlyOwner {
        require(vaultInfo.restaking_enabled != newValue);
        vaultInfo.restaking_enabled = newValue;
        emit RestakingEnabled(newValue);
    }

    /**************************************** ONLY AUTHORIZED FUNCTIONS ****************************************/
    // Update % lock for general users & percent for other roles
    function percentUpdate(uint256 _newlock) public onlyAuthorized {
        PERCENT_LOCK_BONUS_REWARD = _newlock;
    }

    function setStageStarts(uint256[] memory _blockStarts)
        public
        onlyAuthorized
    {
        blockDeltaStartStage = _blockStarts;
    }

    function setStageEnds(uint256[] memory _blockEnds) public onlyAuthorized {
        blockDeltaEndStage = _blockEnds;
    }

    function setUserFeeStage(uint256[] memory _userFees) public onlyAuthorized {
        userFeeStage = _userFees;
    }

    function setDepositFee(uint256 _usrDepFees) public onlyAuthorized {
        userDepFee = _usrDepFees;
    }

    function setMinReinvestToken(uint256 _MIN_TOKENS_TO_REINVEST)
        public
        onlyAuthorized
    {
        MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
    }

    function setFeeBips(uint256 _DEV_FEE_BIPS, uint256 _REINVEST_REWARD_BIPS)
        public
        onlyAuthorized
    {
        DEV_FEE_BIPS = _DEV_FEE_BIPS;
        REINVEST_REWARD_BIPS = _REINVEST_REWARD_BIPS;
    }

    /*********************** Autocompound Strategy ******************
     * Swap all reward tokens to WAVAX and swap half/half WAVAX token to both LP  token0 & token1, Add liquidity to LP token
     ****************************************/
    function _reinvest() private returns (uint256) {
        _getReinvestReward();
        uint256 liquidity;

        if (vaultInfo.restaking_enabled == true) {
            liquidity = _convertRewardIntoWAVAX();
            if (liquidity > 0) {
                vaultInfo.depositAmount += liquidity;
            }
        }
        return liquidity;
    }

    function _convertRewardIntoWAVAX() private returns (uint256) {
        uint256 pathLength = 2;
        address[] memory path = new address[](pathLength);
        uint256 avaxAmount;

        path[0] = address(rewardToken);
        path[1] = address(WAVAX);
        uint256 rewardAmount = rewardToken.balanceOf(address(this));
        if (rewardAmount > 0) {
            _convertExactTokentoToken(
                path,
                (rewardAmount * (DEV_FEE_BIPS + REINVEST_REWARD_BIPS)) /
                    BIPS_DIVISOR
            );
            avaxAmount = WAVAX.balanceOf(address(this));
            uint256 devFee = (avaxAmount * (DEV_FEE_BIPS)) /
                (DEV_FEE_BIPS + REINVEST_REWARD_BIPS);
            if (devFee > 0) {
                WAVAX.safeTransfer(devaddr, devFee);
            }
            uint256 reinvestFee = avaxAmount - devFee;
            if (reinvestFee > 0) {
                WAVAX.safeTransfer(msg.sender, reinvestFee);
            }
        }

        uint256 remainingRewardAmount = rewardToken.balanceOf(address(this));
        return (remainingRewardAmount);
    }

    // Liquidate user collateral when user LP token value lower than user borrowed fund.
    function _liquidateCollateral(address userAccount, uint256 amount) private {
        UserInfo storage user = userInfo[userAccount];
        uint256 depositTokenAmount = getDepositTokensForShares(amount);
        updatePool();
        _harvest(userAccount);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        require(vaultInfo.depositAmount >= depositTokenAmount, "#>Bal");
        _burn(msg.sender, amount);
        _withdrawDepositTokens(depositTokenAmount);
        // Reordered from Sushi function to prevent risk of reentrancy
        user.receiptAmount -= amount;
        user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);
        vaultInfo.depositAmount -= depositTokenAmount;
        vaultInfo.lpToken.safeTransfer(address(liqaddr), depositTokenAmount);

        emit Liquidate(userAccount, amount);
    }

    function _convertExactTokentoToken(address[] memory path, uint256 amount)
        private
        returns (uint256)
    {
        uint256[] memory amountsOutToken = router.getAmountsOut(amount, path);
        uint256 amountOutToken = amountsOutToken[amountsOutToken.length - 1];
        uint256[] memory amountOut = router.swapExactTokensForTokens(
            amount,
            amountOutToken,
            path,
            address(this),
            block.timestamp + 1200
        );
        uint256 swapAmount = amountOut[amountOut.length - 1];

        return swapAmount;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(
        string memory name_,
        string memory symbol_,
        IBavaToken _IBava,
        IBAVAMasterFarm _BavaMasterFarm,
        uint256 _bavaPid,
        address _devaddr,
        address _liqaddr,
        uint256 _userDepFee,
        uint256 _newlock,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage
    ) public initializer {
        Bava = _IBava;
        BavaMasterFarm = _BavaMasterFarm;
        bavaPid = _bavaPid;
        devaddr = _devaddr;
        liqaddr = _liqaddr;
        userDepFee = _userDepFee;
        PERCENT_LOCK_BONUS_REWARD = _newlock;
        blockDeltaStartStage = _blockDeltaStartStage;
        blockDeltaEndStage = _blockDeltaEndStage;
        userFeeStage = _userFeeStage;

        WAVAX = IERC20Upgradeable(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7); // 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7 in mainnet
        BIPS_DIVISOR = 10000;

        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}