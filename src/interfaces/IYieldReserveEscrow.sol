// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IYieldReserveEscrow
/// @dev Interface for the protocol yield reserve: tracks direct deposits, deployments to pools,
///      recalled funds, and available balance.
interface IYieldReserveEscrow {

    // ==================== OPERATIONS ====================

    function recordDirectDeposit(address pool, uint256 amount) external;
    function recordDirectDepositWithdrawn(address pool, uint256 amount) external;
    
    function receiveRecalledFunds(address pool, uint256 amount) external;
    
    function deployToPool(address pool, address escrow, uint256 amount) external;
    
    // ==================== VIEW FUNCTIONS ====================

    function getAvailableBalance() external view returns (uint256);
    function deployedToPool(address pool) external view returns (uint256);
    function directDepositsToPool(address pool) external view returns (uint256);
}
