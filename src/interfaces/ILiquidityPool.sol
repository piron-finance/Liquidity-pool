// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ILiquidityPool
/// @dev Interface for Single-Asset (deal) pool vaults: deposit, withdraw, coupons, and emergency exit.
interface ILiquidityPool is IERC4626 {

    // ==================== EVENTS ====================

    event EmergencyWithdrawal(address indexed user, uint256 refundAmount, uint256 sharesBurned);
    event ManagerUpdated(address oldManager, address newManager);
    event CouponClaimed(address indexed user, uint256 amount);

    
    function claimCoupon() external returns (uint256);
    function getUserCouponAmount(address user) external view returns (uint256);
    
    
    function mintShares(uint256 shares, address receiver) external;
    function burnShares(address owner, uint256 shares) external;
    
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
} 
