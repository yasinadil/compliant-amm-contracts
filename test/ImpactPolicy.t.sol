// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";

contract ImpactPolicyTest is Test {
    ImpactPolicy internal policy;
    address internal admin = makeAddr("admin");

    function setUp() public {
        policy = new ImpactPolicy(admin);
    }

    function test_defaultBands() public view {
        assertEq(policy.getMaxSlippage(999e18), 300);
        assertEq(policy.getMaxSlippage(1_000e18), 200);
        assertEq(policy.getMaxSlippage(9_999e18), 200);
        assertEq(policy.getMaxSlippage(10_000e18), 100);
        assertEq(policy.getMaxSlippage(100_000e18), 50);
        assertEq(policy.getMaxSlippage(type(uint128).max), 50);
    }

    function test_validateImpact_noSlippage() public view {
        // price 2 stable per asset; selling 10 asset should yield 20 stable
        (bool ok, uint256 bps) = policy.validateImpact(10e18, 20e18, 2e18, true);
        assertTrue(ok);
        assertEq(bps, 0);
    }

    function test_validateImpact_sellAsset() public view {
        // $20 trade (< $1k band, 3% cap): 2.5% slippage passes, 3.5% fails
        (bool ok, uint256 bps) = policy.validateImpact(10e18, 19.5e18, 2e18, true);
        assertTrue(ok);
        assertEq(bps, 250);
        (ok, bps) = policy.validateImpact(10e18, 19.3e18, 2e18, true);
        assertFalse(ok);
        assertEq(bps, 350);
    }

    function test_validateImpact_buyAssetUsesStableNotional() public view {
        // $50k buy at price 2 → expected 25k asset; 1.2% short exceeds the 1% band
        (bool ok, uint256 bps) = policy.validateImpact(50_000e18, 24_700e18, 2e18, false);
        assertFalse(ok);
        assertEq(bps, 120);
    }

    function test_setSlippageLimits_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidSlippageLimits.selector);
        policy.setSlippageLimits(100, 200, 50, 10); // not descending
        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidSlippageLimits.selector);
        policy.setSlippageLimits(1001, 500, 100, 50); // above 10% ceiling
        policy.setSlippageLimits(500, 400, 300, 200);
        vm.stopPrank();
        assertEq(policy.getMaxSlippage(0), 500);
    }

    function test_setTierThresholds_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidThresholds.selector);
        policy.setTierThresholds(0, 1, 2);
        vm.expectRevert(ImpactPolicy.ImpactPolicy__InvalidThresholds.selector);
        policy.setTierThresholds(5, 5, 6);
        policy.setTierThresholds(100e18, 200e18, 300e18);
        vm.stopPrank();
        assertEq(policy.getMaxSlippage(150e18), 200);
    }

    function test_pauseBlocksValidation() public {
        vm.prank(admin);
        policy.setPaused(true);
        vm.expectRevert(ImpactPolicy.ImpactPolicy__PolicyPaused.selector);
        policy.validateImpact(1e18, 1e18, 1e18, true);
    }

    function test_onlyOwner() public {
        vm.expectRevert();
        policy.setPaused(true);
        vm.expectRevert();
        policy.setSlippageLimits(300, 200, 100, 50);
        vm.expectRevert();
        policy.setTierThresholds(1, 2, 3);
    }

    /// Larger trades never get a looser slippage cap than smaller ones.
    function testFuzz_capIsMonotonic(uint256 small, uint256 large) public view {
        small = bound(small, 0, type(uint128).max);
        large = bound(large, small, type(uint128).max);
        assertGe(policy.getMaxSlippage(small), policy.getMaxSlippage(large));
    }
}
