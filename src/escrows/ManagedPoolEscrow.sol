// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";
import "../types/IPoolTypes.sol";

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
    
    /// @dev Country-specific configuration
    IPoolTypes.CountryPoolConfig public countryConfig;
    
    /// @dev Current laddered allocation breakdown
    IPoolTypes.LadderedAllocation public ladderedAllocation;
    
    /// @dev Underlying T-bill pools for this country
    address[] public underlyingPools;
    
    /// @dev Current allocation amounts per underlying pool
    mapping(address => uint256) public poolAllocations;
    
    /// @dev Cash buffer for early exits and liquidity management
    uint256 public cashBuffer;
    
    /// @dev Total penalty fees collected from early exits
    uint256 public totalPenaltyFees;
    
    /// @dev Total funds allocated to underlying pools
    uint256 public totalAllocatedFunds;
    
    /// @dev Emergency withdrawal enabled flag
    bool public emergencyWithdrawalEnabled;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event FundsDeposited(address indexed from, uint256 amount, uint256 newCashBuffer);
    event FundsWithdrawn(address indexed to, uint256 amount, uint256 remainingCashBuffer);
    event LadderedAllocationExecuted(
        uint256 shortTermAmount,
        uint256 mediumTermAmount,
        uint256 longTermAmount,
        uint256 remainingCashBuffer
    );
    event UnderlyingPoolFunded(address indexed pool, uint256 amount, uint256 totalAllocated);
    event UnderlyingPoolWithdrawn(address indexed pool, uint256 amount, uint256 remainingAllocated);
    event PenaltyFeeCollected(address indexed user, uint256 amount, uint256 totalCollected);
    event CashBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event EmergencyWithdrawalToggled(bool enabled);
    event CountryConfigUpdated(string countryCode, address stablecoin, uint256 penaltyRate);

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
     * @param countryConfig_ Country-specific configuration
     * @param underlyingPools_ Array of underlying T-bill pools
     */
    function initialize(
        address asset_,
        address managedPool_,
        address accessManager_,
        address timelockController_,
        IPoolTypes.CountryPoolConfig memory countryConfig_,
        address[] memory underlyingPools_
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
        countryConfig = countryConfig_;
        underlyingPools = underlyingPools_;
        version = 1;

        // Initialize laddered allocation (default: 50%/30%/20% + 0% cash buffer)
        ladderedAllocation = IPoolTypes.LadderedAllocation({
            shortTermAllocation: 5000,  // 50%
            mediumTermAllocation: 3000, // 30%
            longTermAllocation: 2000,   // 20%
            cashBuffer: 0,              // 0% initially
            totalAllocated: 0,
            lastRebalanceTime: block.timestamp
        });

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
    /////////////////////////////// LADDERED ALLOCATION /////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Execute laddered allocation to underlying T-bill pools
     * @param totalAmount Total amount to allocate
     */
    function executeLadderedAllocation(uint256 totalAmount) external onlyOperator nonReentrant {
        require(totalAmount > 0, "ManagedPoolEscrow/invalid amount");
        require(cashBuffer >= totalAmount, "ManagedPoolEscrow/insufficient cash buffer");

        // Calculate allocation amounts based on percentages
        uint256 shortTermAmount = (totalAmount * ladderedAllocation.shortTermAllocation) / 10000;
        uint256 mediumTermAmount = (totalAmount * ladderedAllocation.mediumTermAllocation) / 10000;
        uint256 longTermAmount = (totalAmount * ladderedAllocation.longTermAllocation) / 10000;

        // Allocate to underlying pools (simplified - would need actual pool integration)
        _allocateToUnderlyingPools(shortTermAmount, mediumTermAmount, longTermAmount);

        // Update cash buffer
        uint256 allocatedTotal = shortTermAmount + mediumTermAmount + longTermAmount;
        cashBuffer -= allocatedTotal;
        totalAllocatedFunds += allocatedTotal;

        // Update last rebalance time
        ladderedAllocation.lastRebalanceTime = block.timestamp;
        ladderedAllocation.totalAllocated = totalAllocatedFunds;

        emit LadderedAllocationExecuted(shortTermAmount, mediumTermAmount, longTermAmount, cashBuffer);
    }

    /**
     * @notice Recall funds from underlying pools for liquidity
     * @param amount Amount to recall
     */
    function recallFundsFromUnderlyingPools(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, "ManagedPoolEscrow/invalid amount");
        require(totalAllocatedFunds >= amount, "ManagedPoolEscrow/insufficient allocated funds");

        // Recall funds from underlying pools (simplified)
        _recallFromUnderlyingPools(amount);

        totalAllocatedFunds -= amount;
        cashBuffer += amount;
        ladderedAllocation.totalAllocated = totalAllocatedFunds;

        emit CashBufferUpdated(cashBuffer - amount, cashBuffer);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Allocate funds to underlying pools based on laddered strategy
     * @param shortTermAmount Amount for short-term pools (30-90 days)
     * @param mediumTermAmount Amount for medium-term pools (90-180 days)
     * @param longTermAmount Amount for long-term pools (180-365 days)
     */
    function _allocateToUnderlyingPools(
        uint256 shortTermAmount,
        uint256 mediumTermAmount,
        uint256 longTermAmount
    ) internal {
        // Simplified allocation - in production would integrate with actual pool contracts
        
        if (underlyingPools.length >= 3) {
            // Allocate to first 3 pools representing short/medium/long term
            if (shortTermAmount > 0) {
                poolAllocations[underlyingPools[0]] += shortTermAmount;
                emit UnderlyingPoolFunded(underlyingPools[0], shortTermAmount, poolAllocations[underlyingPools[0]]);
            }
            
            if (mediumTermAmount > 0) {
                poolAllocations[underlyingPools[1]] += mediumTermAmount;
                emit UnderlyingPoolFunded(underlyingPools[1], mediumTermAmount, poolAllocations[underlyingPools[1]]);
            }
            
            if (longTermAmount > 0) {
                poolAllocations[underlyingPools[2]] += longTermAmount;
                emit UnderlyingPoolFunded(underlyingPools[2], longTermAmount, poolAllocations[underlyingPools[2]]);
            }
        }
    }

    /**
     * @dev Recall funds from underlying pools
     * @param amount Total amount to recall
     */
    function _recallFromUnderlyingPools(uint256 amount) internal {
        // Simplified recall - in production would integrate with actual pool contracts
        uint256 remaining = amount;
        
        for (uint256 i = 0; i < underlyingPools.length && remaining > 0; i++) {
            address pool = underlyingPools[i];
            uint256 allocated = poolAllocations[pool];
            
            if (allocated > 0) {
                uint256 toRecall = remaining > allocated ? allocated : remaining;
                poolAllocations[pool] -= toRecall;
                remaining -= toRecall;
                
                emit UnderlyingPoolWithdrawn(pool, toRecall, poolAllocations[pool]);
            }
        }
    }

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
     * @notice Get total balance (cash buffer + allocated funds)
     * @return balance Total balance
     */
    function getTotalBalance() external view returns (uint256 balance) {
        return cashBuffer + totalAllocatedFunds;
    }

    /**
     * @notice Get allocation for specific underlying pool
     * @param pool Pool address
     * @return allocation Current allocation amount
     */
    function getPoolAllocation(address pool) external view returns (uint256 allocation) {
        return poolAllocations[pool];
    }

    /**
     * @notice Get underlying pools array
     * @return pools Array of underlying pool addresses
     */
    function getUnderlyingPools() external view returns (address[] memory pools) {
        return underlyingPools;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update laddered allocation percentages
     * @param shortTerm Short-term allocation (basis points)
     * @param mediumTerm Medium-term allocation (basis points)
     * @param longTerm Long-term allocation (basis points)
     * @param cashBufferTarget Cash buffer target (basis points)
     */
    function updateLadderedAllocation(
        uint256 shortTerm,
        uint256 mediumTerm,
        uint256 longTerm,
        uint256 cashBufferTarget
    ) external onlyAdmin {
        require(shortTerm + mediumTerm + longTerm + cashBufferTarget == 10000, "ManagedPoolEscrow/invalid allocation");
        
        ladderedAllocation.shortTermAllocation = shortTerm;
        ladderedAllocation.mediumTermAllocation = mediumTerm;
        ladderedAllocation.longTermAllocation = longTerm;
        ladderedAllocation.cashBuffer = cashBufferTarget;
        ladderedAllocation.lastRebalanceTime = block.timestamp;
    }

    /**
     * @notice Update country configuration
     * @param newConfig New country configuration
     */
    function updateCountryConfig(IPoolTypes.CountryPoolConfig memory newConfig) external onlyAdmin {
        countryConfig = newConfig;
        emit CountryConfigUpdated(newConfig.countryCode, newConfig.stablecoin, newConfig.penaltyRate);
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
}