// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IBRTVault.sol";
import "./interfaces/IBavaToken.sol";

// BavaMasterFarmer is the master of Bava. He can make Bava and he is a fair guy.
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Bava is sufficiently
// distributed and the community can show to govern itself.

contract BavaMasterFarmerUpgradeable is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    using SafeERC20Upgradeable for IERC20Upgradeable;

    IBavaToken internal Bava;                   // The Bava token
    address internal devAddr;                   // Developer/Employee address
	address internal futureTreasuryAddr;	    // Future Treasury address
	address internal advisorAddr;	            // Advisor Address
	address internal founderAddr;	            // Founder Reward
    uint256 internal REWARD_PER_BLOCK;          // Bava tokens created per block
    uint256[] internal REWARD_MULTIPLIER;       // Bonus muliplier for early Bava makers
    uint256[] internal HALVING_AT_BLOCK;        // Init in initFarm function
    uint256 internal FINISH_BONUS_AT_BLOCK;     // The block number bonus multiplier finish(x1)
    uint256 internal MAX_UINT;                  // Max uint256

    uint256 internal START_BLOCK;             // The block number when Bava mining starts
    uint256 internal PERCENT_FOR_DEV;         // Dev bounties + Employees
	uint256 internal PERCENT_FOR_FT;          // Future Treasury fund
	uint256 internal PERCENT_FOR_ADR;         // Advisor fund
	uint256 internal PERCENT_FOR_FOUNDERS;    // founders fund
    uint256 internal totalAllocPoint;         // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 internal poolLength;

    mapping(uint256 => PoolInfo) public poolInfo;       // Info of each pool
    mapping(address => uint256) public poolId1;         // poolId1 count from 1, subtraction 1 before using with poolInfo
    mapping(address => bool) private _authorized;       // Authorized address for onlyAuthorized functions

    // Info of each pool.
    struct PoolInfo {
        IERC20Upgradeable lpToken;      // Address of LP token contract.
        IBRTVault vaultAddress;         // Address of autocompound vault contract.
        uint256 allocPoint;             // How many allocation points assigned to this pool. Bavas to distribute per block.
        uint256 lastRewardBlock;        // Last block number that Bavas distribution occurs.
        uint256 accBavaPerShare;        // Accumulated Bavas per share, times 1e12. See below.
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 devAmount);
    event SendBavaReward(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockAmount);
    event DepositsEnabled(uint pid, bool newValue);

    modifier onlyAuthorized() {
        require(_authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /********************************* INITIAL SETUP *********************************/
    // Init the Farm multiplier reward.
    function initFarm(uint256[] memory _newMulReward, uint256 _halvingAfterBlock) external onlyOwner {
        REWARD_MULTIPLIER = _newMulReward;
        for (uint256 i = 0; i < REWARD_MULTIPLIER.length - 1; i++) {
            uint256 halvingAtBlock = _halvingAfterBlock*(i + 1)+(START_BLOCK);
            HALVING_AT_BLOCK.push(halvingAtBlock);
        }
        FINISH_BONUS_AT_BLOCK = _halvingAfterBlock*(REWARD_MULTIPLIER.length - 1)+(START_BLOCK);
        HALVING_AT_BLOCK.push(type(uint256).max);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolLength;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.vaultAddress.totalSupply();       // User lp token total supply not included compound lp reward token
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 BavaForDev;
        uint256 BavaForFarmer;
		uint256 BavaForFT;
		uint256 BavaForAdr;
		uint256 BavaForFounders;
        (BavaForDev, BavaForFarmer, BavaForFT, BavaForAdr, BavaForFounders) = getPoolReward(pool.lastRewardBlock, block.number, pool.allocPoint);
        Bava.mint(address(pool.vaultAddress), BavaForFarmer);
        pool.accBavaPerShare = pool.accBavaPerShare+(BavaForFarmer*(1e12)/(lpSupply));
        pool.lastRewardBlock = block.number;
        if (BavaForDev > 0) {
            Bava.mint(address(devAddr), BavaForDev);
            //Dev fund has xx% locked during the starting bonus period. After which locked funds drip out linearly each block over 3 years.
            if(block.number <= Bava.lockFromBlock()) {
                Bava.lock(address(devAddr), BavaForDev*(75)/(100));
            }
        }
		if (BavaForFT > 0) {
            Bava.mint(futureTreasuryAddr, BavaForFT);
			//FT + Partnership fund has only xx% locked over time as most of it is needed early on for incentives and listings. The locked amount will drip out linearly each block after the bonus period.
            if(block.number <= Bava.lockFromBlock()) {
                Bava.lock(address(futureTreasuryAddr), BavaForFT*(45)/(100));
            }
        }
		if (BavaForAdr > 0) {
            Bava.mint(advisorAddr, BavaForAdr);
			//Advisor Fund has xx% locked during bonus period and then drips out linearly over 3 years.
            if(block.number <= Bava.lockFromBlock()) {
                Bava.lock(address(advisorAddr), BavaForAdr*(85)/(100));
            }
        }
		if (BavaForFounders > 0) {
            Bava.mint(founderAddr, BavaForFounders);
			//The Founders reward has xx% of their funds locked during the bonus period which then drip out linearly per block over 3 years.
            if(block.number <= Bava.lockFromBlock()) {
                Bava.lock(address(founderAddr), BavaForFounders*(95)/(100));
            }
        }
    }

    /********************************* ONLY View FUNCTIONS *********************************/
    // [20, 30, 40, 50, 60, 70, 80, 99999999]
    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        uint256 result = 0;
        if (_from < START_BLOCK) return 0;

        for (uint256 i = 0; i < HALVING_AT_BLOCK.length; i++) {
            uint256 endBlock = HALVING_AT_BLOCK[i];

            if (_to <= endBlock) {
                uint256 m = (_to-_from)*(REWARD_MULTIPLIER[i]);
                return result+(m);
            }

            if (_from < endBlock) {
                uint256 m = (endBlock-_from)*(REWARD_MULTIPLIER[i]);
                _from = endBlock;
                result = result+(m);
            }
        }
        return result;
    }

    function getPoolReward(uint256 _from, uint256 _to, uint256 _allocPoint) public view returns (uint256 forDev, uint256 forFarmer, uint256 forFT, uint256 forAdr, uint256 forFounders) {
        uint256 multiplier = getMultiplier(_from, _to);
        uint256 amount = multiplier*(REWARD_PER_BLOCK)*(_allocPoint)/(totalAllocPoint);
        uint256 BavaCanMint = Bava.cap()-(Bava.totalSupply());

        if (BavaCanMint < amount) {
            forDev = 0;
			forFarmer = BavaCanMint;
			forFT = 0;
			forAdr = 0;
			forFounders = 0;
        }
        else {
            forDev = amount*(PERCENT_FOR_DEV)/(100000);
			forFarmer = amount;
			forFT = amount*(PERCENT_FOR_FT)/(100);
			forAdr = amount*(PERCENT_FOR_ADR)/(10000);
			forFounders = amount*(PERCENT_FOR_FOUNDERS)/(100000);
        }
    }

    function getBava() external view returns (address) {
        return address(Bava);
    }

    function getDevAddr() external view returns (address) {
        return address(devAddr);
    }

    function getFTAddr() external view returns (address) {
        return address(futureTreasuryAddr);
    }

    function getadvisorAddr() external view returns (address) {
        return address(advisorAddr);
    }

    function getfounderAddr() external view returns (address) {
        return address(founderAddr);
    }

    function getRewardPerBlock() external view returns (uint256) {
        return REWARD_PER_BLOCK;
    }

    function getRewardMultiplier() external view returns (uint256[] memory) {
        return REWARD_MULTIPLIER;
    }

    function getHalvingAtBlock() external view returns (uint256[] memory) {
        return HALVING_AT_BLOCK;
    }

    function getFinishBonusBlock() external view returns (uint256) {
        return FINISH_BONUS_AT_BLOCK;
    }

    function getStartBlock() external view returns (uint256) {
        return START_BLOCK;
    }

    function getPercentAllParties() external view returns (uint256, uint256, uint256, uint256) {
        return (PERCENT_FOR_DEV, PERCENT_FOR_FT, PERCENT_FOR_ADR, PERCENT_FOR_FOUNDERS);
    }

    function getTotalAllocPoint() external view returns (uint256) {
        return totalAllocPoint;
    }

    function getPoolLength() external view returns (uint256) {
        return poolLength;
    }

    /********************************* ONLY AUTHORIZED FUNCTIONS *********************************/
    // Update address.
    function devAddrUpdate(address _devaddr) external onlyOwner {
        require(address(_devaddr) != address(0), 'Address!=0');
        devAddr = _devaddr;
    }

    function ftAddrUpdate(address _newFT) external onlyOwner {
        require(address(_newFT) != address(0), 'Address!=0');
        futureTreasuryAddr = _newFT;
    }

    function adrAddrUpdate(address _newAdr) external onlyOwner {
        require(address(_newAdr) != address(0), 'Address!=0');
        advisorAddr = _newAdr;
    }

    function founderAddrUpdate(address _newFounder) external onlyOwner {
        require(address(_newFounder) != address(0), 'Address!=0');
        founderAddr = _newFounder;
    }

    // Update % lock for general users & percent for other roles
    function percentUpdate(uint _newdev, uint _newft, uint _newadr, uint _newfounder) external onlyAuthorized {
       PERCENT_FOR_DEV = _newdev;
       PERCENT_FOR_FT = _newft;
       PERCENT_FOR_ADR = _newadr;
       PERCENT_FOR_FOUNDERS = _newfounder;
    }

    // Update Finish Bonus Block
    function bonusFinishUpdate(uint256 _newFinish) external onlyAuthorized {
        FINISH_BONUS_AT_BLOCK = _newFinish;
    }
    
    // Update Halving At Block
    function halvingUpdate(uint256[] memory _newHalving) external onlyAuthorized {
        HALVING_AT_BLOCK = _newHalving;
    }
    
    // Update Reward Per Block
    function rewardUpdate(uint256 _newReward) external onlyAuthorized {
       REWARD_PER_BLOCK = _newReward;
    }
    
    // Update Rewards Mulitplier Array
    function rewardMulUpdate(uint256[] memory _newMulReward) external onlyAuthorized {
       REWARD_MULTIPLIER = _newMulReward;
    }
    
    // Update START_BLOCK
    function starblockUpdate(uint _newstarblock) external onlyAuthorized {
       START_BLOCK = _newstarblock;
    }
    
    /********************************* ONLY OWNER FUNCTIONS *********************************/
    // Add a new lp to the vault. Can only be called by the owner.
    function add(uint256 _allocPoint, IERC20Upgradeable _lpToken, IBRTVault _vaultAddress, bool _withUpdate) external onlyOwner {
        require(address(_vaultAddress) != address(0) && address(_lpToken) != address(0), 'Address!=0');
        require(poolId1[address(_vaultAddress)] == 0, "VaultAddress is in list");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > START_BLOCK ? block.number : START_BLOCK;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolId1[address(_vaultAddress)] = poolLength + 1;
        poolInfo[poolLength] = (PoolInfo({
            lpToken: _lpToken,
            vaultAddress: _vaultAddress,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accBavaPerShare: 0
        }));
        poolLength++;
    }

    function updatePoolInfo(uint256 _pid, IERC20Upgradeable _lpToken, IBRTVault _vaultAddress) external onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        require(address(_vaultAddress) != address(0) && address(_lpToken) != address(0), 'Address!=0');
        // require(poolId1[address(_vaultAddress)] == 0, "VaultAddress is in list");

        pool.vaultAddress = _vaultAddress;
        pool.lpToken = _lpToken;
    }

    // Update the given pool's Bava allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint-(poolInfo[_pid].allocPoint)+(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Rescue any token function, just in case if any user not able to withdraw token from the smart contract.
    function rescueDeployedFunds(address token, uint256 amount, address _to) external onlyOwner {
        require(_to != address(0), "send to the zero address");
        IERC20Upgradeable(token).safeTransfer(_to, amount);
    }

    function addAuthorized(address _toAdd) onlyOwner external {
        _authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner external {
        require(_toRemove != msg.sender);
        _authorized[_toRemove] = false;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize (
        IBavaToken _IBava,
        uint256 _rewardPerBlock, 
        uint256 _startBlock,
        address _devaddr,
		address _futureTreasuryaddr,
		address _advisoraddr,
		address _founderaddr,
        uint256 _newdev, 
        uint256 _newft, 
        uint256 _newadr, 
        uint256 _newfounder
    ) public initializer {
        Bava = _IBava;
        REWARD_PER_BLOCK = _rewardPerBlock;
        START_BLOCK = _startBlock;
        devAddr = _devaddr;
        futureTreasuryAddr = _futureTreasuryaddr;
        advisorAddr = _advisoraddr;
        founderAddr = _founderaddr;
        PERCENT_FOR_DEV = _newdev;
        PERCENT_FOR_FT = _newft;
        PERCENT_FOR_ADR = _newadr;
        PERCENT_FOR_FOUNDERS = _newfounder;
        MAX_UINT = type(uint256).max;

        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}