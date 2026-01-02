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
 * @title StableYieldPool - Piron Flexible Pools
 * @dev ERC4626 vault for flexible managed pools with 30-day minimum holding period
 * @notice Flexible stable yield pool supporting cross-border stablecoin investments
 * 
 * Key Features:
 * - 30-day minimum holding period (as per Piron's flexible pool design)
 * - NAV-based pricing with fee deduction
 * - Withdrawal queue system for liquidity management
 * - Support for multiple stablecoins (USDC, USDT, DAI, etc.)
 * - Cross-border accessibility via stablecoin rails
 * - ERC4626 compliant for DeFi integrations
 */
contract StableYieldPool is 
    Initializable,
    ERC4626Upgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES //////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    StableYieldManager public stableYieldManager;
    StableYieldEscrow public escrow;
    AccessManager public accessManager;
    
    uint256 public version;
    

    uint256 public constant MINIMUM_HOLDING_PERIOD = 30 days;
    mapping(address => uint256) public lastDepositTime;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event PoolInitialized(address indexed asset, address indexed escrow, address indexed manager);
    event WithdrawalRequested(address indexed user, uint256 shares, uint256 estimatedValue);
    event HoldingPeriodViolation(address indexed user, uint256 timeRemaining);

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the StableYieldPool
     * @param asset_ Underlying stablecoin asset
     * @param name_ Pool token name
     * @param symbol_ Pool token symbol
     * @param escrow_ Pool escrow contract
     * @param stableYieldManager_ StableYieldManager contract
     * @param accessManager_ AccessManager contract
     */
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

        emit PoolInitialized(asset_, escrow_, stableYieldManager_);
    }

    /**
     * @notice Disable upgrades for security - only factory deploys new versions
     * @dev Pool contracts should never be upgraded
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("StableYieldPool/upgrades disabled for security");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ERC4626 OVERRIDES ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////



    /**
     * @notice Deposit assets and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address to receive shares
     * @return shares Number of shares minted
     */
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

    /**
     * @notice Mint exact number of shares
     * @dev ERC4626 compliant - calculates required assets for exact shares
     * @param shares Number of shares to mint
     * @param receiver Address to receive shares
     * @return assets Amount of assets required for the shares
     */
    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256 assets) {
        require(shares > 0, "StableYieldPool/invalid amount");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        
        uint256 navPerShare = stableYieldManager.calculateNAVPerShare(address(this));
        uint256 netAssetsNeeded = (shares * navPerShare) / 1e18;
        
        // Calculate gross assets by working backwards from fee formula
        // If fee = grossAssets * feeRate / 10000, and netAssets = grossAssets - fee
        // Then: netAssets = grossAssets * (1 - feeRate/10000)
        // So: grossAssets = netAssets / (1 - feeRate/10000) = netAssets * 10000 / (10000 - feeRate)
        
        // Get fee rate to calculate exact gross amount needed
        uint256 protocolFeeRate = stableYieldManager.getPoolTransactionFee(address(this));
        
        assets = (netAssetsNeeded * 10000) / (10000 - protocolFeeRate);
        
        require(IERC20(asset()).allowance(msg.sender, address(escrow)) >= assets, "StableYieldPool/insufficient allowance - approve tokens first");

        IERC20(asset()).safeTransferFrom(msg.sender, address(escrow), assets);

        uint256 actualShares = stableYieldManager.validateDeposit(address(this), assets, receiver);

        _mint(receiver, actualShares);
        
        lastDepositTime[receiver] = block.timestamp;

        emit Deposit(msg.sender, receiver, assets, actualShares);
        
        return assets;
    }

  
    /**
     * @notice Withdraw exact amount of assets
     * @dev ERC4626 compliant - calculates required shares for exact assets
     * @param assets Amount of assets to withdraw
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return shares Number of shares burned for the assets
     */
    function withdraw(uint256 assets, address receiver, address owner) public override whenNotPaused returns (uint256 shares) {
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

    /**
     * @notice Redeem shares for assets
     * @param shares Number of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets received
     */
    function redeem(uint256 shares, address receiver, address owner) public override whenNotPaused returns (uint256 assets) {
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

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get current NAV per share
     */
    function getNAVPerShare() external view returns (uint256) {
        return stableYieldManager.calculateNAVPerShare(address(this));
    }

    /**
     * @notice Get pool data from StableYieldManager
     */
    function getPoolData() external view returns (IStableYieldTypes.PoolData memory) {
        return stableYieldManager.getPoolData(address(this));
    }

    /**
     * @notice Get pool instruments
     */
    function getPoolInstruments() external view returns (IStableYieldTypes.InstrumentHolding[] memory) {
        return stableYieldManager.getPoolInstruments(address(this));
    }

    /**
     * @notice Get withdrawal queue status
     */
    function getWithdrawalQueueStatus() external view returns (uint256 head, uint256 tail, uint256 pending, uint256 totalPendingValue) {
        return stableYieldManager.getWithdrawalQueueStatus(address(this));
    }

    /**
     * @notice Get user withdrawal requests
     */
    function getUserWithdrawalRequests(address user) external view returns (uint256[] memory) {
        return stableYieldManager.getUserWithdrawalRequests(address(this), user);
    }

        /**
     * @notice Get total assets under management
     * @dev Delegates to StableYieldManager for NAV calculation
     */
    function totalAssets() public view override returns (uint256) {
        return stableYieldManager.calculatePoolNAV(address(this));
    }

    /**
     * @notice Convert assets to shares using current NAV
     */
    function _convertToShares(uint256 assets, Math.Rounding) internal view override returns (uint256) {
        return stableYieldManager.calculateSharesView(address(this), assets);
    }

    /**
     * @notice Convert shares to assets using current NAV
     */
    function _convertToAssets(uint256 shares, Math.Rounding) internal view override returns (uint256) {
        return stableYieldManager.calculateAssetValueView(address(this), shares);
    }

        /**
     * @notice Get version
     */
    function getVersion() external view returns (uint256) {
        return version;
    }
    
    /**
     * @notice Check if user can withdraw (holding period satisfied)
     */
    function canWithdraw(address user) external view returns (bool) {
        return block.timestamp >= lastDepositTime[user] + MINIMUM_HOLDING_PERIOD;
    }
    
    /**
     * @notice Get remaining holding period for user
     */
    function getRemainingHoldingPeriod(address user) external view returns (uint256) {
        uint256 unlockTime = lastDepositTime[user] + MINIMUM_HOLDING_PERIOD;
        return block.timestamp >= unlockTime ? 0 : unlockTime - block.timestamp;
    }
    
    /**
     * @notice Get user's unlock timestamp
     */
    function getUnlockTime(address user) external view returns (uint256) {
        return lastDepositTime[user] + MINIMUM_HOLDING_PERIOD;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INTERNAL FUNCTIONS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////
    
    /**
     * @notice Enforce minimum holding period for flexible pools
     * @param user User attempting to withdraw
     */
    function _enforceHoldingPeriod(address user) internal view {
        uint256 unlockTime = lastDepositTime[user] + MINIMUM_HOLDING_PERIOD;
        if (block.timestamp < unlockTime) {
            revert("StableYieldPool/minimum holding period not met");
        }
    }

    /**
     * @notice Override ERC20 _update to track holding period on transfers
     * @dev Ensures recipients of transferred shares must also wait 30 days
     * @param from Sender address
     * @param to Recipient address
     * @param value Amount transferred
     */
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        
        if (to != address(0) && from != address(0)) {
            lastDepositTime[to] = block.timestamp;
        }
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Pause the pool
     */
    function pause() external {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "StableYieldPool/not operator");
        _pause();
    }

    /**
     * @notice Unpause the pool
     */
    function unpause() external {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "StableYieldPool/not operator");
        _unpause();
    }
    
    /**
     * @notice Emergency withdrawal bypass (operators only)
     * @dev Allows operators to process withdrawals without holding period in emergencies
     * @param shares Number of shares to redeem
     * @param receiver Address to receive assets
     * @param owner Address that owns the shares
     * @return assets Amount of assets received
     */
    function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(accessManager.hasRole(accessManager.OPERATOR_ROLE(), msg.sender), "StableYieldPool/not operator");
        require(shares > 0, "StableYieldPool/invalid shares");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        require(owner != address(0), "StableYieldPool/invalid owner");

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


}