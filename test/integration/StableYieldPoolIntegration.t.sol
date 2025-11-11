// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "../fixtures/BaseTest.sol";
import "../../src/managed/StableYieldPool.sol";
import "../../src/escrows/StableYieldEscrow.sol";
import "../../src/AccessManager.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Minimal MockAccessManager used for integration tests (subset of test/mocks/MockContracts.sol)
contract MockAccessManager {
    mapping(bytes32 => mapping(address => bool)) public roles;

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant POOL_CREATOR_ROLE = keccak256("POOL_CREATOR_ROLE");
    bytes32 public constant SPV_ROLE = keccak256("SPV_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant MULTISIG_ADMIN_ROLE = keccak256("MULTISIG_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");

    constructor(address admin) {
        roles[DEFAULT_ADMIN_ROLE][admin] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external {
        roles[role][account] = false;
    }
}

/**
 * @title StableYieldPoolIntegration
 * @notice Integration test for StableYieldPool deposit flow
 * @dev Tests the stable yield product: deposits, escrow management, and share minting
 * 
 * TEST COVERAGE:
 * - StableYieldPool deployment and initialization
 * - User deposits and share minting
 * - Token transfer to StableYieldEscrow
 * - Integration with MockStableYieldManager
 * - Asset tracking and share calculations
 */
contract StableYieldPoolIntegration is BaseTest {
    
    ////////////////////////////////////////////////////////////////////////////////
    /////////////////////////////// STATE VARIABLES ////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////

    MockERC20 public token;
    MockAccessManager public mockAccess;
    StableYieldEscrow public escrowImpl;
    StableYieldPool public poolImpl;
    StableYieldPool public poolProxy;
    MockStableYieldManager public mockManager;

    function setUp() public override {
        super.setUp();

        // Deploy token and mint to user1
        token = new MockERC20("Mock USDC", "USDC", 6);
        token.mint(user1, INITIAL_BALANCE);

        // Deploy mock access manager and grant factory role to this test contract
        mockAccess = new MockAccessManager(admin);
        // Grant FACTORY_ROLE to this contract so it can call escrow.setStableYieldPool
        mockAccess.grantRole(mockAccess.FACTORY_ROLE(), address(this));

        // Deploy escrow implementation and proxy-initialize it
        StableYieldEscrow escrowImplementation = new StableYieldEscrow();
        bytes memory escrowInit = abi.encodeWithSignature(
            "initialize(address,address,string)",
            address(token),
            address(mockAccess),
            "Test StableYieldEscrow"
        );
        ERC1967Proxy escrowProxy = new ERC1967Proxy(address(escrowImplementation), escrowInit);
        escrowImpl = StableYieldEscrow(address(escrowProxy));

        // Deploy manager mock
        mockManager = new MockStableYieldManager();

        // Deploy StableYieldPool implementation and proxy
        poolImpl = new StableYieldPool();

        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,string,string,address,address,address)",
            address(token),
            "SY Pool",
            "SYP",
            address(escrowImpl),
            address(mockManager),
            address(mockAccess)
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(poolImpl), initData);
        poolProxy = StableYieldPool(address(proxy));

        // Link escrow -> pool (requires FACTORY_ROLE on access manager and is callable by this test)
        escrowImpl.setStableYieldPool(address(poolProxy));
    }

    /**
     * @notice Test StableYieldPool deposit flow with escrow and share minting
     * @dev Tests: user deposits → tokens move to escrow → shares minted to user
     */
    function test_deposit_movesTokensToEscrowAndMintsShares() public {
        console.log("\n=== TEST: StableYieldPool Deposit Flow ===");
        
        console.log("\nStep 1: Preparing deposit...");
        uint256 depositAmount = 1_000e6;
        console.log("  Deposit Amount:", depositAmount);
        console.log("  User1 Address:", user1);
        console.log("  User1 Token Balance:", token.balanceOf(user1));
        console.log("  Pool Address:", address(poolProxy));
        console.log("  Escrow Address:", address(escrowImpl));

        // Approve pool (spender) to pull tokens from user (StableYieldPool will transfer to escrow)
        console.log("\nStep 2: User approving tokens...");
        vm.startPrank(user1);
        // Approve both pool and escrow to satisfy the contract's allowance checks
        token.approve(address(poolProxy), depositAmount);
        token.approve(address(escrowImpl), depositAmount);
        console.log("  Pool Allowance:", token.allowance(user1, address(poolProxy)));
        console.log("  Escrow Allowance:", token.allowance(user1, address(escrowImpl)));

        // Deposit into pool
        console.log("\nStep 3: User depositing into StableYieldPool...");
        console.log("  Depositing:", depositAmount);
        console.log("  User Balance Before:", token.balanceOf(user1));
        console.log("  Escrow Balance Before:", token.balanceOf(address(escrowImpl)));
        console.log("  User Shares Before:", poolProxy.balanceOf(user1));
        
        uint256 minted = poolProxy.deposit(depositAmount, user1);
        vm.stopPrank();
        
        console.log("\nStep 4: Verifying deposit results...");
        console.log("  Shares Minted:", minted);
        console.log("  User Balance After:", token.balanceOf(user1));
        console.log("  Escrow Balance After:", token.balanceOf(address(escrowImpl)));
        console.log("  User Shares After:", poolProxy.balanceOf(user1));
        console.log("  Total Supply:", poolProxy.totalSupply());

        // Assert shares minted to user
        console.log("\nStep 5: Assertions...");
        console.log("  User received shares:", poolProxy.balanceOf(user1) == minted);
        console.log("  Escrow holds tokens:", token.balanceOf(address(escrowImpl)) == depositAmount);
        assertEq(poolProxy.balanceOf(user1), minted);

        // Escrow should hold the deposited tokens
        assertEq(token.balanceOf(address(escrowImpl)), depositAmount);
        
        console.log("\n====== STABLE YIELD DEPOSIT COMPLETE ======");
        console.log("  User deposited:", depositAmount, "USDC");
        console.log("  Tokens moved to escrow");
        console.log("  User received:", minted, "shares (1:1 ratio)");
        console.log("  NAV maintained, shares proportional to deposit");
        console.log("\n=== TEST PASSED ===\n");
    }

}

// Minimal mock manager used only for integration testing
contract MockStableYieldManager {
    mapping(address => uint256) public deposits;

    function validateDeposit(address /*pool*/, uint256 assets, address /*receiver*/) external returns (uint256) {
        // Simple 1:1 shares model for integration test
        deposits[msg.sender] += assets;
        return assets;
    }

    function calculateNAVPerShare(address /*pool*/) external pure returns (uint256) {
        return 1e18;
    }

    function calculatePoolNAV(address /*pool*/) external pure returns (uint256) {
        return 0;
    }

    function calculateSharesView(address /*pool*/, uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function calculateAssetValueView(address /*pool*/, uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function validateWithdrawal(address /*pool*/, uint256 shares, address /*receiver*/, address /*owner*/) external pure returns (uint256, uint256) {
        return (shares, shares);
    }
 
    function feeManager() external pure returns (address) { return address(0); }
}
