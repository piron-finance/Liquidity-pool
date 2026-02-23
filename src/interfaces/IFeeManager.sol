// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IFeeManager
/// @dev Interface for protocol-wide fee collection, split configuration, and distribution.
interface IFeeManager {

    // ==================== STRUCTS ====================

    struct FeeSplit {
        uint256 treasuryBps;
        uint256 reserveBps;
        uint256 opsBps;
        bool active;
    }

    struct AssetFeeAccounting {
        uint256 totalCollected;
        uint256 totalDistributed;
        uint256 treasuryCollected;
        uint256 reserveCollected;
        uint256 opsCollected;
    }

    struct PoolFeeAccounting {
        uint256 totalCollected;
        mapping(FeeType => uint256) byType;
    }

    struct FeeRateChange {
        FeeType feeType;
        uint256 oldTreasuryBps;
        uint256 newTreasuryBps;
        uint256 oldReserveBps;
        uint256 newReserveBps;
        uint256 oldOpsBps;
        uint256 newOpsBps;
        uint256 timestamp;
        address changedBy;
    }

    struct ProtocolFeesSummary {
        uint256 totalCollectedAllTime;
        uint256 pendingDistribution;
        uint256 distributedToTreasury;
        uint256 distributedToReserve;
        uint256 distributedToOps;
        uint256 assetCount;
    }

    // ==================== ENUMS ====================

    enum FeeType {
        DEPOSIT_FEE,
        WITHDRAWAL_FEE,
        EARLY_EXIT_PENALTY,
        SPREAD,
        EXCESS_YIELD,
        PERFORMANCE_FEE,
        OTHER
    }

    // ==================== EVENTS ====================

    event FeeCollected(
        address indexed collector,
        address indexed pool,
        address indexed asset,
        uint256 amount,
        FeeType feeType
    );
    event FeeSplitUpdated(
        FeeType feeType,
        uint256 treasuryBps,
        uint256 reserveBps,
        uint256 opsBps,
        bool active
    );
    event CollectorAuthorized(address indexed collector, bool allowed);
    event TreasuryUpdated(address indexed treasury);
    event YieldReserveUpdated(address indexed reserve);
    event OpsWalletUpdated(address indexed ops);
    event DistributionsPaused(bool paused);
    event PoolFeePaused(address indexed pool, bool paused);
    event FeesDistributed(
        address indexed asset,
        uint256 treasuryAmount,
        uint256 reserveAmount,
        uint256 opsAmount
    );
    event MinSweepThresholdUpdated(uint256 newThreshold);

    // ==================== FEE OPERATIONS ====================

    function collectFee(
        address pool,
        address asset,
        uint256 amount,
        FeeType feeType
    ) external;

    function recordFeeOnly(
        address pool,
        address asset,
        uint256 amount,
        FeeType feeType
    ) external;

    function distributeFees(address asset) external;

    function pauseDistributions() external;

    function unPauseDistributions() external;

    function setFeeSplit(
        FeeType feeType,
        uint256 treasuryBps,
        uint256 reserveBps,
        uint256 opsBps,
        bool active
    ) external;

    function setTreasury(address newTreasury) external;

    function setYieldReserve(address newReserve) external;

    function setOpsWallet(address newOps) external;

    function authorizeCollector(address collector, bool allowed) external;

    // ==================== VIEW FUNCTIONS ====================

    function getPendingDistributions(address asset)
        external
        view
        returns (uint256 treasuryPending, uint256 reservePending, uint256 opsPending);

    function getAssetStats(address asset)
        external
        view
        returns (
            uint256 totalCollected,
            uint256 totalDistributed,
            uint256 treasuryCollected,
            uint256 reserveCollected,
            uint256 opsCollected
        );

    function getPoolFeeStats(address pool, address asset)
        external
        view
        returns (uint256 totalCollected, uint256[] memory byFeeType);

    function getMinSweepThreshold() external view returns (uint256);
}
