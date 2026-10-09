// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";

contract ComplianceRegistryTest is Test {
    ComplianceRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal recorder = makeAddr("recorder");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_700_000_000);
        registry = new ComplianceRegistry(admin);
        vm.startPrank(admin);
        registry.grantRole(registry.SWAP_VOLUME_RECORDER_ROLE(), recorder);
        vm.stopPrank();
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__ZeroAddress.selector);
        new ComplianceRegistry(address(0));
    }

    function test_defaultTierLimits() public view {
        assertEq(registry.getTierDailyLimit(1), 10_000e18);
        assertEq(registry.getTierDailyLimit(2), 100_000e18);
        assertEq(registry.getTierDailyLimit(3), 1_000_000e18);
    }

    function test_setTierAndLimits() public {
        vm.prank(admin);
        registry.setComplianceTier(alice, 2);
        assertTrue(registry.isCompliant(alice));
        assertEq(registry.getComplianceTier(alice), 2);
        assertEq(registry.getDailyLimit(alice), 100_000e18);
        assertEq(registry.getRemainingDailyLimit(alice), 100_000e18);

        assertFalse(registry.isCompliant(bob));
        assertEq(registry.getDailyLimit(bob), 0);
    }

    function test_invalidTierInputsRevert() public {
        vm.startPrank(admin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__InvalidTier.selector);
        registry.setComplianceTier(alice, 4);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__ZeroAddress.selector);
        registry.setComplianceTier(address(0), 1);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__InvalidTier.selector);
        registry.setTierDailyLimit(0, 1);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__InvalidTier.selector);
        registry.setTierDailyLimit(4, 1);
        vm.stopPrank();
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__InvalidTier.selector);
        registry.getTierDailyLimit(0);
    }

    function test_batchSet() public {
        address[] memory accounts = new address[](2);
        uint8[] memory tiers = new uint8[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        tiers[0] = 1;
        tiers[1] = 3;
        vm.prank(admin);
        registry.batchSetComplianceTier(accounts, tiers);
        assertEq(registry.getComplianceTier(alice), 1);
        assertEq(registry.getComplianceTier(bob), 3);
    }

    function test_batchSet_validatesInput() public {
        address[] memory accounts = new address[](2);
        uint8[] memory tiers = new uint8[](1);
        vm.startPrank(admin);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__LengthMismatch.selector);
        registry.batchSetComplianceTier(accounts, tiers);

        tiers = new uint8[](2);
        accounts[0] = alice; // accounts[1] stays address(0)
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__ZeroAddress.selector);
        registry.batchSetComplianceTier(accounts, tiers);

        accounts[1] = bob;
        tiers[1] = 9;
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__InvalidTier.selector);
        registry.batchSetComplianceTier(accounts, tiers);
        vm.stopPrank();
    }

    function test_recordDailyVolume_enforcesLimitAndResetsDaily() public {
        vm.prank(admin);
        registry.setComplianceTier(alice, 1); // 10k / day

        vm.startPrank(recorder);
        assertTrue(registry.recordDailyVolume(alice, 6_000e18));
        assertTrue(registry.recordDailyVolume(alice, 4_000e18));
        assertFalse(registry.recordDailyVolume(alice, 1), "over the limit");
        vm.stopPrank();
        assertEq(registry.getRemainingDailyLimit(alice), 0);

        skip(1 days);
        assertEq(registry.getRemainingDailyLimit(alice), 10_000e18, "view resets on new day");
        vm.prank(recorder);
        assertTrue(registry.recordDailyVolume(alice, 10_000e18));
    }

    function test_nonCompliantHasNoAllowance() public {
        vm.prank(recorder);
        assertFalse(registry.recordDailyVolume(bob, 1));
    }

    function test_recordDailyVolume_rolesAndZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.recordDailyVolume(alice, 1);

        vm.prank(recorder);
        vm.expectRevert(ComplianceRegistry.ComplianceRegistry__ZeroAddress.selector);
        registry.recordDailyVolume(address(0), 1);
    }

    function test_adminUpdatesTierLimit() public {
        vm.startPrank(admin);
        registry.setComplianceTier(alice, 1);
        registry.setTierDailyLimit(1, 0);
        vm.stopPrank();
        vm.prank(recorder);
        assertFalse(registry.recordDailyVolume(alice, 1), "limit 0 blocks swaps on-chain");
    }

    function test_onlyOfficerSetsTiers() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.setComplianceTier(alice, 3);
    }

    /// Volume within a UTC day never exceeds the tier limit, whatever the sequence.
    function testFuzz_dailyVolumeNeverExceedsLimit(uint256[8] memory amounts, uint8 tier) public {
        tier = uint8(bound(tier, 1, 3));
        vm.prank(admin);
        registry.setComplianceTier(alice, tier);
        uint256 limit = registry.getDailyLimit(alice);

        vm.startPrank(recorder);
        for (uint256 i; i < amounts.length; i++) {
            registry.recordDailyVolume(alice, bound(amounts[i], 0, limit));
            assertLe(registry.dailyVolumeUsed(alice), limit);
        }
        vm.stopPrank();
    }
}
