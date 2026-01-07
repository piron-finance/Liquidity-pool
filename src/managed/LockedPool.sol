// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../LockedPoolManager.sol";
import "../escrows/LockedPoolEscrow.sol";
import "../AccessManager.sol";
import "../types/ILockedPoolTypes.sol";

/**
 * @title LockedPool
 * @dev ERC4626 vault for locked deposits with fixed tenors
 * @notice Users lock funds for fixed periods (3/6/12 months) and receive interest upfront or at maturity
 */
contract LockedPool is 
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    LockedPoolManager public lockedPoolManager;
    LockedPoolEscrow public escrow;
    AccessManager public accessManager;
    
    uint256 public version;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event PoolInitialized(address indexed asset, address indexed escrow, address indexed manager);
    event LockedDeposit(
        address indexed user,
        uint256 indexed positionId,
        uint256 amount,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice
    );
    event PositionRedeemed(address indexed user, uint256 indexed positionId, uint256 payout);
    event EarlyExit(address indexed user, uint256 indexed positionId, uint256 payout, uint256 penalty);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the LockedPool
     * @param asset_ Underlying stablecoin asset
     * @param name_ Pool token name
     * @param symbol_ Pool token symbol
     * @param escrow_ Pool escrow contract
     * @param lockedPoolManager_ LockedPoolManager contract
     * @param accessManager_ AccessManager contract
     */
    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address escrow_,
        address lockedPoolManager_,
        address accessManager_
    ) public initializer {
        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __Pausable_init();

        require(asset_ != address(0), "LockedPool/invalid asset");
        require(escrow_ != address(0), "LockedPool/invalid escrow");
        require(lockedPoolManager_ != address(0), "LockedPool/invalid manager");
        require(accessManager_ != address(0), "LockedPool/invalid access manager");

        escrow = LockedPoolEscrow(escrow_);
        lockedPoolManager = LockedPoolManager(lockedPoolManager_);
        accessManager = AccessManager(accessManager_);
        version = 1;

        emit PoolInitialized(asset_, escrow_, lockedPoolManager_);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("LockedPool/upgrades disabled");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// LOCKED DEPOSIT FUNCTIONS ////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deposit with lock tier and interest payment choice
     * @param amount Amount to deposit
     * @param tierIndex Lock tier (0=3mo, 1=6mo, 2=12mo typically)
     * @param paymentChoice Upfront or maturity interest
     * @return positionId Created position ID
     * @return shares Shares minted (equal to invested amount)
     */
    function depositLocked(
        uint256 amount,
        uint8 tierIndex,
        ILockedPoolTypes.InterestPayment paymentChoice
    ) external whenNotPaused returns (uint256 positionId, uint256 shares) {
        require(amount > 0, "LockedPool/zero amount");
        
        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), amount);
        
        (positionId, shares) = lockedPoolManager.processDeposit(
            address(this),
            msg.sender,
            amount,
            tierIndex,
            paymentChoice
        );
        
        _mint(msg.sender, shares);
        
        emit LockedDeposit(msg.sender, positionId, amount, tierIndex, paymentChoice);
        
        return (positionId, shares);
    }

    /**
     * @notice Redeem position at maturity
     * @param positionId Position to redeem
     * @return payout Amount received
     */
    function redeemPosition(uint256 positionId) external whenNotPaused returns (uint256 payout) {
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        require(position.user == msg.sender, "LockedPool/not owner");
        
        uint256 sharesToBurn = position.investedAmount;
        require(balanceOf(msg.sender) >= sharesToBurn, "LockedPool/insufficient shares");
        
        _burn(msg.sender, sharesToBurn);
        
        payout = lockedPoolManager.redeem(address(this), positionId, msg.sender);
        
        emit PositionRedeemed(msg.sender, positionId, payout);
        
        return payout;
    }

    /**
     * @notice Early exit from position with penalty
     * @param positionId Position to exit
     * @return payout Amount received after penalty
     * @return penalty Penalty deducted
     */
    function earlyExitPosition(uint256 positionId) external whenNotPaused returns (uint256 payout, uint256 penalty) {
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        require(position.user == msg.sender, "LockedPool/not owner");
        
        uint256 sharesToBurn = position.investedAmount;
        require(balanceOf(msg.sender) >= sharesToBurn, "LockedPool/insufficient shares");
        
        _burn(msg.sender, sharesToBurn);
        
        (payout, penalty) = lockedPoolManager.earlyWithdraw(address(this), positionId, msg.sender);
        
        emit EarlyExit(msg.sender, positionId, payout, penalty);
        
        return (payout, penalty);
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ERC4626 OVERRIDES ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Standard deposit disabled - use depositLocked
     */
    function deposit(uint256, address) public pure override returns (uint256) {
        revert("LockedPool/use depositLocked");
    }

    /**
     * @notice Standard mint disabled - use depositLocked
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert("LockedPool/use depositLocked");
    }

    /**
     * @notice Standard withdraw disabled - use redeemPosition or earlyExitPosition
     */
    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("LockedPool/use redeemPosition");
    }

    /**
     * @notice Standard redeem disabled - use redeemPosition or earlyExitPosition
     */
    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("LockedPool/use redeemPosition");
    }

    /**
     * @notice Total assets equals principal held in escrow
     */
    function totalAssets() public view override returns (uint256) {
        return escrow.getPrincipalHeld();
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get user's position IDs
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return lockedPoolManager.getUserPositions(address(this), user);
    }

    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view returns (ILockedPoolTypes.UserPosition memory) {
        return lockedPoolManager.getPosition(positionId);
    }

    /**
     * @notice Get position summary
     */
    function getPositionSummary(uint256 positionId) external view returns (ILockedPoolTypes.PositionSummary memory) {
        return lockedPoolManager.getPositionSummary(positionId);
    }

    /**
     * @notice Calculate early exit payout
     */
    function calculateEarlyExitPayout(uint256 positionId) external view returns (ILockedPoolTypes.EarlyExitCalculation memory) {
        return lockedPoolManager.calculateEarlyExitPayout(positionId);
    }

    /**
     * @notice Get available lock tiers
     */
    function getLockTiers() external view returns (ILockedPoolTypes.LockTier[] memory) {
        return lockedPoolManager.getPoolTiers(address(this));
    }

    /**
     * @notice Get specific tier
     */
    function getLockTier(uint8 tierIndex) external view returns (ILockedPoolTypes.LockTier memory) {
        return lockedPoolManager.getLockTier(address(this), tierIndex);
    }

    /**
     * @notice Get pool metrics
     */
    function getPoolMetrics() external view returns (ILockedPoolTypes.PoolMetrics memory) {
        return lockedPoolManager.getPoolMetrics(address(this));
    }

    /**
     * @notice Calculate interest for preview
     */
    function previewInterest(
        uint256 principal,
        uint8 tierIndex
    ) external view returns (uint256 interest, uint256 apyBps, uint256 durationDays) {
        ILockedPoolTypes.LockTier memory tier = lockedPoolManager.getLockTier(address(this), tierIndex);
        interest = lockedPoolManager.calculateInterest(principal, tier.apyBps, tier.durationDays);
        apyBps = tier.apyBps;
        durationDays = tier.durationDays;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    function pause() external {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPool/not authorized"
        );
        _pause();
    }

    function unpause() external {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPool/not authorized"
        );
        _unpause();
    }
}

