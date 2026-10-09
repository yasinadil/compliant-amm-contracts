# Operations and trust model

This document describes how privileged roles, custodial flows, and user-facing toggles interact so support, engineering, and compliance share the same expectations.

## Roles (high level)

| System | Role | Typical holder | What it can do |
|--------|------|----------------|----------------|
| PermissionedAMM | `ADMIN_ROLE` | Multisig | Parameters, pause, `directSwapEnabled`, registry pointer, deprecate |
| PermissionedAMM | `DEFAULT_ADMIN_ROLE` | Multisig | AccessControl administration; `emergencyWithdraw` when deprecated |
| PermissionedAMM | `TREASURY_ROLE` | Treasury | `collectFees` (cannot swap) |
| PermissionedAMM | `OPERATOR_ROLE` | Backend / custodial | `swapOnBehalf`; **not** subject to on-chain daily volume limits when calling `swap()` as themselves |
| PermissionedAMM | `TIMELOCK_ROLE` | Timelock | `addLiquidity`, `removeLiquidity`, `rebalance` |
| ComplianceRegistry | `DEFAULT_ADMIN_ROLE` | Multisig | `setTierDailyLimit`; grant/revoke roles |
| ComplianceRegistry | `COMPLIANCE_OFFICER_ROLE` | Compliance tooling | Set / batch-set user tiers |
| ComplianceRegistry | `SWAP_VOLUME_RECORDER_ROLE` | PermissionedAMM only | Increment per-user daily swap volume (direct `swap()` path) |
| FixedApyStaking | `ADMIN_ROLE` | Multisig | Pause, locks, deposits, `directActionsEnabled` |
| FixedApyStaking | `OPERATOR_ROLE` | Backend | `stakeFor`, `unstakeFor`, `claimFor`, `emergencyWithdrawFor` |

## PermissionedAMM: direct swap vs operator swap

### `swap()` (user wallet)

- Gated by `directSwapEnabled` (default off).
- Subject to `ComplianceRegistry.isCompliant(user)` when a registry is configured and the caller is **not** an operator.
- Subject to **on-chain daily USD volume limits** per user tier for that same path. Volume is recorded via `ComplianceRegistry.recordDailyVolume` (vault holds `SWAP_VOLUME_RECORDER_ROLE`).
- Tier caps are **admin-configurable** on the registry (`setTierDailyLimit`).

### `swapOnBehalf(user, …)` (custodial)

- **Tokens:** operator → vault → operator. The `user` argument is for **events / attribution only**; it does not receive tokens on-chain.
- **Limits:** daily tier limits are **not** updated on-chain for `user`. Custodial volume and tier policy are enforced **off-chain** (e.g. API, compliance workflow).
- On-chain compliance checks and volume recording are **skipped** for this path (operator is trusted).

## FixedApyStaking: `directActionsEnabled`

When **`directActionsEnabled` is false** (default):

- Users **cannot** call `stake`, `unstake`, `claim`, or `emergencyWithdraw` on their own.
- Operators **can** still use `stakeFor`, `unstakeFor`, `claimFor`, `emergencyWithdrawFor` (tokens move to/from the operator wallet per function design).

When **`true`:**

- Users can use the four direct functions subject to pause, locks, caps, and funding.

**Operational expectation:** If direct actions are disabled, document an **SLA** for operator-assisted exits and how users request them.

## User exit paths (summary)

| Goal | Self-serve | If blocked |
|------|------------|------------|
| Swap in vault | `swap()` (if enabled + compliant + under daily limit) | App routes via `swapOnBehalf` (custodial) |
| Stake / unstake / claim | Direct functions if `directActionsEnabled` | Operator `*For` functions |
| Emergency exit staking | `emergencyWithdraw` if enabled | `emergencyWithdrawFor` |

## Incident response (outline)

1. **Suspected operator key compromise:** Rotate keys; revoke `OPERATOR_ROLE` on affected addresses; pause vault/staking if needed; communicate scope (custodial flows only vs direct users).
2. **Suspected admin compromise:** Rely on multisig / timelock design; freeze frontends; assess registry and policy addresses.
3. **Users cannot claim rewards:** Check `rewardBucket`, funding, `MonthlyCapExceeded`, and contract Asset balance; treasury may need to `fundRewardBucket` or timelock adjust parameters.

## Integrator notes

- PermissionedAMM **`phase`** and OpenZeppelin **`Pausable`:** `pause()` does not set `phase` storage to `PAUSED`; swaps are blocked by `whenNotPaused`. Do not rely on `phase` alone for “paused” state.
- **Daily limits** apply to **direct `swap()`** volume only, not to `swapOnBehalf` attributed volume.

## Contact

Use your internal security / compliance channels for key rotation and customer comms. Contract security contact (if published): see `@custom:security-contact` in source headers.
