// SPDX-License-Identifier: MIT
// Pre-fix copy (floored aggregate accrual), kept only so tests can demonstrate the rounding bug.
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IFixedApyStaking} from "../../src/interfaces/IFixedApyStaking.sol";

/**
 * @title FixedApyStaking
 * @notice Capacity-controlled fixed APY staking (v2) with configurable annual reward bucket, no fees, no program times
 * @dev Tokenomics-controlled emission system. maxStakeCapacity = rewardBucket/APY. Reward bucket set annually.
 */
contract FixedApyStakingV1 is IFixedApyStaking, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                         HARD-CODED GUARDRAILS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant EPOCH_DURATION = 30 days;
    uint256 public constant PRECISION = 1e18;

    uint256 public constant MAX_APY_BPS = 5_000; // 50% hard ceiling
    uint256 public constant MAX_LOCK_DURATION = 365 days; // 1 year hard ceiling

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable assetToken;
    uint256 public immutable maxStakePerUser;

    /*//////////////////////////////////////////////////////////////
                         CONFIGURABLE PARAMS
    //////////////////////////////////////////////////////////////*/

    uint256 public rewardBucket; // annual budget, configurable
    uint256 public apyBps;
    uint256 public minLockDuration;
    uint256 public minStakeAmount;
    bool public depositsEnabled = true;
    bool public directActionsEnabled;

    /*//////////////////////////////////////////////////////////////
                         DERIVED
    //////////////////////////////////////////////////////////////*/

    uint256 public maxStakeCapacity;
    uint256 public monthlyEmissionCap;

    /*//////////////////////////////////////////////////////////////
                         GLOBAL ACCUMULATOR
    //////////////////////////////////////////////////////////////*/

    uint256 public rewardPerTokenStored;
    uint256 public lastUpdateTime;

    /*//////////////////////////////////////////////////////////////
                         AGGREGATE TRACKING
    //////////////////////////////////////////////////////////////*/

    uint256 public totalStaked;
    uint256 public cumulativeDistributed;
    uint256 public rewardsFunded;
    uint256 public totalAccruedUnpaid;

    /*//////////////////////////////////////////////////////////////
                         MONTHLY EPOCH TRACKING
    //////////////////////////////////////////////////////////////*/

    uint256 public currentEpochStart;
    uint256 public currentEpochEmissions;

    /*//////////////////////////////////////////////////////////////
                         PER-USER STATE
    //////////////////////////////////////////////////////////////*/

    struct StakeInfo {
        uint256 amount;
        uint256 rewardPerTokenPaid;
        uint256 accruedRewards;
        uint256 lockUntil; // per-user, non-retroactive
        uint256 claimedLifetime;
    }
    mapping(address => StakeInfo) public stakes;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Initialized(uint256 rewardBucket, uint256 apyBps, uint256 maxStakeCapacity, uint256 monthlyEmissionCap);
    event Staked(address indexed user, uint256 amount, uint256 lockUntil);
    event Withdrawn(address indexed user, uint256 amount, uint256 rewardsClaimed);
    event Claimed(address indexed user, uint256 reward);
    event EmergencyWithdrawn(address indexed user, uint256 principal);
    event StakedFor(address indexed user, address indexed operator, uint256 amount, uint256 lockUntil);
    event ParamsUpdated(string param, uint256 value);
    event RewardsFunded(address indexed funder, uint256 amount);
    event UnallocatedRewardsWithdrawn(address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error InsufficientBucket();
    error DepositsDisabled();
    error BelowMinimumStake();
    error CapacityFull();
    error UserCapExceeded();
    error InsufficientStake();
    error StillLocked();
    error InvalidAmount();
    error InsufficientFundedRewards();
    error ExceedsGuardrail();
    error NothingStaked();
    error DirectActionsDisabled();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _assetToken, address _admin, address _treasury, uint256 _maxStakePerUser) {
        if (_assetToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        assetToken = IERC20(_assetToken);
        maxStakePerUser = _maxStakePerUser;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _treasury);
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(uint256 _rewardBucket, uint256 _apyBps, uint256 _minLockDuration, uint256 _minStakeAmount)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (maxStakeCapacity != 0) revert AlreadyInitialized();
        if (_rewardBucket == 0) revert InvalidAmount();
        if (_apyBps == 0 || _apyBps > MAX_APY_BPS) revert ExceedsGuardrail();
        if (_minLockDuration > MAX_LOCK_DURATION) revert ExceedsGuardrail();

        rewardBucket = _rewardBucket;
        apyBps = _apyBps;
        minLockDuration = _minLockDuration;
        minStakeAmount = _minStakeAmount;

        _recalculateCapacity();

        lastUpdateTime = block.timestamp;
        currentEpochStart = block.timestamp;

        emit Initialized(_rewardBucket, _apyBps, maxStakeCapacity, monthlyEmissionCap);
    }

    /*//////////////////////////////////////////////////////////////
                         REWARD ACCUMULATOR
    //////////////////////////////////////////////////////////////*/

    function _updateReward(address account) internal {
        uint256 newRewardPerToken = _currentRewardPerToken();
        uint256 delta = newRewardPerToken - rewardPerTokenStored;

        if (totalStaked > 0 && delta > 0) {
            uint256 globalAccrual = (delta * totalStaked) / PRECISION;
            totalAccruedUnpaid += globalAccrual;
        }

        rewardPerTokenStored = newRewardPerToken;
        lastUpdateTime = _lastTimeRewardApplicable();

        if (account != address(0)) {
            StakeInfo storage info = stakes[account];
            uint256 pending = _pendingReward(info);
            info.accruedRewards += pending;
            info.rewardPerTokenPaid = rewardPerTokenStored;
        }
    }

    function _currentRewardPerToken() internal view returns (uint256) {
        uint256 elapsed = _rewardElapsed();
        return rewardPerTokenStored + (elapsed * apyBps * PRECISION) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    function _rewardElapsed() internal view returns (uint256) {
        return block.timestamp > lastUpdateTime ? block.timestamp - lastUpdateTime : 0;
    }

    function _lastTimeRewardApplicable() internal view returns (uint256) {
        return block.timestamp;
    }

    function _pendingReward(StakeInfo storage info) internal view returns (uint256) {
        uint256 rewardPerTokenDelta = _currentRewardPerToken() - info.rewardPerTokenPaid;
        return (info.amount * rewardPerTokenDelta) / PRECISION;
    }

    function _recalculateCapacity() internal {
        monthlyEmissionCap = rewardBucket / 12;
        maxStakeCapacity = (rewardBucket * BPS_DENOMINATOR) / apyBps;
    }

    /*//////////////////////////////////////////////////////////////
                         EPOCH ADVANCEMENT
    //////////////////////////////////////////////////////////////*/

    function _advanceEpochIfNeeded() internal {
        if (block.timestamp >= currentEpochStart + EPOCH_DURATION) {
            currentEpochStart = block.timestamp;
            currentEpochEmissions = 0;
        }
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /*//////////////////////////////////////////////////////////////
                         CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!directActionsEnabled) revert DirectActionsDisabled();
        if (maxStakeCapacity == 0) revert NotInitialized();
        if (!depositsEnabled) revert DepositsDisabled();
        if (amount < minStakeAmount) revert BelowMinimumStake();
        if (totalStaked + amount > maxStakeCapacity) revert CapacityFull();

        _updateReward(msg.sender);

        StakeInfo storage info = stakes[msg.sender];
        if (info.amount + amount > maxStakePerUser) revert UserCapExceeded();

        info.amount += amount;
        info.lockUntil = _max(info.lockUntil, block.timestamp + minLockDuration);
        totalStaked += amount;

        assetToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount, info.lockUntil);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (!directActionsEnabled) revert DirectActionsDisabled();
        StakeInfo storage info = stakes[msg.sender];
        if (info.amount < amount) revert InsufficientStake();
        if (block.timestamp < info.lockUntil) revert StillLocked();

        _updateReward(msg.sender);
        uint256 paidReward = _claimToRecipient(msg.sender, msg.sender);

        info.amount -= amount;
        totalStaked -= amount;

        if (info.amount == 0) {
            info.lockUntil = 0;
        }

        assetToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, paidReward);
    }

    function emergencyWithdraw() external nonReentrant {
        if (!directActionsEnabled) revert DirectActionsDisabled();
        StakeInfo storage info = stakes[msg.sender];
        uint256 principal = info.amount;
        if (principal == 0) revert NothingStaked();

        _updateReward(msg.sender);

        uint256 forfeited = info.accruedRewards;
        totalAccruedUnpaid -= forfeited;

        info.accruedRewards = 0;
        info.amount = 0;
        info.lockUntil = 0;
        totalStaked -= principal;

        assetToken.safeTransfer(msg.sender, principal);

        emit EmergencyWithdrawn(msg.sender, principal);
    }

    function claim() external nonReentrant whenNotPaused {
        if (!directActionsEnabled) revert DirectActionsDisabled();
        _updateReward(msg.sender);
        _claimToRecipient(msg.sender, msg.sender);
    }

    /// @dev Partial-claim: pays out up to the minimum of the bucket, monthly, and funding headroom.
    ///      Any remainder stays in the user's `accruedRewards` and can be claimed in later epochs.
    ///      Returns the amount actually transferred so callers (e.g. `unstake`) can report it.
    function _claimToRecipient(address account, address recipient) internal returns (uint256 paid) {
        uint256 reward = stakes[account].accruedRewards;
        if (reward == 0) return 0;

        _advanceEpochIfNeeded();

        uint256 bucketRoom = rewardBucket > cumulativeDistributed ? rewardBucket - cumulativeDistributed : 0;
        uint256 monthlyRoom =
            monthlyEmissionCap > currentEpochEmissions ? monthlyEmissionCap - currentEpochEmissions : 0;
        uint256 balance = assetToken.balanceOf(address(this));
        uint256 fundingRoom = balance > totalStaked ? balance - totalStaked : 0;

        paid = reward;
        if (paid > bucketRoom) paid = bucketRoom;
        if (paid > monthlyRoom) paid = monthlyRoom;
        if (paid > fundingRoom) paid = fundingRoom;

        if (paid == 0) return 0;

        stakes[account].accruedRewards = reward - paid;
        stakes[account].claimedLifetime += paid;
        totalAccruedUnpaid -= paid;
        cumulativeDistributed += paid;
        currentEpochEmissions += paid;

        assetToken.safeTransfer(recipient, paid);

        emit Claimed(account, paid);
    }

    /*//////////////////////////////////////////////////////////////
                         OPERATOR DELEGATION
    //////////////////////////////////////////////////////////////*/

    function stakeFor(address user, uint256 amount) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (maxStakeCapacity == 0) revert NotInitialized();
        if (!depositsEnabled) revert DepositsDisabled();
        if (amount < minStakeAmount) revert BelowMinimumStake();
        if (totalStaked + amount > maxStakeCapacity) revert CapacityFull();

        // Operator-delegated staking skips on-chain compliance;
        // KYC is enforced off-chain by the platform's identity service.

        _updateReward(user);

        StakeInfo storage info = stakes[user];
        if (info.amount + amount > maxStakePerUser) revert UserCapExceeded();

        info.amount += amount;
        info.lockUntil = _max(info.lockUntil, block.timestamp + minLockDuration);
        totalStaked += amount;

        assetToken.safeTransferFrom(msg.sender, address(this), amount);

        emit StakedFor(user, msg.sender, amount, info.lockUntil);
    }

    function unstakeFor(address user, uint256 amount) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        StakeInfo storage info = stakes[user];
        if (info.amount < amount) revert InsufficientStake();
        if (block.timestamp < info.lockUntil) revert StillLocked();

        _updateReward(user);
        uint256 paidReward = _claimToRecipient(user, msg.sender);

        info.amount -= amount;
        totalStaked -= amount;

        if (info.amount == 0) info.lockUntil = 0;

        assetToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(user, amount, paidReward);
    }

    function claimFor(address user) external nonReentrant whenNotPaused onlyRole(OPERATOR_ROLE) {
        _updateReward(user);
        _claimToRecipient(user, msg.sender);
    }

    function emergencyWithdrawFor(address user) external nonReentrant onlyRole(OPERATOR_ROLE) {
        StakeInfo storage info = stakes[user];
        uint256 principal = info.amount;
        if (principal == 0) revert NothingStaked();

        _updateReward(user);

        uint256 forfeited = info.accruedRewards;
        totalAccruedUnpaid -= forfeited;

        info.accruedRewards = 0;
        info.amount = 0;
        info.lockUntil = 0;
        totalStaked -= principal;

        assetToken.safeTransfer(msg.sender, principal);

        emit EmergencyWithdrawn(user, principal);
    }

    /*//////////////////////////////////////////////////////////////
                         TREASURY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function fundRewardBucket(uint256 amount) external onlyRole(TREASURY_ROLE) {
        if (amount == 0) revert InvalidAmount();
        assetToken.safeTransferFrom(msg.sender, address(this), amount);
        rewardsFunded += amount;
        emit RewardsFunded(msg.sender, amount);
    }

    function withdrawUnallocatedRewards(address to) external onlyRole(ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();

        _updateReward(address(0));

        uint256 allocated = cumulativeDistributed + totalAccruedUnpaid;
        uint256 withdrawable = rewardsFunded > allocated ? rewardsFunded - allocated : 0;

        if (withdrawable == 0) revert InsufficientFundedRewards();

        uint256 stakedBalance = totalStaked;
        uint256 contractBalance = assetToken.balanceOf(address(this));
        uint256 maxWithdraw = contractBalance > stakedBalance ? contractBalance - stakedBalance : 0;
        if (withdrawable > maxWithdraw) {
            withdrawable = maxWithdraw;
        }

        rewardsFunded -= withdrawable;
        assetToken.safeTransfer(to, withdrawable);

        emit UnallocatedRewardsWithdrawn(to, withdrawable);
    }

    /*//////////////////////////////////////////////////////////////
                         ADMIN PARAMETER SETTERS
    //////////////////////////////////////////////////////////////*/

    function setApyBps(uint256 newApyBps) external onlyRole(ADMIN_ROLE) {
        if (newApyBps == 0 || newApyBps > MAX_APY_BPS) revert ExceedsGuardrail();
        _updateReward(address(0));
        apyBps = newApyBps;
        _recalculateCapacity();
        emit ParamsUpdated("apyBps", newApyBps);
    }

    function setRewardBucket(uint256 newBucket) external onlyRole(ADMIN_ROLE) {
        _updateReward(address(0));
        uint256 minRequired = cumulativeDistributed + totalAccruedUnpaid;
        if (newBucket < minRequired) revert InsufficientBucket();
        rewardBucket = newBucket;
        _recalculateCapacity();
        emit ParamsUpdated("rewardBucket", newBucket);
    }

    function setLockDuration(uint256 newDuration) external onlyRole(ADMIN_ROLE) {
        if (newDuration > MAX_LOCK_DURATION) revert ExceedsGuardrail();
        minLockDuration = newDuration;
        emit ParamsUpdated("minLockDuration", newDuration);
    }

    function setMinStakeAmount(uint256 newMinStakeAmount) external onlyRole(ADMIN_ROLE) {
        uint256 oldMin = minStakeAmount;
        minStakeAmount = newMinStakeAmount;
        emit MinStakeAmountUpdated(oldMin, newMinStakeAmount);
    }

    function setDepositsEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        depositsEnabled = enabled;
        emit ParamsUpdated("depositsEnabled", enabled ? 1 : 0);
    }

    function setDirectActionsEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        directActionsEnabled = enabled;
        emit ParamsUpdated("directActionsEnabled", enabled ? 1 : 0);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                         DASHBOARD VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getCapacityInfo()
        external
        view
        returns (uint256 _maxCapacity, uint256 _totalStaked, uint256 _availableCapacity, uint256 _utilizationBps)
    {
        _maxCapacity = maxStakeCapacity;
        _totalStaked = totalStaked;
        _availableCapacity = maxStakeCapacity > totalStaked ? maxStakeCapacity - totalStaked : 0;
        _utilizationBps = maxStakeCapacity > 0 ? (totalStaked * BPS_DENOMINATOR) / maxStakeCapacity : 0;
    }

    function getRewardInfo()
        external
        view
        returns (
            uint256 _rewardBucket,
            uint256 _cumulativeDistributed,
            uint256 _remainingBudget,
            uint256 _currentApyBps
        )
    {
        _rewardBucket = rewardBucket;
        _cumulativeDistributed = cumulativeDistributed;
        _remainingBudget = rewardBucket > cumulativeDistributed ? rewardBucket - cumulativeDistributed : 0;
        _currentApyBps = apyBps;
    }

    function getEpochInfo()
        external
        view
        returns (uint256 _epochStart, uint256 _epochEmissions, uint256 _monthlyEmissionCap, uint256 _nextEpochTimestamp)
    {
        _epochStart = currentEpochStart;
        _epochEmissions = currentEpochEmissions;
        _monthlyEmissionCap = monthlyEmissionCap;
        _nextEpochTimestamp = currentEpochStart + EPOCH_DURATION;
    }

    function getUserInfo(address user)
        external
        view
        returns (uint256 staked, uint256 pending, uint256 lockUntil, uint256 claimedLifetime)
    {
        StakeInfo storage info = stakes[user];
        staked = info.amount;
        pending = info.accruedRewards + _pendingReward(info);
        lockUntil = info.lockUntil;
        claimedLifetime = info.claimedLifetime;
    }

    function pendingRewards(address user) external view returns (uint256) {
        StakeInfo storage info = stakes[user];
        return info.accruedRewards + _pendingReward(info);
    }
}
