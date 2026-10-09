// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PermissionedAMM} from "../src/PermissionedAMM.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract AmmHandler is Test {
    PermissionedAMM internal amm;
    MockERC20 internal asset;
    MockERC20 internal stable;
    address internal treasury;
    address internal operator;
    address[] internal users;

    uint256 public kDecreases; // ghost: swaps that lowered k (must stay 0)
    uint256 public successfulSwaps;

    constructor(
        PermissionedAMM _amm,
        MockERC20 _asset,
        MockERC20 _stable,
        ComplianceRegistry registry,
        address admin,
        address _treasury,
        address _operator
    ) {
        amm = _amm;
        asset = _asset;
        stable = _stable;
        treasury = _treasury;
        operator = _operator;
        for (uint256 i; i < 3; i++) {
            address u = makeAddr(string(abi.encodePacked("trader", vm.toString(i))));
            asset.mint(u, 10_000_000e18);
            stable.mint(u, 10_000_000e18);
            vm.startPrank(u);
            asset.approve(address(amm), type(uint256).max);
            stable.approve(address(amm), type(uint256).max);
            vm.stopPrank();
            vm.prank(admin);
            registry.setComplianceTier(u, 3);
            users.push(u);
        }
        asset.mint(operator, 10_000_000e18);
        stable.mint(operator, 10_000_000e18);
        vm.startPrank(operator);
        asset.approve(address(amm), type(uint256).max);
        stable.approve(address(amm), type(uint256).max);
        vm.stopPrank();
    }

    function _k() internal view returns (uint256) {
        return amm.getK();
    }

    function swap(uint256 seed, bool assetIn, uint256 amount) external {
        (uint256 rA, uint256 rS) = amm.getReserves();
        amount = bound(amount, 1e12, (assetIn ? rA : rS) / 50);
        uint256 kBefore = _k();
        vm.prank(users[seed % users.length]);
        try amm.swap(assetIn, amount, 0) {
            successfulSwaps++;
            if (_k() < kBefore) kDecreases++;
        } catch {}
    }

    function swapOnBehalf(uint256 seed, bool assetIn, uint256 amount) external {
        (uint256 rA, uint256 rS) = amm.getReserves();
        amount = bound(amount, 1e12, (assetIn ? rA : rS) / 50);
        uint256 kBefore = _k();
        vm.prank(operator);
        try amm.swapOnBehalf(users[seed % users.length], assetIn, amount, 0) {
            successfulSwaps++;
            if (_k() < kBefore) kDecreases++;
        } catch {}
    }

    function collectFees() external {
        vm.prank(treasury);
        amm.collectFees(treasury);
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 2 days));
    }
}

contract PermissionedAMMInvariantTest is StdInvariant, Test {
    PermissionedAMM internal amm;
    MockERC20 internal asset;
    MockERC20 internal stable;
    AmmHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal operator = makeAddr("operator");

    function setUp() public {
        vm.startPrank(admin);
        asset = new MockERC20("Asset", "AST", 18);
        stable = new MockERC20("Stable", "USDX", 18);
        ImpactPolicy policy = new ImpactPolicy(admin);
        ComplianceRegistry registry = new ComplianceRegistry(admin);
        amm = new PermissionedAMM(
            address(asset), address(stable), address(policy), address(registry), admin, treasury, address(0)
        );
        amm.grantRole(amm.OPERATOR_ROLE(), operator);
        registry.grantRole(registry.SWAP_VOLUME_RECORDER_ROLE(), address(amm));

        asset.mint(admin, 1_000_000e18);
        stable.mint(admin, 2_000_000e18);
        asset.approve(address(amm), type(uint256).max);
        stable.approve(address(amm), type(uint256).max);
        amm.initialize(1_000_000e18, 2_000_000e18);
        amm.activate();
        amm.setDirectSwapEnabled(true);
        vm.stopPrank();

        handler = new AmmHandler(amm, asset, stable, registry, admin, treasury, operator);
        targetContract(address(handler));
    }

    function afterInvariant() public view {
        assertGt(handler.successfulSwaps(), 0, "handler must exercise real swaps");
    }

    /// Book reserves always equal the tokens actually held (fees are part of reserves until collected).
    function invariant_reservesMatchBalances() public view {
        (uint256 rA, uint256 rS) = amm.getReserves();
        assertEq(asset.balanceOf(address(amm)), rA);
        assertEq(stable.balanceOf(address(amm)), rS);
    }

    /// The constant product never decreases on a swap.
    function invariant_swapsNeverDecreaseK() public view {
        assertEq(handler.kDecreases(), 0);
    }

    /// Accrued fees are always covered by reserves, and reserves never drop below the floor.
    function invariant_feesCoveredAndFloorKept() public view {
        (uint256 rA, uint256 rS) = amm.getReserves();
        assertLe(amm.accumulatedFeesAsset(), rA);
        assertLe(amm.accumulatedFeesStable(), rS);
        assertGe(rA, amm.MINIMUM_LIQUIDITY());
        assertGe(rS, amm.MINIMUM_LIQUIDITY());
    }
}
