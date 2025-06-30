// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILiquidityPool is IERC4626 {
    event RefundSet(address indexed user, uint256 amount);
    event DiscountAccrued(address indexed user, uint256 amount);
    event FundsTransferredToEscrow(uint256 amount);
    event FundsReceivedFromEscrow(uint256 amount);
    event RefundClaimed(address indexed user, uint256 amount);
    event EmergencyWithdrawal(address indexed user, uint256 refundAmount, uint256 sharesBurned);
    event ManagerUpdated(address oldManager, address newManager);

    
    function pendingRefunds(address user) external view returns (uint256);
    function discountedBillsAccrued(address user) external view returns (uint256);
    function totalPendingRefunds() external view returns (uint256);
    function totalDiscountAccrued() external view returns (uint256);
    
    function setUserRefund(address user, uint256 amount) external;
    function setDiscountAccrued(address user, uint256 amount) external;
    function transferToEscrow(uint256 amount) external returns (bool);
    function receiveFromEscrow(uint256 amount) external;
    
    function mintShares(uint256 shares, address receiver) external;
    function burnShares(address owner, uint256 shares) external;
    
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
} 