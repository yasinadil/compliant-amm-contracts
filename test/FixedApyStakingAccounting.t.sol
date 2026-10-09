// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {FixedApyStaking} from "../src/FixedApyStaking.sol";
import {FixedApyStakingV1} from "./legacy/FixedApyStakingV1.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/// @notice Reward-accumulator rounding. Per-user accrual is floored once over the holding period;
///         the aggregate `totalAccruedUnpaid` is computed once per global update. v1 floored the
///         aggregate as well, so Σ user accruals could exceed it and exits underflowed.
contract FixedApyStakingAccountingTest is Test {
    FixedApyStaking internal staking;
    MockERC20 internal token;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant BUCKET = 42_000_000e18;

    function setUp() public {
        token = new MockERC20("Asset", "AST", 18);
        vm.startPrank(admin);
        staking = new FixedApyStaking(address(token), admin, treasury, type(uint256).max);
        staking.initialize(BUCKET, 2000, 0, 1);
        staking.setDirectActionsEnabled(true);
        vm.stopPrank();
        _fund(address(staking));

        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            token.mint(u, 1_000_000_000e18);
            vm.prank(u);
            token.approve(address(staking), type(uint256).max);
        }
    }

    function _fund(address target) internal {
        token.mint(treasury, BUCKET);
        vm.startPrank(treasury);
        token.approve(target, BUCKET);
        FixedApyStaking(target).fundRewardBucket(BUCKET);
        vm.stopPrank();
    }

    /// Regression: minimal counterexample found by the fuzzer.
    function test_regression_lastStakerExitUnderflow() public {
        vm.startPrank(admin);
        FixedApyStakingV1 v1 = new FixedApyStakingV1(address(token), admin, treasury, type(uint256).max);
        v1.initialize(BUCKET, 2000, 0, 1);
        v1.setDirectActionsEnabled(true);
        vm.stopPrank();
        _fund(address(v1));
        vm.prank(alice);
        token.approve(address(v1), type(uint256).max);

        // Same sequence on both versions: stake, global-only update, wait, exit.
        uint256 amount = 2_601_043_546;
        vm.prank(alice);
        v1.stake(amount);
        vm.prank(alice);
        staking.stake(amount);
        skip(1);
        vm.startPrank(admin);
        v1.setRewardBucket(BUCKET);
        staking.setRewardBucket(BUCKET);
        vm.stopPrank();
        skip(2884);

        assertGt(v1.pendingRewards(alice), v1.totalAccruedUnpaid(), "v1: user owed more than aggregate");
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        v1.emergencyWithdraw();

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - before, amount, "v2: principal returned");
    }

    /// Single staker; an admin parameter update splits the accrual period in two.
    function testFuzz_emergencyWithdrawAfterGlobalUpdate(uint96 amount, uint32 t1, uint32 t2) public {
        amount = uint96(bound(amount, 1, 100_000_000e18));
        t1 = uint32(bound(t1, 1, 400 days));
        t2 = uint32(bound(t2, 1, 400 days));

        vm.prank(alice);
        staking.stake(amount);
        skip(t1);
        vm.prank(admin);
        staking.setRewardBucket(BUCKET);
        skip(t2);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        staking.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - before, amount);
    }

    /// Two stakers interleaving; the last one out can always unstake and claim.
    function testFuzz_lastStakerCanUnstake(uint96 a, uint96 b, uint32 t1, uint32 t2, uint32 t3) public {
        a = uint96(bound(a, 1, 100_000_000e18));
        b = uint96(bound(b, 1, 100_000_000e18));
        t1 = uint32(bound(t1, 1, 200 days));
        t2 = uint32(bound(t2, 1, 200 days));
        t3 = uint32(bound(t3, 1, 200 days));

        vm.prank(alice);
        staking.stake(a);
        skip(t1);
        vm.prank(bob);
        staking.stake(b);
        skip(t2);
        vm.prank(bob);
        staking.unstake(b);
        skip(t3);

        vm.prank(alice);
        staking.unstake(a);
        assertEq(staking.totalStaked(), 0);
    }
}
