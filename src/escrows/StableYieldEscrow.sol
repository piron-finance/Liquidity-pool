// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";

/**
 * @title StableYieldEscrow
 * @dev Secure custody for StableYieldPool instances with flexible stablecoin support
 * @notice Handles asset custody and SPV coordination for stable yield pools
 */
contract StableYieldEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    IERC20 public asset;

    address public stableYieldPool;
    address public stableYieldManager;

    AccessManager public accessManager;
    
    uint256 public version;

    string public poolName;
 
    uint256 public cashBuffer;

    uint256 public poolReserves;

    uint256 public transactionFees;

    uint256 public expenseRatioFees;

    bool public emergencyWithdrawalEnabled;

    mapping(address => uint256) public spvAllocations;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event FundsDeposited(address indexed from, uint256 amount, uint256 newCashBuffer);
    event FundsWithdrawn(address indexed to, uint256 amount, uint256 remainingCashBuffer);
    event FundsAllocated(uint256 poolReserves, uint256 transactionFee);
    event FeesCollected(uint256 transactionFees, uint256 expenseRatioFees, address treasury);
    event CashBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event EmergencyWithdrawalToggled(bool enabled);
    event PoolNameUpdated(string newPoolName);
    event SPVAllocation(address indexed spv, uint256 amount, uint256 remainingCashBuffer);
    event SPVLiquidityRequested(address indexed spv, uint256 amount, uint256 timestamp);
    event SPVLiquidityReceived(address indexed spv, uint256 amount, uint256 newCashBuffer);
    event PoolLinked(address indexed stableYieldPool);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the StableYieldEscrow
     * @param asset_ Underlying stablecoin asset
     * @param accessManager_ Access manager address
     * @param poolName_ Pool name for identification
     */
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

    /**
     * @notice Set the stable yield pool address (one-time only)
     * @dev Can only be called once to link escrow to pool after deployment
     * @param pool_ The stable yield pool address
     */
    function setStableYieldPool(address pool_) external onlyFactory {
        require(stableYieldPool == address(0), "StableYieldEscrow/pool already set");
        require(pool_ != address(0), "StableYieldEscrow/invalid pool");
        stableYieldPool = pool_;
        emit PoolLinked(pool_);
    }
    
    /**
     * @notice Set the stable yield manager address (one-time only)
     * @dev Can only be called once to link escrow to manager after deployment
     * @param manager_ The stable yield manager address
     */
    function setStableYieldManager(address manager_) external onlyFactory {
        require(manager_ != address(0), "StableYieldEscrow/invalid manager");
        require(stableYieldManager == address(0), "StableYieldEscrow/manager already set");
        
        stableYieldManager = manager_;
    }

    /**
     * @notice Disable upgrades for security
     * @dev Escrows should never be upgraded once deployed with user funds
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("StableYieldEscrow/upgrades disabled for security");
    }

    /**
     * @notice Get version number
     */
    function getVersion() external view returns (uint256) {
        return version;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT & WITHDRAWAL ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////


    /**
     * @notice Withdraw funds to user (for processed withdrawal requests)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdraw(
        address to,
        uint256 amount
    ) external onlyStableYieldPoolOrManager nonReentrant {
        require(to != address(0), "StableYieldEscrow/invalid recipient");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient pool reserves");

        poolReserves -= amount;
        cashBuffer -= amount;
        asset.safeTransfer(to, amount);

        emit FundsWithdrawn(to, amount, cashBuffer);
    }

    /**
     * @notice Allocate deposited funds between pool reserves and transaction fees
     * @dev Called by StableYieldManager after deposit validation
     * @param totalAmount Total amount deposited
     * @param reserveAmount Amount allocated to pool reserves
     * @param transactionFee Amount allocated to transaction fees
     */
    function allocateDeposit(
        uint256 totalAmount,
        uint256 reserveAmount, 
        uint256 transactionFee
    ) external onlyStableYieldPoolOrManager {
        require(totalAmount == reserveAmount + transactionFee, "StableYieldEscrow/allocation mismatch");
        
        // Update cash buffer with incoming funds (tokens already transferred to escrow)
        uint256 currentBalance = asset.balanceOf(address(this));
        uint256 expectedBuffer = poolReserves + transactionFees + expenseRatioFees + totalAmount;
        require(currentBalance >= expectedBuffer - cashBuffer, "StableYieldEscrow/insufficient balance");
        cashBuffer += totalAmount;
        
        poolReserves += reserveAmount;
        transactionFees += transactionFee;
        
        emit FundsAllocated(reserveAmount, transactionFee);
    }

    /**
     * @notice Allocate withdrawal transaction fee from reserves to fee bucket
     * @dev Called by StableYieldManager during withdrawal processing
     * @param transactionFee Amount to move from reserves to transaction fees
     */
    function allocateWithdrawalFee(uint256 transactionFee) external onlyStableYieldPoolOrManager {
        require(transactionFee > 0, "StableYieldEscrow/invalid fee amount");
        require(poolReserves >= transactionFee, "StableYieldEscrow/insufficient reserves");
        
        poolReserves -= transactionFee;
        transactionFees += transactionFee;
    }

    /**
     * @notice Move accrued expense ratio fees from reserves to fee bucket
     * @dev Called by StableYieldManager during monthly fee collection
     * @param amount Amount to move from reserves to expense ratio fees
     */
    function collectExpenseRatioFees(uint256 amount) external onlyStableYieldPoolOrManager {
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient reserves");
        
        poolReserves -= amount;
        expenseRatioFees += amount;
    }

    /**
     * @notice Transfer collected fees to treasury
     * @param treasury Treasury address
     */
    function transferFeesToTreasury(address treasury) external onlyOperator nonReentrant {
        require(treasury != address(0), "StableYieldEscrow/invalid treasury");
        
        uint256 totalFees = transactionFees + expenseRatioFees;
        require(totalFees > 0, "StableYieldEscrow/no fees to transfer");
        require(cashBuffer >= totalFees, "StableYieldEscrow/insufficient cash buffer");
        
        uint256 txFees = transactionFees;
        uint256 expenseFees = expenseRatioFees;
        
        transactionFees = 0;
        expenseRatioFees = 0;
        cashBuffer -= totalFees;
        
        asset.safeTransfer(treasury, totalFees);
        
        emit FeesCollected(txFees, expenseFees, treasury);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV COORDINATION ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Allocate funds to SPV for instrument purchases
     * @param spvAddress SPV address
     * @param amount Amount to allocate
     */
    function allocateToSPV(address spvAddress, uint256 amount) external onlyOperator nonReentrant {
        require(spvAddress != address(0), "StableYieldEscrow/invalid SPV");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(cashBuffer >= amount, "StableYieldEscrow/insufficient cash buffer");
        require(poolReserves >= amount, "StableYieldEscrow/insufficient pool reserves");
        
        // Reduce both cash buffer and pool reserves when allocating to SPV
        // This ensures poolReserves accurately reflects funds available in escrow
        cashBuffer -= amount;
        poolReserves -= amount;
        spvAllocations[spvAddress] += amount;
        
        asset.safeTransfer(spvAddress, amount);
        
        emit SPVAllocation(spvAddress, amount, cashBuffer);
    }
    

    
    /**
     * @notice Receive liquidity back from SPV
     * @param amount Amount received
     */
    function receiveSPVLiquidity(uint256 amount) external onlyOperator nonReentrant {
        require(amount > 0, "StableYieldEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        cashBuffer += amount;
        poolReserves += amount;
        
        emit SPVLiquidityReceived(msg.sender, amount, cashBuffer);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get current cash buffer amount
     */
    function getCashBuffer() external view returns (uint256) {
        return cashBuffer;
    }

    /**
     * @notice Get pool reserves available for investing
     */
    function getPoolReserves() external view returns (uint256) {
        return poolReserves;
    }

    /**
     * @notice Get collected transaction fees
     */
    function getTransactionFees() external view returns (uint256) {
        return transactionFees;
    }

    /**
     * @notice Get collected expense ratio fees
     */
    function getExpenseRatioFees() external view returns (uint256) {
        return expenseRatioFees;
    }

    /**
     * @notice Get total collected fees
     */
    function getTotalFees() external view returns (uint256) {
        return transactionFees + expenseRatioFees;
    }

    /**
     * @notice Get total balance (cash buffer)
     */
    function getTotalBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Get SPV allocation amount
     */
    function getSPVAllocation(address spvAddress) external view returns (uint256) {
        return spvAllocations[spvAddress];
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Update pool name
     */
    function updatePoolName(string memory newPoolName) external onlyAdmin {
        require(bytes(newPoolName).length > 0, "StableYieldEscrow/invalid pool name");
        poolName = newPoolName;
        emit PoolNameUpdated(newPoolName);
    }

    /**
     * @notice Toggle emergency withdrawal capability
     */
    function toggleEmergencyWithdrawal(bool enabled) external onlyAdmin {
        emergencyWithdrawalEnabled = enabled;
        emit EmergencyWithdrawalToggled(enabled);
    }

    /**
     * @notice Emergency withdraw (admin only, when enabled)
     */
    function emergencyWithdraw(
        address to,
        uint256 amount
    ) external onlyAdmin whenEmergencyEnabled nonReentrant {
        require(to != address(0), "StableYieldEscrow/invalid recipient");
        require(amount > 0, "StableYieldEscrow/invalid amount");
        require(asset.balanceOf(address(this)) >= amount, "StableYieldEscrow/insufficient balance");

        asset.safeTransfer(to, amount);
        
        if (cashBuffer > amount) {
            cashBuffer -= amount;
        } else {
            cashBuffer = 0;
        }

        emit FundsWithdrawn(to, amount, cashBuffer);
    }

}