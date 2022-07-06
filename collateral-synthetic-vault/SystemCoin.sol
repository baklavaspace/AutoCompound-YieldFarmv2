// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

contract SystemCoin is Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable {
    // --- Auth ---
    mapping (address => uint256) public authorizedAccounts;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Add auth to an account
     * @param account Account to add auth to
     */
    function addAuthorization(address account) external onlyOwner notZeroAddress(account) {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    /**
     * @notice Remove auth from an account
     * @param account Account to remove auth from
     */
    function removeAuthorization(address account) external onlyOwner notZeroAddress(account) {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    /**
    * @notice Checks whether msg.sender can call an authed function
    **/
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "Coin/account-not-authorized");
        _;
    }
    modifier notZeroAddress(address inputAddress) {
        require(inputAddress != address(0), "Coin : input zero address");
        _;
    }

    // --- ERC20 Data ---
    // The name of this coin
    string  public name;
    // The symbol of this coin
    string  public symbol;
    // The version of this Coin contract
    string  public version;
    // The number of decimals that this coin has
    uint8   public decimals;
    // The total supply of this coin
    uint256 public totalSupply;

    // Mapping of coin balances
    mapping (address => uint256) public balanceOf;
    // Mapping of allowances
    mapping (address => mapping (address => uint256)) public allowance;
    // Mapping of nonces used for permits
    mapping (address => uint256) public nonces;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event Approval(address indexed src, address indexed guy, uint256 amount);
    event Transfer(address indexed src, address indexed dst, uint256 amount);

    // --- Token ---
    /*
    * @notice Transfer coins to another address
    * @param dst The address to transfer coins to
    * @param amount The amount of coins to transfer
    */
    function transfer(address dst, uint256 amount) whenNotPaused external returns (bool) {
        return transferFrom(msg.sender, dst, amount);
    }
    /*
    * @notice Transfer coins from a source address to a destination address (if allowed)
    * @param src The address from which to transfer coins
    * @param dst The address that will receive the coins
    * @param amount The amount of coins to transfer
    */
    function transferFrom(address src, address dst, uint256 amount) whenNotPaused public returns (bool) {
        require(dst != address(0), "Coin/null-dst");
        require(dst != address(this), "Coin/dst-cannot-be-this-contract");
        require(balanceOf[src] >= amount, "Coin/insufficient-balance");
        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= amount, "Coin/insufficient-allowance");
            allowance[src][msg.sender] = allowance[src][msg.sender] - amount;
        }
        balanceOf[src] = balanceOf[src] - amount;
        balanceOf[dst] = balanceOf[dst] + amount;
        emit Transfer(src, dst, amount);
        return true;
    }
    /*
    * @notice Mint new coins
    * @param usr The address for which to mint coins
    * @param amount The amount of coins to mint
    */
    function mint(address usr, uint256 amount) whenNotPaused external isAuthorized notZeroAddress(usr) {
        balanceOf[usr] = balanceOf[usr] + amount;
        totalSupply    = totalSupply + amount;
        emit Transfer(address(0), usr, amount);
    }
    /*
    * @notice Burn coins from an address
    * @param usr The address that will have its coins burned
    * @param amount The amount of coins to burn
    */
    function burn(address usr, uint256 amount) whenNotPaused external {
        require(balanceOf[usr] >= amount, "Coin/insufficient-balance");
        if (usr != msg.sender && allowance[usr][msg.sender] != type(uint256).max) {
            require(allowance[usr][msg.sender] >= amount, "Coin/insufficient-allowance");
            allowance[usr][msg.sender] = allowance[usr][msg.sender] - amount;
        }
        balanceOf[usr] = balanceOf[usr] - amount;
        totalSupply    = totalSupply - amount;
        emit Transfer(usr, address(0), amount);
    }
    /*
    * @notice Change the transfer/burn allowance that another address has on your behalf
    * @param usr The address whose allowance is changed
    * @param amount The new total allowance for the usr
    */
    function approve(address usr, uint256 amount) whenNotPaused external notZeroAddress(usr) returns (bool)  {
        allowance[msg.sender][usr] = amount;
        emit Approval(msg.sender, usr, amount);
        return true;
    }

    function pause() external whenNotPaused onlyOwner {
        _pause();
    }

    function unpause() external whenPaused onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize(string memory name_, string memory symbol_) public initializer {

        version = "1";
        decimals = 18;
        authorizedAccounts[msg.sender] = 1;
        name          = name_;
        symbol        = symbol_;

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
        emit AddAuthorization(msg.sender);
    }
}