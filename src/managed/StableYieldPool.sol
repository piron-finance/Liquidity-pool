// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../StableYieldManager.sol";
import "../escrows/StableYieldEscrow.sol";
import "../AccessManager.sol";

/**
 * @title StableYieldPool
 * @dev ERC4626 vault for flexible managed pools. Delegates deposit/withdrawal
 *      validation to StableYieldManager. Enforces a configurable holding period
 *      on share transfers and withdrawals.
 */
contract StableYieldPool is 
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    // ==================== STATE ====================

    using SafeERC20 for IERC20;
    StableYieldManager public stableYieldManager;
    StableYieldEscrow public escrow;
    AccessManager public accessManager;
    
    uint256 public version;
    
    uint256 public minimumHoldingPeriod;
    uint256 public constant MAX_HOLDING_PERIOD = 365 days;
    uint256 public constant DEFAULT_HOLDING_PERIOD = 30 days;
    
    mapping(address => uint256) public lastDepositTime;

    event PoolInitialized(address indexed asset, address indexed escrow, address indexed manager);
    event WithdrawalRequested(address indexed user, uint256 shares, uint256 estimatedValue);
    event HoldingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address escrow_,
        address stableYieldManager_,
        address accessManager_
    ) public initializer {
        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __Pausable_init();

        require(asset_ != address(0), "StableYieldPool/invalid asset");
        require(escrow_ != address(0), "StableYieldPool/invalid escrow");
        require(stableYieldManager_ != address(0), "StableYieldPool/invalid manager");
        require(accessManager_ != address(0), "StableYieldPool/invalid access manager");

        escrow = StableYieldEscrow(escrow_);
        stableYieldManager = StableYieldManager(stableYieldManager_);
        accessManager = AccessManager(accessManager_);
        version = 1;
        minimumHoldingPeriod = DEFAULT_HOLDING_PERIOD;

        emit PoolInitialized(asset_, escrow_, stableYieldManager_);
    }

    function _authorizeUpgrade(address) internal pure override {
        revert("StableYieldPool/upgrades disabled for security");
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256 shares) {
        require(assets > 0, "StableYieldPool/invalid amount");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        require(IERC20(asset()).allowance(msg.sender, address(this)) >= assets, "StableYieldPool/insufficient allowance - approve tokens first");

        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        shares = stableYieldManager.validateDeposit(address(this), assets, receiver);

        _mint(receiver, shares);
   
        lastDepositTime[receiver] = block.timestamp;

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256 assets) {
        require(shares > 0, "StableYieldPool/invalid amount");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        
        uint256 navPerShare = stableYieldManager.calculateNAVPerShare(address(this));
        uint256 netAssetsNeeded = (shares * navPerShare) / 1e18;
        
        uint256 protocolFeeRate = stableYieldManager.getPoolTransactionFee(address(this));
        
        assets = (netAssetsNeeded * 10000) / (10000 - protocolFeeRate);
        
        require(IERC20(asset()).allowance(msg.sender, address(this)) >= assets, "StableYieldPool/insufficient allowance - approve tokens first");

        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 actualShares = stableYieldManager.validateDeposit(address(this), assets, receiver);

        _mint(receiver, actualShares);
        
        lastDepositTime[receiver] = block.timestamp;

        emit Deposit(msg.sender, receiver, assets, actualShares);
        
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        require(assets > 0, "StableYieldPool/invalid amount");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        require(owner != address(0), "StableYieldPool/invalid owner");
        
        _enforceHoldingPeriod(owner);

        uint256 protocolFeeRate = stableYieldManager.getPoolTransactionFee(address(this));
        uint256 grossWithdrawalNeeded = (assets * 10000) / (10000 - protocolFeeRate);
        
        uint256 navPerShare = stableYieldManager.calculateNAVPerShare(address(this));
        shares = (grossWithdrawalNeeded * 1e18) / navPerShare;

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (uint256 actualShares, uint256 withdrawalValue, bool immediate) = stableYieldManager.validateWithdrawal(address(this), shares, receiver, owner);
        
        _burn(owner, actualShares);
        
        if (immediate) {
            escrow.withdraw(receiver, withdrawalValue);
            emit Withdraw(msg.sender, receiver, owner, withdrawalValue, actualShares);
        } else {
            emit WithdrawalRequested(owner, shares, withdrawalValue);
        }

        return actualShares; 
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        require(shares > 0, "StableYieldPool/invalid shares");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        require(owner != address(0), "StableYieldPool/invalid owner");
        
        _enforceHoldingPeriod(owner); 

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (uint256 actualShares, uint256 withdrawalValue, bool immediate) = stableYieldManager.validateWithdrawal(address(this), shares, receiver, owner);
        
        _burn(owner, actualShares);
        
        if (immediate) {
            escrow.withdraw(receiver, withdrawalValue);
            emit Withdraw(msg.sender, receiver, owner, withdrawalValue, actualShares);
        } else {
            emit WithdrawalRequested(owner, shares, withdrawalValue);
        }

        return withdrawalValue;
    }

    function getNAVPerShare() external view returns (uint256) {
        return stableYieldManager.calculateNAVPerShare(address(this));
    }

    function getPoolData() external view returns (IStableYieldTypes.PoolData memory) {
        return stableYieldManager.getPoolData(address(this));
    }

    function getPoolInstruments() external view returns (IStableYieldTypes.InstrumentHolding[] memory) {
        return stableYieldManager.getPoolInstruments(address(this));
    }

    function getWithdrawalQueueStatus() external view returns (uint256 head, uint256 tail, uint256 pending, uint256 totalPendingValue) {
        return stableYieldManager.getWithdrawalQueueStatus(address(this));
    }

    function getUserWithdrawalRequests(address user) external view returns (uint256[] memory) {
        return stableYieldManager.getUserWithdrawalRequests(address(this), user);
    }

    function totalAssets() public view override returns (uint256) {
        return stableYieldManager.calculatePoolNAV(address(this));
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal view override returns (uint256) {
        return stableYieldManager.calculateShares(address(this), assets);
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal view override returns (uint256) {
        return stableYieldManager.calculateAssetValue(address(this), shares);
    }

    function getVersion() external view returns (uint256) {
        return version;
    }
    
    function canWithdraw(address user) public view returns (bool) {
        return block.timestamp >= lastDepositTime[user] + minimumHoldingPeriod;
    }
    
    function getRemainingHoldingPeriod(address user) external view returns (uint256) {
        uint256 unlockTime = lastDepositTime[user] + minimumHoldingPeriod;
        return block.timestamp >= unlockTime ? 0 : unlockTime - block.timestamp;
    }
    
    function getUnlockTime(address user) external view returns (uint256) {
        return lastDepositTime[user] + minimumHoldingPeriod;
    }
    
    function getMinimumHoldingPeriod() external view returns (uint256) {
        return minimumHoldingPeriod;
    }

    function _enforceHoldingPeriod(address user) internal view {
        uint256 unlockTime = lastDepositTime[user] + minimumHoldingPeriod;
        if (block.timestamp < unlockTime) {
            revert("StableYieldPool/minimum holding period not met");
        }
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        
        if (to != address(0) && from != address(0)) {
            lastDepositTime[to] = block.timestamp;
        }
    }

    /// @dev Pausing freezes deposits and mints. Withdrawals stay open so holders can
    ///      always exit at NAV. Kept wide so whoever notices a problem first can act.
    function pause() external {
        require(
            accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender) ||
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "StableYieldPool/not authorized"
        );
        _pause();
    }

    /// @dev Admin only, so a compromised operator cannot undo a pause.
    function unpause() external {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "StableYieldPool/not admin");
        _unpause();
    }
    
    function setMinimumHoldingPeriod(uint256 newPeriod) external {
        require(
            accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender),
            "StableYieldPool/not admin"
        );
        require(newPeriod <= MAX_HOLDING_PERIOD, "StableYieldPool/period too long");
        
        uint256 oldPeriod = minimumHoldingPeriod;
        minimumHoldingPeriod = newPeriod;
        
        emit HoldingPeriodUpdated(oldPeriod, newPeriod);
    }
    
    /**
     * @dev Operator-run exit on a holder's behalf, for when a holder cannot transact.
     *      Proceeds always go to the holder: an operator-chosen recipient would make this
     *      a way to burn anyone's shares and take the assets.
     */
    function emergencyRedeem(uint256 shares, address owner) external returns (uint256 assets) {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "StableYieldPool/not operator");
        require(shares > 0, "StableYieldPool/invalid shares");
        require(owner != address(0), "StableYieldPool/invalid owner");

        (uint256 actualShares, uint256 withdrawalValue, bool immediate) = stableYieldManager.validateWithdrawal(address(this), shares, owner, owner);
        
        _burn(owner, actualShares);
        
        if (immediate) {
            escrow.withdraw(owner, withdrawalValue);
            emit Withdraw(msg.sender, owner, owner, withdrawalValue, actualShares);
        } else {
            emit WithdrawalRequested(owner, shares, withdrawalValue);
        }

        return withdrawalValue;
    }

}
