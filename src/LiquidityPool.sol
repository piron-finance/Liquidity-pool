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
import "./types/IPoolTypes.sol";

/**
 * @title LiquidityPool
 * @dev ERC4626 vault for Single Asset (deal) pools. Delegates lifecycle logic to Manager.
 *      Supports coupon claims, maturity entitlements, and emergency exit.
 */
contract LiquidityPool is Initializable, UUPSUpgradeable, ERC4626Upgradeable, ILiquidityPool, PausableUpgradeable {
    // ==================== STATE ====================

    using SafeERC20 for IERC20;
    
    IPoolManager public manager;
    IPoolEscrow public escrow;

    // ==================== MODIFIERS ====================

    modifier onlyManager() {
        require(msg.sender == address(manager), "Only manager can call");
        _;
    }

    // ==================== INITIALIZER ====================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    /// @dev Initializes the ERC4626 vault with the underlying asset, name, symbol, and manager/escrow links.
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
    
    function _authorizeUpgrade(address) internal pure override {
        revert("Pool upgrades disabled for security");
    }

    // ==================== DEPOSIT ====================

    /// @dev Deposits assets into the pool, transfers them to the escrow, and mints shares.
    function deposit(uint256 assets, address receiver) public override(ERC4626Upgradeable, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero deposits allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
       
        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 shares = IPoolManager(manager).handleDeposit(address(this), assets, receiver, msg.sender);

        _mint(receiver, shares);
        
        return shares;
    }
    
    /// @dev Mints shares by converting to assets, transferring to escrow, and minting via manager.
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

    // ==================== WITHDRAW ====================

    /// @dev Withdraws assets by delegating burn + transfer logic to the manager.
    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626Upgradeable, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero assets allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(owner != address(0), "LiquidityPool/Valid owner required");
    
        uint256 actualShares = IPoolManager(manager).handleWithdraw(address(this), assets, receiver, owner, msg.sender);
        
        return actualShares;
    }

    // ==================== EMERGENCY ====================

    /// @dev Emergency exit: burns all caller shares and retrieves available assets.
    function emergencyWithdraw() external whenNotPaused {
        uint256 userShares = balanceOf(msg.sender);
        require(userShares > 0, "LiquidityPool/no-shares");
        
        uint256 actualShares = manager.handleWithdraw(address(this), userShares, msg.sender, msg.sender, msg.sender);
        
        emit EmergencyWithdrawal(msg.sender, userShares, actualShares);
    }

    // ==================== COUPON ====================

    /// @dev Claims accrued coupon payment for the caller.
    function claimCoupon() external override whenNotPaused returns (uint256) {
        uint256 couponAmount = IPoolManager(manager).claimUserCoupon(address(this), msg.sender);
        require(couponAmount > 0, "LiquidityPool/no-coupon-available");
        
        emit CouponClaimed(msg.sender, couponAmount);
        return couponAmount;
    }
    
    function getUserCouponAmount(address user) external view override returns (uint256) {
        return IPoolManager(manager).getUserAvailableCoupon(address(this), user);
    }

    // ==================== MANAGER-ONLY STATE SETTERS ====================

    function mintShares(uint256 shares, address receiver) external override onlyManager {
        _mint(receiver, shares);
    }
    
    function burnShares(address owner, uint256 shares) external override onlyManager {
        _burn(owner, shares);
    }

    // ==================== PAUSE ====================

    function pause() external override onlyManager {
        _pause();
    }
    
    function unpause() external override onlyManager {
        _unpause();
    }

    function paused() public view override(ILiquidityPool, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    // ==================== VIEW FUNCTIONS ====================

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return manager.calculateTotalAssets();
    }

    function getUserReturn(address user) external view returns (uint256) {
        return IPoolManager(manager).calculateUserReturn(user);
    }
    
    function getUserDiscount(address user) external view returns (uint256) {
        return IPoolManager(manager).calculateUserDiscount(user);
    }
    
    function getPoolStatus() external view returns (uint8) {
        return manager.getPoolStatus();
    }
    
    function isInFundingPeriod() external view returns (bool) {
        return IPoolManager(manager).isInFundingPeriod();
    }
    
    function isPoolMatured() external view returns (bool) {
        return manager.isMatured();
    }
    
    function getTimeToMaturity() external view returns (uint256) {
        return IPoolManager(manager).getTimeToMaturity();
    }
    
    function getExpectedReturn() external view returns (uint256) {
        return IPoolManager(manager).getExpectedReturn();
    }
    
    /// @dev True while the pool holds a live investment.
    function isActive() external view returns (bool) {
        return manager.getPoolStatus() == uint8(IPoolTypes.PoolStatus.INVESTED);
    }
    
    function isInEmergency() external view returns (bool) {
        return manager.getPoolStatus() == uint8(IPoolTypes.PoolStatus.EMERGENCY);
    }

}
