// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol"; 
import "../types/IManagedPoolTypes.sol";

/**
 * @title ManagedPoolEscrow
 * @dev Enhanced escrow with flexible stablecoin support and laddered allocation for country-specific pools
 * @notice Secure custody and allocation management for StableYieldPool instances
 */
contract ManagedPoolEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @dev Flexible stablecoin based on country (CNGN, USDT, USDC, etc.)
    IERC20 public asset;
    
    /// @dev The managed pool that owns this escrow
    address public managedPool;
    
    /// @dev Access manager for role-based permissions
    AccessManager public accessManager;
    
    /// @dev Timelock controller for upgrade authorization
    address public timelockController;
    
    /// @dev Version for upgrade tracking
    uint256 public version;
    
    /// @dev Pool name for identification (e.g., "Piron USDC Stable Yield Pool")
    string public poolName;
    
    /// @dev Legacy: underlying pools no longer used, SPV handles T-bill allocation directly
    
    /// @dev Cash buffer for early exits and liquidity management
    uint256 public cashBuffer;
    
    /// @dev Total penalty fees collected from early exits
    uint256 public totalPenaltyFees;
    
    /// @dev Total funds allocated to underlying pools
    uint256 public totalAllocatedFunds;
    
    /// @dev Emergency withdrawal enabled flag
    bool public emergencyWithdrawalEnabled;
    
    /// @dev SPV allocations for T-bill purchases
    mapping(address => uint256) public spvAllocations;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event FundsDeposited(address indexed from, uint256 amount, uint256 newCashBuffer);
    event FundsWithdrawn(address indexed to, uint256 amount, uint256 remainingCashBuffer);
    event PenaltyFeeCollected(address indexed user, uint256 amount, uint256 totalCollected);
    event CashBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event EmergencyWithdrawalToggled(bool enabled);
    event PoolNameUpdated(string newPoolName);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyManagedPool() {
        require(msg.sender == managedPool, "ManagedPoolEscrow/only managed pool");
        _;
    }

    modifier onlyOperator() {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "ManagedPoolEscrow/not operator");
        _;
    }

    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "ManagedPoolEscrow/not admin");
        _;
    }

    modifier whenEmergencyEnabled() {
        require(emergencyWithdrawalEnabled, "ManagedPoolEscrow/emergency disabled");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Enhanced Managed Pool Escrow
     * @param asset_ Country-specific stablecoin (CNGN, USDT, USDC, etc.)
     * @param managedPool_ The managed pool address
     * @param accessManager_ Access manager address
     * @param timelockController_ Timelock controller address
     * @param poolName_ Pool name for identification
     */
    function initialize(
        address asset_,
        address managedPool_,
        address accessManager_,
        address timelockController_,
        string memory poolName_
    ) public initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuard_init();

        require(asset_ != address(0), "ManagedPoolEscrow/invalid asset");
        require(managedPool_ != address(0), "ManagedPoolEscrow/invalid managed pool");
        require(accessManager_ != address(0), "ManagedPoolEscrow/invalid access manager");
        require(timelockController_ != address(0), "ManagedPoolEscrow/invalid timelock");

        asset = IERC20(asset_);
        managedPool = managedPool_;
        accessManager = AccessManager(accessManager_);
        timelockController = timelockController_;
        poolName = poolName_;
        version = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT & WITHDRAWAL ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deposit funds from managed pool
     * @param amount Amount to deposit
     */
    function deposit(uint256 amount) external onlyManagedPool nonReentrant {
        require(amount > 0, "ManagedPoolEscrow/invalid amount");

        asset.safeTransferFrom(managedPool, address(this), amount);
        cashBuffer += amount;

        emit FundsDeposited(managedPool, amount, cashBuffer);
    }

    /**
     * @notice Withdraw funds to user (for processed withdrawal requests)
     * @param to Recipient address
     * @param amount Amount to withdraw
     * @param isPenaltyWithdrawal Whether this is a penalized early exit
     * @param penaltyAmount Penalty amount (if applicable)
     */
    function withdraw(
        address to,
        uint256 amount,
        bool isPenaltyWithdrawal,
        uint256 penaltyAmount
    ) external onlyManagedPool nonReentrant {
        require(to != address(0), "ManagedPoolEscrow/invalid recipient");
        require(amount > 0, "ManagedPoolEscrow/invalid amount");

        uint256 totalWithdrawal = amount;
        if (isPenaltyWithdrawal) {
            totalWithdrawal += penaltyAmount;
            totalPenaltyFees += penaltyAmount;
            emit PenaltyFeeCollected(to, penaltyAmount, totalPenaltyFees);
        }

        require(cashBuffer >= totalWithdrawal, "ManagedPoolEscrow/insufficient cash buffer");

        cashBuffer -= totalWithdrawal;
        asset.safeTransfer(to, amount);

        // Penalty fees remain in escrow as protocol revenue

        emit FundsWithdrawn(to, amount, cashBuffer);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SIMPLIFIED ALLOCATION //////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get current cash buffer amount
     * @return buffer Current cash buffer
     */
    function getCashBuffer() external view returns (uint256 buffer) {
        return cashBuffer;
    }

    /**
     * @notice Get total balance (just cash buffer now)
     * @return balance Total balance
     */
    function getTotalBalance() external view returns (uint256 balance) {
        return cashBuffer;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update pool name
     * @param newPoolName New pool name
     */
    function updatePoolName(string memory newPoolName) external onlyAdmin {
        require(bytes(newPoolName).length > 0, "ManagedPoolEscrow/invalid pool name");
        poolName = newPoolName;
        emit PoolNameUpdated(newPoolName);
    }

    /**
     * @notice Toggle emergency withdrawal capability
     * @param enabled Whether emergency withdrawals are enabled
     */
    function toggleEmergencyWithdrawal(bool enabled) external onlyAdmin {
        emergencyWithdrawalEnabled = enabled;
        emit EmergencyWithdrawalToggled(enabled);
    }

    /**
     * @notice Emergency withdraw (admin only, when enabled)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address to,
        uint256 amount
    ) external onlyAdmin whenEmergencyEnabled nonReentrant {
        require(to != address(0), "ManagedPoolEscrow/invalid recipient");
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        require(cashBuffer >= amount, "ManagedPoolEscrow/insufficient balance");

        cashBuffer -= amount;
        asset.safeTransfer(to, amount);

        emit FundsWithdrawn(to, amount, cashBuffer);
    }

    /**
     * @notice Withdraw penalty fees (protocol revenue)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawPenaltyFees(
        address to,
        uint256 amount
    ) external onlyAdmin nonReentrant {
        require(to != address(0), "ManagedPoolEscrow/invalid recipient");
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        require(totalPenaltyFees >= amount, "ManagedPoolEscrow/insufficient penalty fees");

        totalPenaltyFees -= amount;
        asset.safeTransfer(to, amount);
    }

    /**
     * @notice Update managed pool address (called during initialization)
     * @param newManagedPool New managed pool address
     */
    function updateManagedPool(address newManagedPool) external onlyAdmin {
        require(newManagedPool != address(0), "ManagedPoolEscrow/invalid managed pool");
        managedPool = newManagedPool;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// UPGRADE AUTHORIZATION //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation New implementation contract address
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == timelockController, "ManagedPoolEscrow/only timelock");
        require(newImplementation != address(0), "ManagedPoolEscrow/invalid implementation");
        version += 1;
    }

    /**
     * @notice Get version number
     */
    function getVersion() external view returns (uint256) {
        return version;
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV COORDINATION ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Allocate funds to SPV for T-bill purchases
     * @param spvAddress SPV address
     * @param amount Amount to allocate
     */
    function allocateToSPV(address spvAddress, uint256 amount) external onlyManagedPool {
        require(spvAddress != address(0), "ManagedPoolEscrow/invalid SPV");
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        require(cashBuffer >= amount, "ManagedPoolEscrow/insufficient cash buffer");
        
        cashBuffer -= amount;
        spvAllocations[spvAddress] += amount;
        
        // Transfer funds to SPV
        asset.safeTransfer(spvAddress, amount);
        
        emit SPVAllocation(spvAddress, amount, cashBuffer);
    }
    
    /**
     * @notice Request liquidity from SPV by liquidating T-bills
     * @param spvAddress SPV address
     * @param amount Amount of liquidity needed
     */
    function requestSPVLiquidity(address spvAddress, uint256 amount) external onlyManagedPool {
        require(spvAddress != address(0), "ManagedPoolEscrow/invalid SPV");
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        require(spvAllocations[spvAddress] >= amount, "ManagedPoolEscrow/insufficient SPV allocation");
        
        spvAllocations[spvAddress] -= amount;
        
        emit SPVLiquidityRequested(spvAddress, amount, block.timestamp);
        
        // Note: SPV will transfer funds back via receiveSPVLiquidity()
    }
    
    /**
     * @notice Receive liquidity back from SPV
     * @param amount Amount received
     */
    function receiveSPVLiquidity(uint256 amount) external {
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        
        // Only SPV or authorized addresses can call this
        // In production, this would have proper SPV authentication
        
        cashBuffer += amount;
        
        emit SPVLiquidityReceived(msg.sender, amount, cashBuffer);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    event SPVAllocation(address indexed spv, uint256 amount, uint256 remainingCashBuffer);
    event SPVLiquidityRequested(address indexed spv, uint256 amount, uint256 timestamp);
    event SPVLiquidityReceived(address indexed spv, uint256 amount, uint256 newCashBuffer);
}