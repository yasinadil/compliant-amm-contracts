// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IFixedApyStaking
 * @notice Interface for Asset Global fixed APY staking contract (v2 - client clarifications)
 */
interface IFixedApyStaking {
    event MinStakeAmountUpdated(uint256 oldMin, uint256 newMin);

    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function claim() external;
    function emergencyWithdraw() external;

    function stakeFor(address user, uint256 amount) external;
    function unstakeFor(address user, uint256 amount) external;
    function claimFor(address user) external;
    function emergencyWithdrawFor(address user) external;

    function fundRewardBucket(uint256 amount) external;
    function withdrawUnallocatedRewards(address to) external;

    function setApyBps(uint256 newApyBps) external;
    function setRewardBucket(uint256 newBucket) external;
    function setLockDuration(uint256 newDuration) external;
    function setDepositsEnabled(bool enabled) external;

    function getCapacityInfo()
        external
        view
        returns (uint256 maxCapacity, uint256 totalStaked, uint256 availableCapacity, uint256 utilizationBps);

    function getRewardInfo()
        external
        view
        returns (uint256 rewardBucket, uint256 cumulativeDistributed, uint256 remainingBudget, uint256 currentApyBps);

    function getEpochInfo()
        external
        view
        returns (uint256 epochStart, uint256 epochEmissions, uint256 monthlyEmissionCap, uint256 nextEpochTimestamp);

    function getUserInfo(address user)
        external
        view
        returns (uint256 staked, uint256 pending, uint256 lockUntil, uint256 claimedLifetime);

    function pendingRewards(address user) external view returns (uint256);

    function assetToken() external view returns (IERC20);
    function rewardBucket() external view returns (uint256);
    function maxStakePerUser() external view returns (uint256);
    function apyBps() external view returns (uint256);
    function depositsEnabled() external view returns (bool);
    function maxStakeCapacity() external view returns (uint256);
    function totalStaked() external view returns (uint256);
}
