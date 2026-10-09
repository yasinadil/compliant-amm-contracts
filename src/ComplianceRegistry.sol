// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";

/**
 * @title ComplianceRegistry
 * @notice Manages KYC/AML compliance status for users
 * @dev Allows permissioned operators to set compliance status after off-chain verification
 *
 * Compliance Tiers:
 * - Tier 0: Not compliant (cannot swap)
 * - Tier 1–3: Compliant tiers with per-tier daily limits (USD, 18 decimals), configurable by admin
 */
contract ComplianceRegistry is IComplianceRegistry, AccessControl {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Role for compliance officers who can update user status
    bytes32 public constant COMPLIANCE_OFFICER_ROLE = keccak256("COMPLIANCE_OFFICER_ROLE");

    /// @notice Role for contracts (PermissionedAMM) that record direct-swap volume only
    bytes32 public constant SWAP_VOLUME_RECORDER_ROLE = keccak256("SWAP_VOLUME_RECORDER_ROLE");

    /// @notice Default tier limits at deploy (admin may change via setTierDailyLimit)
    uint256 public constant DEFAULT_TIER_1_DAILY_LIMIT = 10_000e18;
    uint256 public constant DEFAULT_TIER_2_DAILY_LIMIT = 100_000e18;
    uint256 public constant DEFAULT_TIER_3_DAILY_LIMIT = 1_000_000e18;

    /// @notice Per-tier daily direct-swap limit in USD (18 decimals); tier key 1..3
    mapping(uint8 => uint256) private _tierDailyLimitUSD;

    /// @notice Mapping of address to compliance tier
    mapping(address => uint8) private _complianceTier;

    /// @notice Mapping of address to daily volume used
    mapping(address => uint256) public dailyVolumeUsed;

    /// @notice Mapping of address to last volume reset timestamp
    mapping(address => uint256) public lastVolumeReset;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user's compliance status is updated
    event ComplianceStatusUpdated(address indexed account, uint8 oldTier, uint8 newTier, address indexed updatedBy);

    /// @notice Emitted when daily volume is recorded
    event DailyVolumeRecorded(address indexed account, uint256 amount, uint256 totalToday);

    /// @notice Emitted when admin updates a tier's daily limit
    event TierDailyLimitUpdated(uint8 indexed tier, uint256 newLimitUSD, address indexed updatedBy);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ComplianceRegistry__InvalidTier();
    error ComplianceRegistry__ZeroAddress();
    error ComplianceRegistry__LengthMismatch();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) {
        if (admin == address(0)) revert ComplianceRegistry__ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_OFFICER_ROLE, admin);

        _tierDailyLimitUSD[1] = DEFAULT_TIER_1_DAILY_LIMIT;
        _tierDailyLimitUSD[2] = DEFAULT_TIER_2_DAILY_LIMIT;
        _tierDailyLimitUSD[3] = DEFAULT_TIER_3_DAILY_LIMIT;
    }

    /*//////////////////////////////////////////////////////////////
                     USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the USD daily limit for a compliance tier (1–3)
     * @param tier Tier index
     * @param limitUSD Limit in USD (18 decimals); use 0 to disallow swaps for that tier on-chain
     */
    function setTierDailyLimit(uint8 tier, uint256 limitUSD) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tier == 0 || tier > 3) revert ComplianceRegistry__InvalidTier();
        _tierDailyLimitUSD[tier] = limitUSD;
        emit TierDailyLimitUpdated(tier, limitUSD, msg.sender);
    }

    /**
     * @notice Returns the configured daily limit for a tier (1–3); tier 0 is invalid for this view
     */
    function getTierDailyLimit(uint8 tier) external view returns (uint256) {
        if (tier == 0 || tier > 3) revert ComplianceRegistry__InvalidTier();
        return _tierDailyLimitUSD[tier];
    }

    /**
     * @notice Sets the compliance tier for an account
     * @param account The account to update
     * @param tier The new compliance tier (0-3)
     */
    function setComplianceTier(address account, uint8 tier) external onlyRole(COMPLIANCE_OFFICER_ROLE) {
        if (account == address(0)) revert ComplianceRegistry__ZeroAddress();
        if (tier > 3) revert ComplianceRegistry__InvalidTier();

        uint8 oldTier = _complianceTier[account];
        _complianceTier[account] = tier;

        emit ComplianceStatusUpdated(account, oldTier, tier, msg.sender);
    }

    /**
     * @notice Batch update compliance tiers for multiple accounts
     * @param accounts Array of accounts to update
     * @param tiers Array of new tiers
     */
    function batchSetComplianceTier(address[] calldata accounts, uint8[] calldata tiers)
        external
        onlyRole(COMPLIANCE_OFFICER_ROLE)
    {
        if (accounts.length != tiers.length) revert ComplianceRegistry__LengthMismatch();

        for (uint256 i; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert ComplianceRegistry__ZeroAddress();
            if (tiers[i] > 3) revert ComplianceRegistry__InvalidTier();

            uint8 oldTier = _complianceTier[accounts[i]];
            _complianceTier[accounts[i]] = tiers[i];

            emit ComplianceStatusUpdated(accounts[i], oldTier, tiers[i], msg.sender);
        }
    }

    /**
     * @notice Records daily volume used by an account (PermissionedAMM direct swap path only)
     * @param account The account
     * @param amountUSD The amount in USD (18 decimals)
     * @return success True if within daily limit
     */
    function recordDailyVolume(address account, uint256 amountUSD)
        external
        onlyRole(SWAP_VOLUME_RECORDER_ROLE)
        returns (bool success)
    {
        if (account == address(0)) revert ComplianceRegistry__ZeroAddress();
        _resetDailyVolumeIfNeeded(account);

        uint256 limit = _getDailyLimit(account);
        uint256 newTotal = dailyVolumeUsed[account] + amountUSD;

        if (newTotal > limit) {
            return false;
        }

        dailyVolumeUsed[account] = newTotal;
        emit DailyVolumeRecorded(account, amountUSD, newTotal);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IComplianceRegistry
    function isCompliant(address account) external view override returns (bool) {
        return _complianceTier[account] > 0;
    }

    /// @inheritdoc IComplianceRegistry
    function getComplianceTier(address account) external view override returns (uint8 tier) {
        return _complianceTier[account];
    }

    /// @inheritdoc IComplianceRegistry
    function getDailyLimit(address account) external view override returns (uint256 limit) {
        return _getDailyLimit(account);
    }

    /// @inheritdoc IComplianceRegistry
    function getRemainingDailyLimit(address account) external view override returns (uint256 remaining) {
        uint256 limit = _getDailyLimit(account);
        uint256 used = _getDailyVolumeUsed(account);

        if (used >= limit) return 0;
        return limit - used;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getDailyLimit(address account) internal view returns (uint256 limit) {
        uint8 tier = _complianceTier[account];
        if (tier == 0) return 0;
        return _tierDailyLimitUSD[tier];
    }

    function _getDailyVolumeUsed(address account) internal view returns (uint256) {
        uint256 lastReset = lastVolumeReset[account];
        uint256 currentDay = block.timestamp / 1 days;
        uint256 lastResetDay = lastReset / 1 days;

        if (currentDay > lastResetDay) {
            return 0;
        }
        return dailyVolumeUsed[account];
    }

    function _resetDailyVolumeIfNeeded(address account) internal {
        uint256 lastReset = lastVolumeReset[account];
        uint256 currentDay = block.timestamp / 1 days;
        uint256 lastResetDay = lastReset / 1 days;

        if (currentDay > lastResetDay) {
            dailyVolumeUsed[account] = 0;
            lastVolumeReset[account] = block.timestamp;
        }
    }
}
