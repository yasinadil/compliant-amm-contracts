// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {Timelock} from "../src/Timelock.sol";

contract Target {
    uint256 public value;
    uint256 public received;

    function set(uint256 v) external payable {
        value = v;
        received += msg.value;
    }

    function boom() external pure {
        revert("boom");
    }
}

contract TimelockTest is Test {
    Timelock internal timelock;
    Target internal target;
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");
    uint256 internal constant DELAY = 2 days;

    function setUp() public {
        timelock = new Timelock(admin, DELAY);
        target = new Target();
    }

    function _queue(bytes memory data, uint256 value) internal returns (bytes32 id) {
        vm.prank(admin);
        id = timelock.queue(address(target), value, data, "op");
    }

    function test_constructor_enforcesDelayBounds() public {
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__InvalidDelay.selector, 1 hours));
        new Timelock(admin, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__InvalidDelay.selector, 31 days));
        new Timelock(admin, 31 days);
    }

    function test_queueThenExecuteAfterDelay() public {
        bytes32 id = _queue(abi.encodeCall(Target.set, (42)), 0);
        assertEq(uint256(timelock.getOperationStatus(id)), uint256(Timelock.OperationStatus.Queued));
        assertEq(timelock.getTimeRemaining(id), DELAY);
        assertFalse(timelock.isOperationReady(id));

        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(id);

        skip(DELAY);
        assertTrue(timelock.isOperationReady(id));
        assertEq(timelock.getTimeRemaining(id), 0);
        vm.prank(admin);
        timelock.execute(id);

        assertEq(target.value(), 42);
        assertEq(uint256(timelock.getOperationStatus(id)), uint256(Timelock.OperationStatus.Executed));
        assertFalse(timelock.isOperationReady(id));
    }

    function test_executeForwardsValue() public {
        vm.deal(address(timelock), 1 ether);
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 1 ether);
        skip(DELAY);
        vm.prank(admin);
        timelock.execute(id);
        assertEq(target.received(), 1 ether);
    }

    function test_cannotExecuteTwice() public {
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 0);
        skip(DELAY);
        vm.startPrank(admin);
        timelock.execute(id);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__OperationAlreadyExecuted.selector, id));
        timelock.execute(id);
        vm.stopPrank();
    }

    function test_staleAfterGracePeriod() public {
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 0);
        skip(DELAY + timelock.GRACE_PERIOD() + 1);
        assertFalse(timelock.isOperationReady(id));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__OperationStale.selector, id));
        timelock.execute(id);
    }

    function test_cancel() public {
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 0);
        vm.prank(admin);
        timelock.cancel(id);
        assertEq(uint256(timelock.getOperationStatus(id)), uint256(Timelock.OperationStatus.Cancelled));
        assertEq(timelock.getTimeRemaining(id), 0);

        skip(DELAY);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__OperationNotQueued.selector, id));
        timelock.execute(id);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__OperationNotQueued.selector, id));
        timelock.cancel(id);
        vm.stopPrank();
    }

    function test_duplicateQueueInSameBlockReverts() public {
        bytes memory data = abi.encodeCall(Target.set, (7));
        bytes32 id = _queue(data, 0);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__OperationAlreadyQueued.selector, id));
        timelock.queue(address(target), 0, data, "dup");
    }

    function test_failedCallReverts() public {
        bytes32 id = _queue(abi.encodeCall(Target.boom, ()), 0);
        skip(DELAY);
        vm.prank(admin);
        vm.expectRevert(Timelock.Timelock__ExecutionFailed.selector);
        timelock.execute(id);
        assertEq(uint256(timelock.getOperationStatus(id)), uint256(Timelock.OperationStatus.Queued));
    }

    function test_pendingOperationsView() public {
        bytes32 a = _queue(abi.encodeCall(Target.set, (1)), 0);
        skip(1);
        _queue(abi.encodeCall(Target.set, (2)), 0);
        vm.prank(admin);
        timelock.cancel(a);
        assertEq(timelock.getOperationCount(), 2);
        assertEq(timelock.getPendingOperations().length, 1);
    }

    function test_setDelay() public {
        vm.prank(admin);
        timelock.setDelay(3 days);
        assertEq(timelock.delay(), 3 days);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(Timelock.Timelock__InvalidDelay.selector, 1));
        timelock.setDelay(1);
        vm.stopPrank();
    }

    function test_rolesEnforced() public {
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 0);
        vm.startPrank(stranger);
        vm.expectRevert();
        timelock.queue(address(target), 0, "", "x");
        vm.expectRevert();
        timelock.execute(id);
        vm.expectRevert();
        timelock.cancel(id);
        vm.expectRevert();
        timelock.setDelay(3 days);
        vm.stopPrank();
    }

    function testFuzz_cannotExecuteEarly(uint256 wait) public {
        wait = bound(wait, 0, DELAY - 1);
        bytes32 id = _queue(abi.encodeCall(Target.set, (1)), 0);
        skip(wait);
        vm.prank(admin);
        vm.expectRevert();
        timelock.execute(id);
    }
}
