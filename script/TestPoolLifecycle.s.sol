// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/managed/StableYieldPool.sol";
import "../src/factories/ManagedPoolFactory.sol";
import "../src/StableYieldManager.sol";
import "../src/escrows/StableYieldEscrow.sol";
import "../src/AccessManager.sol";
import "../src/FeeManager.sol";
import "../test/mocks/MockContracts.sol";

/**
 * @title TestPoolLifecycle
 * @notice Comprehensive test of stable yield pool lifecycle on testnet
 * @dev Tests: create pool → deposit → allocate → add instrument → check NAV → withdraw
 */
contract TestPoolLifecycle is Script {
    
    // Deployed addresses from kk.txt
    address constant ADMIN = 0xFeed27E8413d416Df4B26bf7BE275Bf92997413c;
    address constant MOCK_TOKEN = 0x9e50F96908187CD5cf19EFeB666B6e017DF42Aa0;
    address constant MANAGED_FACTORY = 0xfA5ae2Ea54e6cBbC8CBEa1C37b40CE8fAc9F856C;
    address constant STABLE_YIELD_MANAGER = 0x87528b87C9d46022a89b95932a44b6a5fBA31894;
    address constant ACCESS_MANAGER = 0xF1759a96d67DF3666FB32420ba62ab4Bb2a0aA38;
    address constant FEE_MANAGER = 0x3BBdbc2Bc7A2bdAE85010831AcFad0c6c170334a;
    
    ManagedPoolFactory factory;
    StableYieldManager stableYieldMgr;
    AccessManager accessMgr;
    MockERC20 token;
    
    address poolAddress;
    address escrowAddress;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        
        // Initialize contracts
        factory = ManagedPoolFactory(MANAGED_FACTORY);
        stableYieldMgr = StableYieldManager(STABLE_YIELD_MANAGER);
        accessMgr = AccessManager(ACCESS_MANAGER);
        token = MockERC20(MOCK_TOKEN);
        
        console.log("\n=== PIRON POOL LIFECYCLE TEST ===");
        console.log("Admin:", ADMIN);
        console.log("Test Token:", MOCK_TOKEN);
        
        // STEP 1: Create Pool
        _createStableYieldPool();
        
        // STEP 2: Deposit funds
        _depositFunds();
        
        // STEP 3: Allocate to SPV
        _allocateToSPV();
        
        // STEP 4: Add instrument
        _addInstrument();
        
        // STEP 5: Check NAV
        _checkNAV();
        
        // STEP 6: Wait and withdraw
        _testWithdrawal();
        
        console.log("\n=== LIFECYCLE TEST COMPLETE ===");
        console.log("Pool Address:", poolAddress);
        console.log("Escrow Address:", escrowAddress);
        
        vm.stopBroadcast();
    }
    
    function _createStableYieldPool() internal {
        console.log("\n[STEP 1] Creating Stable Yield Pool...");
        
        uint256[] memory tenors = new uint256[](2);
        tenors[0] = 90;
        tenors[1] = 180;
        
        ManagedPoolFactory.PoolDeploymentConfig memory config = ManagedPoolFactory.PoolDeploymentConfig({
            asset: MOCK_TOKEN,
            poolName: "Piron Test Pool",
            poolSymbol: "pTEST",
            spvAddress: ADMIN, // Admin acts as SPV for testing
            supportedTenors: tenors,
            minInvestment: 100e6, // 100 USDC
            underlyingPools: new address[](0)
        });
        
        (poolAddress, escrowAddress) = factory.createStableYieldPool(config);
        
        console.log("  Pool created:", poolAddress);
        console.log("  Escrow created:", escrowAddress);
    }
    
    function _depositFunds() internal {
        console.log("\n[STEP 2] Depositing Funds...");
        
        uint256 depositAmount = 10000e6; // 10,000 USDC
        
        // Mint tokens if needed
        uint256 balance = token.balanceOf(ADMIN);
        if (balance < depositAmount) {
            console.log("  Minting test tokens...");
            token.mint(ADMIN, depositAmount);
        }
        
        // Approve pool
        token.approve(poolAddress, depositAmount);
        console.log("  Approved pool for:", depositAmount);
        
        // Deposit
        uint256 sharesBefore = StableYieldPool(poolAddress).balanceOf(ADMIN);
        uint256 shares = StableYieldPool(poolAddress).deposit(depositAmount, ADMIN);
        uint256 sharesAfter = StableYieldPool(poolAddress).balanceOf(ADMIN);
        
        console.log("  Deposited:", depositAmount);
        console.log("  Shares received:", shares);
        console.log("  Total shares:", sharesAfter);
        
        require(shares > 0, "No shares minted");
        require(sharesAfter == sharesBefore + shares, "Share balance mismatch");
    }
    
    function _allocateToSPV() internal {
        console.log("\n[STEP 3] Allocating Funds to SPV...");
        
        uint256 allocationAmount = 5000e6; // 5,000 USDC for investment
        
        // Check reserves before
        StableYieldEscrow escrow = StableYieldEscrow(escrowAddress);
        uint256 reservesBefore = escrow.getPoolReserves();
        console.log("  Reserves before:", reservesBefore);
        
        // Allocate to SPV (admin has OPERATOR_ROLE)
        escrow.allocateToSPV(ADMIN, allocationAmount);
        
        uint256 reservesAfter = escrow.getPoolReserves();
        console.log("  Allocated to SPV:", allocationAmount);
        console.log("  Reserves after:", reservesAfter);
        
        require(reservesAfter == reservesBefore - allocationAmount, "Reserves not updated correctly");
    }
    
    function _addInstrument() internal {
        console.log("\n[STEP 4] Adding Instrument...");
        
        // Admin acts as SPV and has SPV_ROLE
        stableYieldMgr.addInstrument(
            poolAddress,
            IStableYieldTypes.InstrumentType.DISCOUNTED,
            4500e6, // Purchase price (10% discount)
            5000e6, // Face value
            block.timestamp + 90 days, // Maturity
            0, // No coupon for discounted
            0  // No frequency for discounted
        );
        
        console.log("  Instrument added:");
        console.log("    Type: DISCOUNTED");
        console.log("    Purchase Price: 4500e6");
        console.log("    Face Value: 5000e6");
        console.log("    Maturity: 90 days");
    }
    
    function _checkNAV() internal {
        console.log("\n[STEP 5] Checking NAV...");
        
        uint256 nav = stableYieldMgr.calculatePoolNAV(poolAddress);
        uint256 navPerShare = stableYieldMgr.calculateNAVPerShare(poolAddress);
        uint256 totalShares = StableYieldPool(poolAddress).totalSupply();
        
        console.log("  Total NAV:", nav);
        console.log("  NAV per Share:", navPerShare);
        console.log("  Total Shares:", totalShares);
        console.log("  Expected NAV check: NAV > 9000e6 (reserves + instrument value)");
        
        require(nav > 9000e6, "NAV too low");
        require(navPerShare > 0, "NAV per share is zero");
    }
    
    function _testWithdrawal() internal {
        console.log("\n[STEP 6] Testing Withdrawal...");
        
        // Warp forward past minimum holding period (30 days)
        vm.warp(block.timestamp + 31 days);
        console.log("  Warped forward 31 days (past minimum holding period)");
        
        uint256 shareBalance = StableYieldPool(poolAddress).balanceOf(ADMIN);
        uint256 withdrawShares = shareBalance / 4; // Withdraw 25%
        
        console.log("  Withdrawing 25% of shares:", withdrawShares);
        
        uint256 tokenBalanceBefore = token.balanceOf(ADMIN);
        uint256 assetsReceived = StableYieldPool(poolAddress).redeem(withdrawShares, ADMIN, ADMIN);
        uint256 tokenBalanceAfter = token.balanceOf(ADMIN);
        
        console.log("  Assets received:", assetsReceived);
        console.log("  Token balance before:", tokenBalanceBefore);
        console.log("  Token balance after:", tokenBalanceAfter);
        
        require(assetsReceived > 0, "No assets received");
        require(tokenBalanceAfter > tokenBalanceBefore, "Token balance not increased");
    }
}

