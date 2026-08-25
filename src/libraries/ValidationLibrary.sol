// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/ILiquidityPool.sol";
import "../interfaces/IPoolEscrow.sol";

/**
 * @title ValidationLibrary
 * @dev Common validation helpers used by Manager and DepositWithdrawalLibrary.
 *      Validates deposits, withdrawals, maturity, pool status, and addresses.
 *      Also contains the withdrawal handlers for the funding and emergency states.
 */
library ValidationLibrary {

    // ==================== DEPOSIT VALIDATION ====================

    /// @dev Validates all preconditions for a deposit during the FUNDING phase.
    function validateDeposit(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress,
        uint256 assets,
        address receiver
    ) internal view {
        require(assets != 0, "ValidationLibrary/invalid amount");
        require(receiver != address(0), "ValidationLibrary/invalid receiver");
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        
        require(assets >= poolData.config.minInvestment, "ValidationLibrary/below minimum investment");

        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "ValidationLibrary/not funding phase");
        
        require(block.timestamp <= poolData.config.epochEndTime, "ValidationLibrary/funding ended");
        
        require(poolData.totalRaised + assets <= poolData.config.targetRaise, "ValidationLibrary/exceeds target");
        
        IPoolRegistry.PoolInfo memory poolInfo = poolRegistry.getPoolInfo(poolAddress);
        require(poolInfo.createdAt != 0, "ValidationLibrary/invalid pool");
        require(poolRegistry.isApprovedAsset(poolInfo.asset), "ValidationLibrary/asset not approved");
    }

    // ==================== WITHDRAWAL VALIDATION ====================

    /// @dev Validates that a withdrawal is allowed given the current pool status.
    function validateWithdrawal(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress,
        address owner
    ) internal view {
        require(owner != address(0), "ValidationLibrary/invalid owner");
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        
        // INVESTED is deliberately absent. It used to be admitted once past the maturity
        // date, but handleWithdraw has no INVESTED branch and reverts on it regardless, so
        // the clause only moved the rejection to a later line with a worse message.
        // Settlement is what opens redemption.
        bool canWithdraw = poolData.status == IPoolTypes.PoolStatus.FUNDING ||
                          poolData.status == IPoolTypes.PoolStatus.MATURED || 
                          poolData.status == IPoolTypes.PoolStatus.EMERGENCY;
        
        require(canWithdraw, "ValidationLibrary/withdrawals not allowed");
    }

    // ==================== STATUS-SPECIFIC VALIDATION ====================

    function validateMaturityProcessing(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress,
        uint256 finalAmount
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "ValidationLibrary/not invested");
        require(block.timestamp >= poolData.config.maturityDate, "ValidationLibrary/not matured");
        require(finalAmount != 0, "ValidationLibrary/invalid amount");
    }

    function validatePoolCancellation(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "ValidationLibrary/not funding phase");
    }

    // ==================== GENERIC VALIDATORS ====================

    function validateAddress(address addr, bool isReceiver) internal pure {
        if (isReceiver) {
            require(addr != address(0), "ValidationLibrary/invalid receiver");
        } else {
            require(addr != address(0), "ValidationLibrary/invalid sender");
        }
    }

    function validateAmount(uint256 amount) internal pure {
        require(amount != 0, "ValidationLibrary/invalid amount");
    }

    function validatePoolRegistration(
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
    }

    // ==================== WITHDRAWAL HANDLERS ====================

    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    /// @dev Emitted on every withdrawal path. Libraries are delegatecalled, so `Withdraw` alone
    ///      carries no pool address; indexers need this to attribute a withdrawal to a pool.
    ///      `kind`: 0 = funding-phase refund, 1 = matured redemption, 2 = emergency exit.
    event PoolWithdrawal(address indexed pool, address indexed owner, address indexed receiver, uint256 assets, uint256 shares, uint8 kind);

    /// @dev Handles withdrawal during FUNDING: burns shares, releases funds from escrow.
    function handleFundingWithdrawal(
        mapping(address => IPoolTypes.PoolData) storage pools,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address poolAddress,
        uint256 assets,
        address receiver,
        address owner,
        IPoolTypes.PoolConfig storage poolConfig
    ) external returns (uint256 shares) {
        require(block.timestamp <= poolConfig.epochEndTime, "ValidationLib/funding ended");
        
        shares = assets;
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares >= shares, "ValidationLib/insufficient shares");
        
        require(pools[poolAddress].totalRaised >= assets, "ValidationLib/insufficient pool balance");
        pools[poolAddress].totalRaised -= assets;
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);

        uint256 remainingShares = IERC20(poolAddress).balanceOf(owner);

        if (remainingShares == 0) {
            poolUsers[poolAddress][owner].depositTime = 0;
        }
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        emit PoolWithdrawal(poolAddress, owner, receiver, assets, shares, 0);
        return shares;
    }
    
    /// @dev Handles emergency withdrawal: returns proportional assets to the user.
    function handleEmergencyWithdrawal(
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address poolAddress,
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares) {
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares != 0, "ValidationLib/no shares");
        
        require(assets <= userShares, "ValidationLib/exceeds refund amount");
        
        shares = assets;
        
        ILiquidityPool(poolAddress).burnShares(owner, shares);

        uint256 remainingShares = IERC20(poolAddress).balanceOf(owner);
        if (remainingShares == 0) {
            poolUsers[poolAddress][owner].depositTime = 0;
        }
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, assets);
        
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        emit PoolWithdrawal(poolAddress, owner, receiver, assets, shares, 2);
        return shares;
    }
}
