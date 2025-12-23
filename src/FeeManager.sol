// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "./interfaces/IFeeManager.sol";
import "./interfaces/IPoolRegistry.sol";
import "./AccessManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title FeeManager - Protocol Treasury & Fee Collection
 * @dev Acts as protocol treasury with daily expense ratio accrual and transaction fee collection
 * @notice Manages all protocol fees, expense ratios, and treasury functions
 */
contract FeeManager is IFeeManager, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    AccessManager public accessManager;
    IPoolRegistry public poolRegistry;
    address public manager;
    address public stableYieldManager;
    address public treasury;
    
    /// @dev Treasury holdings by asset
    mapping(address => uint256) public treasuryBalances;
    
    /// @dev Transaction fees collected per pool per asset
    mapping(address => mapping(address => uint256)) public transactionFees;
    
    /// @dev Performance fees collected per pool
    mapping(address => uint256) public performanceFees;
    
    FeeConfig private _defaultFeeConfig;
    mapping(address => FeeConfig) public poolFeeConfigs;
    mapping(address => FeeDistribution) public poolFeeDistributions;
    mapping(address => mapping(string => uint256)) public accumulatedFees;
    mapping(address => uint256) public totalFeesCollected;
    mapping(address => uint256) public lastDistributionTime;
    
    uint256 public constant MAX_FEE_RATE = 1000; // 10% maximum fee rate
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_DISTRIBUTION_INTERVAL = 24 hours;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    
    event FeeConfigUpdated(
        address indexed pool,
        uint256 protocolFee,
        uint256 spvFee,
        uint256 performanceFee,
        uint256 earlyWithdrawalFee
    );
    
    event FeeCollected(
        address indexed pool,
        address indexed payer,
        uint256 amount,
        string feeType,
        uint256 timestamp
    );
    
    event FeeDistributed(
        address indexed pool,
        address indexed recipient,
        uint256 amount,
        string feeType,
        uint256 timestamp
    );
    
    event DefaultFeeConfigUpdated(uint256 protocolFee, uint256 spvFee, uint256 performanceFee);
    event EmergencyWithdrawal(address indexed token, uint256 amount, address indexed recipient);
    
    // Treasury Events
    event TransactionFeeCollected(address indexed pool, address indexed asset, uint256 amount, string feeType);
    event TreasuryDeposit(address indexed asset, uint256 amount, uint256 newBalance);
    event TreasuryWithdrawal(address indexed asset, address indexed recipient, uint256 amount, uint256 remainingBalance);
    event PerformanceFeeCollected(address indexed pool, uint256 amount, uint256 totalCollected);

    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "FeeManager/access-denied");
        _;
    }
    
    modifier onlyValidPool(address pool) {
        require(pool != address(0), "FeeManager/invalid-pool");
        _;
    }
    
    modifier onlyValidManager() {
        require(msg.sender == manager || msg.sender == stableYieldManager, "FeeManager/only-manager");
        _;
    }
    
    modifier whenFeeManagerNotPaused() {
        require(!paused(), "FeeManager/paused");
        _;
    }
    
    constructor(
        address _accessManager,
        address _treasury
    ) {
        require(_accessManager != address(0), "FeeManager/invalid-access-manager");
        require(_treasury != address(0), "FeeManager/invalid-treasury");
        
        accessManager = AccessManager(_accessManager);
        treasury = _treasury;
        
        // Set default fee configuration (transaction fees only)
        _defaultFeeConfig = FeeConfig({
            protocolFee: 200,        // 2% transaction fee for deposits/withdrawals
            spvFee: 100,             // 1% SPV fee
            performanceFee: 100,     // 10% performance fee on profits
            earlyWithdrawalFee: 0,   // No early withdrawal fees for flex pools
            refundGasFee: 10,        // 0.1%
            isActive: true
        });
    }
    
    function setManagers(address _manager, address _stableYieldManager, address _poolRegistry) external {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "FeeManager/only-admin");
        require(_poolRegistry != address(0), "FeeManager/invalid-registry");
        require(_manager != address(0) || _stableYieldManager != address(0), "FeeManager/at-least-one-manager");
        manager = _manager;
        stableYieldManager = _stableYieldManager;
        poolRegistry = IPoolRegistry(_poolRegistry);
    }
    
    function protocolTreasury() external view override returns (address) {
        return address(this); // FeeManager acts as the treasury
    }
    
    function defaultFeeConfig() external view override returns (FeeConfig memory) {
        return _defaultFeeConfig;
    }
    
    function paused() public view override(IFeeManager, Pausable) returns (bool) {
        return Pausable.paused();
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// TREASURY MANAGEMENT //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deposit funds to treasury
     * @param asset Asset to deposit
     * @param amount Amount to deposit
     */
    function depositToTreasury(address asset, uint256 amount) external override onlyRole(accessManager.OPERATOR_ROLE()) nonReentrant {
        require(asset != address(0), "FeeManager/invalid asset");
        require(amount > 0, "FeeManager/invalid amount");
        
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        treasuryBalances[asset] += amount;
        
        emit TreasuryDeposit(asset, amount, treasuryBalances[asset]);
    }


    /**
     * @notice Get treasury balance for an asset
     */
    function getTreasuryBalance(address asset) external view override returns (uint256) {
        return treasuryBalances[asset];
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// TRANSACTION FEE COLLECTION ///////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Collect transaction fee (deposit/withdrawal fees)
     * @param pool Pool address
     * @param asset Asset being collected
     * @param amount Fee amount
     * @param feeType Type of transaction fee
     */
    function collectTransactionFee(
        address pool,
        address asset,
        uint256 amount,
        string memory feeType
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) onlyValidPool(pool) nonReentrant {
        require(asset != address(0), "FeeManager/invalid asset");
        require(amount > 0, "FeeManager/invalid amount");
        require(bytes(feeType).length > 0, "FeeManager/invalid fee type");
        
        // Transfer fee from caller to treasury
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        treasuryBalances[asset] += amount;
        transactionFees[pool][asset] += amount;
        
        emit TransactionFeeCollected(pool, asset, amount, feeType);
    }

    /**
     * @notice Collect performance fee
     * @param pool Pool address
     * @param asset Pool's base asset
     * @param amount Performance fee amount
     */
    function collectPerformanceFee(
        address pool,
        address asset,
        uint256 amount
    ) external override onlyRole(accessManager.OPERATOR_ROLE()) onlyValidPool(pool) nonReentrant {
        require(asset != address(0), "FeeManager/invalid asset");
        require(amount > 0, "FeeManager/invalid amount");
        
        // Transfer fee from caller to treasury
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        treasuryBalances[asset] += amount;
        performanceFees[pool] += amount;
        
        emit PerformanceFeeCollected(pool, amount, performanceFees[pool]);
    }

    /**
     * @notice Get transaction fees collected for a pool and asset
     */
    function getTransactionFees(address pool, address asset) external view returns (uint256) {
        return transactionFees[pool][asset];
    }

    /**
     * @notice Get performance fees collected for a pool
     */
    function getPerformanceFees(address pool) external view override returns (uint256) {
        return performanceFees[pool];
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FEE CALCULATIONS /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function calculateProtocolFee(address pool, uint256 amount) external view override returns (uint256) {
        if (amount == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        uint256 pironFees = config.protocolFee + config.spvFee; 
        return (amount * pironFees) / BASIS_POINTS;
    }
    
    function calculateSpvFee(address pool, uint256 amount) external view override returns (uint256) {
        if (amount == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        return (amount * config.spvFee) / BASIS_POINTS;
    }
    
    function calculatePerformanceFee(address pool, uint256 profit) external view override returns (uint256) {
        if (profit == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        return (profit * config.performanceFee) / BASIS_POINTS;
    }
    
    function calculateEarlyWithdrawalFee(address pool, uint256 amount) external view override returns (uint256) {
        if (amount == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        return (amount * config.earlyWithdrawalFee) / BASIS_POINTS;
    }
    
    function calculateRefundGasFee(address pool, uint256 refundAmount) external view override returns (uint256) {
        if (refundAmount == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        return (refundAmount * config.refundGasFee) / BASIS_POINTS;
    }
    
    function calculateDynamicWithdrawalFee(
        address pool,
        uint256 amount,
        uint256 depositTime
    ) external view returns (uint256) {
        if (amount == 0 || depositTime == 0) return 0;
        
        uint256 timeHeld = block.timestamp - depositTime;
        uint256 baseFee = this.calculateEarlyWithdrawalFee(pool, amount);
        
        // Dynamic fee based on time held
        if (timeHeld < 7 days) {
            return (baseFee * 250) / 100; // 2.5x base fee for < 1 week
        } else if (timeHeld < 30 days) {
            return (baseFee * 150) / 100; // 1.5x base fee for < 1 month
        } else if (timeHeld < 90 days) {
            return baseFee; // Base fee for < 3 months
        } else {
            return baseFee / 2; // 0.5x base fee for > 3 months
        }
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FEE CONFIGURATION ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function getPoolFeeConfig(address pool) public view override returns (FeeConfig memory) {
        FeeConfig memory config = poolFeeConfigs[pool];
        
        // If pool doesn't have custom config, return default
        if (!config.isActive) {
            return _defaultFeeConfig;
        }
        
        return config;
    }
    
    function getFeeDistribution(address pool) public view override returns (FeeDistribution memory) {
        FeeDistribution memory distribution = poolFeeDistributions[pool];
        
        // If pool doesn't have custom distribution, return default
        if (distribution.protocolTreasury == address(0)) {
            return FeeDistribution({
                protocolTreasury: address(this), // FeeManager acts as treasury
                spvAddress: address(0), // This should be set by the pool
                protocolShare: 5000,    // 50%
                spvShare: 5000         // 50%
            });
        }
        
        return distribution;
    }
    
    function canDistributeFees(address pool) public view returns (bool) {
        return block.timestamp >= lastDistributionTime[pool] + MIN_DISTRIBUTION_INTERVAL;
    }
    
    function setPoolFeeConfig(
        address pool,
        FeeConfig memory config
    ) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) onlyValidPool(pool) {
        require(config.protocolFee <= MAX_FEE_RATE, "FeeManager/protocol-fee-too-high");
        require(config.spvFee <= MAX_FEE_RATE, "FeeManager/spv-fee-too-high");
        require(config.performanceFee <= MAX_FEE_RATE, "FeeManager/performance-fee-too-high");
        require(config.earlyWithdrawalFee <= MAX_FEE_RATE, "FeeManager/withdrawal-fee-too-high");
        require(config.refundGasFee <= MAX_FEE_RATE, "FeeManager/refund-fee-too-high");
        
        poolFeeConfigs[pool] = config;
        
        emit FeeConfigUpdated(
            pool,
            config.protocolFee,
            config.spvFee,
            config.performanceFee,
            config.earlyWithdrawalFee
        );
    }
    
    function setDefaultFeeConfig(
        FeeConfig memory config
    ) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(config.protocolFee <= MAX_FEE_RATE, "FeeManager/protocol-fee-too-high");
        require(config.spvFee <= MAX_FEE_RATE, "FeeManager/spv-fee-too-high");
        require(config.performanceFee <= MAX_FEE_RATE, "FeeManager/performance-fee-too-high");
        require(config.earlyWithdrawalFee <= MAX_FEE_RATE, "FeeManager/withdrawal-fee-too-high");
        require(config.refundGasFee <= MAX_FEE_RATE, "FeeManager/refund-fee-too-high");
        
        _defaultFeeConfig = config;
        
        emit DefaultFeeConfigUpdated(
            config.protocolFee,
            config.spvFee,
            config.performanceFee
        );
    }
    
    function setFeeDistribution(
        address pool,
        FeeDistribution memory distribution
    ) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) onlyValidPool(pool) {
        require(distribution.protocolTreasury != address(0), "FeeManager/invalid-protocol-treasury");
        require(distribution.spvAddress != address(0), "FeeManager/invalid-spv-address");
        require(distribution.protocolShare + distribution.spvShare == BASIS_POINTS, "FeeManager/invalid-share-distribution");
        
        poolFeeDistributions[pool] = distribution;
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// FEE COLLECTION & DISTRIBUTION ////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function collectFee(
        address pool,
        address payer,
        uint256 amount,
        string memory feeType
    ) external override onlyRole(accessManager.SPV_ROLE()) onlyValidPool(pool) whenFeeManagerNotPaused nonReentrant {
        require(amount > 0, "FeeManager/invalid-amount");
        require(bytes(feeType).length > 0, "FeeManager/invalid-fee-type");
        
        accumulatedFees[pool][feeType] += amount;
        
        emit FeeCollected(pool, payer, amount, feeType, block.timestamp);
    }
    
    function distributeFees(address pool) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) onlyValidPool(pool) whenFeeManagerNotPaused {
        _distributeFees(pool);
    }
    
    function distributeFeesBatch(address[] memory pools) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) whenFeeManagerNotPaused nonReentrant {
        require(pools.length > 0, "FeeManager/empty-pools-array");
        require(pools.length <= 50, "FeeManager/too-many-pools");
        
        for (uint256 i = 0; i < pools.length; i++) {
            if (canDistributeFees(pools[i])) {
                this.distributeFees(pools[i]);
            }
        }
    }
    
    function getAccumulatedFees(address pool) public view override returns (uint256) {
        return accumulatedFees[pool]["protocol"] +
               accumulatedFees[pool]["spv"] +
               accumulatedFees[pool]["performance"] +
               accumulatedFees[pool]["earlyWithdrawal"] +
               accumulatedFees[pool]["refundGas"];
    }
    
    function getAccumulatedFeesByType(address pool, string memory feeType) external view returns (uint256) {
        return accumulatedFees[pool][feeType];
    }
    
    function getTotalFeesCollected(address pool) external view returns (uint256) {
        return totalFeesCollected[pool];
    }
    
    function getLastDistributionTime(address pool) external view returns (uint256) {
        return lastDistributionTime[pool];
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY & ADMIN ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function pause() external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        _pause();
    }
    
    function unpause() external override onlyRole(accessManager.EMERGENCY_ROLE()) {
        _unpause();
    }
    
    function emergencyWithdraw(
        address token,
        uint256 amount,
        address recipient
    ) external onlyRole(accessManager.EMERGENCY_ROLE()) {
        require(token != address(0), "FeeManager/invalid-token");
        require(amount > 0, "FeeManager/invalid-amount");
        require(recipient != address(0), "FeeManager/invalid-recipient");
        
        IERC20(token).safeTransfer(recipient, amount);
        
        emit EmergencyWithdrawal(token, amount, recipient);
    }
    
    function batchDistributeFees(address[] calldata pools) external onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) whenFeeManagerNotPaused {
        for (uint256 i = 0; i < pools.length; i++) {
            if (canDistributeFees(pools[i])) {
                _distributeFees(pools[i]);
            }
        }
    }
    
    function _distributeFees(address pool) internal nonReentrant {
        require(pool != address(0), "FeeManager/invalid-pool");
        require(canDistributeFees(pool), "FeeManager/distribution-too-frequent");
        
        FeeDistribution memory distribution = getFeeDistribution(pool);
        require(distribution.spvAddress != address(0), "FeeManager/spv-not-set");
        
        // Get total accumulated fees for this pool
        uint256 totalFees = getAccumulatedFees(pool);
        require(totalFees > 0, "FeeManager/no-fees-to-distribute");
        
        uint256 protocolAmount = (totalFees * distribution.protocolShare) / BASIS_POINTS;
        uint256 spvAmount = totalFees - protocolAmount;
        
        // Reset accumulated fees
        delete accumulatedFees[pool]["protocol"];
        delete accumulatedFees[pool]["spv"];
        delete accumulatedFees[pool]["performance"];
        delete accumulatedFees[pool]["earlyWithdrawal"];
        delete accumulatedFees[pool]["refundGas"];
        
        lastDistributionTime[pool] = block.timestamp;
        
        emit FeeDistributed(pool, distribution.protocolTreasury, protocolAmount, "protocol", block.timestamp);
        emit FeeDistributed(pool, distribution.spvAddress, spvAmount, "spv", block.timestamp);
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW HELPERS /////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function estimateFeesForAmount(
        address pool,
        uint256 amount,
        string memory feeType
    ) external view returns (uint256) {
        if (keccak256(bytes(feeType)) == keccak256(bytes("protocol"))) {
            return this.calculateProtocolFee(pool, amount);
        } else if (keccak256(bytes(feeType)) == keccak256(bytes("spv"))) {
            return this.calculateSpvFee(pool, amount);
        } else if (keccak256(bytes(feeType)) == keccak256(bytes("performance"))) {
            return this.calculatePerformanceFee(pool, amount);
        } else if (keccak256(bytes(feeType)) == keccak256(bytes("earlyWithdrawal"))) {
            return this.calculateEarlyWithdrawalFee(pool, amount);
        } else if (keccak256(bytes(feeType)) == keccak256(bytes("refundGas"))) {
            return this.calculateRefundGasFee(pool, amount);
        } else {
            return 0;
        }
    }
    
    function getPoolFeesSummary(address pool) external view returns (
        uint256 totalCollected,
        uint256 lastDistribution,
        uint256 protocolFees,
        uint256 spvFees,
        uint256 poolPerformanceFees,
        uint256 withdrawalFees,
        uint256 refundFees
    ) {
        return (
            totalFeesCollected[pool],
            lastDistributionTime[pool],
            accumulatedFees[pool]["protocol"],
            accumulatedFees[pool]["spv"],
            accumulatedFees[pool]["performance"],
            accumulatedFees[pool]["earlyWithdrawal"],
            accumulatedFees[pool]["refundGas"]
        );
    }

    function withdrawFromTreasury(address asset, uint256 amount, address to) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(to != address(0), "FeeManager/invalid recipient");
        require(amount > 0, "FeeManager/invalid amount");
        require(treasuryBalances[asset] >= amount, "FeeManager/insufficient treasury balance");
        
        treasuryBalances[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        
        emit TreasuryWithdrawal(asset, to, amount, treasuryBalances[asset]);
    }
}
