// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FixedApyStaking} from "../src/FixedApyStaking.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract StakingHandler is Test {
    FixedApyStaking internal staking;
    MockERC20 internal token;
    address internal admin;
    address[] public actors;

    constructor(FixedApyStaking _staking, MockERC20 _token, address _admin) {
        staking = _staking;
        token = _token;
        admin = _admin;
        for (uint256 i; i < 4; i++) {
            address a = makeAddr(string(abi.encodePacked("staker", vm.toString(i))));
            token.mint(a, 1_000_000_000e18);
            vm.prank(a);
            token.approve(address(staking), type(uint256).max);
            actors.push(a);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        uint256 room = staking.maxStakeCapacity() - staking.totalStaked();
        if (room == 0) return;
        amount = bound(amount, 1, room < 50_000_000e18 ? room : 50_000_000e18);
        vm.prank(a);
        staking.stake(amount);
    }

    function unstake(uint256 seed, uint256 amount) external {
        address a = actors[seed % actors.length];
        (uint256 staked,,,) = staking.getUserInfo(a);
        if (staked == 0) return;
        vm.prank(a);
        staking.unstake(bound(amount, 1, staked));
    }

    function claim(uint256 seed) external {
        vm.prank(actors[seed % actors.length]);
        staking.claim();
    }

    function globalUpdate(uint256 apySeed) external {
        vm.prank(admin);
        staking.setApyBps(bound(apySeed, 500, 2000));
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 45 days));
    }
}

contract FixedApyStakingInvariantTest is StdInvariant, Test {
    FixedApyStaking internal staking;
    MockERC20 internal token;
    StakingHandler internal handler;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        token = new MockERC20("Asset", "AST", 18);
        vm.startPrank(admin);
        staking = new FixedApyStaking(address(token), admin, treasury, type(uint256).max);
        staking.initialize(42_000_000e18, 2000, 0, 1);
        staking.setDirectActionsEnabled(true);
        vm.stopPrank();

        token.mint(treasury, 42_000_000e18);
        vm.startPrank(treasury);
        token.approve(address(staking), type(uint256).max);
        staking.fundRewardBucket(42_000_000e18);
        vm.stopPrank();

        handler = new StakingHandler(staking, token, admin);
        targetContract(address(handler));
    }

    /// Principal is always fully backed by the contract's balance.
    function invariant_principalBacked() public view {
        assertGe(token.balanceOf(address(staking)), staking.totalStaked());
    }

    /// Every staker can always get their principal out, regardless of reward accounting.
    function invariant_everyStakerCanExit() public {
        uint256 snapshot = vm.snapshotState();
        for (uint256 i; i < handler.actorCount(); i++) {
            address a = handler.actors(i);
            (uint256 staked,,,) = staking.getUserInfo(a);
            if (staked == 0) continue;
            uint256 before = token.balanceOf(a);
            vm.prank(a);
            staking.emergencyWithdraw();
            assertEq(token.balanceOf(a) - before, staked);
        }
        assertEq(staking.totalStaked(), 0);
        vm.revertToState(snapshot);
    }
}
