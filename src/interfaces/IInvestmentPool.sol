// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC4626 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address receiver) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function maxMint(address receiver) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IInvestmentPool is IERC4626 {
    event RefundSet(address indexed user, uint256 amount);
    event DiscountAccrued(address indexed user, uint256 amount);
    event FundsTransferredToEscrow(uint256 amount);
    event FundsReceivedFromEscrow(uint256 amount);
    event ManagerUpdated(address oldManager, address newManager);
    
    function manager() external view returns (address);
    function escrow() external view returns (address);
    
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