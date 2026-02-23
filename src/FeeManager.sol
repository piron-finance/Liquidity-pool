// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./AccessManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./interfaces/IFeeManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/**
 * @title FeeManager
 * @dev Protocol treasury and fee collection hub. Collects fees from escrows,
 *      splits them by configurable ratios (treasury/reserve/ops), and distributes
 *      on demand. Each fee type has independent split configuration.
 */
contract FeeManager is  
    IFeeManager,
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable {

    // ==================== STATE ====================

    using SafeERC20 for IERC20;
    AccessManager public accessManager;
    IPoolRegistry public poolRegistry;

    address public treasury;
    address public yieldReserve;
    address public opsWallet;

    uint256 public version;
    bool public distributionPaused;

    mapping(address => bool) public poolFeePaused;

    mapping(address => bool) public authorizedCollectors;
    mapping(FeeType => FeeSplit) public feeSplits;

    mapping(address => AssetFeeAccounting) public assetAccounting;

    mapping(address => uint256) public pendingTreasury;
    mapping(address => uint256) public pendingReserve;
    mapping(address => uint256) public pendingOps;

    mapping(address => mapping(address => uint256)) public poolAssetTotalCollected;
    mapping(address => mapping(address => mapping(FeeType => uint256))) public poolAssetByTypeCollected;

    FeeRateChange[] public feeRateHistory;

    uint256 public minSweepThreshold;

    address[] public trackedAssets;
    mapping(address => bool) public isTrackedAsset;

    uint256 public constant BPS = 10000;

    // ==================== MODIFIERS ====================

    modifier onlyRegisteredPool() {
        require(poolRegistry.isManagedPool(msg.sender) || poolRegistry.isRegisteredPool(msg.sender), "FeeManager/pool not found");
        _;
    }

    modifier poolExists(address poolAddress) {
        require(poolRegistry.isManagedPool(poolAddress) || poolRegistry.isRegisteredPool(poolAddress), "FeeManager/pool not found");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "FeeManager/unauthorized action");
        _;
    }

    modifier onlyCollector() {
        require(authorizedCollectors[msg.sender], "FeeManager/unauthorized collector");
        _;
    }

    modifier poolFeeNotPaused(address pool) {
        require(!poolFeePaused[pool], "FeeManager/pool fees paused");
        _;
    }

    // ==================== INITIALIZATION ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize with core addresses and default fee splits.
     * @param _accessManager AccessManager contract
     * @param _poolRegistry PoolRegistry proxy
     * @param _yieldReserve YieldReserveEscrow proxy
     * @param _treasury Treasury wallet
     * @param _opsWallet Operations wallet
     */
    function initialize(
        address _accessManager,
        address _poolRegistry,
        address _yieldReserve,
        address _treasury,
        address _opsWallet
    ) external initializer {
        require(_accessManager != address(0), "FeeManager/invalid accessManager");
        require(_poolRegistry != address(0), "FeeManager/invalid poolRegistry");
        require(_yieldReserve != address(0), "FeeManager/invalid yieldReserve");
        require(_treasury != address(0), "FeeManager/invalid treasury"); 
        require(_opsWallet != address(0), "FeeManager/invalid opsWallet");

        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        accessManager = AccessManager(_accessManager);
        poolRegistry = IPoolRegistry(_poolRegistry);

        yieldReserve = _yieldReserve;
        treasury = _treasury;
        opsWallet = _opsWallet;
        version = 1;
        minSweepThreshold = 100e6;

        feeSplits[FeeType.DEPOSIT_FEE] = FeeSplit({treasuryBps: 10_000, reserveBps: 0, opsBps: 0, active: true});
        feeSplits[FeeType.WITHDRAWAL_FEE] = FeeSplit({treasuryBps: 10_000, reserveBps: 0, opsBps: 0, active: true});
        feeSplits[FeeType.EARLY_EXIT_PENALTY] = FeeSplit({treasuryBps: 0, reserveBps: 10_000, opsBps: 0, active: true});
        feeSplits[FeeType.OTHER] = FeeSplit({treasuryBps: 10_000, reserveBps: 0, opsBps: 0, active: true});
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(accessManager.MULTISIG_ADMIN_ROLE()) {
        require(newImplementation != address(0), "FeeManager/invalid implementation address");
        version += 1;
    }

    // ==================== FEE COLLECTION ====================

    /**
     * @dev Collect fee via safeTransferFrom from an authorized escrow.
     * @param pool Pool the fee originates from
     * @param asset Token being collected
     * @param amount Fee amount in asset decimals
     * @param feeType Classification of the fee
     */
    function collectFee(
        address pool,
        address asset,
        uint256 amount,
        FeeType feeType
    ) external override poolExists(pool) onlyCollector poolFeeNotPaused(pool) nonReentrant {
        require(pool != address(0), "FeeManager/invalid pool address");
        require(asset != address(0), "FeeManager/invalid asset");
        require(amount > 0, "FeeManager/invalid amount");

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        _trackAsset(asset);
        _bookKeepFee(msg.sender, pool, asset, amount, feeType);
    }

    /**
     * @dev Record a fee without pulling tokens (tokens already sent separately).
     * @param pool Pool the fee originates from
     * @param asset Token being recorded
     * @param amount Fee amount
     * @param feeType Classification of the fee
     */
    function recordFeeOnly(
        address pool,
        address asset,
        uint256 amount,
        FeeType feeType
    ) external override poolExists(pool) onlyCollector poolFeeNotPaused(pool) {
        require(pool != address(0), "FeeManager/invalid pool address");
        require(asset != address(0), "FeeManager/invalid asset");
        require(amount > 0, "FeeManager/invalid amount");

        _trackAsset(asset);
        _bookKeepFee(msg.sender, pool, asset, amount, feeType);
    }

    function _trackAsset(address asset) internal {
        if (!isTrackedAsset[asset]) {
            trackedAssets.push(asset);
            isTrackedAsset[asset] = true;
        }
    }

    function _bookKeepFee(
        address collector,
        address pool,
        address asset,
        uint256 amount,
        FeeType feeType
    ) internal {
        FeeSplit memory split = feeSplits[feeType];

        require(split.active, "FeeManager/fee type not active");
        require(split.treasuryBps + split.reserveBps + split.opsBps == BPS, "FeeManager/invalid split ratio");

        uint256 toTreasury = (amount * split.treasuryBps) / BPS;
        uint256 toReserve = (amount * split.reserveBps) / BPS;
        uint256 toOps = amount - toTreasury - toReserve;

        pendingTreasury[asset] += toTreasury; 
        pendingReserve[asset] += toReserve;
        pendingOps[asset] += toOps;

        AssetFeeAccounting storage a = assetAccounting[asset];

        a.totalCollected += amount;
        a.treasuryCollected += toTreasury;
        a.reserveCollected += toReserve;
        a.opsCollected += toOps;

        poolAssetTotalCollected[pool][asset] += amount;
        poolAssetByTypeCollected[pool][asset][feeType] += amount;

        emit FeeCollected(collector, pool, asset, amount, feeType);
    }

    // ==================== FEE DISTRIBUTION ====================

    /**
     * @dev Distribute all pending fees for an asset to treasury, reserve, and ops.
     * @param asset Token to distribute
     */
    function distributeFees(address asset) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) nonReentrant {
        require(!distributionPaused, "FeeManager/distribution paused");
        require(asset != address(0), "FeeManager/invalid asset");

        uint256 t = pendingTreasury[asset];
        uint256 r = pendingReserve[asset];
        uint256 o = pendingOps[asset];

        require(t > 0 || r > 0 || o > 0, "FeeManager/no fees to distribute");

        pendingTreasury[asset] = 0;
        pendingReserve[asset] = 0;
        pendingOps[asset] = 0;

        if (t > 0) IERC20(asset).safeTransfer(treasury, t);
        if (r > 0) IERC20(asset).safeTransfer(yieldReserve, r);
        if (o > 0) IERC20(asset).safeTransfer(opsWallet, o);

        assetAccounting[asset].totalDistributed += (t + r + o);

        emit FeesDistributed(asset, t, r, o);
    }

    /**
     * @dev Halt all fee distributions globally.
     */
    function pauseDistributions() external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        distributionPaused = true;
        emit DistributionsPaused(true);
    }

    /**
     * @dev Resume fee distributions.
     */
    function unPauseDistributions() external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        distributionPaused = false;
        emit DistributionsPaused(false);
    }

    /**
     * @dev Pause fee collection for a single pool.
     * @param pool Pool to pause
     */
    function pausePoolFees(address pool) external onlyRole(accessManager.OPERATOR_ROLE()) {
        poolFeePaused[pool] = true;
        emit PoolFeePaused(pool, true);
    }

    /**
     * @dev Resume fee collection for a single pool.
     * @param pool Pool to unpause
     */
    function unpausePoolFees(address pool) external onlyRole(accessManager.OPERATOR_ROLE()) {
        poolFeePaused[pool] = false;
        emit PoolFeePaused(pool, false);
    }

    // ==================== GOVERNANCE CONFIG ====================

    /**
     * @dev Update the fee split ratios for a given fee type.
     * @param feeType Fee category to configure
     * @param _treasuryBps Basis points routed to treasury
     * @param _reserveBps Basis points routed to yield reserve
     * @param _opsBps Basis points routed to ops wallet
     * @param _active Whether this fee type is enabled
     */
    function setFeeSplit(
        FeeType feeType,
        uint256 _treasuryBps,
        uint256 _reserveBps,
        uint256 _opsBps,
        bool _active
    ) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_treasuryBps + _reserveBps + _opsBps == BPS, "FeeManager/invalid fee split");

        FeeSplit memory oldSplit = feeSplits[feeType];

        feeSplits[feeType] = FeeSplit({
            treasuryBps: _treasuryBps,
            reserveBps: _reserveBps,
            opsBps: _opsBps,
            active: _active
        });

        feeRateHistory.push(FeeRateChange({
            feeType: feeType,
            oldTreasuryBps: oldSplit.treasuryBps,
            newTreasuryBps: _treasuryBps,
            oldReserveBps: oldSplit.reserveBps,
            newReserveBps: _reserveBps,
            oldOpsBps: oldSplit.opsBps,
            newOpsBps: _opsBps,
            timestamp: block.timestamp,
            changedBy: msg.sender
        }));

        emit FeeSplitUpdated(feeType, _treasuryBps, _reserveBps, _opsBps, _active);
    }

    /**
     * @dev Authorize or deauthorize an escrow as a fee collector.
     *      Callable by DEFAULT_ADMIN_ROLE or FACTORY_ROLE.
     * @param collector Escrow address
     * @param allowed Whether to authorize or deauthorize
     */
    function authorizeCollector(address collector, bool allowed) external override {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.FACTORY_ROLE(), msg.sender),
            "FeeManager/unauthorized action"
        );
        require(collector != address(0), "FeeManager/invalid collector");
        require(authorizedCollectors[collector] != allowed, "FeeManager/no state change");

        authorizedCollectors[collector] = allowed;

        emit CollectorAuthorized(collector, allowed);
    }

    /**
     * @dev Update the treasury wallet address.
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_treasury != address(0), "FeeManager/invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(treasury);
    }

    /**
     * @dev Update the yield reserve address.
     * @param _yieldReserve New yield reserve address
     */
    function setYieldReserve(address _yieldReserve) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_yieldReserve != address(0), "FeeManager/invalid yieldReserve");
        yieldReserve = _yieldReserve;
        emit YieldReserveUpdated(_yieldReserve);
    }

    /**
     * @dev Update the operations wallet address.
     * @param _opsWallet New ops wallet address
     */
    function setOpsWallet(address _opsWallet) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(_opsWallet != address(0), "FeeManager/invalid opsWallet");
        opsWallet = _opsWallet;
        emit OpsWalletUpdated(_opsWallet);
    }

    /**
     * @dev Set the minimum threshold for dust sweep operations.
     * @param _threshold Minimum amount in asset decimals
     */
    function setMinSweepThreshold(uint256 _threshold) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        minSweepThreshold = _threshold;
        emit MinSweepThresholdUpdated(_threshold);
    }

    // ==================== VIEW ====================

    function getPendingDistributions(address asset) external view override returns (
        uint256 treasuryPending,
        uint256 reservePending,
        uint256 opsPending
    ) {
        return (pendingTreasury[asset], pendingReserve[asset], pendingOps[asset]);
    }

    function getAssetStats(address asset) external view override returns (
        uint256 totalCollected,
        uint256 totalDistributed,
        uint256 treasuryCollected,
        uint256 reserveCollected,
        uint256 opsCollected
    ) {
        AssetFeeAccounting storage a = assetAccounting[asset];
        return (
            a.totalCollected,
            a.totalDistributed,
            a.treasuryCollected,
            a.reserveCollected,
            a.opsCollected
        );
    }

    function getPoolFeeStats(address pool, address asset) external view override returns (
        uint256 totalCollected,
        uint256[] memory byFeeType
    ) {
        totalCollected = poolAssetTotalCollected[pool][asset];

        byFeeType = new uint256[](uint256(FeeType.OTHER) + 1);

        byFeeType[uint256(FeeType.DEPOSIT_FEE)] = poolAssetByTypeCollected[pool][asset][FeeType.DEPOSIT_FEE];
        byFeeType[uint256(FeeType.WITHDRAWAL_FEE)] = poolAssetByTypeCollected[pool][asset][FeeType.WITHDRAWAL_FEE];
        byFeeType[uint256(FeeType.EARLY_EXIT_PENALTY)] = poolAssetByTypeCollected[pool][asset][FeeType.EARLY_EXIT_PENALTY];
        byFeeType[uint256(FeeType.SPREAD)] = poolAssetByTypeCollected[pool][asset][FeeType.SPREAD];
        byFeeType[uint256(FeeType.EXCESS_YIELD)] = poolAssetByTypeCollected[pool][asset][FeeType.EXCESS_YIELD];
        byFeeType[uint256(FeeType.PERFORMANCE_FEE)] = poolAssetByTypeCollected[pool][asset][FeeType.PERFORMANCE_FEE];
        byFeeType[uint256(FeeType.OTHER)] = poolAssetByTypeCollected[pool][asset][FeeType.OTHER];
    }

    /**
     * @dev Aggregate protocol fee summary across all tracked assets.
     * @return summary Complete protocol fee snapshot
     */
    function getProtocolFeesSummary() external view returns (ProtocolFeesSummary memory summary) {
        uint256 totalCollectedAllTime;
        uint256 totalPendingDistribution;
        uint256 totalDistributedToTreasury;
        uint256 totalDistributedToReserve;
        uint256 totalDistributedToOps;

        for (uint256 i = 0; i < trackedAssets.length; i++) {
            address asset = trackedAssets[i];
            AssetFeeAccounting storage a = assetAccounting[asset];
            
            totalCollectedAllTime += a.totalCollected;
            totalPendingDistribution += pendingTreasury[asset] + pendingReserve[asset] + pendingOps[asset];
            totalDistributedToTreasury += a.treasuryCollected;
            totalDistributedToReserve += a.reserveCollected;
            totalDistributedToOps += a.opsCollected;
        }

        return ProtocolFeesSummary({
            totalCollectedAllTime: totalCollectedAllTime,
            pendingDistribution: totalPendingDistribution,
            distributedToTreasury: totalDistributedToTreasury,
            distributedToReserve: totalDistributedToReserve,
            distributedToOps: totalDistributedToOps,
            assetCount: trackedAssets.length
        });
    }

    function getFeeRateHistory() external view returns (FeeRateChange[] memory) {
        return feeRateHistory;
    }

    function getFeeRateHistoryCount() external view returns (uint256) {
        return feeRateHistory.length;
    }

    function getTrackedAssets() external view returns (address[] memory) {
        return trackedAssets;
    }

    function getFeeSplit(FeeType feeType) external view returns (FeeSplit memory) {
        return feeSplits[feeType];
    }

    function isAuthorizedCollector(address collector) external view returns (bool) {
        return authorizedCollectors[collector];
    }

    function getMinSweepThreshold() external view returns (uint256) {
        return minSweepThreshold;
    }
}
