// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../types/IStableYieldTypes.sol";
import "../escrows/StableYieldEscrow.sol";
import "../escrows/YieldReserveEscrow.sol";

/// @title StableYieldManagerLib

library StableYieldManagerLib {
    using SafeERC20 for IERC20;

    error InsufficientLiquidity();

    event TransactionFeeCollected(address indexed poolAddress, string feeType, uint256 transactionAmount, uint256 feeAmount);
    event WithdrawalProcessed(address indexed poolAddress, address indexed user, uint256 indexed requestId, uint256 actualValue, uint256 penaltyDeducted);

    function processQueue(
        mapping(address => IStableYieldTypes.WithdrawalQueue) storage poolQueues,
        mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) storage withdrawalRequests,
        mapping(address => IStableYieldTypes.PoolData) storage pools,
        address yieldReserve,
        address poolAddress,
        uint256 maxRequests,
        uint256 maxValue
    ) external returns (uint256 processed) {
        IStableYieldTypes.WithdrawalQueue storage queue = poolQueues[poolAddress];
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);

        uint256 requestsProcessed = 0;
        uint256 valueProcessed = 0;
        uint256 currentHead = queue.head;

        while (requestsProcessed < maxRequests &&
               valueProcessed < maxValue &&
               currentHead < queue.tail) {

            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][currentHead];

            if (request.processed) {
                currentHead++;
                continue;
            }

            uint256 netValue = request.estimatedValue;
            uint256 totalRequired = netValue + request.feeAmount;

            if (valueProcessed + netValue > maxValue) {
                break;
            }

            uint256 available = escrow.getPoolReserves();

            if (available < totalRequired) {
                uint256 shortfall = totalRequired - available;
                uint256 deployed = _trySourceFromYieldReserve(pools, yieldReserve, poolAddress, shortfall);
                available += deployed;

                if (available < totalRequired) {
                    break;
                }
            }

            _processQueuedWithdrawal(poolQueues, withdrawalRequests, pools, poolAddress, currentHead);
            requestsProcessed++;
            valueProcessed += netValue;
            currentHead++;
        }

        queue.head = currentHead;
        return requestsProcessed;
    }

    function settleWithdrawals(
        mapping(address => IStableYieldTypes.WithdrawalQueue) storage poolQueues,
        mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) storage withdrawalRequests,
        mapping(address => IStableYieldTypes.PoolData) storage pools,
        address yieldReserve,
        address poolAddress,
        uint256[] calldata requestIds
    ) external returns (uint256 processed) {
        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);

        uint256 totalNeeded = 0;
        for (uint256 i = 0; i < requestIds.length; i++) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestIds[i]];
            if (!request.processed) {
                totalNeeded += request.estimatedValue + request.feeAmount;
            }
        }

        uint256 available = escrow.getPoolReserves();
        if (available < totalNeeded) {
            uint256 shortfall = totalNeeded - available;
            uint256 deployed = _trySourceFromYieldReserve(pools, yieldReserve, poolAddress, shortfall);
            available += deployed;
            if (available < totalNeeded) revert InsufficientLiquidity();
        }

        for (uint256 i = 0; i < requestIds.length; i++) {
            IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestIds[i]];
            if (!request.processed) {
                _processQueuedWithdrawal(poolQueues, withdrawalRequests, pools, poolAddress, requestIds[i]);
                processed++;
            }
        }

        return processed;
    }

    function _trySourceFromYieldReserve(
        mapping(address => IStableYieldTypes.PoolData) storage pools,
        address yieldReserve,
        address poolAddress,
        uint256 amount
    ) internal returns (uint256 deployed) {
        if (yieldReserve == address(0)) return 0;

        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
        uint256 reserveAvailable = reserve.getAvailableBalance();

        deployed = amount > reserveAvailable ? reserveAvailable : amount;

        if (deployed > 0) {
            reserve.deployToPool(poolAddress, poolData.escrowAddress, deployed);
            StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);
            escrow.recordProtocolFundsFromReserve(deployed);
        }
    }

    function _processQueuedWithdrawal(
        mapping(address => IStableYieldTypes.WithdrawalQueue) storage poolQueues,
        mapping(address => mapping(uint256 => IStableYieldTypes.WithdrawalRequest)) storage withdrawalRequests,
        mapping(address => IStableYieldTypes.PoolData) storage pools,
        address poolAddress,
        uint256 requestId
    ) internal {
        IStableYieldTypes.WithdrawalRequest storage request = withdrawalRequests[poolAddress][requestId];

        uint256 netValue = request.estimatedValue;
        uint256 feeAmount = request.feeAmount;

        IStableYieldTypes.PoolData storage poolData = pools[poolAddress];
        StableYieldEscrow escrow = StableYieldEscrow(poolData.escrowAddress);

        request.processed = true;
        request.processedTime = block.timestamp;

        poolQueues[poolAddress].totalPendingValue -= request.estimatedValue;

        if (feeAmount > 0) {
            escrow.collectWithdrawalFee(feeAmount);
            emit TransactionFeeCollected(poolAddress, "withdrawal", netValue + feeAmount, feeAmount);
        }

        escrow.withdraw(request.user, netValue);

        emit WithdrawalProcessed(poolAddress, request.user, requestId, netValue, feeAmount);
    }
}
