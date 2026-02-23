// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title PironTimelockController
 * @dev Enforces a 72-hour delay between scheduling and executing UUPS upgrades.
 *      The guardian can pause all upgrades; only TIMELOCK_ADMIN can unpause.
 *      Operations expire after a 7-day grace period.
 */
contract PironTimelockController is AccessControl, ReentrancyGuard {

    // ==================== CONSTANTS ====================
    
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    uint256 public constant UPGRADE_DELAY = 72 hours;
    uint256 public constant GRACE_PERIOD = 7 days;

    // ==================== STATE ====================
    
    mapping(bytes32 => uint256) public timestamps;
    mapping(bytes32 => bool) public executed;
    mapping(bytes32 => bool) public cancelled;
    bool public upgradesPaused;
    address public guardian;

    // ==================== EVENTS ====================
    
    event UpgradeScheduled(
        bytes32 indexed id,
        address indexed target,
        address indexed newImplementation,
        uint256 executeTime
    );
    
    event UpgradeExecuted(
        bytes32 indexed id,
        address indexed target,
        address indexed newImplementation
    );
    
    event UpgradeCancelled(bytes32 indexed id);
    event UpgradesPaused(address indexed guardian);
    event UpgradesUnpaused(address indexed admin);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    // ==================== ERRORS ====================
    
    error InvalidTarget();
    error InvalidImplementation();
    error OperationNotScheduled();
    error OperationNotReady();
    error OperationExpired();
    error OperationAlreadyExecuted();
    error OperationCancelled();
    error UpgradesPausedByGuardian();
    error UnauthorizedGuardian();
    error InvalidDelay();

    // ==================== MODIFIERS ====================
    
    modifier onlyGuardian() {
        require(msg.sender == guardian, "Unauthorized guardian");
        _;
    }
    
    modifier whenUpgradesNotPaused() {
        require(!upgradesPaused, "Upgrades paused by guardian");
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address admin,
        address proposer,
        address executor,
        address canceller,
        address _guardian
    ) {
        require(admin != address(0), "Invalid admin");
        require(proposer != address(0), "Invalid proposer");
        require(executor != address(0), "Invalid executor");
        require(canceller != address(0), "Invalid canceller");
        require(_guardian != address(0), "Invalid guardian");
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(TIMELOCK_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, proposer);
        _grantRole(EXECUTOR_ROLE, executor);
        _grantRole(CANCELLER_ROLE, canceller);
        
        guardian = _guardian;
        upgradesPaused = false;
    }
    
    // ==================== SCHEDULING ====================

    /// @dev Schedules a UUPS upgrade with a 72-hour delay. Returns the operation id.
    function scheduleUpgrade(
        address target,
        address newImplementation
    ) external onlyRole(PROPOSER_ROLE) whenUpgradesNotPaused returns (bytes32 id) {
        require(target != address(0), "Invalid target");
        require(newImplementation != address(0), "Invalid implementation");
        require(_isContract(newImplementation), "Invalid implementation");
        
        id = keccak256(abi.encode(target, newImplementation, block.timestamp));
        require(timestamps[id] == 0, "Operation already scheduled");
        
        uint256 executeTime = block.timestamp + UPGRADE_DELAY;
        timestamps[id] = executeTime;
        
        emit UpgradeScheduled(id, target, newImplementation, executeTime);
        return id;
    }
    
    // ==================== EXECUTION ====================

    /// @dev Executes a scheduled upgrade after the delay has passed and before the grace period expires.
    function executeUpgrade(
        address target,
        address newImplementation,
        bytes32 operationId
    ) external onlyRole(EXECUTOR_ROLE) whenUpgradesNotPaused nonReentrant {
        require(timestamps[operationId] != 0, "Operation not scheduled");
        require(!executed[operationId], "Operation already executed");
        require(!cancelled[operationId], "Operation cancelled");
        require(block.timestamp >= timestamps[operationId], "Operation not ready");
        require(block.timestamp <= timestamps[operationId] + GRACE_PERIOD, "Operation expired");
        
        executed[operationId] = true;
        
        (bool success, ) = target.call(abi.encodeWithSignature("upgradeTo(address)", newImplementation));
        require(success, "Upgrade execution failed");
        
        emit UpgradeExecuted(operationId, target, newImplementation);
    }
    
    // ==================== CANCELLATION ====================

    function cancelUpgrade(bytes32 id) external onlyRole(CANCELLER_ROLE) {
        require(timestamps[id] != 0, "Operation not scheduled");
        require(!executed[id], "Operation already executed");
        require(!cancelled[id], "Operation cancelled");
        
        cancelled[id] = true;
        emit UpgradeCancelled(id);
    }
    
    // ==================== PAUSE / UNPAUSE ====================

    function pauseUpgrades() external onlyGuardian {
        upgradesPaused = true;
        emit UpgradesPaused(guardian);
    }
    
    function unpauseUpgrades() external onlyRole(TIMELOCK_ADMIN_ROLE) {
        upgradesPaused = false;
        emit UpgradesUnpaused(msg.sender);
    }
    
    // ==================== ADMIN ====================

    function updateGuardian(address newGuardian) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(newGuardian != address(0), "Invalid guardian");
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }
    
    // ==================== VIEW FUNCTIONS ====================

    function isOperationReady(bytes32 id) external view returns (bool ready) {
        return timestamps[id] != 0 && 
               !executed[id] && 
               !cancelled[id] && 
               block.timestamp >= timestamps[id] &&
               block.timestamp <= timestamps[id] + GRACE_PERIOD;
    }
    
    function getOperation(bytes32 id) external view returns (
        uint256 timestamp,
        bool executed_,
        bool cancelled_
    ) {
        return (timestamps[id], executed[id], cancelled[id]);
    }
    
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
