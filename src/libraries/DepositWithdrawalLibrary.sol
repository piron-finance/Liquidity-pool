// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IPoolEscrow.sol";
import "../interfaces/ILiquidityPool.sol";
import "./ValidationLibrary.sol";

library DepositWithdrawalLibrary {
    uint256 constant BASIS_POINTS = 10000;
    
    event Deposit(address indexed pool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event WithdrawalFeeCollected(address indexed pool, address indexed user, uint256 feeAmount, uint256 netAmount);

    error WithdrawalNotAllowed();

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
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        
        if (poolUsers[liquidityPool][receiver].depositTime == 0) {
            poolUsers[liquidityPool][receiver].depositTime = block.timestamp;
        }
        shares = assets;
        
        poolData.totalRaised += assets;
        
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.receiveDeposit(receiver, assets);
        
        emit Deposit(liquidityPool, sender, receiver, assets, shares);
        
        return shares;
    }

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
            // No fee during funding phase - users get full refund
            return ValidationLibrary.handleFundingWithdrawal(pools, poolUsers, registry, liquidityPool, assets, receiver, owner, poolData.config);
        } else if (currentStatus == IPoolTypes.PoolStatus.INVESTED) {
            revert WithdrawalNotAllowed();
        } else if (currentStatus == IPoolTypes.PoolStatus.MATURED) {
            // Matured withdrawal with fee collection
            return _handleMaturedWithdrawWithFee(pools, poolUsers, registry, liquidityPool, receiver, owner, poolData, treasury);
        } else if (currentStatus == IPoolTypes.PoolStatus.EMERGENCY) {
            // No fee during emergency - users get full refund
            return ValidationLibrary.handleEmergencyWithdrawal(poolUsers, registry, liquidityPool, assets, receiver, owner);
        } else {
            revert WithdrawalNotAllowed();
        }
    }
    
    /**
     * @dev Internal function to handle matured withdrawal with fee collection
     */
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
        
        uint256 totalShares = IERC20(liquidityPool).totalSupply();
        uint256 totalReturns = calculateTotalReturns(poolData);
        uint256 userEntitlement = (userShares * totalReturns) / totalShares;
        
        // Calculate fee
        uint256 feeBps = poolData.config.withdrawalFeeBps;
        uint256 feeAmount = (userEntitlement * feeBps) / BASIS_POINTS;
        uint256 netAmount = userEntitlement - feeAmount;
        
        shares = userShares;
        ILiquidityPool(liquidityPool).burnShares(owner, shares);
        
        poolUsers[liquidityPool][owner].depositTime = 0;
        
        // Track fee collection
        pools[liquidityPool].totalFeesCollected += feeAmount;
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(liquidityPool);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        
        // Send net amount to user
        escrowContract.releaseFunds(receiver, netAmount);
        
        // Send fee to treasury
        if (feeAmount > 0 && treasury != address(0)) {
            escrowContract.releaseFunds(treasury, feeAmount);
        }
        
        emit Withdraw(msg.sender, receiver, owner, netAmount, shares);
        emit WithdrawalFeeCollected(liquidityPool, owner, feeAmount, netAmount);
        
        return shares;
    }
    
    function calculateTotalReturns(IPoolTypes.PoolData storage poolData) internal view returns (uint256) {
        uint256 baseValue = poolData.actualInvested;
        
        if (poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED) {
            return baseValue + poolData.totalDiscountEarned;
        } else if (poolData.config.instrumentType == IPoolTypes.InstrumentType.INTEREST_BEARING) {
            return baseValue + poolData.totalCouponsReceived;
        }
        
        return baseValue;
    }

    function distributeDiscount(
        mapping(address => IPoolTypes.PoolData) storage pools,
        IPoolRegistry registry,
        address liquidityPool,
        uint256 discount
    ) external {
        require(registry.isRegisteredPool(liquidityPool), "DepositWithdrawal/invalid pool");
        IPoolTypes.PoolData storage poolData = pools[liquidityPool];
        
        require(poolData.status == IPoolTypes.PoolStatus.MATURED, "DepositWithdrawal/not matured");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED, "DepositWithdrawal/not discounted");
        require(discount > 0, "DepositWithdrawal/invalid discount");
        
        poolData.totalDiscountEarned = discount;
    }

}

