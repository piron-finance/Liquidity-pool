// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/ILiquidityPool.sol";
import "./Manager.sol";
import "./Escrow.sol";

contract LiquidityPool is ERC4626, ILiquidityPool, Pausable {
    using SafeERC20 for IERC20;
    
    Manager internal manager;
    address internal escrow;

    mapping(address => uint256) public override pendingRefunds;
    mapping(address => uint256) public override discountedBillsAccrued; 

    uint256 public override totalPendingRefunds;
    uint256 public override totalDiscountAccrued;

    constructor(
        IERC20 asset_, 
        string memory name_, 
        string memory symbol_, 
        address _manager, 
        address _escrow
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        manager = Manager(_manager);
        escrow = _escrow;
    }

    modifier onlyManager() {
        require(msg.sender == address(manager), "Only manager can call");
        _;
    }

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
    
    function transferToEscrow(uint256 amount) external override onlyManager returns (bool) {
        IERC20(asset()).safeTransfer(escrow, amount);
        emit FundsTransferredToEscrow(amount);
        return true;
    }
    
    function receiveFromEscrow(uint256 amount) external override onlyManager {
        // This would be called by escrow to transfer funds back
        emit FundsReceivedFromEscrow(amount);
    }
    
    function mintShares(uint256 shares, address receiver) external override onlyManager {
        _mint(receiver, shares);
    }
    
    function burnShares(address owner, uint256 shares) external override onlyManager {
        _burn(owner, shares);
    }
    
    function pause() external override onlyManager {
        _pause();
    }
    
    function unpause() external override onlyManager {
        _unpause();
    }
    
    function paused() public view override(ILiquidityPool, Pausable) returns (bool) {
        return super.paused();
    }
    
    function deposit(uint256 assets, address receiver) public override(ERC4626, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero deposits allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
       
        IERC20(asset()).safeTransferFrom(msg.sender, escrow, assets);

        uint256 shares = manager.handleDeposit(address(this), assets, receiver, msg.sender);

        _mint(receiver, shares);
        
        return shares;
    }
    
    function mint(uint256 shares, address receiver) public override(ERC4626, IERC4626) whenNotPaused returns (uint256) {
        require(shares > 0, "LiquidityPool/Non zero shares allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        
        uint256 assets = previewMint(shares);
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
        
        IERC20(asset()).safeTransferFrom(msg.sender, escrow, assets);

        uint256 actualShares = manager.handleDeposit(address(this), assets, receiver, msg.sender);
        
        require(actualShares >= shares, "LiquidityPool/Insufficient shares minted");

        _mint(receiver, actualShares);
        
        return assets;
    }
    
    function redeem(uint256 shares, address receiver, address owner) public override(ERC4626, IERC4626) whenNotPaused returns (uint256) {
        require(shares > 0, "LiquidityPool/Non zero shares allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(owner != address(0), "LiquidityPool/Valid owner required");
        
        uint256 assets = previewRedeem(shares);
        
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        
        uint256 actualShares = manager.handleWithdraw(assets, receiver, owner, msg.sender);
        
        return assets;
    }
    
    function withdraw(uint256 assets, address receiver, address owner) public override(ERC4626, IERC4626) whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero assets allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(owner != address(0), "LiquidityPool/Valid owner required");
        uint256 shares = previewWithdraw(assets);
        
        // Check authorization and spend allowance if needed. just incase caller is not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        
        uint256 actualShares = manager.handleWithdraw(assets, receiver, owner, msg.sender);
        
        return actualShares;
    }
    
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        return manager.calculateTotalAssets();
    }
    
    /**
     * @dev Claim refund during emergency status
     */
    function claimRefund() external whenNotPaused {
        require(pendingRefunds[msg.sender] > 0, "LiquidityPool/no-refund-available");
        
        uint256 refundAmount = pendingRefunds[msg.sender];
        uint256 userShares = balanceOf(msg.sender);
        
        pendingRefunds[msg.sender] = 0;
        totalPendingRefunds -= refundAmount;
        
        _burn(msg.sender, userShares);
        
        IERC20(asset()).safeTransferFrom(escrow, msg.sender, refundAmount);
        
        emit RefundClaimed(msg.sender, refundAmount);
    }
    
    /**
     * @dev Emergency withdrawal - bypasses normal withdrawal logic
     */
    function emergencyWithdraw() external whenNotPaused {
        uint256 userShares = balanceOf(msg.sender);
        require(userShares > 0, "LiquidityPool/no-shares");
        
        uint256 refundAmount = manager.getUserRefund(msg.sender);
        require(refundAmount > 0, "LiquidityPool/no-refund-available");
        
        _burn(msg.sender, userShares);
        IERC20(asset()).safeTransferFrom(escrow, msg.sender, refundAmount);
        
        emit EmergencyWithdrawal(msg.sender, refundAmount, userShares);
    }
    
    /**
     * @dev Get user's current return value
     */
    function getUserReturn(address user) external view returns (uint256) {
        return manager.calculateUserReturn(user);
    }
    
    /**
     * @dev Get user's discount earned (for discounted instruments)
     */
    function getUserDiscount(address user) external view returns (uint256) {
        return manager.calculateUserDiscount(user);
    }
    
    /**
     * @dev Check if pool is in funding period
     */
    function isInFundingPeriod() external view returns (bool) {
        return manager.isInFundingPeriod();
    }
    
    /**
     * @dev Check if pool has matured
     */
    function isMatured() external view returns (bool) {
        return manager.isMatured();
    }
    
    /**
     * @dev Get time remaining to maturity
     */
    function getTimeToMaturity() external view returns (uint256) {
        return manager.getTimeToMaturity();
    }
    
    /**
     * @dev Get expected return at maturity
     */
    function getExpectedReturn() external view returns (uint256) {
        return manager.getExpectedReturn();
    }
}



