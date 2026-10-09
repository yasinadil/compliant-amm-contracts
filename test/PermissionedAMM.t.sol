// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {PermissionedAMM} from "../src/PermissionedAMM.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Timelock} from "../src/Timelock.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract PermissionedAMMTest is Test {
    PermissionedAMM public vault;
    ImpactPolicy public impactPolicy;
    ComplianceRegistry public complianceRegistry;
    Timelock public timelock;
    MockERC20 public assetToken;
    MockERC20 public stableToken;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public operator = makeAddr("operator");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint256 public constant INITIAL_ASSET = 1_000_000e18;
    uint256 public constant INITIAL_STABLE = 1_000_000e18;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy tokens
        assetToken = new MockERC20("Asset Global", "Asset", 18);
        stableToken = new MockERC20("Asset USD", "Stable", 18);

        // Deploy supporting contracts
        impactPolicy = new ImpactPolicy(admin);
        complianceRegistry = new ComplianceRegistry(admin);
        timelock = new Timelock(admin, 24 hours);

        // Deploy vault
        vault = new PermissionedAMM(
            address(assetToken),
            address(stableToken),
            address(impactPolicy),
            address(complianceRegistry),
            admin,
            treasury,
            address(timelock)
        );

        // Setup roles
        vault.grantRole(vault.OPERATOR_ROLE(), operator);
        vault.grantRole(vault.ADMIN_ROLE(), address(timelock));
        complianceRegistry.grantRole(complianceRegistry.SWAP_VOLUME_RECORDER_ROLE(), address(vault));

        // Mint tokens for testing
        assetToken.mint(admin, INITIAL_ASSET * 10);
        stableToken.mint(admin, INITIAL_STABLE * 10);
        assetToken.mint(user1, 100_000e18);
        stableToken.mint(user1, 100_000e18);
        assetToken.mint(user2, 100_000e18);
        stableToken.mint(user2, 100_000e18);

        // Set compliance for users
        complianceRegistry.setComplianceTier(user1, 2); // Enhanced KYC
        complianceRegistry.setComplianceTier(user2, 1); // Basic KYC

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public {
        vm.startPrank(admin);

        assetToken.approve(address(vault), INITIAL_ASSET);
        stableToken.approve(address(vault), INITIAL_STABLE);

        vault.initialize(INITIAL_ASSET, INITIAL_STABLE);

        assertEq(vault.reserveAsset(), INITIAL_ASSET);
        assertEq(vault.reserveStable(), INITIAL_STABLE);
        assertEq(uint256(vault.phase()), uint256(PermissionedAMM.PoolPhase.SEED));

        // Check spot price is $1.00
        assertEq(vault.getSpotPrice(), 1e18);

        vm.stopPrank();
    }

    function test_Initialize_CustomPrice() public {
        vm.startPrank(admin);

        // Initialize at $0.50 per Asset
        uint256 assetAmount = 2_000_000e18;
        uint256 stableAmount = 1_000_000e18;

        assetToken.approve(address(vault), assetAmount);
        stableToken.approve(address(vault), stableAmount);

        vault.initialize(assetAmount, stableAmount);

        // Price = Stable/Asset = 1M/2M = 0.5
        assertEq(vault.getSpotPrice(), 0.5e18);

        vm.stopPrank();
    }

    function test_RevertWhen_InitializeTwice() public {
        vm.startPrank(admin);

        assetToken.approve(address(vault), INITIAL_ASSET);
        stableToken.approve(address(vault), INITIAL_STABLE);
        vault.initialize(INITIAL_ASSET, INITIAL_STABLE);

        assetToken.approve(address(vault), INITIAL_ASSET);
        stableToken.approve(address(vault), INITIAL_STABLE);

        vm.expectRevert();
        vault.initialize(INITIAL_ASSET, INITIAL_STABLE);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Swap_BuyAsset() public {
        _initializeAndActivatePool();

        vm.startPrank(user1);

        uint256 stableIn = 5_000e18;
        stableToken.approve(address(vault), stableIn);

        uint256 assetBefore = assetToken.balanceOf(user1);
        uint256 stableBefore = stableToken.balanceOf(user1);

        // Get quote first
        (uint256 expectedOut,) = vault.quoteSwap(false, stableIn);

        // Execute swap
        uint256 assetOut = vault.swap(false, stableIn, expectedOut * 99 / 100); // 1% slippage

        uint256 assetAfter = assetToken.balanceOf(user1);
        uint256 stableAfter = stableToken.balanceOf(user1);

        assertEq(assetAfter - assetBefore, assetOut);
        assertEq(stableBefore - stableAfter, stableIn);
        assertTrue(assetOut > 0);

        vm.stopPrank();
    }

    function test_Swap_SellAsset() public {
        _initializeAndActivatePool();

        vm.startPrank(user1);

        uint256 assetIn = 5_000e18;
        assetToken.approve(address(vault), assetIn);

        uint256 assetBefore = assetToken.balanceOf(user1);
        uint256 stableBefore = stableToken.balanceOf(user1);

        // Get quote
        (uint256 expectedOut,) = vault.quoteSwap(true, assetIn);

        // Execute swap
        uint256 stableOut = vault.swap(true, assetIn, expectedOut * 99 / 100);

        uint256 assetAfter = assetToken.balanceOf(user1);
        uint256 stableAfter = stableToken.balanceOf(user1);

        assertEq(assetBefore - assetAfter, assetIn);
        assertEq(stableAfter - stableBefore, stableOut);
        assertTrue(stableOut > 0);

        vm.stopPrank();
    }

    function test_RevertWhen_TreasurySwaps() public {
        _initializeAndActivatePool();

        vm.startPrank(treasury);

        stableToken.approve(address(vault), 1000e18);

        vm.expectRevert(PermissionedAMM.PermissionedAMM__TreasuryCannotSwap.selector);
        vault.swap(false, 1000e18, 0);

        vm.stopPrank();
    }

    function test_RevertWhen_NonCompliantUser() public {
        _initializeAndActivatePool();

        address nonCompliantUser = makeAddr("nonCompliant");
        vm.startPrank(admin);
        stableToken.mint(nonCompliantUser, 10_000e18);
        vm.stopPrank();

        vm.startPrank(nonCompliantUser);
        stableToken.approve(address(vault), 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(PermissionedAMM.PermissionedAMM__NotCompliant.selector, nonCompliantUser)
        );
        vault.swap(false, 1000e18, 0);

        vm.stopPrank();
    }

    function test_RevertWhen_PoolNotActive() public {
        // Initialize but don't activate
        vm.startPrank(admin);
        assetToken.approve(address(vault), INITIAL_ASSET);
        stableToken.approve(address(vault), INITIAL_STABLE);
        vault.initialize(INITIAL_ASSET, INITIAL_STABLE);
        vault.setDirectSwapEnabled(true);
        vm.stopPrank();

        vm.startPrank(user1);
        stableToken.approve(address(vault), 1000e18);

        vm.expectRevert();
        vault.swap(false, 1000e18, 0);

        vm.stopPrank();
    }

    function test_RevertWhen_DirectSwapDisabled() public {
        _initializeAndActivatePool();

        vm.startPrank(admin);
        vault.setDirectSwapEnabled(false);
        vm.stopPrank();

        vm.startPrank(user1);
        stableToken.approve(address(vault), 1000e18);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__DirectSwapDisabled.selector);
        vault.swap(false, 1000e18, 0);
        vm.stopPrank();
    }

    function test_SwapOnBehalf_WorksWhenDirectSwapDisabled() public {
        _initializeAndActivatePool();

        vm.startPrank(admin);
        vault.setDirectSwapEnabled(false);
        stableToken.mint(operator, 5_000e18);
        vm.stopPrank();

        vm.startPrank(operator);
        stableToken.approve(address(vault), 5_000e18);
        (uint256 expectedOut,) = vault.quoteSwap(false, 5_000e18);
        uint256 assetOut = vault.swapOnBehalf(user1, false, 5_000e18, expectedOut * 99 / 100);
        vm.stopPrank();

        assertTrue(assetOut > 0);
        assertEq(assetToken.balanceOf(operator), assetOut);
        assertEq(assetToken.balanceOf(user1), 100_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                         SLIPPAGE PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhen_SlippageExceeded() public {
        _initializeAndActivatePool();

        vm.startPrank(user1);

        // Try a very large swap that would cause >1% slippage
        uint256 largeAmount = 100_000e18; // 10% of pool
        stableToken.approve(address(vault), largeAmount);

        // This should revert due to impact policy
        vm.expectRevert();
        vault.swap(false, largeAmount, 0);

        vm.stopPrank();
    }

    function test_QuoteSwap_ShowsImpact() public {
        _initializeAndActivatePool();

        // Small swap - low impact
        (uint256 smallOut, uint256 smallImpact) = vault.quoteSwap(false, 1000e18);
        assertTrue(smallImpact < 100); // Less than 1%

        // Larger swap - higher impact
        (uint256 largeOut, uint256 largeImpact) = vault.quoteSwap(false, 50_000e18);
        assertTrue(largeImpact > smallImpact);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDITY MANAGEMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AddLiquidity_ViaTimelock() public {
        _initializeAndActivatePool();

        uint256 addAsset = 500_000e18;
        uint256 addStable = 500_000e18;

        vm.startPrank(admin);
        assetToken.approve(address(timelock), addAsset);
        stableToken.approve(address(timelock), addStable);
        assetToken.transfer(address(timelock), addAsset);
        stableToken.transfer(address(timelock), addStable);

        // Queue the operation
        bytes memory data = abi.encodeWithSelector(vault.addLiquidity.selector, addAsset, addStable);

        // Approve from timelock
        vm.stopPrank();
        vm.startPrank(address(timelock));
        assetToken.approve(address(vault), addAsset);
        stableToken.approve(address(vault), addStable);
        vm.stopPrank();

        vm.startPrank(admin);
        bytes32 opId = timelock.queue(address(vault), 0, data, "Add liquidity");

        // Try to execute immediately - should fail
        vm.expectRevert();
        timelock.execute(opId);

        // Wait for delay
        vm.warp(block.timestamp + 24 hours + 1);

        uint256 reserveAssetBefore = vault.reserveAsset();
        uint256 reserveStableBefore = vault.reserveStable();

        // Now execute
        timelock.execute(opId);

        assertEq(vault.reserveAsset(), reserveAssetBefore + addAsset);
        assertEq(vault.reserveStable(), reserveStableBefore + addStable);

        vm.stopPrank();
    }

    function test_Rebalance_ViaTimelock() public {
        _initializeAndActivatePool();

        uint256 priceBefore = vault.getSpotPrice();

        // Add Stable to increase price
        uint256 addStable = 200_000e18;

        vm.startPrank(admin);
        stableToken.transfer(address(timelock), addStable);
        vm.stopPrank();

        vm.startPrank(address(timelock));
        stableToken.approve(address(vault), addStable);
        vm.stopPrank();

        vm.startPrank(admin);
        bytes memory data = abi.encodeWithSelector(vault.rebalance.selector, address(stableToken), addStable);

        bytes32 opId = timelock.queue(address(vault), 0, data, "Rebalance - add Stable");

        vm.warp(block.timestamp + 24 hours + 1);
        timelock.execute(opId);

        uint256 priceAfter = vault.getSpotPrice();
        assertTrue(priceAfter > priceBefore); // Price increased

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          SWAP ON BEHALF (OPERATOR) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapOnBehalf_BuyAsset_OutputToOperator() public {
        _initializeAndActivatePool();

        uint256 fiatAmount = 5_000e18;

        vm.startPrank(admin);
        stableToken.mint(operator, fiatAmount);
        vm.stopPrank();

        uint256 userAssetBefore = assetToken.balanceOf(user1);
        uint256 operatorAssetBefore = assetToken.balanceOf(operator);

        vm.startPrank(operator);
        stableToken.approve(address(vault), fiatAmount);
        (uint256 expectedOut,) = vault.quoteSwap(false, fiatAmount);
        uint256 assetOut = vault.swapOnBehalf(user1, false, fiatAmount, expectedOut * 99 / 100);
        vm.stopPrank();

        assertEq(assetToken.balanceOf(user1), userAssetBefore);
        assertEq(assetToken.balanceOf(operator) - operatorAssetBefore, assetOut);
        assertTrue(assetOut > 0);
    }

    /*//////////////////////////////////////////////////////////////
                            FEE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FeesAccumulate() public {
        _initializeAndActivatePool();

        // Execute several swaps
        vm.startPrank(user1);
        stableToken.approve(address(vault), 50_000e18);
        vault.swap(false, 5_000e18, 0);
        vault.swap(false, 5_000e18, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        assetToken.approve(address(vault), 20_000e18);
        vault.swap(true, 5_000e18, 0);
        vm.stopPrank();

        // Check fees accumulated
        (,, uint256 feesAsset, uint256 feesStable,) = vault.getPoolStats();
        assertTrue(feesAsset > 0 || feesStable > 0);
    }

    function test_CollectFees() public {
        _initializeAndActivatePool();

        // Execute swap to generate fees
        vm.startPrank(user1);
        stableToken.approve(address(vault), 5_000e18);
        vault.swap(false, 5_000e18, 0);
        vm.stopPrank();

        // Collect fees
        vm.startPrank(treasury);

        (,, uint256 feesBefore,,) = vault.getPoolStats();

        address feeRecipient = makeAddr("feeRecipient");
        vault.collectFees(feeRecipient);

        // Fees should be transferred
        assertTrue(assetToken.balanceOf(feeRecipient) > 0 || stableToken.balanceOf(feeRecipient) > 0);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        IMPACT POLICY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ImpactPolicy_TieredLimits() public {
        // Small trade - high slippage allowed
        uint256 maxSmall = impactPolicy.getMaxSlippage(500e18); // $500
        assertEq(maxSmall, 300); // 3%

        // Medium trade
        uint256 maxMedium = impactPolicy.getMaxSlippage(5_000e18); // $5,000
        assertEq(maxMedium, 200); // 2%

        // Large trade
        uint256 maxLarge = impactPolicy.getMaxSlippage(50_000e18); // $50,000
        assertEq(maxLarge, 100); // 1%

        // Whale trade
        uint256 maxWhale = impactPolicy.getMaxSlippage(500_000e18); // $500,000
        assertEq(maxWhale, 50); // 0.5%
    }

    function test_ImpactPolicy_SetTierThresholdsChangesBands() public {
        assertEq(impactPolicy.tier1ThresholdUSD(), 1_000e18);

        vm.startPrank(admin);
        impactPolicy.setTierThresholds(2_000e18, 20_000e18, 200_000e18);
        vm.stopPrank();

        assertEq(impactPolicy.getMaxSlippage(1_500e18), 300);
        assertEq(impactPolicy.getMaxSlippage(5_000e18), 200);
        assertEq(impactPolicy.getMaxSlippage(50_000e18), 100);
        assertEq(impactPolicy.getMaxSlippage(500_000e18), 50);
    }

    function test_ImpactPolicy_RevertWhen_InvalidTierThresholds() public {
        vm.startPrank(admin);
        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidThresholds.selector);
        impactPolicy.setTierThresholds(0, 10_000e18, 100_000e18);

        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidThresholds.selector);
        impactPolicy.setTierThresholds(10_000e18, 10_000e18, 100_000e18);

        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidThresholds.selector);
        impactPolicy.setTierThresholds(10_000e18, 20_000e18, 20_000e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        COMPLIANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ComplianceRegistry_Tiers() public {
        assertTrue(complianceRegistry.isCompliant(user1));
        assertTrue(complianceRegistry.isCompliant(user2));

        address nonCompliant = makeAddr("nonCompliant");
        assertFalse(complianceRegistry.isCompliant(nonCompliant));

        assertEq(complianceRegistry.getComplianceTier(user1), 2);
        assertEq(complianceRegistry.getComplianceTier(user2), 1);

        assertEq(complianceRegistry.getDailyLimit(user1), 100_000e18);
        assertEq(complianceRegistry.getDailyLimit(user2), 10_000e18);
    }

    function test_SetTierDailyLimit_UpdatesDirectSwapCap() public {
        vm.startPrank(admin);
        complianceRegistry.setTierDailyLimit(2, 50_000e18);
        vm.stopPrank();
        assertEq(complianceRegistry.getDailyLimit(user1), 50_000e18);
        assertEq(complianceRegistry.getTierDailyLimit(2), 50_000e18);
    }

    function test_RevertWhen_DailyLimitExceeded() public {
        _initializeAndActivatePool();

        vm.startPrank(admin);
        complianceRegistry.setTierDailyLimit(2, 8_000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        stableToken.approve(address(vault), 20_000e18);
        vault.swap(false, 5_000e18, 0);
        vault.swap(false, 3_000e18, 0);
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedAMM.PermissionedAMM__DailyLimitExceeded.selector, user1, uint256(0))
        );
        vault.swap(false, 1_000e18, 0);
        vm.stopPrank();
    }

    function test_SwapOnBehalf_DoesNotConsumeAttributedUserDailyLimit() public {
        _initializeAndActivatePool();

        vm.startPrank(admin);
        complianceRegistry.setTierDailyLimit(2, 6_000e18);
        stableToken.mint(operator, 50_000e18);
        vm.stopPrank();

        vm.startPrank(user1);
        stableToken.approve(address(vault), 10_000e18);
        vault.swap(false, 5_000e18, 0);
        vm.stopPrank();

        assertEq(complianceRegistry.dailyVolumeUsed(user1), 5_000e18);

        vm.startPrank(operator);
        stableToken.approve(address(vault), 50_000e18);
        vault.swapOnBehalf(user1, false, 3_000e18, 0);
        vm.stopPrank();

        assertEq(complianceRegistry.dailyVolumeUsed(user1), 5_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                          TIMELOCK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Timelock_QueueAndExecute() public {
        vm.startPrank(admin);

        bytes memory data = abi.encodeWithSignature("setSwapFee(uint256)", 50);
        bytes32 opId = timelock.queue(address(vault), 0, data, "Update swap fee");

        // Check operation is queued
        assertEq(uint256(timelock.getOperationStatus(opId)), uint256(Timelock.OperationStatus.Queued));

        // Check time remaining
        uint256 remaining = timelock.getTimeRemaining(opId);
        assertGt(remaining, 0);

        // Warp past delay
        vm.warp(block.timestamp + 24 hours + 1);

        // Execute
        timelock.execute(opId);

        assertEq(vault.swapFeeBps(), 50);
        assertEq(uint256(timelock.getOperationStatus(opId)), uint256(Timelock.OperationStatus.Executed));

        vm.stopPrank();
    }

    function test_Timelock_Cancel() public {
        vm.startPrank(admin);

        bytes memory data = abi.encodeWithSignature("setSwapFee(uint256)", 100);
        bytes32 opId = timelock.queue(address(vault), 0, data, "Update swap fee");

        timelock.cancel(opId);

        assertEq(uint256(timelock.getOperationStatus(opId)), uint256(Timelock.OperationStatus.Cancelled));

        // Cannot execute cancelled operation
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert();
        timelock.execute(opId);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Fuzz_Swap_BuyAsset(uint256 amountIn) public {
        _initializeAndActivatePool();

        amountIn = bound(amountIn, 1e18, 5_000e18);

        vm.startPrank(admin);
        stableToken.mint(user1, amountIn);
        vm.stopPrank();

        uint256 kBefore = vault.getK();

        vm.startPrank(user1);
        stableToken.approve(address(vault), amountIn);
        uint256 assetOut = vault.swap(false, amountIn, 0);
        vm.stopPrank();

        assertTrue(assetOut > 0);

        (uint256 rAsset, uint256 rStable) = vault.getReserves();
        assertTrue(rAsset * rStable >= kBefore);
    }

    function test_Fuzz_Swap_SellAsset(uint256 amountIn) public {
        _initializeAndActivatePool();

        amountIn = bound(amountIn, 1e18, 5_000e18);

        vm.startPrank(admin);
        assetToken.mint(user1, amountIn);
        vm.stopPrank();

        uint256 kBefore = vault.getK();

        vm.startPrank(user1);
        assetToken.approve(address(vault), amountIn);
        uint256 stableOut = vault.swap(true, amountIn, 0);
        vm.stopPrank();

        assertTrue(stableOut > 0);

        (uint256 rAsset, uint256 rStable) = vault.getReserves();
        assertTrue(rAsset * rStable >= kBefore);
    }

    function test_Fuzz_SwapOnBehalf_BuyAsset(uint256 stableAmount) public {
        _initializeAndActivatePool();

        stableAmount = bound(stableAmount, 1e18, 5_000e18);

        vm.startPrank(admin);
        stableToken.mint(operator, stableAmount);
        vm.stopPrank();

        uint256 userAssetBefore = assetToken.balanceOf(user1);
        uint256 operatorAssetBefore = assetToken.balanceOf(operator);

        vm.startPrank(operator);
        stableToken.approve(address(vault), stableAmount);
        uint256 assetOut = vault.swapOnBehalf(user1, false, stableAmount, 0);
        vm.stopPrank();

        assertEq(assetToken.balanceOf(user1), userAssetBefore);
        assertEq(assetToken.balanceOf(operator) - operatorAssetBefore, assetOut);
        assertTrue(assetOut > 0);

        (uint256 rAsset, uint256 rStable) = vault.getReserves();
        assertTrue(rAsset > 0);
        assertTrue(rStable > 0);
    }

    function test_Fuzz_GetAmountOut_NeverExceedsReserve(uint256 amountIn) public {
        _initializeAndActivatePool();

        amountIn = bound(amountIn, 1e18, 50_000e18);

        (uint256 amountOut,) = vault.getAmountOut(amountIn, INITIAL_ASSET, INITIAL_STABLE);
        assertTrue(amountOut < INITIAL_STABLE);

        (uint256 amountOut2,) = vault.getAmountOut(amountIn, INITIAL_STABLE, INITIAL_ASSET);
        assertTrue(amountOut2 < INITIAL_ASSET);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _initializeAndActivatePool() internal {
        vm.startPrank(admin);

        assetToken.approve(address(vault), INITIAL_ASSET);
        stableToken.approve(address(vault), INITIAL_STABLE);
        vault.initialize(INITIAL_ASSET, INITIAL_STABLE);
        vault.activate();
        vault.setDirectSwapEnabled(true);

        vm.stopPrank();
    }
}

