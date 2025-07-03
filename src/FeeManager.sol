// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IFeeManager.sol";
import "./AccessManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

contract FeeManager is IFeeManager, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    AccessManager public accessManager;
    address private _protocolTreasury;
    
    FeeConfig private _defaultFeeConfig;
    mapping(address => FeeConfig) public poolFeeConfigs;
    mapping(address => FeeDistribution) public poolFeeDistributions;
    mapping(address => mapping(string => uint256)) public accumulatedFees;
    mapping(address => uint256) public totalFeesCollected;
    mapping(address => uint256) public lastDistributionTime;
    
    uint256 public constant MAX_FEE_RATE = 1000; // 10% maximum fee rate
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MIN_DISTRIBUTION_INTERVAL = 24 hours;
    
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

    
    modifier onlyRole(bytes32 role) {
        require(accessManager.hasRole(role, msg.sender), "FeeManager/access-denied");
        _;
    }
    
    modifier onlyValidPool(address pool) {
        require(pool != address(0), "FeeManager/invalid-pool");
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
        _protocolTreasury = _treasury;
        
        // Set default fee configuration
        _defaultFeeConfig = FeeConfig({
            protocolFee: 50,      // 0.5%
            spvFee: 100,          // 1%
            performanceFee: 200,  // 2%
            earlyWithdrawalFee: 100, // 1%
            refundGasFee: 10,     // 0.1%
            isActive: true
        });
    }
    
    function protocolTreasury() external view override returns (address) {
        return _protocolTreasury;
    }
    
    function defaultFeeConfig() external view override returns (FeeConfig memory) {
        return _defaultFeeConfig;
    }
    
    function paused() public view override(IFeeManager, Pausable) returns (bool) {
        return Pausable.paused();
    }
    
    function calculateProtocolFee(address pool, uint256 amount) external view override returns (uint256) {
        if (amount == 0) return 0;
        
        FeeConfig memory config = getPoolFeeConfig(pool);
        return (amount * config.protocolFee) / BASIS_POINTS;
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
                protocolTreasury: _protocolTreasury,
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
    
    function setProtocolTreasury(address treasury) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) {
        require(treasury != address(0), "FeeManager/invalid-treasury");
        
        address oldTreasury = _protocolTreasury;
        _protocolTreasury = treasury;
        
        emit TreasuryUpdated(oldTreasury, treasury);
    }
    
    function collectFee(
        address pool,
        address payer,
        uint256 amount,
        string memory feeType
    ) external override onlyRole(accessManager.SPV_ROLE()) onlyValidPool(pool) whenFeeManagerNotPaused nonReentrant {
        require(amount > 0, "FeeManager/invalid-amount");
        require(bytes(feeType).length > 0, "FeeManager/invalid-fee-type");
        
        accumulatedFees[pool][feeType] += amount;
        
        emit FeeCollected(pool, payer, amount, feeType);
    }
    
    function distributeFees(address pool) external override onlyRole(accessManager.DEFAULT_ADMIN_ROLE()) onlyValidPool(pool) whenFeeManagerNotPaused nonReentrant {
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
        
        emit FeeDistributed(pool, distribution.protocolTreasury, protocolAmount, "protocol");
        emit FeeDistributed(pool, distribution.spvAddress, spvAmount, "spv");
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
    
    function batchDistributeFees(address[] calldata pools) external whenFeeManagerNotPaused {
        for (uint256 i = 0; i < pools.length; i++) {
            if (canDistributeFees(pools[i])) {
                this.distributeFees(pools[i]);
            }
        }
    }
    
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
        uint256 performanceFees,
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
} 