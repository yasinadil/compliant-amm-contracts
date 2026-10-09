// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {PermissionedAMM} from "../src/PermissionedAMM.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Lifecycle, liquidity management, admin controls and emergency paths.
contract PermissionedAMMAdminTest is Test {
    PermissionedAMM internal amm;
    MockERC20 internal asset;
    MockERC20 internal stable;
    ImpactPolicy internal policy;
    ComplianceRegistry internal registry;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal timelock = makeAddr("timelock");
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        stable = new MockERC20("Stable", "USDX", 18);
        vm.startPrank(admin);
        policy = new ImpactPolicy(admin);
        registry = new ComplianceRegistry(admin);
        amm = new PermissionedAMM(
            address(asset), address(stable), address(policy), address(registry), admin, treasury, timelock
        );
        registry.grantRole(registry.SWAP_VOLUME_RECORDER_ROLE(), address(amm));
        registry.setComplianceTier(trader, 3);
        vm.stopPrank();

        address[3] memory funded = [admin, timelock, trader];
        for (uint256 i; i < funded.length; i++) {
            asset.mint(funded[i], 10_000_000e18);
            stable.mint(funded[i], 10_000_000e18);
            vm.startPrank(funded[i]);
            asset.approve(address(amm), type(uint256).max);
            stable.approve(address(amm), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _launch() internal {
        vm.startPrank(admin);
        amm.initialize(1_000_000e18, 2_000_000e18);
        amm.activate();
        amm.setDirectSwapEnabled(true);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- construction & lifecycle

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        new PermissionedAMM(address(0), address(stable), address(0), address(0), admin, treasury, timelock);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        new PermissionedAMM(address(asset), address(0), address(0), address(0), admin, treasury, timelock);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        new PermissionedAMM(address(asset), address(stable), address(0), address(0), address(0), treasury, timelock);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        new PermissionedAMM(address(asset), address(stable), address(0), address(0), admin, address(0), timelock);
    }

    function test_phaseMachine() public {
        assertEq(uint256(amm.phase()), uint256(PermissionedAMM.PoolPhase.UNINITIALIZED));
        vm.startPrank(admin);
        vm.expectRevert();
        amm.activate(); // must seed first
        amm.initialize(1_000_000e18, 2_000_000e18);
        assertEq(uint256(amm.phase()), uint256(PermissionedAMM.PoolPhase.SEED));
        assertEq(amm.getSpotPrice(), 2e18);
        vm.expectRevert();
        amm.initialize(1, 1); // only once
        amm.activate();
        assertEq(uint256(amm.phase()), uint256(PermissionedAMM.PoolPhase.ACTIVE));
        amm.deprecate();
        assertEq(uint256(amm.phase()), uint256(PermissionedAMM.PoolPhase.DEPRECATED));
        vm.stopPrank();
    }

    function test_swapsBlockedOutsideActive() public {
        vm.startPrank(admin);
        amm.initialize(1_000_000e18, 2_000_000e18);
        amm.setDirectSwapEnabled(true);
        vm.stopPrank();
        vm.prank(trader);
        vm.expectRevert();
        amm.swap(true, 1e18, 0);
    }

    // ---------------------------------------------------------------- timelocked liquidity

    function test_addAndRemoveLiquidity_onlyTimelock() public {
        _launch();
        vm.startPrank(timelock);
        amm.addLiquidity(100e18, 200e18);
        (uint256 rA, uint256 rS) = amm.getReserves();
        assertEq(rA, 1_000_100e18);
        assertEq(rS, 2_000_200e18);

        amm.removeLiquidity(100e18, 200e18, timelock);
        (rA, rS) = amm.getReserves();
        assertEq(rA, 1_000_000e18);
        assertEq(rS, 2_000_000e18);

        vm.expectRevert(PermissionedAMM.PermissionedAMM__InsufficientLiquidity.selector);
        amm.removeLiquidity(rA, 0, timelock); // must leave MINIMUM_LIQUIDITY
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        amm.removeLiquidity(1, 0, address(0));
        vm.stopPrank();

        vm.prank(admin);
        vm.expectRevert();
        amm.addLiquidity(1, 1);
    }

    function test_addLiquidity_rejectedBeforeInitOrAfterDeprecation() public {
        vm.prank(timelock);
        vm.expectRevert();
        amm.addLiquidity(1, 1);
        _launch();
        vm.prank(admin);
        amm.deprecate();
        vm.prank(timelock);
        vm.expectRevert();
        amm.addLiquidity(1, 1);
    }

    function test_rebalanceMovesPrice() public {
        _launch();
        uint256 before = amm.getSpotPrice();
        vm.prank(timelock);
        amm.rebalance(address(stable), 200_000e18);
        assertGt(amm.getSpotPrice(), before, "adding stable raises asset price");

        vm.startPrank(timelock);
        amm.rebalance(address(asset), 500_000e18);
        assertLt(amm.getSpotPrice(), before);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InvalidAmount.selector);
        amm.rebalance(address(asset), 0);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        amm.rebalance(stranger, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- fees

    function test_feesAccrueAndCollect() public {
        _launch();
        vm.prank(trader);
        amm.swap(true, 1_000e18, 0); // 0.30% fee = 3 asset
        assertEq(amm.accumulatedFeesAsset(), 3e18);

        vm.prank(stranger);
        vm.expectRevert();
        amm.collectFees(stranger);

        vm.prank(treasury);
        amm.collectFees(treasury);
        assertEq(asset.balanceOf(treasury), 3e18);
        assertEq(amm.accumulatedFeesAsset(), 0);
        (uint256 rA,) = amm.getReserves();
        assertEq(asset.balanceOf(address(amm)), rA);

        vm.prank(treasury);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        amm.collectFees(address(0));
    }

    function test_treasuryCannotTrade() public {
        _launch();
        asset.mint(treasury, 1e18);
        vm.startPrank(treasury);
        asset.approve(address(amm), 1e18);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__TreasuryCannotSwap.selector);
        amm.swap(true, 1e18, 0);
        vm.stopPrank();
    }

    function test_setSwapFee() public {
        vm.startPrank(admin);
        amm.setSwapFee(100);
        assertEq(amm.swapFeeBps(), 100);
        vm.expectRevert(abi.encodeWithSelector(PermissionedAMM.PermissionedAMM__InvalidFee.selector, 501));
        amm.setSwapFee(501);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- admin controls

    function test_pauseBlocksSwaps() public {
        _launch();
        vm.prank(admin);
        amm.pause();
        vm.prank(trader);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        amm.swap(true, 1e18, 0);

        vm.prank(admin);
        amm.unpause();
        vm.prank(trader);
        amm.swap(true, 1e18, 0);
    }

    function test_policyAndRegistryCanBeDetached() public {
        _launch();
        vm.startPrank(admin);
        amm.setImpactPolicy(address(0));
        amm.setComplianceRegistry(address(0));
        vm.stopPrank();
        assertEq(address(amm.impactPolicy()), address(0));

        // With no registry, an unverified wallet can trade; with no policy, large impact is allowed.
        asset.mint(stranger, 200_000e18);
        vm.startPrank(stranger);
        asset.approve(address(amm), type(uint256).max);
        amm.swap(true, 200_000e18, 0);
        vm.stopPrank();
        (uint256 out, uint256 impact) = amm.quoteSwap(true, 1e18);
        assertGt(out, 0);
        assertEq(impact, 0);
    }

    function test_adminFunctionsAreRoleGated() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        amm.initialize(1e18, 1e18);
        vm.expectRevert();
        amm.setSwapFee(1);
        vm.expectRevert();
        amm.setImpactPolicy(address(0));
        vm.expectRevert();
        amm.setComplianceRegistry(address(0));
        vm.expectRevert();
        amm.setDirectSwapEnabled(true);
        vm.expectRevert();
        amm.pause();
        vm.expectRevert();
        amm.deprecate();
        vm.expectRevert();
        amm.emergencyWithdraw(stranger);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- emergency

    function test_emergencyWithdrawOnlyWhenDeprecated() public {
        _launch();
        vm.startPrank(admin);
        vm.expectRevert();
        amm.emergencyWithdraw(admin);

        amm.deprecate();
        vm.expectRevert(PermissionedAMM.PermissionedAMM__ZeroAddress.selector);
        amm.emergencyWithdraw(address(0));

        uint256 before = asset.balanceOf(admin);
        amm.emergencyWithdraw(admin);
        vm.stopPrank();

        assertEq(asset.balanceOf(admin) - before, 1_000_000e18);
        (uint256 rA, uint256 rS) = amm.getReserves();
        assertEq(rA + rS, 0);
    }

    // ---------------------------------------------------------------- pricing math

    function test_getAmountInInvertsGetAmountOut() public {
        _launch();
        (uint256 rA, uint256 rS) = amm.getReserves();
        uint256 wantOut = 1_000e18;
        uint256 amountIn = amm.getAmountIn(wantOut, rS, rA);
        (uint256 gotOut,) = amm.getAmountOut(amountIn, rS, rA);
        assertGe(gotOut, wantOut, "quoted input always buys at least the requested output");
    }

    function test_pricingMathRejectsBadInputs() public {
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InvalidAmount.selector);
        amm.getAmountOut(0, 1, 1);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InsufficientLiquidity.selector);
        amm.getAmountOut(1, 0, 1);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InvalidAmount.selector);
        amm.getAmountIn(0, 1, 1);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InsufficientLiquidity.selector);
        amm.getAmountIn(1, 0, 1);
        vm.expectRevert(PermissionedAMM.PermissionedAMM__InsufficientLiquidity.selector);
        amm.getAmountIn(5, 10, 5);
        assertEq(amm.getSpotPrice(), 0, "uninitialised pool has no price");
    }

    function testFuzz_getAmountInIsSufficient(uint256 wantOut) public {
        _launch();
        (uint256 rA, uint256 rS) = amm.getReserves();
        wantOut = bound(wantOut, 1, rA / 2);
        uint256 amountIn = amm.getAmountIn(wantOut, rS, rA);
        (uint256 gotOut,) = amm.getAmountOut(amountIn, rS, rA);
        assertGe(gotOut, wantOut);
    }
}
