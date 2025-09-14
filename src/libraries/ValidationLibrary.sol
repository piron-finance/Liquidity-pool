// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../types/IPoolTypes.sol";
import "../interfaces/IPoolRegistry.sol";

/**
 * @title ValidationLibrary
 * @dev Library for performing validation checks across the protocol
 * @notice This library centralizes all validation logic 
 */
library ValidationLibrary {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// CUSTOM ERRORS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    error InvalidAmount();
    error InvalidReceiver();
    error InvalidOwner();
    error InvalidSender();
    error InvalidPool();
    error AssetNotApproved();
    error NotFundingPhase();
    error FundingEnded();
    error ExceedsTarget();
    error NotInEmergency();
    error NotMatured();
    error WithdrawalsNotAllowed();
    error NotDiscountedInstrument();

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
        require(assets != 0, InvalidAmount());
        require(receiver != address(0), InvalidReceiver());
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        

        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, NotFundingPhase());
        
        require(block.timestamp <= poolData.config.epochEndTime, FundingEnded());
        
        require(poolData.totalRaised + assets <= poolData.config.targetRaise, ExceedsTarget());
        
        IPoolRegistry.PoolInfo memory poolInfo = poolRegistry.getPoolInfo(poolAddress);
        require(poolInfo.createdAt != 0, InvalidPool());
        require(poolRegistry.isApprovedAsset(poolInfo.asset), AssetNotApproved());
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
        require(owner != address(0), InvalidOwner());
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        
        // Pool status validation - Allow withdrawals in specific states
        bool canWithdraw = poolData.status == IPoolTypes.PoolStatus.MATURED || 
                          poolData.status == IPoolTypes.PoolStatus.EMERGENCY ||
                          (poolData.status == IPoolTypes.PoolStatus.INVESTED && 
                           block.timestamp >= poolData.config.maturityDate);
        
        require(canWithdraw, WithdrawalsNotAllowed());
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
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        require(poolData.status == IPoolTypes.PoolStatus.EMERGENCY, NotInEmergency());
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
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        require(poolData.status == IPoolTypes.PoolStatus.MATURED, NotMatured());
        require(poolData.config.instrumentType == IPoolTypes.InstrumentType.DISCOUNTED, NotDiscountedInstrument());
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
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        require(poolData.status == IPoolTypes.PoolStatus.INVESTED, "NotInvested");
        require(block.timestamp >= poolData.config.maturityDate, NotMatured());
        require(finalAmount != 0, InvalidAmount());
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
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
        require(poolData.status == IPoolTypes.PoolStatus.FUNDING, NotFundingPhase());
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
            require(addr != address(0), InvalidReceiver());
        } else {
            require(addr != address(0), InvalidSender());
        }
    }

    /**
     * @notice Validates amount parameters
     * @dev Common validation for non-zero amounts
     * @param amount Amount to validate
     */
    function validateAmount(uint256 amount) internal pure {
        require(amount != 0, InvalidAmount());
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
        require(poolRegistry.isRegisteredPool(poolAddress), InvalidPool());
    }
}
