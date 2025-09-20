// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../StableYieldManager.sol";
import "../escrows/ManagedPoolEscrow.sol";
import "../types/IPoolTypes.sol";
import "../types/IManagedPoolTypes.sol";
import "../AccessManager.sol";

/**
 * @title StableYieldPool
 * @dev  ERC4626 vault that delegates all business logic to StableYieldManager
 * @notice  managed pool with  NAV-based pricing
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

    ManagedPoolEscrow public escrow;
    
    AccessManager public accessManager;
    
    uint256 public version;

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// EVENTS //////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    event TenorDepositDelegated(
        address indexed user,
        uint256 amount,
        uint256 tenorDays,
        IManagedPoolTypes.MaturityAction maturityAction
    );
    
    event EarlyExitDelegated(
        address indexed user,
        uint256 shares
    );

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// MODIFIERS ///////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    modifier onlyAdmin() {
        require(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), msg.sender), "StableYieldPool/not admin");
        _;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// INITIALIZATION /////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the StableYieldPool contract
     * @param asset_ The underlying asset (all assets are stablecoins eg: CNGN, KES, USDT, etc.)
     * @param name_ Pool token name
     * @param symbol_ Pool token symbol
     * @param stableYieldManager_ StableYieldManager contract address
     * @param accessManager_ AccessManager contract address
     * @param escrow_ ManagedPoolEscrow contract address
     */
    function initialize(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address stableYieldManager_,
        address accessManager_,
        address escrow_
    ) public initializer {
        __ERC4626_init(asset_);
        __ERC20_init(name_, symbol_);
        __UUPSUpgradeable_init();
        __Pausable_init();

        require(stableYieldManager_ != address(0), "StableYieldPool/invalid manager");
        require(accessManager_ != address(0), "StableYieldPool/invalid access manager");
        require(escrow_ != address(0), "StableYieldPool/invalid escrow");

        stableYieldManager = StableYieldManager(stableYieldManager_);
        accessManager = AccessManager(accessManager_);
        escrow = ManagedPoolEscrow(escrow_);
        version = 1;
    }

    /**
     * @notice Authorize contract upgrades (UUPS)
     * @dev Pool upgrades are disabled 
     */
    function _authorizeUpgrade(address) internal pure override {
        revert("StableYieldPool/upgrades disabled");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// DEPOSIT FUNCTIONS ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Deposit with tenor selection 
     * @param amount Amount to deposit
     * @param tenorDays Selected tenor in days (90, 180, 270, 360)
     * @param maturityAction What to do at maturity (compound/withdraw)
     * @param receiver Address to receive shares
     * @return shares Number of shares minted
     */
    function depositWithTenor(
        uint256 amount,
        uint256 tenorDays,
        IManagedPoolTypes.MaturityAction maturityAction,
        address receiver
    ) external whenNotPaused returns (uint256 shares) {
        require(amount > 0, "StableYieldPool/invalid amount");
        require(receiver != address(0), "StableYieldPool/invalid receiver");
        require(tenorDays == 90 || tenorDays == 180 || tenorDays == 270 || tenorDays == 360, "StableYieldPool/invalid tenor");

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        
        // Approve and deposit to escrow
        IERC20(asset()).approve(address(escrow), amount);
        escrow.deposit(amount);

        shares = stableYieldManager.handleManagedDeposit(
            address(this),
            amount,
            tenorDays,
            maturityAction,
            receiver,
            msg.sender
        );

        _mint(receiver, shares);

        emit TenorDepositDelegated(receiver, amount, tenorDays, maturityAction);
        emit Deposit(msg.sender, receiver, amount, shares);

        return shares;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// WITHDRAWAL FUNCTIONS ////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Request early exit from managed pool
     * @param shares Number of shares to withdraw
     * @return success Whether withdrawal was processed immediately
     */
    function requestEarlyExit(uint256 shares) external whenNotPaused returns (bool success) {
        require(shares > 0, "StableYieldPool/invalid shares");
        require(balanceOf(msg.sender) >= shares, "StableYieldPool/insufficient balance");

        uint256 actualShares = stableYieldManager.handleManagedWithdraw(
            address(this),
            shares,
            msg.sender,
            msg.sender,
            msg.sender
        );

        if (actualShares > 0) {
            _burn(msg.sender, actualShares);
            success = true;
        } else {
            success = false;
        }

        emit EarlyExitDelegated(msg.sender, shares);
        return success;
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ERC4626 OVERRIDES ///////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Override totalAssets to use professional NAV calculation
     * @return Total assets under management
     */
    function totalAssets() public view override returns (uint256) {
        return stableYieldManager.calculatePoolNAV(address(this));
    }

    /**
     * @notice Standard ERC4626 deposit - DISABLED for managed pools
     * @dev Managed pools require explicit tenor selection via depositWithTenor()
     */
    function deposit(uint256, address) 
        public 
        pure
        override 
        returns (uint256) 
    {
        revert("StableYieldPool/use depositWithTenor");
    }

    /**
     * @notice Standard ERC4626 mint - DISABLED for managed pools
     * @dev Managed pools require explicit tenor selection via depositWithTenor()
     */
    function mint(uint256, address) 
        public 
        pure
        override 
        returns (uint256) 
    {
        revert("StableYieldPool/use depositWithTenor");
    }

    function withdraw(uint256, address, address) 
        public 
        pure
        override 
        returns (uint256) 
    {
        revert("StableYieldPool/use requestEarlyExit");
    }

    function redeem(uint256, address, address) 
        public 
        pure
        override 
        returns (uint256) 
    {
        revert("StableYieldPool/use requestEarlyExit");
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// VIEW FUNCTIONS ///////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Get managed pool data from manager
     * @return Pool configuration and status
     */
    function getManagedPoolData() external view returns (IManagedPoolTypes.ManagedPoolData memory) {
        return stableYieldManager.getManagedPoolData(address(this));
    }
    
    /**
     * @notice Get pool reserves information
     * @return Pool reserves data
     */
    function getPoolReserves() external view returns (IManagedPoolTypes.PoolReserves memory) {
        return stableYieldManager.getPoolReserves(address(this));
    }
    
    /**
     * @notice Get user positions
     * @param user User address
     * @return Array of user positions
     */
    function getUserPositions(address user) external view returns (IManagedPoolTypes.UserPosition[] memory) {
        return stableYieldManager.getUserPositions(address(this), user);
    }
    
    /**
     * @notice Get current NAV per share
     * @return NAV per share (18 decimals)
     */
    function getNAVPerShare() external view returns (uint256) {
        return stableYieldManager.calculateNAVPerShare(address(this));
    }

    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// ADMIN FUNCTIONS ////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    /**
     * @notice Emergency pause (admin only)
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @notice Unpause (admin only)
     */
    function unpause() external onlyAdmin {
        _unpause();
    }
}