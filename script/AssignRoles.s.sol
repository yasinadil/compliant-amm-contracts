// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console2} from "forge-std/Script.sol";
import {Timelock} from "../src/Timelock.sol";
import {PermissionedAMM} from "../src/PermissionedAMM.sol";
import {ImpactPolicy} from "../src/ImpactPolicy.sol";

/**
 * @title AssignRoles
 * @notice Grants/assigns operational authority over the Asset system to wallet(s) of your choice.
 *
 * It performs up to three independent, env-gated actions (run any subset by only setting
 * the env vars for the parts you want):
 *
 *   1. Timelock roles      -> grants DEFAULT_ADMIN_ROLE, PROPOSER_ROLE, EXECUTOR_ROLE,
 *                             CANCELLER_ROLE on the `Timelock` contract to TIMELOCK_ADMIN_WALLET.
 *   2. ImpactPolicy bps    -> transfers ownership of `ImpactPolicy` (Ownable2Step) to
 *                             IMPACT_POLICY_WALLET. This is the only way to grant the ability
 *                             to raise slippage/bps limits (setSlippageLimits / setTierThresholds).
 *                             NOTE: two-step. The recipient must then run AcceptImpactPolicyOwnership.
 *   3. PermissionedAMM liquidity    -> grants TIMELOCK_ROLE on `PermissionedAMM` to VAULT_LIQUIDITY_WALLET, enabling
 *                             addLiquidity / removeLiquidity / rebalance (add/remove/inc/dec liquidity).
 *
 * The broadcasting key MUST currently hold the relevant authority:
 *   - DEFAULT_ADMIN_ROLE on the Timelock   (for action 1)
 *   - owner() of the ImpactPolicy          (for action 2)
 *   - DEFAULT_ADMIN_ROLE on the PermissionedAMM    (for action 3)
 * Unauthorized calls will revert with the standard AccessControl / Ownable error.
 *
 * Usage:
 *   forge script script/AssignRoles.s.sol:AssignRoles \
 *     --rpc-url $BASE_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Env vars (set only what you need; unset sections are skipped):
 *   Contract addresses:
 *     - TIMELOCK               : Timelock contract address           (action 1)
 *     - IMPACT_POLICY          : ImpactPolicy contract address       (action 2)
 *     - AMM               : PermissionedAMM contract address            (action 3)
 *   Recipient wallets:
 *     - TIMELOCK_ADMIN_WALLET  : receives the 4 Timelock roles       (action 1)
 *     - IMPACT_POLICY_WALLET   : becomes ImpactPolicy pending owner   (action 2)
 *     - VAULT_LIQUIDITY_WALLET : receives PermissionedAMM TIMELOCK_ROLE       (action 3)
 *
 * This script only grants/assigns; it never revokes authority from existing holders.
 */
contract AssignRoles is Script {
    function run() external {
        // Contract addresses
        address timelockAddr = vm.envOr("TIMELOCK", address(0));
        address impactPolicyAddr = vm.envOr("IMPACT_POLICY", address(0));
        address vaultAddr = vm.envOr("AMM", address(0));

        // Recipient wallets
        address timelockAdminWallet = vm.envOr("TIMELOCK_ADMIN_WALLET", address(0));
        address impactPolicyWallet = vm.envOr("IMPACT_POLICY_WALLET", address(0));
        address vaultLiquidityWallet = vm.envOr("VAULT_LIQUIDITY_WALLET", address(0));

        console2.log("=== AssignRoles ===");

        vm.startBroadcast();

        // 1. Timelock roles
        if (timelockAddr != address(0) && timelockAdminWallet != address(0)) {
            _grantTimelockRoles(Timelock(payable(timelockAddr)), timelockAdminWallet);
        } else {
            console2.log("[skip] Timelock roles (set TIMELOCK and TIMELOCK_ADMIN_WALLET to enable)");
        }

        // 2. ImpactPolicy ownership (bps control)
        // if (impactPolicyAddr != address(0) && impactPolicyWallet != address(0)) {
        //     _transferImpactPolicyOwnership(ImpactPolicy(impactPolicyAddr), impactPolicyWallet);
        // } else {
        //     console2.log("[skip] ImpactPolicy ownership (set IMPACT_POLICY and IMPACT_POLICY_WALLET to enable)");
        // }

        // 3. PermissionedAMM liquidity role
        if (vaultAddr != address(0) && vaultLiquidityWallet != address(0)) {
            _grantVaultLiquidityRole(PermissionedAMM(vaultAddr), vaultLiquidityWallet);
        } else {
            console2.log("[skip] PermissionedAMM liquidity role (set AMM and VAULT_LIQUIDITY_WALLET to enable)");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Done ===");
        if (impactPolicyAddr != address(0) && impactPolicyWallet != address(0)) {
            console2.log("ACTION REQUIRED: ImpactPolicy is Ownable2Step.");
            console2.log("  The recipient wallet must accept ownership by running:");
            console2.log("  IMPACT_POLICY=<addr> forge script script/AssignRoles.s.sol:AcceptImpactPolicyOwnership \\");
            console2.log("    --rpc-url <rpc> --private-key <recipient_key> --broadcast");
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ACTION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _grantTimelockRoles(Timelock timelock, address wallet) internal {
        console2.log("-- Timelock roles ->", wallet);

        timelock.grantRole(timelock.DEFAULT_ADMIN_ROLE(), wallet);
        timelock.grantRole(timelock.PROPOSER_ROLE(), wallet);
        timelock.grantRole(timelock.EXECUTOR_ROLE(), wallet);
        timelock.grantRole(timelock.CANCELLER_ROLE(), wallet);
        console2.log("   granted DEFAULT_ADMIN_ROLE, PROPOSER_ROLE, EXECUTOR_ROLE, CANCELLER_ROLE");
    }

    // function _transferImpactPolicyOwnership(ImpactPolicy policy, address wallet) internal {
    //     console2.log("-- ImpactPolicy ownership ->", wallet);
    //     console2.log("   current owner:", policy.owner());
    //     policy.transferOwnership(wallet);
    //     console2.log("   pending owner set to:", policy.pendingOwner());
    //     console2.log("   (recipient must call acceptOwnership to finalize)");
    // }

    function _grantVaultLiquidityRole(PermissionedAMM vault, address wallet) internal {
        console2.log("-- PermissionedAMM liquidity (TIMELOCK_ROLE) ->", wallet);

        vault.grantRole(vault.TIMELOCK_ROLE(), wallet);
        console2.log("   granted TIMELOCK_ROLE (addLiquidity / removeLiquidity / rebalance)");
    }
}

/**
 * @title AcceptImpactPolicyOwnership
 * @notice Companion script for the RECIPIENT wallet to finalize the ImpactPolicy ownership transfer.
 *         Must be broadcast with the recipient wallet's key (the pending owner set by AssignRoles).
 *
 * Usage:
 *   IMPACT_POLICY=<addr> forge script script/AssignRoles.s.sol:AcceptImpactPolicyOwnership \
 *     --rpc-url $BASE_RPC_URL --private-key $RECIPIENT_PRIVATE_KEY --broadcast
 */
// contract AcceptImpactPolicyOwnership is Script {
//     function run() external {
//         address impactPolicyAddr = vm.envAddress("IMPACT_POLICY");
//         ImpactPolicy policy = ImpactPolicy(impactPolicyAddr);

//         console2.log("=== AcceptImpactPolicyOwnership ===");
//         console2.log("ImpactPolicy:", impactPolicyAddr);
//         console2.log("Pending owner (must match your key):", policy.pendingOwner());

//         vm.startBroadcast();
//         policy.acceptOwnership();
//         vm.stopBroadcast();

//         console2.log("New owner:", policy.owner());
//     }
// }
