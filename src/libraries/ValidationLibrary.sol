// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";
import "../interfaces/ILiquidityPool.sol";
import "../interfaces/IPoolEscrow.sol";

/**
 * @title ValidationLibrary
 * @dev Library for performing validation checks across the protocol
 * @notice This library centralizes all validation logic 
 */
library ValidationLibrary {

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT VALIDATIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates deposit parameters and pool state
     * @dev Comprehensive validation for deposit operations with lifecycle checks
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     * @param assets Amount of assets being deposited
     * @param receiver Address receiving the shares
     */
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
        
        // Check minimum investment
        require(assets >= poolData.config.minInvestment, "ValidationLibrary/below minimum investment");

        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "ValidationLibrary/not funding phase");
        
        require(block.timestamp <= poolData.config.epochEndTime, "ValidationLibrary/funding ended");
        
        require(poolData.totalRaised + assets <= poolData.config.targetRaise, "ValidationLibrary/exceeds target");
        
        IPoolRegistry.PoolInfo memory poolInfo = poolRegistry.getPoolInfo(poolAddress);
        require(poolInfo.createdAt != 0, "ValidationLibrary/invalid pool");
        require(poolRegistry.isApprovedAsset(poolInfo.asset), "ValidationLibrary/asset not approved");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// WITHDRAWAL VALIDATIONS ////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates withdrawal parameters and pool state
     * @dev Comprehensive validation for withdrawal operations with maturity checks
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     * @param owner Address of the share owner
     */
    function validateWithdrawal(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress,
        address owner
    ) internal view {
        // Basic parameter validation
        require(owner != address(0), "ValidationLibrary/invalid owner");
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        
        // Pool status validation - Allow withdrawals in specific states
        bool canWithdraw = poolData.status == IPoolTypes.PoolStatus.FUNDING ||
                          poolData.status == IPoolTypes.PoolStatus.MATURED || 
                          poolData.status == IPoolTypes.PoolStatus.EMERGENCY ||
                          (poolData.status == IPoolTypes.PoolStatus.INVESTED && 
                           block.timestamp >= poolData.config.maturityDate);
        
        require(canWithdraw, "ValidationLibrary/withdrawals not allowed");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EMERGENCY VALIDATIONS //////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates emergency refund distribution parameters
     * @dev Validates that emergency refunds can be distributed for a pool
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     */
    function validateEmergencyRefunds(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.EMERGENCY, "ValidationLibrary/not in emergency");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DISCOUNT VALIDATIONS ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates discount distribution parameters
     * @dev Validates that discounts can be distributed for a discounted instrument pool
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     */
    function validateDiscountDistribution(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.MATURED, "ValidationLibrary/not matured");
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED, "ValidationLibrary/not discounted instrument");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MATURITY VALIDATIONS ///////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates maturity processing parameters
     * @dev Validates that a pool can have its maturity processed
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     * @param finalAmount Final amount being returned by SPV
     */
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// POOL CANCELLATION VALIDATIONS //////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates pool cancellation parameters
     * @dev Validates that a pool can be cancelled (emergency exit during funding)
     * @param poolData Storage reference to pool data
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     */
    function validatePoolCancellation(
        IPoolTypes.PoolData storage poolData,
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, "ValidationLibrary/not funding phase");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// BASIC VALIDATIONS //////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Validates basic address parameters
     * @dev Common validation for non-zero addresses
     * @param addr Address to validate
     * @param isReceiver Whether this is a receiver address (affects error type)
     */
    function validateAddress(address addr, bool isReceiver) internal pure {
        if (isReceiver) {
            require(addr != address(0), "ValidationLibrary/invalid receiver");
        } else {
            require(addr != address(0), "ValidationLibrary/invalid sender");
        }
    }

    /**
     * @notice Validates amount parameters
     * @dev Common validation for non-zero amounts
     * @param amount Amount to validate
     */
    function validateAmount(uint256 amount) internal pure {
        require(amount != 0, "ValidationLibrary/invalid amount");
    }

    /**
     * @notice Validates pool registration
     * @dev Common validation for pool registration status
     * @param poolRegistry Address of the pool registry contract
     * @param poolAddress Address of the pool being validated
     */
    function validatePoolRegistration(
        IPoolRegistry poolRegistry,
        address poolAddress
    ) internal view {
        require(poolRegistry.isRegisteredPool(poolAddress), "ValidationLibrary/invalid pool");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// WITHDRAWAL HANDLERS ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    /**
     * @notice Handles withdrawal during funding phase
     * @dev Allows full withdrawal before pool is filled and invested
     */
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
        return shares;
    }
    
    /**
     * @notice Handles withdrawal after pool maturity
     * @dev Calculates proportional returns including principal + returns
     */
    function handleMaturedWithdrawal(
        mapping(address => IPoolTypes.PoolData) storage /* pools */,
        mapping(address => mapping(address => IPoolTypes.UserPoolData)) storage poolUsers,
        IPoolRegistry registry,
        address poolAddress,
        address receiver,
        address owner,
        IPoolTypes.PoolConfig storage poolConfig,
        uint256 totalReturns
    ) external returns (uint256 shares) {
        require(block.timestamp >= poolConfig.maturityDate, "ValidationLib/not matured");
        
        uint256 userShares = IERC20(poolAddress).balanceOf(owner);
        require(userShares != 0, "ValidationLib/no shares");
        
        uint256 totalShares = IERC20(poolAddress).totalSupply();
        
        uint256 userEntitlement = (userShares * totalReturns) / totalShares;
        
        shares = userShares;
        ILiquidityPool(poolAddress).burnShares(owner, shares);
        
        poolUsers[poolAddress][owner].depositTime = 0;
        
        IPoolRegistry.PoolInfo memory poolInfo = registry.getPoolInfo(poolAddress);
        IPoolEscrow escrowContract = IPoolEscrow(poolInfo.escrow);
        escrowContract.releaseFunds(receiver, userEntitlement);
        
        emit Withdraw(msg.sender, receiver, owner, userEntitlement, shares);
        return shares;
    }
    
    /**
     * @notice Handles emergency withdrawal
     * @dev Emergency exit mechanism for users when pool is in emergency state
     */
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
        return shares;
    }
}

