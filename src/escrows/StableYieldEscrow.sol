// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";
import "../interfaces/IFeeManager.sol";
import "../interfaces/IYieldReserveEscrow.sol";

/**
 * @title StableYieldEscrow
 * @dev Secure custody for a single StableYieldPool. Holds user deposits, tracks
 *      reserves, processes deposit/withdrawal fees, manages SPV allocations,
 *      and routes protocol capital from YieldReserveEscrow.
 */
contract StableYieldEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    // ==================== STATE ====================

    using SafeERC20 for IERC20;

    IERC20 public asset;

    address public stableYieldPool;
    address public stableYieldManager;

    AccessManager public accessManager;
    
    uint256 public version;

    string public poolName;

    uint256 public poolReserves;
    uint256 public depositFeesCollected;
    uint256 public withdrawalFeesCollected;

    bool public emergencyWithdrawalEnabled;

    mapping(address => uint256) public spvAllocations;

    uint256 public protocolFundsFromReserve; 
    uint256 public protocolFundsDirectDeposit; 
    
    address public feeManager;
    address public yieldReserve;

    // ==================== EVENTS ====================

    event FundsDeposited(address indexed from, uint256 amount, uint256 newCashBuffer);
    event FundsWithdrawn(address indexed to, uint256 amount, uint256 remainingCashBuffer);
    event FundsAllocated(uint256 reserveAmount, uint256 depositFee);
    event WithdrawalFeeAllocated(uint256 withdrawalFee);
    event FeesCollected(uint256 transactionFees, address treasury);
    event EmergencyWithdrawalToggled(bool enabled);
    event PoolNameUpdated(string newPoolName);
    event SPVAllocation(address indexed spv, uint256 amount, uint256 remainingCashBuffer);
    event SPVLiquidityRequested(address indexed spv, uint256 amount, uint256 timestamp);
    event SPVLiquidityReceived(address indexed spv, uint256 amount, uint256 newCashBuffer);
    event PoolLinked(address indexed stableYieldPool);
    
    event ProtocolFundsReceived(address indexed from, uint256 amount);
    event ProtocolFundsReleased(address indexed to, uint256 amount);
    event DustSwept(address indexed feeManager, uint256 amount);
    event DepositFeeCollected(uint256 amount);
    event WithdrawalFeeCollected(uint256 amount);
    event FeeManagerUpdated(address indexed feeManager);
    event YieldReserveUpdated(address indexed yieldReserve);

    // ==================== MODIFIERS ====================

    modifier onlyStableYieldPool() {
        require(msg.sender == stableYieldPool, "StableYieldEscrow/only stable yield pool");
        _;
    }

    modifier onlyStableYieldPoolOrManager() {
        require(
            msg.sender == stableYieldPool ||  
            msg.sender == stableYieldManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), 
            "StableYieldEscrow/only pool or manager"
        );
        _;
    }

    modifier onlyOperator() {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "StableYieldEscrow/not operator");
        _;
    }

    modifier onlyFactory () {
        require (accessManager.hasRole(accessManager.FACTORY_ROLE(), msg.sender), "StableYieldEscrow/not factory");

        _;
    }

    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "StableYieldEscrow/not admin");
        _;
    }

    modifier whenEmergencyEnabled() {
        require(emergencyWithdrawalEnabled, "StableYieldEscrow/emergency disabled");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        address accessManager_,
        string memory poolName_
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        require(asset_ != address(0), "StableYieldEscrow/invalid asset");
        require(accessManager_ != address(0), "StableYieldEscrow/invalid access manager");
        require(bytes(poolName_).length > 0, "StableYieldEscrow/invalid pool name");

        asset = IERC20(asset_);
        stableYieldPool = address(0); 
        accessManager = AccessManager(accessManager_);
        poolName = poolName_;
        version = 1;

    }

    function setStableYieldPool(address pool_) external onlyFactory {
        require(stableYieldPool == address(0), "StableYieldEscrow/pool already set");
        require(pool_ != address(0), "StableYieldEscrow/invalid pool");
        stableYieldPool = pool_;
        emit PoolLinked(pool_);
    }
    
    function setStableYieldManager(address manager_) external onlyFactory {
        require(manager_ != address(0), "StableYieldEscrow/invalid manager");
        require(stableYieldManager == address(0), "StableYieldEscrow/manager already set");
        
        stableYieldManager = manager_;
    }

    function setFeeManager(address feeManager_) external onlyFactory {
        require(feeManager_ != address(0), "StableYieldEscrow/invalid fee manager");
        feeManager = feeManager_;
        emit FeeManagerUpdated(feeManager_);
    }

    function setYieldReserve(address yieldReserve_) external onlyFactory {
        require(yieldReserve_ != address(0), "StableYieldEscrow/invalid yield reserve");
        yieldReserve = yieldReserve_;
        emit YieldReserveUpdated(yieldReserve_);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("StableYieldEscrow/upgrades disabled for security");
    }

    function getVersion() external view returns (uint256) {
        return version;
    }

    function processDeposit(uint256 amount, uint256 feeBps) external onlyStableYieldPoolOrManager nonReentrant returns (uint256 netAmount, uint256 fee) {
        require(amount > 0, "StableYieldEscrow/invalid amount");
        
        uint256 currentBalance = asset.balanceOf(address(this));
        require(currentBalance >= poolReserves + amount, "StableYieldEscrow/insufficient balance");
        
        fee = (feeBps > 0 && feeManager != address(0)) ? (amount * feeBps) / 10000 : 0;
        netAmount = amount - fee;
        
        poolReserves += netAmount;
        
        if (fee > 0) {
            depositFeesCollected += fee;
            asset.safeTransfer(feeManager, fee);
            IFeeManager(feeManager).recordFeeOnly(
                stableYieldPool,
                address(asset),
                fee,
                IFeeManager.FeeType.DEPOSIT_FEE
            );
            emit DepositFeeCollected(fee);
        }
        
        emit FundsAllocated(netAmount, fee);
    }

    function collectWithdrawalFee(uint256 amount) external onlyStableYieldPoolOrManager nonReentrant {
        require(feeManager != address(0), "StableYieldEscrow/fee manager not set");
        require(amount > 0, "StableYieldEscrow/invalid fee amount");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient reserves");
        
        poolReserves -= amount;
        withdrawalFeesCollected += amount;
        
        asset.safeTransfer(feeManager, amount);
        IFeeManager(feeManager).recordFeeOnly(
            stableYieldPool,
            address(asset),
            amount,
            IFeeManager.FeeType.WITHDRAWAL_FEE
        );
        
        emit WithdrawalFeeCollected(amount);
    }

    function withdraw( 
        address to,
        uint256 amount
    ) external onlyStableYieldPoolOrManager nonReentrant {
        require(to != address(0), "StableYieldEscrow/invalid recipient");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient pool reserves");

        poolReserves -= amount;
        asset.safeTransfer(to, amount);

        emit FundsWithdrawn(to, amount, poolReserves);
    }

    function receiveProtocolFundsFromAdmin(uint256 amount) external onlyAdmin nonReentrant {
        require(amount > 0, "StableYieldEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        protocolFundsDirectDeposit += amount;
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDeposit(stableYieldPool, amount);
        }
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function recordProtocolFundsFromReserve(uint256 amount) external {
        require(
            msg.sender == yieldReserve || 
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "StableYieldEscrow/unauthorized"
        );
        require(amount > 0, "StableYieldEscrow/invalid amount");
        
        protocolFundsFromReserve += amount;
        poolReserves += amount;
        
        emit ProtocolFundsReceived(msg.sender, amount);
    }

    function returnProtocolFundsToReserve(uint256 amount) external nonReentrant {
        require(
            msg.sender == stableYieldManager ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "StableYieldEscrow/unauthorized"
        );
        require(yieldReserve != address(0), "StableYieldEscrow/yield reserve not set");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(protocolFundsFromReserve >= amount, "StableYieldEscrow/exceeds reserve funds");
        
        protocolFundsFromReserve -= amount;
        if (poolReserves >= amount) {
            poolReserves -= amount;
        } else {
            poolReserves = 0;
        }
        
        asset.forceApprove(yieldReserve, amount);
        IYieldReserveEscrow(yieldReserve).receiveRecalledFunds(stableYieldPool, amount);
        
        emit ProtocolFundsReleased(yieldReserve, amount);
    }

    function releaseDirectDepositFunds(address to, uint256 amount) external onlyAdmin nonReentrant {
        require(to != address(0), "StableYieldEscrow/invalid recipient");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(protocolFundsDirectDeposit >= amount, "StableYieldEscrow/exceeds direct deposits");
        
        protocolFundsDirectDeposit -= amount;
        
        asset.safeTransfer(to, amount);
        
        if (yieldReserve != address(0)) {
            IYieldReserveEscrow(yieldReserve).recordDirectDepositWithdrawn(stableYieldPool, amount);
        }
        
        emit ProtocolFundsReleased(to, amount);
    }

    function getProtocolFundsHeld() external view returns (uint256) {
        return protocolFundsFromReserve + protocolFundsDirectDeposit;
    }

    function sweepDust() external onlyOperator nonReentrant {
        require(feeManager != address(0), "StableYieldEscrow/fee manager not set");
        
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = poolReserves + protocolFundsDirectDeposit;
        
        require(actualBalance > expectedBalance, "StableYieldEscrow/no dust to sweep");
        
        uint256 dust = actualBalance - expectedBalance;
        
        uint256 minThreshold = IFeeManager(feeManager).getMinSweepThreshold();
        require(dust >= minThreshold, "StableYieldEscrow/dust below threshold");
        
        asset.safeTransfer(feeManager, dust);
        IFeeManager(feeManager).recordFeeOnly(
            stableYieldPool,
            address(asset),
            dust,
            IFeeManager.FeeType.OTHER
        );
        
        emit DustSwept(feeManager, dust);
    }

    function getSweepableDust() external view returns (uint256 dust) {
        uint256 actualBalance = asset.balanceOf(address(this));
        uint256 expectedBalance = poolReserves + protocolFundsDirectDeposit;
        
        if (actualBalance > expectedBalance) {
            return actualBalance - expectedBalance;
        }
        return 0;
    }

    function allocateToSPV(address spvAddress, uint256 amount) external onlyOperator nonReentrant {
        require(spvAddress != address(0), "StableYieldEscrow/invalid SPV");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient pool reserves");
        
        poolReserves -= amount;
        spvAllocations[spvAddress] += amount;
        
        asset.safeTransfer(spvAddress, amount);
        
        emit SPVAllocation(spvAddress, amount, poolReserves);
    }
    
    function recordReceivedLiquidity(uint256 amount) external {
        require(msg.sender == stableYieldManager, "StableYieldEscrow/only manager");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        
        poolReserves += amount;
        
        emit SPVLiquidityReceived(msg.sender, amount, poolReserves);
    }

    function getPoolReserves() external view returns (uint256) {
        return poolReserves;
    }

    function getDepositFeesCollected() external view returns (uint256) {
        return depositFeesCollected;
    }

    function getWithdrawalFeesCollected() external view returns (uint256) {
        return withdrawalFeesCollected;
    }

    function getTotalFeesCollected() external view returns (uint256) {
        return depositFeesCollected + withdrawalFeesCollected;
    }

    function getProtocolFundsFromReserve() external view returns (uint256) {
        return protocolFundsFromReserve;
    }

    function getProtocolFundsDirectDeposit() external view returns (uint256) {
        return protocolFundsDirectDeposit;
    }

    function getTotalBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function getExpectedBalance() external view returns (uint256) {
        return poolReserves + protocolFundsDirectDeposit;
    }

    function getSPVAllocation(address spvAddress) external view returns (uint256) {
        return spvAllocations[spvAddress];
    }

    function toggleEmergencyWithdrawal(bool enabled) external onlyAdmin {
        emergencyWithdrawalEnabled = enabled;
        emit EmergencyWithdrawalToggled(enabled);
    }

    function emergencyWithdraw(
        address to,
        uint256 amount
    ) external onlyAdmin whenEmergencyEnabled nonReentrant {
        require(to != address(0), "StableYieldEscrow/invalid recipient");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(asset.balanceOf(address(this)) >= amount, "StableYieldEscrow/insufficient balance");

        asset.safeTransfer(to, amount);
        
        if (poolReserves >= amount) {
            poolReserves -= amount;
        } else {
            poolReserves = 0;
        }

        emit FundsWithdrawn(to, amount, poolReserves);
    }

}
