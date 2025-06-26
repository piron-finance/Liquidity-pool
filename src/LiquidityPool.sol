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
    Escrow internal escrow;

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
        escrow = Escrow(_escrow);
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
        IERC20(asset()).safeTransfer(address(escrow), amount);
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
    
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256) {
        require(assets > 0, "LiquidityPool/Non zero deposits allowed");
        require(receiver != address(0), "LiquidityPool/Valid addresses only");
        require(IERC20(asset()).balanceOf(msg.sender) >= assets, "LiquidityPool/Insufficient balance");
       
        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 shares = manager.handleDeposit(address(this), assets, receiver, msg.sender);

        _mint(receiver, shares);
        
        return shares;
    }
    
    function withdraw(uint256 assets, address receiver, address owner) public override whenNotPaused returns (uint256) {
        return manager.handleWithdraw(assets, receiver, owner, msg.sender);
    }
    
    function totalAssets() public view override returns (uint256) {
        return manager.calculateTotalAssets();
    }
}



