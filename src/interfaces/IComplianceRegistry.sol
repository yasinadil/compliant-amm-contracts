// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IComplianceRegistry
 * @notice Interface for the compliance registry that tracks KYC/AML status
 */
interface IComplianceRegistry {
    /// @notice Checks if an address is compliant (KYC verified)
    /// @param account The address to check
    /// @return True if the account is compliant
    function isCompliant(address account) external view returns (bool);

    /// @notice Gets the compliance tier for an address (for tiered limits)
    /// @param account The address to check
    /// @return tier The compliance tier (0 = not compliant, 1+ = compliant tiers)
    function getComplianceTier(address account) external view returns (uint8 tier);

    /// @notice Gets the daily limit for an account based on their tier
    /// @param account The address to check
    /// @return limit The daily swap limit in USD (18 decimals)
    function getDailyLimit(address account) external view returns (uint256 limit);

    /// @notice Records swap volume against an account's daily limit
    /// @dev Restricted to the swap-volume recorder role in the implementation
    /// @param account The account to attribute volume to
    /// @param amountUSD The amount in USD (18 decimals)
    /// @return success True if the volume was within the daily limit and recorded
    function recordDailyVolume(address account, uint256 amountUSD) external returns (bool success);

    /// @notice Gets the remaining daily limit for an account
    /// @param account The address to check
    /// @return remaining The remaining daily swap limit in USD (18 decimals)
    function getRemainingDailyLimit(address account) external view returns (uint256 remaining);
}

