// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title UpgradeGuardian
 * @dev Emergency brake for UUPS upgrades. Emergency contacts or the EMERGENCY_ROLE
 *      can pause upgrades via the timelock controller. Pause auto-expires after 30 days.
 */
contract UpgradeGuardian is AccessControl {

    // ==================== CONSTANTS ====================
    
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint256 public constant MAX_PAUSE_DURATION = 30 days;

    // ==================== STATE ====================
    
    address public timelockController;
    bool public emergencyPauseActive;
    uint256 public pauseStartTime;
    mapping(address => bool) public emergencyContacts;
    address[] public emergencyContactList;

    // ==================== EVENTS ====================
    
    event EmergencyPauseActivated(address indexed guardian, string reason, uint256 timestamp);
    event EmergencyPauseDeactivated(address indexed admin, uint256 timestamp);
    event EmergencyContactAdded(address indexed contact);
    event EmergencyContactRemoved(address indexed contact);
    event TimelockControllerUpdated(address indexed oldController, address indexed newController);

    // ==================== ERRORS ====================
    
    error UnauthorizedGuardian();
    error EmergencyAlreadyActive();
    error EmergencyNotActive();
    error PauseDurationExceeded();
    error InvalidTimelockController();
    error InvalidEmergencyContact();

    // ==================== MODIFIERS ====================
    
    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "Unauthorized guardian");
        _;
    }
    
    modifier onlyEmergency() {
        require(hasRole(EMERGENCY_ROLE, msg.sender) || emergencyContacts[msg.sender], "Unauthorized emergency");
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    constructor(
        address admin,
        address guardian,
        address emergency,
        address _timelockController
    ) {
        require(admin != address(0), "Invalid admin");
        require(guardian != address(0), "Invalid guardian");
        require(emergency != address(0), "Invalid emergency");
        require(_timelockController != address(0), "Invalid timelock controller");
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(EMERGENCY_ROLE, emergency);
        
        timelockController = _timelockController;
        emergencyPauseActive = false;
    }
    
    // ==================== EMERGENCY PAUSE ====================

    /// @dev Activates emergency pause on the timelock controller.
    function emergencyPauseUpgrades(string calldata reason) external onlyEmergency {
        require(!emergencyPauseActive, "Emergency already active");
        
        emergencyPauseActive = true;
        pauseStartTime = block.timestamp;
        
        (bool success, ) = timelockController.call(
            abi.encodeWithSignature("pauseUpgrades()")
        );
        require(success, "Failed to pause timelock");
        
        emit EmergencyPauseActivated(msg.sender, reason, block.timestamp);
    }
    
    /// @dev Deactivates emergency pause. Only DEFAULT_ADMIN can call.
    function deactivateEmergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(emergencyPauseActive, "Emergency not active");
        
        emergencyPauseActive = false;
        
        (bool success, ) = timelockController.call(
            abi.encodeWithSignature("unpauseUpgrades()")
        );
        require(success, "Failed to unpause timelock");
        
        emit EmergencyPauseDeactivated(msg.sender, block.timestamp);
    }
    
    /// @dev Allows anyone to force-deactivate the pause after MAX_PAUSE_DURATION has elapsed.
    function forceDeactivatePause() external {
        require(emergencyPauseActive, "Emergency not active");
        require(block.timestamp >= pauseStartTime + MAX_PAUSE_DURATION, "Pause duration exceeded");
        
        emergencyPauseActive = false;
        
        emit EmergencyPauseDeactivated(address(0), block.timestamp);
    }
    
    // ==================== EMERGENCY CONTACTS ====================

    function addEmergencyContact(address contact) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(contact != address(0), "Invalid emergency contact");
        require(!emergencyContacts[contact], "Contact already added");
        
        emergencyContacts[contact] = true;
        emergencyContactList.push(contact);
        
        emit EmergencyContactAdded(contact);
    }
    
    function removeEmergencyContact(address contact) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(emergencyContacts[contact], "Contact not found");
        
        emergencyContacts[contact] = false;
        
        for (uint256 i = 0; i < emergencyContactList.length; i++) {
            if (emergencyContactList[i] == contact) {
                emergencyContactList[i] = emergencyContactList[emergencyContactList.length - 1];
                emergencyContactList.pop();
                break;
            }
        }
        
        emit EmergencyContactRemoved(contact);
    }
    
    // ==================== ADMIN ====================

    function updateTimelockController(address newController) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newController != address(0), "Invalid timelock controller");
        address oldController = timelockController;
        timelockController = newController;
        emit TimelockControllerUpdated(oldController, newController);
    }
    
    // ==================== VIEW FUNCTIONS ====================

    function getEmergencyContacts() external view returns (address[] memory contacts) {
        return emergencyContactList;
    }
    
    function getEmergencyStatus() external view returns (bool active, uint256 timeRemaining) {
        active = emergencyPauseActive;
        if (active) {
            uint256 maxEndTime = pauseStartTime + MAX_PAUSE_DURATION;
            timeRemaining = block.timestamp >= maxEndTime ? 0 : maxEndTime - block.timestamp;
        }
    }
}
