// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title UpgradeGuardian
 * @notice Emergency guardian for protocol upgrade security
 * @dev Can pause upgrades in case of detected attacks or vulnerabilities
 */
contract UpgradeGuardian is AccessControl {
    
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // Guardian settings
    address public timelockController;
    bool public emergencyPauseActive;
    uint256 public pauseStartTime;
    uint256 public constant MAX_PAUSE_DURATION = 30 days;
    
    // Emergency contacts
    mapping(address => bool) public emergencyContacts;
    address[] public emergencyContactList;
    
    // Events
    event EmergencyPauseActivated(address indexed guardian, string reason, uint256 timestamp);
    event EmergencyPauseDeactivated(address indexed admin, uint256 timestamp);
    event EmergencyContactAdded(address indexed contact);
    event EmergencyContactRemoved(address indexed contact);
    event TimelockControllerUpdated(address indexed oldController, address indexed newController);
    
    // Errors
    error UnauthorizedGuardian();
    error EmergencyAlreadyActive();
    error EmergencyNotActive();
    error PauseDurationExceeded();
    error InvalidTimelockController();
    error InvalidEmergencyContact();
    
    modifier onlyGuardian() {
        require(hasRole(GUARDIAN_ROLE, msg.sender), "Unauthorized guardian");
        _;
    }
    
    modifier onlyEmergency() {
        require(hasRole(EMERGENCY_ROLE, msg.sender) || emergencyContacts[msg.sender], "Unauthorized emergency");
        _;
    }
    
    /**
     * @notice Initialize guardian with multi-sig requirements
     * @param admin Admin multi-sig wallet
     * @param guardian Guardian multi-sig wallet (3/5)
     * @param emergency Emergency multi-sig wallet (2/3)
     * @param _timelockController Timelock controller address
     */
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
    
    /**
     * @notice Emergency pause all protocol upgrades
     * @param reason Reason for emergency pause
     * @dev Can be called by guardian or emergency contacts
     */
    function emergencyPauseUpgrades(string calldata reason) external onlyEmergency {
        require(!emergencyPauseActive, "Emergency already active");
        
        emergencyPauseActive = true;
        pauseStartTime = block.timestamp;
        
        // Call timelock to pause upgrades
        (bool success, ) = timelockController.call(
            abi.encodeWithSignature("pauseUpgrades()")
        );
        require(success, "Failed to pause timelock");
        
        emit EmergencyPauseActivated(msg.sender, reason, block.timestamp);
    }
    
    /**
     * @notice Deactivate emergency pause
     * @dev Can only be called by admin after investigation
     */
    function deactivateEmergencyPause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(emergencyPauseActive, "Emergency not active");
        
        emergencyPauseActive = false;
        
        // Call timelock to unpause upgrades
        (bool success, ) = timelockController.call(
            abi.encodeWithSignature("unpauseUpgrades()")
        );
        require(success, "Failed to unpause timelock");
        
        emit EmergencyPauseDeactivated(msg.sender, block.timestamp);
    }
    
    /**
     * @notice Force deactivate pause if max duration exceeded
     * @dev Prevents permanent pause scenarios
     */
    function forceDeactivatePause() external {
        require(emergencyPauseActive, "Emergency not active");
        require(block.timestamp >= pauseStartTime + MAX_PAUSE_DURATION, "Pause duration exceeded");
        
        emergencyPauseActive = false;
        
        emit EmergencyPauseDeactivated(address(0), block.timestamp);
    }
    
    /**
     * @notice Add emergency contact
     * @param contact Address that can trigger emergency pause
     */
    function addEmergencyContact(address contact) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(contact != address(0), "Invalid emergency contact");
        require(!emergencyContacts[contact], "Contact already added");
        
        emergencyContacts[contact] = true;
        emergencyContactList.push(contact);
        
        emit EmergencyContactAdded(contact);
    }
    
    /**
     * @notice Remove emergency contact
     * @param contact Address to remove
     */
    function removeEmergencyContact(address contact) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(emergencyContacts[contact], "Contact not found");
        
        emergencyContacts[contact] = false;
        
        // Remove from array
        for (uint256 i = 0; i < emergencyContactList.length; i++) {
            if (emergencyContactList[i] == contact) {
                emergencyContactList[i] = emergencyContactList[emergencyContactList.length - 1];
                emergencyContactList.pop();
                break;
            }
        }
        
        emit EmergencyContactRemoved(contact);
    }
    
    /**
     * @notice Update timelock controller address
     * @param newController New timelock controller
     */
    function updateTimelockController(address newController) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newController != address(0), "Invalid timelock controller");
        address oldController = timelockController;
        timelockController = newController;
        emit TimelockControllerUpdated(oldController, newController);
    }
    
    /**
     * @notice Get all emergency contacts
     * @return contacts Array of emergency contact addresses
     */
    function getEmergencyContacts() external view returns (address[] memory contacts) {
        return emergencyContactList;
    }
    
    /**
     * @notice Check if emergency pause is active and within duration
     * @return active True if emergency pause is active
     * @return timeRemaining Seconds until force deactivation
     */
    function getEmergencyStatus() external view returns (bool active, uint256 timeRemaining) {
        active = emergencyPauseActive;
        if (active) {
            uint256 maxEndTime = pauseStartTime + MAX_PAUSE_DURATION;
            timeRemaining = block.timestamp >= maxEndTime ? 0 : maxEndTime - block.timestamp;
        }
    }
}