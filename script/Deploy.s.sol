// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {PermissionedAMM} from "../src/PermissionedAMM.sol";
import {FixedApyStaking} from "../src/FixedApyStaking.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";
import {Timelock} from "../src/Timelock.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

/**
 * @title Deploy
 * @notice Deployment script for PermissionedAMM presale system on Base
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *     --rpc-url $BASE_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Required Environment Variables:
 *   - ASSET_TOKEN: Address of the Asset token
 *   - STABLE_TOKEN: Address of the Stable stablecoin
 *   - ADMIN: Admin address
 *   - TREASURY: Treasury address
 *   - TIMELOCK_DELAY: Timelock delay in seconds (default 24 hours)
 */
contract Deploy is Script {
    function run() external {
        // Load configuration from environment
        address assetToken = vm.envAddress("ASSET_TOKEN");
        address stableToken = vm.envAddress("STABLE_TOKEN");
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(24 hours));

        console2.log("=== PermissionedAMM Deployment ===");
        console2.log("Asset Token:", assetToken);
        console2.log("Stable Token:", stableToken);
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);
        console2.log("Timelock Delay:", timelockDelay);

        vm.startBroadcast();

        // 1. Deploy ImpactPolicy
        ImpactPolicy impactPolicy = new ImpactPolicy(admin);
        console2.log("ImpactPolicy deployed:", address(impactPolicy));

        // 2. Deploy ComplianceRegistry
        ComplianceRegistry complianceRegistry = new ComplianceRegistry(admin);
        console2.log("ComplianceRegistry deployed:", address(complianceRegistry));

        // 3. Deploy Timelock
        Timelock timelock = new Timelock(admin, timelockDelay);
        console2.log("Timelock deployed:", address(timelock));

        // 4. Deploy PermissionedAMM
        PermissionedAMM vault = new PermissionedAMM(
            assetToken,
            stableToken,
            address(impactPolicy),
            address(complianceRegistry),
            admin,
            treasury,
            address(timelock)
        );
        console2.log("PermissionedAMM deployed:", address(vault));

        // 5. Allow vault to record direct-swap daily volume (not COMPLIANCE_OFFICER)
        complianceRegistry.grantRole(complianceRegistry.SWAP_VOLUME_RECORDER_ROLE(), address(vault));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Approve Asset and Stable tokens for vault");
        console2.log("2. Call vault.initialize(assetAmount, stableAmount)");
        console2.log("3. Call vault.activate() to start trading");
        console2.log("4. Add operators via vault.grantRole(OPERATOR_ROLE, operatorAddress)");
        console2.log("5. Set user compliance via complianceRegistry.setComplianceTier(user, tier)");
    }
}

/**
 * @title DeployLocal
 * @notice Local deployment script with mock tokens for testing
 */
contract DeployLocal is Script {
    function run() external {
        address admin = vm.addr(1);
        address treasury = vm.addr(2);

        console2.log("=== Local PermissionedAMM Deployment ===");
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);

        vm.startBroadcast(admin);

        // Deploy mock tokens for local testing
        // In production, use real token addresses

        // Deploy supporting contracts
        ImpactPolicy impactPolicy = new ImpactPolicy(admin);
        console2.log("ImpactPolicy:", address(impactPolicy));

        ComplianceRegistry complianceRegistry = new ComplianceRegistry(admin);
        console2.log("ComplianceRegistry:", address(complianceRegistry));

        Timelock timelock = new Timelock(admin, 24 hours);
        console2.log("Timelock:", address(timelock));

        // Note: Asset and Stable token addresses would be provided
        // For local testing, deploy MockERC20 tokens first

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Supporting Contracts Deployed ===");
        console2.log("Deploy PermissionedAMM with these addresses after deploying tokens");
    }
}

/**
 * @title DeployFixedApyStaking
 * @notice Deployment script for FixedApyStaking fixed APY staking system (v2 client clarifications)
 *
 * Usage:
 *   forge script script/Deploy.s.sol:DeployFixedApyStaking \
 *     --rpc-url $BASE_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 *
 * Required Environment Variables:
 *   - ASSET_TOKEN: Address of the Asset token
 *   - ADMIN: Admin address
 *   - TREASURY: Treasury address
 *   - REWARD_BUCKET: Annual reward budget (e.g. 42000000000000000000000000 for 42M)
 *   - APY_BPS: APY in basis points (e.g. 2000 for 20%)
 *   - MAX_STAKE_PER_USER: Per-user stake cap
 *
 * Optional:
 *   - MIN_LOCK_DURATION: Lock duration in seconds (default 0)
 *   - MIN_STAKE_AMOUNT: Minimum stake (default 100e18)
 */
contract DeployFixedApyStaking is Script {
    function run() external {
        address assetToken = vm.envAddress("ASSET_TOKEN");
        address admin = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");
        uint256 rewardBucket = vm.envUint("REWARD_BUCKET");
        uint256 maxStakePerUser = vm.envUint("MAX_STAKE_PER_USER");
        uint256 apyBps = vm.envUint("APY_BPS");
        uint256 minLockDuration = vm.envOr("MIN_LOCK_DURATION", uint256(0));
        uint256 minStakeAmount = vm.envOr("MIN_STAKE_AMOUNT", uint256(5e18));

        console2.log("=== FixedApyStaking Deployment ===");
        console2.log("Asset Token:", assetToken);
        console2.log("Admin:", admin);
        console2.log("Treasury:", treasury);
        console2.log("Reward Bucket:", rewardBucket);
        console2.log("Max Stake Per User:", maxStakePerUser);
        console2.log("APY (bps):", apyBps);

        vm.startBroadcast();

        FixedApyStaking staking = new FixedApyStaking(assetToken, admin, treasury, maxStakePerUser);
        console2.log("FixedApyStaking deployed:", address(staking));

        staking.initialize(rewardBucket, apyBps, minLockDuration, minStakeAmount);
        console2.log("FixedApyStaking initialized");

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Max Stake Capacity:", staking.maxStakeCapacity());
        console2.log("Monthly Emission Cap:", staking.monthlyEmissionCap());
        console2.log("");
        console2.log("Next Steps:");
        console2.log("1. Treasury: fund reward bucket via staking.fundRewardBucket(amount)");
        console2.log("2. If allowing user-direct stake/claim/unstake: staking.setDirectActionsEnabled(true)");
    }
}

/**
 * @title DeployFixedApyStakingLocal
 * @notice Local deployment with mock tokens for testing
 */
contract DeployFixedApyStakingLocal is Script {
    function run() external {
        address admin = vm.addr(1);
        address treasury = vm.addr(2);

        uint256 rewardBucket = 42_000_000e18;
        uint256 maxStakePerUser = 200_000_000e18;
        uint256 apyBps = 2000;

        console2.log("=== Local FixedApyStaking Deployment ===");

        vm.startBroadcast();

        MockERC20 assetToken = new MockERC20("Asset Global", "Asset", 18);
        assetToken.mint(treasury, rewardBucket * 2);

        FixedApyStaking staking = new FixedApyStaking(address(assetToken), admin, treasury, maxStakePerUser);

        staking.initialize(rewardBucket, apyBps, 0, 100e18);
        staking.setDirectActionsEnabled(true);

        assetToken.approve(address(staking), rewardBucket);
        staking.fundRewardBucket(rewardBucket);

        vm.stopBroadcast();

        console2.log("FixedApyStaking:", address(staking));
        console2.log("Asset Token:", address(assetToken));
        console2.log("Max Capacity:", staking.maxStakeCapacity());
    }
}

