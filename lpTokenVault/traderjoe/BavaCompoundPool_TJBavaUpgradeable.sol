// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "../BRTERC20Upgradeable.sol";
import "./interfaces/IJoeChef.sol";
import "./interfaces/IJoeRouter02.sol";
import "./interfaces/IJoePair.sol";
import "../interfaces/IBavaMasterFarm.sol";
import "../interfaces/IBavaToken.sol";

// BavaCompoundVault is the compoundVault of BavaMasterFarmer. It will autocompound user LP.
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Bava is sufficiently
// distributed and the community can show to govern itself.

contract BavaCompoundPool_TJBAVAUpgradeable is
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

    IJoeRouter02 public router; // Router
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

    mapping(address => UserInfo) public userInfo; // Info of each user that stakes LP tokens. pid => user address => info
    mapping(address => bool) public authorized;
    VaultInfo public vaultInfo; // Info of vault.

    // Info of each user.
    struct UserInfo {
        uint256 receiptAmount; // user receipt tokens.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint128 blockdelta; // time passed since last deposit
        uint128 lastDepositBlock; // the last block a user deposited at.
    }

    // Info of Vault.
    struct VaultInfo {
        IERC20Upgradeable lpToken; // Address of LP token contract.
        IJoeChef stakingContract; // Dummy data to standartize Vault data structure
        uint256 depositAmount; // Total deposit amount
        uint256 restakingFarmID; // Dummy data to standartize Vault data structure
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
        require(authorized[msg.sender] || owner() == msg.sender, "!Owner");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /********************************* INITIAL SETUP *********************************/
    // Init the vault.
    function initVault(
        address _lpToken,
        address _stakingContract,
        uint256 _restakingFarmID,
        address _rewardToken,
        IERC20Upgradeable[] memory _bonusRewardTokens,
        address _router,
        uint256 _MIN_TOKENS_TO_REINVEST,
        uint256 _DEV_FEE_BIPS,
        uint256 _REINVEST_REWARD_BIPS
    ) external onlyOwner {
        require(address(_lpToken) != address(0), "0Add");
        // require(address(_stakingContract) != address(0), "0Add");    // Set to 0x0 address since no restaking

        vaultInfo.lpToken = IERC20Upgradeable(_lpToken);
        vaultInfo.stakingContract = IJoeChef(_stakingContract);
        vaultInfo.depositAmount = 0;
        vaultInfo.restakingFarmID = _restakingFarmID;
        vaultInfo.deposits_enabled = true;
        vaultInfo.restaking_enabled = false;

        rewardToken = IERC20Upgradeable(_rewardToken);
        bonusRewardTokens = _bonusRewardTokens;
        router = IJoeRouter02(_router);
        MIN_TOKENS_TO_REINVEST = _MIN_TOKENS_TO_REINVEST;
        DEV_FEE_BIPS = _DEV_FEE_BIPS;
        REINVEST_REWARD_BIPS = _REINVEST_REWARD_BIPS;
    }

    /**
     * @notice Approve tokens for use in Strategy, Restricted to avoid griefing attacks
     */
    function setAllowances(uint256 _amount) external onlyOwner {
        revert("setAllowances::deprecated");
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

    function claimReward() external {
        updatePool();
        _harvest(msg.sender);
    }

    // Deposit LP tokens to BavaMasterFarmer for $Bava allocation.
    function deposit(uint256 _amount) external {
        require(_amount > 0, "#<0");
        require(vaultInfo.deposits_enabled == true, "False");

        UserInfo storage user = userInfo[msg.sender];
        UserInfo storage devr = userInfo[devaddr];

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

        emit Deposit(msg.sender, bavaPid, _amount);
        user.lastDepositBlock = uint128(block.number);
    }

    // Withdraw LP tokens from BavaMasterFarmer. argument "_amount" is receipt amount.
    function withdraw(uint256 _amount) external {
        UserInfo storage user = userInfo[msg.sender];
        require(user.receiptAmount >= _amount, "#>Stake");
        uint256 depositTokenAmount = getDepositTokensForShares(_amount);
        require(vaultInfo.depositAmount >= depositTokenAmount, "#>Bal");
        updatePool();
        _harvest(msg.sender);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        if (depositTokenAmount > 0) {
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
        revert("reinvest::archived");
    }

    function liquidateCollateral(address userAccount, uint256 amount)
        external
        onlyAuthorized
    {
        require(amount > 0, "#<0");
        _liquidateCollateral(userAccount, amount);
    }

    /**************************************** Internal FUNCTIONS ****************************************/
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
                uint256 lockAmount = (pending * (PERCENT_LOCK_BONUS_REWARD)) /
                    (100);
                Bava.lock(account, lockAmount);

                emit SendBavaReward(account, bavaPid, pending, lockAmount);
            }
            user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);
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

    // View function to see pending 3rd party reward. Ignore bonus reward view to minimize possible code error due to 3rd party contract changes
    function checkReward() public pure returns (uint256) {
        uint256 pendingJoe = 0;
        return (pendingJoe);
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
    function emergencyWithdrawDepositTokens() external onlyOwner {}

    // Update the given vault's Bava restaking contract. Can only be called by the owner.
    function setVaultInfo(
        address _stakingContract,
        uint256 _restakingFarmID,
        address _rewardToken,
        IERC20Upgradeable[] memory _bonusRewardTokens,
        bool _withUpdate
    ) external onlyOwner {
        require(address(_stakingContract) != address(0), "0Addr");
        if (_withUpdate) {
            updatePool();
        }
        vaultInfo.stakingContract = IJoeChef(_stakingContract);
        vaultInfo.restakingFarmID = _restakingFarmID;
        rewardToken = IERC20Upgradeable(_rewardToken);
        bonusRewardTokens = _bonusRewardTokens;
    }

    function setBavaMasterFarm(address _BavaMasterFarm, uint256 _bavaPid)
        external
        onlyOwner
    {
        BavaMasterFarm = IBAVAMasterFarm(_BavaMasterFarm);
        bavaPid = _bavaPid;
    }

    function addrUpdate(address _devaddr, address _liqaddr) public onlyOwner {
        devaddr = _devaddr;
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

    function setStage(
        uint256[] memory _blockStarts,
        uint256[] memory _blockEnds
    ) public onlyAuthorized {
        blockDeltaStartStage = _blockStarts;
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

    /*********************** Autocompound & Liquidate Strategy ******************
     * Swap all reward tokens to WAVAX and swap half/half WAVAX token to both LP token0 & token1, Add liquidity to LP token
     ****************************************/
    // Liquidate user collateral when user LP token value lower than user borrowed fund.
    function _liquidateCollateral(address userAccount, uint256 amount) private {
        UserInfo storage user = userInfo[userAccount];
        uint256 depositTokenAmount = getDepositTokensForShares(amount);
        updatePool();
        _harvest(userAccount);
        (, , , , uint256 accBavaPerShare) = BavaMasterFarm.poolInfo(bavaPid);

        require(vaultInfo.depositAmount >= depositTokenAmount, "#>Bal");
        _burn(msg.sender, amount);
        // Reordered from Sushi function to prevent risk of reentrancy
        user.receiptAmount -= amount;
        user.rewardDebt = (user.receiptAmount * (accBavaPerShare)) / (1e12);
        vaultInfo.depositAmount -= depositTokenAmount;
        vaultInfo.lpToken.safeTransfer(address(liqaddr), depositTokenAmount);

        emit Liquidate(userAccount, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     * @param symbol: BRT2LPSYMBOL
     *************************************************************/
    function initialize(
        string memory name_,
        string memory symbol_,
        address _IBava,
        address _BavaMasterFarm,
        uint256 _bavaPid,
        address _devaddr,
        address _liqaddr,
        uint256 _userDepFee,
        uint256 _newlock,
        uint256[] memory _blockDeltaStartStage,
        uint256[] memory _blockDeltaEndStage,
        uint256[] memory _userFeeStage
    ) public initializer {
        Bava = IBavaToken(_IBava);
        BavaMasterFarm = IBAVAMasterFarm(_BavaMasterFarm);
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
