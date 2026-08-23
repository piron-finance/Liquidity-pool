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
 * @dev ERC4626 vault for fixed-term locked deposits. Delegates position logic
 *      to LockedPoolManager. Shares represent invested principal. Supports
 *      tiered deposits, early exit, redemption, rollover, and position transfer.
 */
contract LockedPool is 
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // ==================== STATE ====================

    using SafeERC20 for IERC20;

    LockedPoolManager public lockedPoolManager;
    LockedPoolEscrow public escrow;
    AccessManager public accessManager;
    
    uint256 public version;

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
    event AutoRolloverUpdated(address indexed user, uint256 indexed positionId, bool enabled);
    event PositionTransferred(address indexed from, address indexed to, uint256 indexed positionId, uint256 shares);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

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

    function setAutoRollover(uint256 positionId, bool enabled) external whenNotPaused {
        lockedPoolManager.setAutoRollover(positionId, enabled, msg.sender);
        
        emit AutoRolloverUpdated(msg.sender, positionId, enabled);
    }
    
    function transferPosition(uint256 positionId, address newOwner) external whenNotPaused {
        require(newOwner != address(0), "LockedPool/invalid recipient");
        require(newOwner != msg.sender, "LockedPool/cannot transfer to self");
        
        ILockedPoolTypes.UserPosition memory position = lockedPoolManager.getPosition(positionId);
        require(position.user == msg.sender, "LockedPool/not owner");
        require(
            position.status == ILockedPoolTypes.PositionStatus.ACTIVE ||
            position.status == ILockedPoolTypes.PositionStatus.MATURED,
            "LockedPool/position not transferable"
        );
        
        uint256 sharesToTransfer = position.investedAmount;
        require(balanceOf(msg.sender) >= sharesToTransfer, "LockedPool/insufficient shares");
        
        _burn(msg.sender, sharesToTransfer);
        _mint(newOwner, sharesToTransfer);
        
        lockedPoolManager.transferPositionOwnership(positionId, newOwner, msg.sender);
        
        emit PositionTransferred(msg.sender, newOwner, positionId, sharesToTransfer);
    }

    function deposit(uint256, address) public pure override returns (uint256) {
        revert("LockedPool/use depositLocked");
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert("LockedPool/use depositLocked");
    }

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        revert("LockedPool/use redeemPosition");
    }

    function redeem(uint256, address, address) public pure override returns (uint256) {
        revert("LockedPool/use redeemPosition");
    }

    function totalAssets() public view override returns (uint256) {
        return escrow.getPrincipalHeld();
    }

    function mintRolloverShares(address user, uint256 amount) external {
        require(msg.sender == address(lockedPoolManager), "LockedPool/only manager");
        require(amount > 0, "LockedPool/zero amount");
        _mint(user, amount);
    }
    
    function burnRolloverShares(address user, uint256 amount) external {
        require(msg.sender == address(lockedPoolManager), "LockedPool/only manager");
        require(amount > 0, "LockedPool/zero amount");
        require(balanceOf(user) >= amount, "LockedPool/insufficient shares");
        _burn(user, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            revert("LockedPool/transfers disabled");
        }
        super._update(from, to, amount);
    }

    function getUserPositions(address user) external view returns (uint256[] memory) {
        return lockedPoolManager.getUserPositions(address(this), user);
    }

    function getPosition(uint256 positionId) external view returns (ILockedPoolTypes.UserPosition memory) {
        return lockedPoolManager.getPosition(positionId);
    }

    function getPositionSummary(uint256 positionId) external view returns (ILockedPoolTypes.PositionSummary memory) {
        return lockedPoolManager.getPositionSummary(positionId);
    }

    function calculateEarlyExitPayout(uint256 positionId) external view returns (ILockedPoolTypes.EarlyExitCalculation memory) {
        return lockedPoolManager.calculateEarlyExitPayout(positionId);
    }

    function getLockTiers() external view returns (ILockedPoolTypes.LockTier[] memory) {
        return lockedPoolManager.getPoolTiers(address(this));
    }

    function getLockTier(uint8 tierIndex) external view returns (ILockedPoolTypes.LockTier memory) {
        return lockedPoolManager.getLockTier(address(this), tierIndex);
    }

    function getPoolMetrics() external view returns (ILockedPoolTypes.PoolMetrics memory) {
        return lockedPoolManager.getPoolMetrics(address(this));
    }

    function previewInterest(
        uint256 principal,
        uint8 tierIndex
    ) external view returns (uint256 interest, uint256 apyBps, uint256 durationDays) {
        ILockedPoolTypes.LockTier memory tier = lockedPoolManager.getLockTier(address(this), tierIndex);
        interest = lockedPoolManager.calculateInterest(principal, tier.apyBps, tier.durationDays);
        apyBps = tier.apyBps;
        durationDays = tier.durationDays;
    }

    /// @dev Anyone who can spot trouble may halt the pool. Releasing it is admin-only:
    ///      whoever pulled the brake should not also decide when it comes off.
    function pause() external {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.EMERGENCY_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "LockedPool/not authorized"
        );
        _pause();
    }

    function unpause() external {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "LockedPool/not admin");
        _unpause();
    }
}
