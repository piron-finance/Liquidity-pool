// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../types/ILockedPoolTypes.sol";
import "../escrows/LockedPoolEscrow.sol";
import "../escrows/YieldReserveEscrow.sol";
import "../libraries/LockedPoolLibrary.sol";
import "../managed/LockedPool.sol";

/// @title LockedPoolManagerLib
library LockedPoolManagerLib {
    using SafeERC20 for IERC20;

    error InsufficientFunds();
    error InsufficientReserve();
    error NoYieldReserve();

    event DebtSettled(address indexed pool, uint256 indexed positionId, uint256 reserveLoanRepaid, uint256 penaltyRecorded);
    event EarlyExitPenaltyRecorded(address indexed pool, uint256 indexed positionId, uint256 penalty);

    function processEarlyExitPayment(
        mapping(address => address) storage poolEscrows,
        mapping(address => ILockedPoolTypes.PoolProtocolAccounting) storage poolAccounting,
        mapping(uint256 => ILockedPoolTypes.DebtPosition) storage debtPositions,
        mapping(address => uint256[]) storage poolDebtPositionIds,
        address yieldReserve,
        address poolAddress,
        uint256 positionId,
        address user,
        uint256 payout,
        uint256 penalty
    ) external {
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        uint256 available = escrow.getPrincipalHeld();

        if (available >= payout + penalty) {
            escrow.withdraw(user, payout);
            if (penalty > 0) {
                escrow.recordPenalty(penalty);
            }
        } else if (available >= payout) {
            escrow.withdraw(user, payout);
            uint256 penaltyInEscrow = available - payout;
            if (penaltyInEscrow > 0) {
                escrow.recordPenalty(penaltyInEscrow);
            }
        } else {
            _processPaymentWithReserveLoan(
                poolEscrows, poolAccounting, debtPositions, poolDebtPositionIds,
                yieldReserve, poolAddress, positionId, user, payout, available, penalty
            );
        }

        if (penalty > 0) {
            poolAccounting[poolAddress].totalPenaltiesEarned += penalty;
        }
    }

    function _processPaymentWithReserveLoan(
        mapping(address => address) storage poolEscrows,
        mapping(address => ILockedPoolTypes.PoolProtocolAccounting) storage poolAccounting,
        mapping(uint256 => ILockedPoolTypes.DebtPosition) storage debtPositions,
        mapping(address => uint256[]) storage poolDebtPositionIds,
        address yieldReserve,
        address poolAddress,
        uint256 positionId,
        address user,
        uint256 payout,
        uint256 escrowAvailable,
        uint256 penalty
    ) internal {
        if (yieldReserve == address(0)) revert NoYieldReserve();

        uint256 reserveLoan = payout - escrowAvailable;
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);
        if (reserve.getAvailableBalance() < reserveLoan) revert InsufficientReserve();

        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        if (escrowAvailable > 0) {
            escrow.withdraw(user, escrowAvailable);
        }
        reserve.loanToPool(poolAddress, positionId, reserveLoan, user);

        uint256 pendingPenalty = 0;
        if (penalty > 0) {
            uint256 escrowPrincipal = escrow.getPrincipalHeld();
            if (escrowPrincipal >= penalty) {
                escrow.recordPenalty(penalty);
            } else {
                if (escrowPrincipal > 0) {
                    escrow.recordPenalty(escrowPrincipal);
                }
                pendingPenalty = penalty - escrowPrincipal;
            }
        }

        debtPositions[positionId] = ILockedPoolTypes.DebtPosition({
            positionId: positionId,
            user: user,
            amountOwed: payout,
            reserveLoan: reserveLoan,
            pendingPenalty: pendingPenalty,
            exitTime: block.timestamp,
            settled: false
        });
        poolDebtPositionIds[poolAddress].push(positionId);
        poolAccounting[poolAddress].reserveLoansOutstanding += reserveLoan;
    }

    function settlePoolDebt(
        mapping(address => address) storage poolEscrows,
        mapping(address => ILockedPoolTypes.PoolProtocolAccounting) storage poolAccounting,
        mapping(uint256 => ILockedPoolTypes.DebtPosition) storage debtPositions,
        address yieldReserve,
        address poolAddress,
        uint256[] calldata positionIds
    ) external {
        LockedPoolEscrow escrow = LockedPoolEscrow(poolEscrows[poolAddress]);
        YieldReserveEscrow reserve = YieldReserveEscrow(yieldReserve);

        for (uint256 i = 0; i < positionIds.length; i++) {
            ILockedPoolTypes.DebtPosition storage debt = debtPositions[positionIds[i]];
            if (debt.settled || debt.reserveLoan == 0) continue;

            uint256 repayAmount = debt.reserveLoan;
            uint256 penaltyAmount = debt.pendingPenalty;
            uint256 totalNeeded = repayAmount + penaltyAmount;

            uint256 available = escrow.getPrincipalHeld();
            if (available < totalNeeded) revert InsufficientFunds();

            escrow.withdraw(address(reserve), repayAmount);
            reserve.recordLoanRepayment(poolAddress, positionIds[i], repayAmount);

            if (penaltyAmount > 0) {
                escrow.recordPenalty(penaltyAmount);
            }

            debt.settled = true;
            poolAccounting[poolAddress].reserveLoansOutstanding -= repayAmount;

            emit DebtSettled(poolAddress, positionIds[i], repayAmount, penaltyAmount);
        }
    }

    function getSettleableDebt(
        mapping(address => address) storage poolEscrows,
        mapping(uint256 => ILockedPoolTypes.DebtPosition) storage debtPositions,
        uint256[] storage allDebtIds,
        address poolAddress
    ) external view returns (
        uint256[] memory positionIds,
        uint256[] memory loanAmounts,
        uint256[] memory penaltyAmounts,
        uint256 totalLoanSettleable,
        uint256 totalPenaltySettleable,
        uint256 escrowAvailable
    ) {
        uint256 count;
        for (uint256 i = 0; i < allDebtIds.length; i++) {
            if (!debtPositions[allDebtIds[i]].settled && debtPositions[allDebtIds[i]].reserveLoan > 0) {
                count++;
            }
        }

        positionIds = new uint256[](count);
        loanAmounts = new uint256[](count);
        penaltyAmounts = new uint256[](count);

        uint256 idx;
        for (uint256 i = 0; i < allDebtIds.length; i++) {
            ILockedPoolTypes.DebtPosition storage debt = debtPositions[allDebtIds[i]];
            if (!debt.settled && debt.reserveLoan > 0) {
                positionIds[idx] = allDebtIds[i];
                loanAmounts[idx] = debt.reserveLoan;
                penaltyAmounts[idx] = debt.pendingPenalty;
                totalLoanSettleable += debt.reserveLoan;
                totalPenaltySettleable += debt.pendingPenalty;
                idx++;
            }
        }

        if (poolEscrows[poolAddress] != address(0)) {
            escrowAvailable = LockedPoolEscrow(poolEscrows[poolAddress]).getPrincipalHeld();
        }
    }

    function transferPositionOwnership(
        mapping(uint256 => ILockedPoolTypes.UserPosition) storage positions,
        mapping(address => mapping(address => uint256[])) storage userPositionIds,
        uint256 positionId,
        address newOwner
    ) external {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        address oldOwner = position.user;
        position.user = newOwner;

        uint256[] storage oldOwnerPositions = userPositionIds[position.poolAddress][oldOwner];
        for (uint256 i = 0; i < oldOwnerPositions.length; i++) {
            if (oldOwnerPositions[i] == positionId) {
                oldOwnerPositions[i] = oldOwnerPositions[oldOwnerPositions.length - 1];
                oldOwnerPositions.pop();
                break;
            }
        }

        userPositionIds[position.poolAddress][newOwner].push(positionId);
    }

    event InterestPaidUpfront(address indexed pool, address indexed user, uint256 indexed positionId, uint256 amount);
    event PositionCreated(
        address indexed poolAddress, address indexed user, uint256 indexed positionId,
        uint256 principal, uint256 interestAmount, ILockedPoolTypes.InterestPayment paymentChoice, uint256 lockEnd
    );
    event PositionRolledOver(
        address indexed poolAddress, address indexed user, uint256 indexed oldPositionId,
        uint256 newPositionId, uint256 principalRolled, uint256 interestHandled
    );

    function executeRollover(
        mapping(uint256 => ILockedPoolTypes.UserPosition) storage positions,
        mapping(address => mapping(address => uint256[])) storage userPositionIds,
        mapping(address => ILockedPoolTypes.LockTier[]) storage poolTiers,
        mapping(address => ILockedPoolTypes.PoolMetrics) storage poolMetrics,
        mapping(address => address) storage poolEscrows,
        uint256 positionId,
        uint256 newPositionId
    ) external {
        ILockedPoolTypes.UserPosition storage position = positions[positionId];
        address poolAddress = position.poolAddress;
        address user = position.user;
        uint8 tierIndex = position.tierIndex;
        ILockedPoolTypes.InterestPayment paymentChoice = position.paymentChoice;

        uint256 principalToRoll;
        uint256 interestHandled;

        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            principalToRoll = position.principalDeposited;
            interestHandled = position.fullInterestAmount;
        } else {
            principalToRoll = position.principalDeposited + position.fullInterestAmount;
            interestHandled = position.fullInterestAmount;
            position.interestEarned = position.fullInterestAmount;
        }

        uint256 oldInvested = position.investedAmount;

        position.status = ILockedPoolTypes.PositionStatus.ROLLED_OVER;
        position.actualPayout = 0;

        ILockedPoolTypes.PoolMetrics storage metrics = poolMetrics[poolAddress];
        metrics.activePositions--;
        metrics.totalPrincipalLocked -= position.principalDeposited;
        metrics.totalExpectedMaturityPayout -= position.expectedMaturityPayout;

        if (paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            metrics.totalInterestPendingMaturity -= position.fullInterestAmount;
        }

        // Build new rollover position
        ILockedPoolTypes.LockTier memory tierMem = poolTiers[poolAddress][tierIndex];
        positions[newPositionId] = LockedPoolLibrary.buildPosition(
            newPositionId, user, poolAddress, principalToRoll,
            tierMem, tierIndex, paymentChoice, block.timestamp
        );
        positions[newPositionId].autoRollover = true;
        positions[newPositionId].rolledFromPositionId = positionId;

        userPositionIds[poolAddress][user].push(newPositionId);

        ILockedPoolTypes.UserPosition storage newPos = positions[newPositionId];
        metrics.totalPrincipalLocked += principalToRoll;
        metrics.totalInterestCommitted += newPos.fullInterestAmount;
        metrics.totalInvestedAmount += newPos.investedAmount;
        metrics.totalExpectedMaturityPayout += newPos.expectedMaturityPayout;
        metrics.activePositions++;
        metrics.totalPositions++;

        if (paymentChoice == ILockedPoolTypes.InterestPayment.UPFRONT) {
            LockedPoolEscrow(poolEscrows[poolAddress]).payInterest(user, newPos.fullInterestAmount);
            metrics.totalInterestPaidUpfront += newPos.fullInterestAmount;
            emit InterestPaidUpfront(poolAddress, user, newPositionId, newPos.fullInterestAmount);
        } else {
            metrics.totalInterestPendingMaturity += newPos.fullInterestAmount;
        }

        emit PositionCreated(
            poolAddress, user, newPositionId, principalToRoll,
            newPos.fullInterestAmount, paymentChoice, newPos.lockEnd
        );

        if (paymentChoice == ILockedPoolTypes.InterestPayment.AT_MATURITY) {
            LockedPool(poolAddress).mintRolloverShares(user, interestHandled);
        } else {
            uint256 newInvested = newPos.investedAmount;
            if (newInvested > oldInvested) {
                LockedPool(poolAddress).mintRolloverShares(user, newInvested - oldInvested);
            } else if (oldInvested > newInvested) {
                LockedPool(poolAddress).burnRolloverShares(user, oldInvested - newInvested);
            }
        }

        emit PositionRolledOver(
            poolAddress, user, positionId, newPositionId,
            principalToRoll, interestHandled
        );
    }
}
