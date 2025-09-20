// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../interfaces/IManager.sol"; 
import "../interfaces/ILiquidityPool.sol";
import "../types/IPoolTypes.sol";
import "../types/IManagedPoolTypes.sol";
import "../AccessManager.sol";

/**
 * @title YieldCalculator
 * @dev Sophisticated yield calculation engine for tenor-based returns
 * @notice Implements the mathematical framework from look4.txt for transparent yield calculation
 */
contract YieldCalculator is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @dev Access manager for role-based permissions
    AccessManager public accessManager;
    
    /// @dev Version for upgrade tracking
    uint256 public version;

    /// @dev Tenor duration in days mapping
    mapping(IManagedPoolTypes.TenorDuration => uint256) public tenorDays;

    /// @dev Constants for calculations
    uint256 public constant DAYS_IN_YEAR = 365;
    uint256 public constant BASIS_POINTS = 10000;
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event PoolAPYCalculated(address indexed pool, uint256 weightedAPY, uint256 timestamp);
    event TenorAPYCalculated(address indexed pool, IManagedPoolTypes.TenorDuration tenor, uint256 tenorAPY, uint256 timestamp);
    event YieldAccrualCalculated(address indexed user, uint256 principal, uint256 days, uint256 accruedValue);
    event EarlyExitCalculated(address indexed user, uint256 accruedValue, uint256 penalty, uint256 finalAmount);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the Yield Calculator
     * @param accessManager_ Access manager address
     */
    function initialize(address accessManager_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        
        require(accessManager_ != address(0), "YieldCalculator/invalid access manager");
        
        accessManager = AccessManager(accessManager_);
        version = 1;
        
        // Initialize tenor duration mappings
        tenorDays[IManagedPoolTypes.TenorDuration.TENOR_90D] = 90;
        tenorDays[IManagedPoolTypes.TenorDuration.TENOR_180D] = 180;
        tenorDays[IManagedPoolTypes.TenorDuration.TENOR_270D] = 270;
        tenorDays[IManagedPoolTypes.TenorDuration.TENOR_360D] = 360;
        
        // Grant DEFAULT_ADMIN_ROLE to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// CORE YIELD CALCULATIONS ////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Calculate weighted average APY for a pool based on underlying T-bills
     * @param underlyingPools Array of underlying pool addresses
     * @param allocationWeights Array of allocation weights (basis points)
     * @return weightedAPY Weighted average APY in basis points
     */
    function calculatePoolAPY(
        address[] memory underlyingPools,
        uint256[] memory allocationWeights
    ) external view returns (uint256 weightedAPY) {
        require(underlyingPools.length == allocationWeights.length, "YieldCalculator/length mismatch");
        
        uint256 totalWeight = 0;
        uint256 weightedSum = 0;
        
        for (uint256 i = 0; i < underlyingPools.length; i++) {
            if (allocationWeights[i] > 0) {
                // Get APY from underlying pool (simplified - would integrate with actual pool data)
                uint256 poolAPY = _getUnderlyingPoolAPY(underlyingPools[i]);
                
                weightedSum += (poolAPY * allocationWeights[i]);
                totalWeight += allocationWeights[i];
            }
        }
        
        require(totalWeight > 0, "YieldCalculator/no valid allocations");
        weightedAPY = weightedSum / totalWeight;
        
        emit PoolAPYCalculated(address(this), weightedAPY, block.timestamp);
    }

    /**
     * @notice Calculate tenor-specific APY from pool APY
     * @param poolAPY Pool's weighted average APY (basis points)
     * @param tenor Selected tenor duration
     * @return tenorAPY Tenor-specific APY in basis points
     */
    function calculateTenorAPY(
        uint256 poolAPY,
        IManagedPoolTypes.TenorDuration tenor
    ) external view returns (uint256 tenorAPY) {
        uint256 tenorDaysCount = tenorDays[tenor];
        require(tenorDaysCount > 0, "YieldCalculator/invalid tenor");
        
        // Convert poolAPY from basis points to decimal (divide by 10000)
        // Formula: ((1 + poolAPY)^(tenorDays/365) - 1) * 365/tenorDays
        
        // For precision, we use scaled arithmetic
        uint256 scaledPoolAPY = poolAPY; // Already in basis points
        
        // Calculate: (1 + poolAPY/10000)^(tenorDays/365) - 1
        uint256 scaledReturn = _calculateCompoundReturn(scaledPoolAPY, tenorDaysCount);
        
        // Convert back to annualized: return * 365/tenorDays
        tenorAPY = (scaledReturn * DAYS_IN_YEAR) / tenorDaysCount;
        
        emit TenorAPYCalculated(address(this), tenor, tenorAPY, block.timestamp);
    }

    /**
     * @notice Calculate daily yield accrual for a position
     * @param principal Original principal amount
     * @param poolAPY Pool's weighted average APY (basis points)
     * @param daysElapsed Number of days since deposit
     * @return accruedValue Current value including accrued yield
     */
    function calculateYieldAccrual(
        uint256 principal,
        uint256 poolAPY,
        uint256 daysElapsed
    ) external returns (uint256 accruedValue) {
        require(principal > 0, "YieldCalculator/invalid principal");
        require(daysElapsed >= 0, "YieldCalculator/invalid days");
        
        if (daysElapsed == 0) {
            return principal;
        }
        
        // Formula: Principal × (1 + dailyRate)^days
        // Where dailyRate = (1 + poolAPY/10000)^(1/365) - 1
        
        uint256 dailyRate = _calculateDailyRate(poolAPY);
        accruedValue = _calculateCompoundAccrual(principal, dailyRate, daysElapsed);
        
        emit YieldAccrualCalculated(msg.sender, principal, daysElapsed, accruedValue);
    }

    /**
     * @notice Calculate early exit amount with penalty
     * @param accruedValue Current accrued value
     * @param penaltyRate Penalty rate in basis points
     * @return finalAmount Amount after penalty deduction
     * @return penaltyAmount Penalty amount deducted
     */
    function calculateEarlyExitValue(
        uint256 accruedValue,
        uint256 penaltyRate
    ) external returns (uint256 finalAmount, uint256 penaltyAmount) {
        require(accruedValue > 0, "YieldCalculator/invalid accrued value");
        require(penaltyRate <= BASIS_POINTS, "YieldCalculator/invalid penalty rate");
        
        // Calculate penalty: accruedValue * (penaltyRate / 10000)
        penaltyAmount = (accruedValue * penaltyRate) / BASIS_POINTS;
        finalAmount = accruedValue - penaltyAmount;
        
        emit EarlyExitCalculated(msg.sender, accruedValue, penaltyAmount, finalAmount);
    }

    /**
     * @notice Calculate projected return for a given tenor and principal
     * @param principal Principal amount
     * @param poolAPY Pool's weighted average APY (basis points)
     * @param tenor Selected tenor duration
     * @return projectedReturn Total expected return at maturity
     */
    function calculateProjectedReturn(
        uint256 principal,
        uint256 poolAPY,
        IManagedPoolTypes.TenorDuration tenor
    ) external view returns (uint256 projectedReturn) {
        uint256 tenorDaysCount = tenorDays[tenor];
        require(tenorDaysCount > 0, "YieldCalculator/invalid tenor");
        require(principal > 0, "YieldCalculator/invalid principal");
        
        uint256 dailyRate = _calculateDailyRate(poolAPY);
        projectedReturn = _calculateCompoundAccrual(principal, dailyRate, tenorDaysCount);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL CALCULATIONS /////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @dev Calculate daily rate from annual APY
     * @param poolAPY Annual APY in basis points
     * @return dailyRate Daily rate in basis points
     */
    function _calculateDailyRate(uint256 poolAPY) internal pure returns (uint256 dailyRate) {
        // Formula: (1 + poolAPY/10000)^(1/365) - 1
        // Simplified for gas efficiency: poolAPY / (365 * 10000)
        // This is an approximation that's accurate for typical APY ranges
        dailyRate = poolAPY / DAYS_IN_YEAR;
    }

    /**
     * @dev Calculate compound accrual over time
     * @param principal Principal amount
     * @param dailyRate Daily rate in basis points
     * @param days Number of days
     * @return accruedValue Final accrued value
     */
    function _calculateCompoundAccrual(
        uint256 principal,
        uint256 dailyRate,
        uint256 days
    ) internal pure returns (uint256 accruedValue) {
        if (days == 0) return principal;
        
        // Simplified compound calculation for gas efficiency
        // Formula: principal * (1 + dailyRate/10000)^days
        // Approximation: principal * (1 + (dailyRate * days)/10000)
        
        uint256 totalReturn = (dailyRate * days * principal) / BASIS_POINTS;
        accruedValue = principal + totalReturn;
    }

    /**
     * @dev Calculate compound return for tenor calculation
     * @param poolAPY Pool APY in basis points
     * @param tenorDaysCount Number of days in tenor
     * @return scaledReturn Return for the tenor period
     */
    function _calculateCompoundReturn(
        uint256 poolAPY,
        uint256 tenorDaysCount
    ) internal pure returns (uint256 scaledReturn) {
        // Simplified calculation: (poolAPY * tenorDays) / (365 * 10000) * 10000
        scaledReturn = (poolAPY * tenorDaysCount) / DAYS_IN_YEAR;
    }

    /**
     * @dev Get APY from underlying pool (placeholder for actual integration)
     * @param poolAddress Address of underlying pool
     * @return apy Pool's current APY in basis points
     */
    function _getUnderlyingPoolAPY(address poolAddress) internal view returns (uint256 apy) {
        // Placeholder - would integrate with actual pool data
        // For now, return a default APY based on pool type
        // In production, this would query the pool's current yield
        return 800; // 8% default APY in basis points
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get tenor duration in days
     * @param tenor Tenor duration enum
     * @return days Number of days for the tenor
     */
    function getTenorDays(IManagedPoolTypes.TenorDuration tenor) external view returns (uint256 days) {
        return tenorDays[tenor];
    }

    /**
     * @notice Check if early exit is allowed for a position
     * @param depositTime Timestamp of deposit
     * @param minimumHoldPeriod Minimum hold period in days
     * @return allowed Whether early exit is allowed
     * @return daysHeld Number of days position has been held
     */
    function isEarlyExitAllowed(
        uint256 depositTime,
        uint256 minimumHoldPeriod
    ) external view returns (bool allowed, uint256 daysHeld) {
        require(depositTime <= block.timestamp, "YieldCalculator/invalid deposit time");
        
        daysHeld = (block.timestamp - depositTime) / 1 days;
        allowed = daysHeld >= minimumHoldPeriod;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update tenor duration mapping
     * @param tenor Tenor duration enum
     * @param days Number of days for the tenor
     */
    function updateTenorDays(
        IManagedPoolTypes.TenorDuration tenor,
        uint256 days
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(days > 0, "YieldCalculator/invalid days");
        tenorDays[tenor] = days;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// UPGRADE AUTHORIZATION //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Authorize contract upgrades
     * @param newImplementation New implementation contract address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImplementation != address(0), "YieldCalculator/invalid implementation");
        version += 1;
    }

    /**
     * @notice Get version number
     */
    function getVersion() external view returns (uint256) {
        return version;
    }
}