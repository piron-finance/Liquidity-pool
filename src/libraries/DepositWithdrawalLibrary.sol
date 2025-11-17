// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/IPoolEscrow.sol";
import "../interfaces/ILiquidityPool.sol";
import "./ValidationLibrary.sol";

library DepositWithdrawalLibrary {
    event Deposit(address indexed pool, address indexed sender, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

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
        address sender
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
            uint256 totalReturns = calculateTotalReturns(poolData);
            return ValidationLibrary.handleMaturedWithdrawal(pools, poolUsers, registry, liquidityPool, receiver, owner, poolData.config, totalReturns);
        } else if (currentStatus == IPoolTypes.PoolStatus.EMERGENCY) {
            return ValidationLibrary.handleEmergencyWithdrawal(poolUsers, registry, liquidityPool, assets, receiver, owner);
        } else {
            revert WithdrawalNotAllowed();
        }
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

