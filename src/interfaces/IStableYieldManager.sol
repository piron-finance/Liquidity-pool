// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/IPoolTypes.sol";
import "../types/IManagedPoolTypes.sol";

/**
 * @title IStableYieldManager
 * @dev Interface for the StableYieldManager contract
 */
interface IStableYieldManager {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STRUCTS ////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    struct ManagedPoolData {
        address poolAddress;        // StableYieldPool instance
        address asset;              // Any approved stablecoin
        address escrow;             // ManagedPoolEscrow instance
        address spvAddress;         // SPV for this pool
        uint256[] supportedTenors;  // [90, 180, 270, 360] days
        uint256 minInvestment;      // In asset units
        uint256 expenseRatio;       // Basis points
        uint256 reserveRatio;       // Basis points (default 1000 = 10%)
        bool isActive;
        uint256 createdAt;
    }
    
    struct PoolReserves {
        uint256 targetReserveRatio;    // 1000 = 10%
        uint256 minReserveRatio;       // 500 = 5% (emergency minimum)
        uint256 maxReserveRatio;       // 2000 = 20% (if high withdrawal demand)
        uint256 currentCashBuffer;     // Current cash held
        uint256 totalPoolAUM;          // Total pool assets
        uint256 lastRebalanceTime;    // Last reserve rebalancing
    }

    struct UserPosition {
        uint256 principal;             // Original deposit amount
        uint256 shares;                // Pool shares owned
        IManagedPoolTypes.TenorDuration tenor; // Selected tenor
        IManagedPoolTypes.MaturityAction maturityAction; // Compound or withdraw
        uint256 depositTime;           // When position was created
        uint256 maturityTime;          // When tenor expires
        uint256 accruedYield;          // Cached yield calculation
        bool isActive;                 // Position status
    }

    struct WithdrawalRequest {
        address user;                  // Requesting user
        uint256 shares;                // Shares to withdraw
        uint256 expectedAmount;        // Expected payout (with penalties)
        uint256 requestTime;           // When request was made
        bool isPenalized;              // Early exit penalty applied
        bool isProcessed;              // Request completion status
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event ManagedPoolRegistered(
        address indexed poolAddress,
        address indexed asset,
        address indexed escrow,
        address spvAddress,
        uint256[] supportedTenors
    );
    
    event ManagedDeposit(
        address indexed pool,
        address indexed user,
        uint256 amount,
        uint256 shares,
        IManagedPoolTypes.TenorDuration tenor,
        IManagedPoolTypes.MaturityAction maturityAction
    );
    
    event EarlyExitRequested(
        address indexed pool,
        address indexed user,
        uint256 positionIndex,
        uint256 shares,
        uint256 penaltyAmount,
        uint256 expectedAmount
    );
    
    event WithdrawalQueued(
        address indexed pool,
        address indexed user,
        uint256 requestIndex,
        uint256 shares,
        uint256 expectedAmount,
        bool isPenalized
    );
    
    event WithdrawalProcessed(
        address indexed pool,
        address indexed user,
        uint256 requestIndex,
        uint256 actualAmount
    );
    
    event NAVUpdated(
        address indexed pool,
        uint256 newNAV,
        uint256 navPerShare,
        uint256 timestamp
    );
    
    event ReservesRebalanced(
        address indexed pool,
        uint256 oldRatio,
        uint256 newRatio,
        uint256 liquidityRequested
    );

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FUNCTIONS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    // Registration
    function registerManagedPool(
        address poolAddress,
        address asset,
        address escrow,
        address spvAddress,
        uint256[] memory supportedTenors,
        uint256 minInvestment,
        uint256 expenseRatio
    ) external;

    // Core Operations
    function handleManagedDeposit(
        address poolAddress,
        uint256 amount,
        uint256 tenorDays,
        IManagedPoolTypes.MaturityAction maturityAction,
        address receiver,
        address sender
    ) external returns (uint256 shares);

    function handleManagedWithdraw(
        address poolAddress,
        uint256 shares,
        address receiver,
        address owner,
        address sender
    ) external returns (uint256 actualShares);

    // NAV Calculations
    function calculatePoolNAV(address poolAddress) external view returns (uint256 nav);
    function calculateNAVPerShare(address poolAddress) external view returns (uint256 navPerShare);

    // Queue Management
    function processWithdrawalQueue(address poolAddress, uint256 maxRequests) external;
    function manageReserves(address poolAddress) external;

    // View Functions
    function getManagedPoolData(address poolAddress) external view returns (ManagedPoolData memory);
    function getPoolReserves(address poolAddress) external view returns (PoolReserves memory);
    function getUserPositions(address poolAddress, address user) external view returns (UserPosition[] memory);
    function getWithdrawalQueueLength(address poolAddress) external view returns (uint256);
}