// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../types/ILockedPoolTypes.sol";

/// @title ILockedPoolManager
/// @dev Interface for managing locked (fixed-term) pools: tier configuration, deposits,
///      redemptions, early exits, rollovers, and SPV allocations.
interface ILockedPoolManager {

    // ==================== EVENTS ====================

    event PoolRegistered(
        address indexed poolAddress,
        address indexed escrowAddress,
        address indexed asset,
        string name
    );

    event LockTierConfigured(
        address indexed poolAddress,
        uint8 tierIndex,
        uint256 durationDays,
        uint256 apyBps,
        uint256 earlyExitPenaltyBps
    );

    event PositionCreated(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed positionId,
        uint256 principal,
        uint256 interestAmount,
        ILockedPoolTypes.InterestPayment paymentChoice,
        uint256 lockEnd
    );

    event InterestPaidUpfront(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed positionId,
        uint256 interestAmount
    );

    event PositionRedeemed(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed positionId,
        uint256 payout
    );

    event PositionMatured(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed positionId,
        uint256 maturityTime
    );

    event EarlyExitProcessed(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed positionId,
        uint256 payout,
        uint256 penalty,
        uint256 interestEarned
    );

    event AllocationCreated(
        address indexed poolAddress,
        address indexed spv,
        bytes32 indexed allocationId,
        uint256 amount
    );

    event AllocationMatured(
        address indexed poolAddress,
        bytes32 indexed allocationId,
        uint256 returnedAmount
    );

    event AutoRolloverSet(
        uint256 indexed positionId,
        address indexed user,
        bool enabled
    );

    event PositionRolledOver(
        address indexed poolAddress,
        address indexed user,
        uint256 indexed oldPositionId,
        uint256 newPositionId,
        uint256 principalRolled,
        uint256 interestHandled
    );

    event DepositFeeCollected(
        address indexed poolAddress,
        address indexed depositor,
        uint256 amount,
        uint256 fee
    );

    event FeeManagerUpdated(address indexed feeManager);
    event DefaultDepositFeeUpdated(uint256 feeBps);
    event PoolDepositFeeUpdated(address indexed pool, uint256 feeBps);

    // ==================== POOL SETUP ====================

    function registerPool(
        address poolAddress,
        address escrowAddress,
        address asset,
        string memory name,
        uint256 minInvestment
    ) external;

    function configureLockTier(
        address poolAddress,
        uint8 tierIndex,
        ILockedPoolTypes.LockTier memory tier
    ) external;

    function setTierActive(
        address poolAddress,
        uint8 tierIndex,
        bool isActive
    ) external;

    function updateTierAPY(
        address poolAddress,
        uint8 tierIndex,
        uint256 newApyBps
    ) external;

    // ==================== DEPOSIT / REDEEM / EXIT ====================

    function processDeposit(
        address poolAddress,
        address depositor,
        uint256 amount,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice
    ) external returns (uint256 positionId, uint256 shares);

    function redeem(
        address poolAddress,
        uint256 positionId,
        address caller
    ) external returns (uint256 payout);

    function earlyWithdraw(
        address poolAddress,
        uint256 positionId,
        address caller
    ) external returns (uint256 payout, uint256 penalty);

    // ==================== ROLLOVER ====================

    function setAutoRollover(
        uint256 positionId,
        bool enabled,
        address caller
    ) external;
    
    function transferPositionOwnership(
        uint256 positionId,
        address newOwner,
        address caller
    ) external;

    function executeRollover(
        uint256 positionId
    ) external returns (uint256 newPositionId);

    function batchExecuteRollovers(
        uint256[] calldata positionIds
    ) external returns (uint256[] memory newPositionIds);

    // ==================== SPV ALLOCATION ====================

    function createPendingAllocation(
        address poolAddress,
        address spvAddress,
        uint256 amount
    ) external returns (bytes32 allocationId);

    function matureAllocation(
        bytes32 allocationId,
        uint256 returnedAmount
    ) external;

    // ==================== VIEW FUNCTIONS ====================

    function getPosition(
        uint256 positionId
    ) external view returns (ILockedPoolTypes.UserPosition memory);

    function getUserPositions(
        address poolAddress,
        address user
    ) external view returns (uint256[] memory positionIds);

    function getPositionSummary(
        uint256 positionId
    ) external view returns (ILockedPoolTypes.PositionSummary memory);

    function calculateEarlyExitPayout(
        uint256 positionId
    ) external view returns (ILockedPoolTypes.EarlyExitCalculation memory);

    function getLockTier(
        address poolAddress,
        uint8 tierIndex
    ) external view returns (ILockedPoolTypes.LockTier memory);

    function getPoolMetrics(
        address poolAddress
    ) external view returns (ILockedPoolTypes.PoolMetrics memory);

    function calculateInterest(
        uint256 principal,
        uint256 apyBps,
        uint256 durationDays
    ) external pure returns (uint256);
}
