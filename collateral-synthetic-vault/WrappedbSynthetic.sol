// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

contract WrappedbSynthetic is Initializable, UUPSUpgradeable, PausableUpgradeable, OwnableUpgradeable, IERC20Upgradeable {

    using SafeERC20Upgradeable for IERC20Upgradeable;

    string private _name;
    string private _symbol;
    uint256 private _totalSupply;
    uint256 private BIPS_DIVISOR;
    uint256 private _tokenStockSplitIndex;
    uint256 private _totalSupplySplitIndex;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => uint256) private _userStockSplitIndex;
    mapping(uint256 => uint256) private _stockSplitRatio;
    mapping(address => bool) private _authorized;
    
    event UpdateStockSplitRatio(uint256 newStockSplitRatio);
    event UpdateBalance(address user, uint256 userStockSplitIndex);
    event EmergencyUpdateStockSplitRatio(uint256 stockSplitIndex, uint256 newStockSplitRatio);

    modifier onlyAuthorized() {
        require(_authorized[msg.sender] || owner() == msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**********************
     * @dev view functions
    ***********************/
    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 3;
    }

    function tokenStockSplitIndex() external view returns (uint256) {
        return _tokenStockSplitIndex;
    }

    function stockSplitRatio(uint256 index) external view returns (uint256) {
        return _stockSplitRatio[index];
    }

    function userStockSplitIndex(address user) external view returns (uint256) {
        return _userStockSplitIndex[user];
    }
    
    function authorized(address user) external view returns (bool) {
        return _authorized[user];
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        uint userBalance;
        if(_userStockSplitIndex[account] != _tokenStockSplitIndex) {
            userBalance = _balances[account] * _stockSplitRatio[_tokenStockSplitIndex] / _stockSplitRatio[_userStockSplitIndex[account]];
        } else {
            userBalance = _balances[account];
        }
        return userBalance;
    }

    function allowance(address user, address spender) public view override returns (uint256) {
        return _allowances[user][spender];
    }

    /***************************
     * @dev ERC20-Core functions
     **************************/
    function transfer(address to, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        _transfer(sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        _approve(sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) public onlyAuthorized {
        _mint(to, amount);
    }

    function burn(uint256 amount) public {
        _burn(_msgSender(), amount);
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        address sender = _msgSender();
        _approve(sender, spender, _allowances[sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        address sender = _msgSender();
        uint256 currentAllowance = _allowances[sender][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
         _approve(sender, spender, currentAllowance - subtractedValue);
        
        return true;
    }

    function updateBalance() external {
        require(_userStockSplitIndex[msg.sender] !=_tokenStockSplitIndex, "==Index");
        _updateBalance(msg.sender);
    }

    /********************************
     * @dev ERC20-internal functions
     *******************************/
    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");

        _balances[from] = (fromBalance - amount);
        _balances[to] += amount;

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");

        _balances[account] = (accountBalance - amount);
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function _approve(address sender, address spender, uint256 amount) internal {
        require(sender != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[sender][spender] = amount;
        emit Approval(sender, spender, amount);
    }

    function _spendAllowance(address sender, address spender, uint256 amount) internal {
        uint256 currentAllowance = allowance(sender, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            _approve(sender, spender, currentAllowance - amount);
        }
    }

    function _updateBalance(address user) internal {
        uint256 userSplitIndex =  _userStockSplitIndex[user];
        uint256 accountBalance = _balances[user];

        _userStockSplitIndex[user] = _tokenStockSplitIndex;
        _balances[user] = accountBalance * _stockSplitRatio[_tokenStockSplitIndex] / _stockSplitRatio[userSplitIndex];
        emit UpdateBalance(user, _balances[user]);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal whenNotPaused {
        if (_userStockSplitIndex[from] != _tokenStockSplitIndex) {
            _updateBalance(from);
        }
        if (_userStockSplitIndex[to] != _tokenStockSplitIndex) {
            _updateBalance(to);
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal {}

    /********************************
     * @dev onlyOwner functions
     *******************************/
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addAuthorized(address _toAdd) onlyOwner external {
        _authorized[_toAdd] = true;
    }

    function removeAuthorized(address _toRemove) onlyOwner external {
        require(_toRemove != msg.sender);
        _authorized[_toRemove] = false;
    }

    // Before calling this fucntion, need to pause token transfer. Only for stock Split event, not going to work stock Merge event
    // @param i.e: index1, stockSplit 1 to 2, param newStockSplitRatio will be 2, index2 stockSplit 1 to 3, param newStockSplitRatio will be 3.
    function updateStockSplitRatio(uint256 newStockSplitRatio) external whenPaused onlyOwner {
        require(newStockSplitRatio != 0, "!=0");
        uint256 currentSplitRatio = _stockSplitRatio[_tokenStockSplitIndex];
        _tokenStockSplitIndex += 1;
        _stockSplitRatio[_tokenStockSplitIndex] = currentSplitRatio * newStockSplitRatio;
        _totalSupply = _totalSupply * newStockSplitRatio;

        emit UpdateStockSplitRatio(_stockSplitRatio[_tokenStockSplitIndex]);
    }

    // @dev Emergency function only if updateStockSplitRatio() update a wrong value.
    function emergencyUpdateLatestStockSplitRatio(uint256 newStockSplitRatio) external onlyOwner {
        require(newStockSplitRatio != 0, "!=0");
        uint256 currentStockSplitRatio = _stockSplitRatio[_tokenStockSplitIndex];
        _stockSplitRatio[_tokenStockSplitIndex] = newStockSplitRatio;
        _totalSupply = _totalSupply * newStockSplitRatio / currentStockSplitRatio;

        emit EmergencyUpdateStockSplitRatio(_tokenStockSplitIndex, _stockSplitRatio[_tokenStockSplitIndex]);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**************************************************************
     * @dev Initialize smart contract functions - only called once
     *************************************************************/
    function initialize() public initializer {

        _name = "Wrapped Baklava BTC Token";
        _symbol = "bBTC";
        _totalSupply = 0;
        _tokenStockSplitIndex = 0;
        _stockSplitRatio[0] = 1000;
        BIPS_DIVISOR = 1000;

        __Pausable_init();
        __Ownable_init();
        __UUPSUpgradeable_init();
    }
}