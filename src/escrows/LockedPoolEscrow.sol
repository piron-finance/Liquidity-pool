// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../AccessManager.sol";

/**
 * @title LockedPoolEscrow
 * @dev Secure custody for LockedPool funds
 * @notice Handles principal custody, interest payments, and SPV coordination
 */
contract LockedPoolEscrow is 
    Initializable, 
    UUPSUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20; 

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE  //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    IERC20 public asset;

    address public lockedPool;
    address public lockedPoolManager;

    AccessManager public accessManager;
    
    uint256 public version;

    string public poolName;
 
    uint256 public principalHeld;
    uint256 public interestPaidOut;
    uint256 public penaltiesCollected;
   
    mapping(address => uint256) public spvAllocations;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event FundsDeposited(address indexed from, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event InterestPaid(address indexed to, uint256 amount);
    event PenaltyCollected(uint256 amount);
    event SPVAllocation(address indexed spv, uint256 amount);
    event SPVReturn(address indexed spv, uint256 amount);
    event PoolLinked(address indexed lockedPool);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyLockedPool() {
        require(msg.sender == lockedPool, "LockedPoolEscrow/only pool");
        _;
    }

    modifier onlyLockedPoolOrManager() {
        require(
            msg.sender == lockedPool || 
            msg.sender == lockedPoolManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), 
            "LockedPoolEscrow/only pool or manager"
        );
        _;
    }

    modifier onlyOperator() {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender),
            "LockedPoolEscrow/not operator"
        );
        _;
    }

    modifier onlyFactory() {
        require(
            accessManager.hasRole(accessManager.FACTORY_ROLE(), msg.sender),
            "LockedPoolEscrow/not factory"
        );
        _;
    }

    modifier onlyAdmin() {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPoolEscrow/not admin"
        );
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
     * @notice Initialize the LockedPoolEscrow
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

        require(asset_ != address(0), "LockedPoolEscrow/invalid asset");
        require(accessManager_ != address(0), "LockedPoolEscrow/invalid access manager");
        require(bytes(poolName_).length > 0, "LockedPoolEscrow/invalid pool name");

        asset = IERC20(asset_);
        lockedPool = address(0); 
        accessManager = AccessManager(accessManager_);
        poolName = poolName_;
        version = 1;
    }

    /**
     * @notice Set the locked pool address (one-time only)
     * @param pool_ The locked pool address
     */
    function setLockedPool(address pool_) external onlyFactory {
        require(lockedPool == address(0), "LockedPoolEscrow/pool already set");
        require(pool_ != address(0), "LockedPoolEscrow/invalid pool");
        lockedPool = pool_;
        emit PoolLinked(pool_);
    }
    
    /**
     * @notice Set the locked pool manager address (one-time only)
     * @param manager_ The locked pool manager address
     */
    function setLockedPoolManager(address manager_) external onlyFactory {
        require(manager_ != address(0), "LockedPoolEscrow/invalid manager");
        require(lockedPoolManager == address(0), "LockedPoolEscrow/manager already set");
        lockedPoolManager = manager_;
    }

    /**
     * @notice Disable upgrades for security
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("LockedPoolEscrow/upgrades disabled");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT & WITHDRAWAL ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Record deposit and update principal
     * @param amount Amount deposited
     */
    function recordDeposit(uint256 amount) external onlyLockedPoolOrManager {
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        uint256 currentBalance = asset.balanceOf(address(this));
        require(currentBalance >= principalHeld + amount, "LockedPoolEscrow/insufficient balance");
        
        principalHeld += amount;
        
        emit FundsDeposited(msg.sender, amount);
    }

    /**
     * @notice Pay upfront interest to user
     * @param to User receiving interest
     * @param amount Interest amount
     */
    function payInterest(address to, uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(to != address(0), "LockedPoolEscrow/invalid recipient");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(principalHeld >= amount, "LockedPoolEscrow/insufficient principal");
        
        principalHeld -= amount;
        interestPaidOut += amount;
        
        asset.safeTransfer(to, amount);
        
        emit InterestPaid(to, amount);
    }

    /**
     * @notice Withdraw principal to user (at maturity or early exit)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdraw(address to, uint256 amount) external onlyLockedPoolOrManager nonReentrant {
        require(to != address(0), "LockedPoolEscrow/invalid recipient");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(asset.balanceOf(address(this)) >= amount, "LockedPoolEscrow/insufficient balance");
        
        if (principalHeld >= amount) {
            principalHeld -= amount;
        } else {
            principalHeld = 0;
        }
        
        asset.safeTransfer(to, amount);
        
        emit FundsWithdrawn(to, amount);
    }

    /**
     * @notice Record penalty collection and separate from principal
     * @param amount Penalty amount
     */
    function recordPenalty(uint256 amount) external onlyLockedPoolOrManager {
        require(principalHeld >= amount, "LockedPoolEscrow/penalty exceeds principal");
        principalHeld -= amount;
        penaltiesCollected += amount;
        emit PenaltyCollected(amount);
    }

    /**
     * @notice Transfer penalties to treasury
     * @param treasury Treasury address
     */
    function transferPenaltiesToTreasury(address treasury) external onlyOperator nonReentrant {
        require(treasury != address(0), "LockedPoolEscrow/invalid treasury");
        require(penaltiesCollected > 0, "LockedPoolEscrow/no penalties");
        
        uint256 amount = penaltiesCollected;
        penaltiesCollected = 0;
        
        asset.safeTransfer(treasury, amount);
    }

    /**
     * @notice Transfer penalties to yield reserve
     * @param yieldReserve Yield reserve escrow address
     */
    function transferPenaltiesToReserve(address yieldReserve) external onlyOperator nonReentrant {
        require(yieldReserve != address(0), "LockedPoolEscrow/invalid reserve");
        require(penaltiesCollected > 0, "LockedPoolEscrow/no penalties");
        
        uint256 amount = penaltiesCollected;
        penaltiesCollected = 0;
        
        asset.forceApprove(yieldReserve, amount);
        
        (bool success,) = yieldReserve.call(
            abi.encodeWithSignature("receiveYield(uint256)", amount)
        );
        require(success, "LockedPoolEscrow/reserve transfer failed");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// SPV COORDINATION ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Allocate funds to SPV for investment
     * @param spvAddress SPV address
     * @param amount Amount to allocate
     */
    function allocateToSPV(address spvAddress, uint256 amount) external onlyOperator nonReentrant {
        require(spvAddress != address(0), "LockedPoolEscrow/invalid SPV");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        require(principalHeld >= amount, "LockedPoolEscrow/insufficient principal");
        
        principalHeld -= amount;
        spvAllocations[spvAddress] += amount;
        
        asset.safeTransfer(spvAddress, amount);
        
        emit SPVAllocation(spvAddress, amount);
    }
    
    /**
     * @notice Receive funds back from SPV
     * @param amount Amount received
     */
    function receiveSPVReturn(uint256 amount) external nonReentrant {
        require(
            msg.sender == lockedPoolManager ||
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.SPV_ROLE(), msg.sender),
            "LockedPoolEscrow/not authorized"
        );
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        principalHeld += amount;
        
        emit SPVReturn(msg.sender, amount);
    }

    /**
     * @notice Record received funds without transfer (when manager transfers directly)
     * @param amount Amount to record
     */
    function recordReceivedFunds(uint256 amount) external {
        require(msg.sender == lockedPoolManager, "LockedPoolEscrow/only manager");
        require(amount > 0, "LockedPoolEscrow/invalid amount");
        
        principalHeld += amount;
        
        emit SPVReturn(msg.sender, amount);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function getPrincipalHeld() external view returns (uint256) {
        return principalHeld;
    }

    function getInterestPaidOut() external view returns (uint256) {
        return interestPaidOut;
    }

    function getPenaltiesCollected() external view returns (uint256) {
        return penaltiesCollected;
    }

    function getSPVAllocation(address spvAddress) external view returns (uint256) {
        return spvAllocations[spvAddress];
    }

    function getTotalBalance() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function getVersion() external view returns (uint256) {
        return version;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function updatePoolName(string memory newPoolName) external onlyAdmin {
        require(bytes(newPoolName).length > 0, "LockedPoolEscrow/invalid pool name");
        poolName = newPoolName;
    }
}

