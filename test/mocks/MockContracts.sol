// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @dev Mock ERC20 token for testing purposes
 * @notice Provides additional functionality for testing scenarios
 */
contract MockERC20 is ERC20 {
    uint8 private _decimals;
    
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function faucet() external {
        _mint(msg.sender, 1000 * 10**decimals());
    }
}

/**
 * @title MockManager
 * @dev Mock manager contract for testing LiquidityPool in isolation
 */
contract MockManager {
    mapping(address => bool) public pools;
    
    function addPool(address pool) external {
        pools[pool] = true;
    }
    
    function isValidPool(address pool) external view returns (bool) {
        return pools[pool];
    }
    
    function handleDeposit(address pool, address user, uint256 amount) external {
        // Mock implementation
    }
    
    function handleWithdrawal(address pool, address user, uint256 amount) external {
        // Mock implementation
    }
}

/**
 * @title MockPoolEscrow
 * @dev Mock escrow contract for testing LiquidityPool in isolation
 */
contract MockPoolEscrow {
    IERC20 public asset;
    address public manager;
    address public pool;
    
    mapping(address => uint256) public balances;
    
    function initialize(address _asset, address _manager, address _spvAddress) external {
        asset = IERC20(_asset);
        manager = _manager;
    }
    
    function setPool(address _pool) external {
        pool = _pool;
    }
    
    function receiveDeposit(address user, uint256 amount) external {
        balances[user] += amount;
        asset.transferFrom(msg.sender, address(this), amount);
    }
    
    function releaseFunds(address recipient, uint256 amount) external {
        require(balances[recipient] >= amount, "Insufficient balance");
        balances[recipient] -= amount;
        asset.transfer(recipient, amount);
    }
    
    function getBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

/**
 * @title MockAccessManager
 * @dev Mock access manager for testing contracts that depend on AccessManager
 */
contract MockAccessManager {
    mapping(bytes32 => mapping(address => bool)) public roles;
    
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    bool public paused;
    
    constructor(address admin) {
        roles[DEFAULT_ADMIN_ROLE][admin] = true;
    }
    
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    
    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }
    
    function revokeRole(bytes32 role, address account) external {
        roles[role][account] = false;
    }
    
    function emergencyPause() external {
        paused = true;
    }
    
    function unpause() external {
        paused = false;
    }
}

/**
 * @title MockUpgradeable
 * @dev Mock upgradeable contract for testing upgrade scenarios
 */
contract MockUpgradeable {
    address public implementation;
    bool public upgraded;
    
    function upgradeTo(address newImplementation) external {
        implementation = newImplementation;
        upgraded = true;
    }
    
    function getImplementation() external view returns (address) {
        return implementation;
    }
}
