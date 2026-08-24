// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IPoolEscrow.sol";
import "../interfaces/ILiquidityPool.sol";
import "./ValidationLibrary.sol";
import "./CalculationLibrary.sol";

/**
 * @title DepositWithdrawalLibrary
 * @dev Orchestrates deposit, withdrawal, and fee logic for Single-Asset (deal) pools.
 *      Delegates status-specific handling to ValidationLibrary.
 */
library DepositWithdrawalLibrary {
    uint256 constant BASIS_POINTS = 10000;

    // ==================== EVENTS / ERRORS ====================
    
    event Deposit(address indexed pool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event WithdrawalFeeCollected(address indexed pool, address indexed user, uint256 feeAmount, uint256 netAmount);
    event PoolWithdrawal(address indexed pool, address indexed owner, address indexed receiver, uint256 assets, uint256 shares, uint8 kind);

    error WithdrawalNotAllowed();

    // ==================== DEPOSIT ====================

    /// @dev Handles a deposit during the FUNDING phase. Mints 1:1 shares.
    function handleDeposit(
        mapping(address => IPoolTypes.PoolData) storage pools,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 assets,
        address receiver,
        address sender
    ) external returns (uint256 shares) {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        ValidationLibrary.validateDeposit(poolData, registry, liquidityPool, assets, receiver);
        ValidationLibrary.validateAddress(sender, false);
        
        if (poolUsers[liquidityPool][receiver].depositTime == 0) {
            poolUsers[liquidityPool][receiver].depositTime = block.timestamp;
        }
        shares = assets;
        
        poolData.totalRaised += assets;
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        return shares;
    }

    // ==================== WITHDRAW ====================

    /// @dev Routes withdrawal to the correct handler based on pool status.
    function handleWithdraw(
        mapping(address => IPoolTypes.PoolData) storage pools,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 assets,
        address receiver,
        address owner,
        address sender,
        address treasury
    ) external returns (uint256 shares) {
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        IPoolTypes.PoolStatus currentStatus = poolData.status;

        ValidationLibrary.validateWithdrawal(poolData, registry, liquidityPool, owner);
        ValidationLibrary.validateAddress(receiver, true);
        ValidationLibrary.validateAddress(sender, false);
        ValidationLibrary.validateAmount(assets);
        
        if (sender != owner) {
            uint256 allowed = IERC20(liquidityPool).allowance(owner, sender);
            require(allowed >= assets, "DepositWithdrawal/insufficient allowance");
        }
        
        if (currentStatus == IPoolTypes.PoolStatus.FUNDING) {
            return ValidationLibrary.handleFundingWithdrawal(pools, poolUsers, registry, liquidityPool, assets, receiver, owner, poolData.config);
        } else if (currentStatus == IPoolTypes.PoolStatus.INVESTED) {
            revert WithdrawalNotAllowed();
        } else if (currentStatus == IPoolTypes.PoolStatus.MATURED) {
            return _handleMaturedWithdrawWithFee(pools, poolUsers, registry, liquidityPool, receiver, owner, poolData, treasury);
        } else if (currentStatus == IPoolTypes.PoolStatus.EMERGENCY) {
            return ValidationLibrary.handleEmergencyWithdrawal(poolUsers, registry, liquidityPool, assets, receiver, owner);
        } else {
            revert WithdrawalNotAllowed();
        }
    }
    
    // ==================== MATURED WITHDRAWAL (INTERNAL) ====================

    /// @dev Handles post-maturity withdrawal: calculates user entitlement, deducts fee, and transfers.
    function _handleMaturedWithdrawWithFee(
        mapping(address => IPoolTypes.PoolData) storage pools,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address liquidityPool,
        address receiver,
        address owner,
        IPoolTypes.PoolData storage poolData,
        address treasury
    ) internal returns (uint256 shares) {
        require(block.timestamp >= poolData.config.maturityDate, "DepositWithdrawal/not matured yet");
        
        uint256 userShares = IERC20(liquidityPool).balanceOf(owner);
        require(userShares != 0, "DepositWithdrawal/no shares");
        
        uint256 settledShares = poolData.sharesAtMaturity;
        require(settledShares != 0, "DepositWithdrawal/maturity not settled");
        
        uint256 totalReturns = CalculationLibrary.calculateTotalReturns(poolData);
        uint256 userEntitlement = (userShares * totalReturns) / settledShares;
        
        uint256 feeBps = poolData.config.withdrawalFeeBps;
        uint256 feeAmount = (userEntitlement * feeBps) / BASIS_POINTS;
        uint256 netAmount = userEntitlement - feeAmount;
        
        shares = userShares;
        ILiquidityPool(liquidityPool).burnShares(owner, shares);
        
        poolUsers[liquidityPool][owner].depositTime = 0;
        pools[liquidityPool].totalFeesCollected += feeAmount;
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        
        escrowContract.releaseFunds(receiver, netAmount);
        
        if (feeAmount > 0 && treasury != address(0)) {
            escrowContract.releaseFunds(treasury, feeAmount);
        }
        
        emit Withdraw(msg.sender, receiver, owner, netAmount, shares);
        emit PoolWithdrawal(liquidityPool, owner, receiver, netAmount, shares, 1);
        emit WithdrawalFeeCollected(liquidityPool, owner, feeAmount, netAmount);
        
        return shares;
    }
    
}
