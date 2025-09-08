// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./interfaces/ILiquidityPool.sol";
import "./interfaces/IManager.sol";
import "./interfaces/IPoolEscrow.sol";


contract LiquidityPool is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ILiquidityPool, PausableUpgradeable {
    using SafeERC20 for IERC20;
    
    IPoolManager public manager;
    IPoolEscrow public escrow;

    mapping(address => uint256) public override pendingRefunds;
    mapping(address => uint256) public override discountedBillsAccrued; 

    uint256 public override totalPendingRefunds;
    uint256 public override totalDiscountAccrued;

    modifier onlyManager() {
        require(msg.sender == address(manager), "Only manager can call");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /**
     * @notice Initialize the LiquidityPool contract
     * @param asset_ The underlying ERC20 asset
     * @param name_ Pool token name
     * @param symbol_ Pool token symbol
     * @param _manager Manager contract address
     * @param _escrow Pool escrow contract address
     */
    function initialize(
        IERC20 asset_, 
        string memory name_, 
        string memory symbol_, 
        address _manager, 
        address _escrow
    ) public initializer {
        require(_manager != address(0), "LiquidityPool/invalid-manager");
        require(_escrow != address(0), "LiquidityPool/invalid-escrow");
        
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __Pausable_init();
        __UUPSUpgradeable_init();
        
        manager = IPoolManager(_manager);
        escrow = IPoolEscrow(_escrow);
    }
    
    /**
     * @notice Disable upgrades for live pools
     * @dev Pools should never be upgraded once deployed
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("Pool upgrades disabled for security");
    }

    ////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////  DEPOSIT FLOW /////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function deposit(uint256 assets, address receiver) public override(ERC4626Upgradeable, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero deposits allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
       
        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 shares = IPoolManager(manager).handleDeposit(address(this), assets, receiver, msg.sender);

        _mint(receiver, shares);
        
        return shares;
    }
    
    function mint(uint256 shares, address receiver) public override(ERC4626Upgradeable, IERC4626) whenNotPaused returns (uint256) {
        require(shares > 0, "LiquidityPool/Non zero shares allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        
        uint256 assets = previewMint(shares);
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
        
        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 actualShares = IPoolManager(manager).handleDeposit(address(this), assets, receiver, msg.sender);
        
        require(actualShares >= shares, "LiquidityPool/Insufficient shares minted");

        _mint(receiver, actualShares);
        
        return assets;
    }

    ////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////  WITHDRAWAL FLOW //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626Upgradeable, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero assets allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(owner != address(0), "LiquidityPool/Valid owner required");
    
        uint256 actualShares = IPoolManager(manager).handleWithdraw(address(this), assets, receiver, owner, msg.sender);
        
        return actualShares;
    }
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY FUNCTIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function claimRefund() external whenNotPaused {
        require(pendingRefunds[msg.sender] > 0, "LiquidityPool/no-refund-available");
        
        uint256 refundAmount = pendingRefunds[msg.sender];
        uint256 userShares = balanceOf(msg.sender);
        
       
        uint256 totalUserValue = IPoolManager(manager).calculateUserReturn(msg.sender);
        uint256 sharesToBurn = totalUserValue > 0 ? (userShares * refundAmount) / totalUserValue : userShares;
        
        pendingRefunds[msg.sender] = 0;
        totalPendingRefunds -= refundAmount;
        
        _burn(msg.sender, sharesToBurn);
        
        IPoolManager(manager).handleWithdraw(address(this), refundAmount, msg.sender, msg.sender, msg.sender);
        
        emit RefundClaimed(msg.sender, refundAmount);
    }
    
    function emergencyWithdraw() external whenNotPaused {
        uint256 userShares = balanceOf(msg.sender);
        require(userShares > 0, "LiquidityPool/no-shares");
        
        uint256 refundAmount = IPoolManager(manager).getUserRefund(msg.sender);
        require(refundAmount > 0, "LiquidityPool/no-refund-available");
        
        _burn(msg.sender, userShares);
        IPoolManager(manager).handleWithdraw(address(this), refundAmount, msg.sender, msg.sender, msg.sender);
        
        emit EmergencyWithdrawal(msg.sender, refundAmount, userShares);
    }
    
    /**
     * @dev User claims their proportional coupon payment
     * @notice Users can call this to claim their share of distributed coupons
     */
    function claimCoupon() external override whenNotPaused returns (uint256) {
        uint256 couponAmount = IPoolManager(manager).claimUserCoupon(address(this), msg.sender);
        require(couponAmount > 0, "LiquidityPool/no-coupon-available");
        
        emit CouponClaimed(msg.sender, couponAmount);
        return couponAmount;
    }
    
    /**
     * @dev Get user's potential coupon amount
     */
    function getUserCouponAmount(address user) external view override returns (uint256) {
        return IPoolManager(manager).getUserAvailableCoupon(address(this), user);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MANAGER ONLY FUNCTIONS //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function setUserRefund(address user, uint256 amount) external override onlyManager {
        uint256 oldAmount = pendingRefunds[user];
        pendingRefunds[user] = amount;
        
        if (amount > oldAmount) {
            totalPendingRefunds += (amount - oldAmount);
        } else {
            totalPendingRefunds -= (oldAmount - amount);
        }
        
        emit RefundSet(user, amount);
    }

    function setDiscountAccrued(address user, uint256 amount) external override onlyManager {
        uint256 oldAmount = discountedBillsAccrued[user];
        discountedBillsAccrued[user] = amount;
        
        if (amount > oldAmount) {
            totalDiscountAccrued += (amount - oldAmount);
        } else {
            totalDiscountAccrued -= (oldAmount - amount);
        }
        
        emit DiscountAccrued(user, amount);
    }
    
    function mintShares(uint256 shares, address receiver) external override onlyManager {
        _mint(receiver, shares);
    }
    
    function burnShares(address owner, uint256 shares) external override onlyManager {
        _burn(owner, shares);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    function pause() external override onlyManager {
        _pause();
    }
    
    function unpause() external override onlyManager {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function paused() public view override(ILiquidityPool, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return IPoolManager(manager).calculateTotalAssets();
    }

    function getUserReturn(address user) external view returns (uint256) {
        return IPoolManager(manager).calculateUserReturn(user);
    }
    
    function getUserDiscount(address user) external view returns (uint256) {
        return IPoolManager(manager).calculateUserDiscount(user);
    }
    
    function isInFundingPeriod() external view returns (bool) {
        return IPoolManager(manager).isInFundingPeriod();
    }
    
    function isMatured() external view returns (bool) {
        return IPoolManager(manager).isMatured();
    }
    
    function getTimeToMaturity() external view returns (uint256) {
        return IPoolManager(manager).getTimeToMaturity();
    }
    
    function getExpectedReturn() external view returns (uint256) {
        return IPoolManager(manager).getExpectedReturn();
    }
}



