// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {FixedApyStaking} from "../src/FixedApyStaking.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract FixedApyStakingTest is Test {
    FixedApyStaking public staking;
    MockERC20 public assetToken;

    address public admin = makeAddr("admin");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public operator = makeAddr("operator");

    uint256 public constant REWARD_BUCKET = 42_000_000e18;
    uint256 public constant MAX_STAKE_PER_USER = 200_000_000e18;
    uint256 public constant APY_BPS = 2000; // 20%
    uint256 public constant MIN_STAKE = 100e18;
    uint256 public constant MIN_LOCK = 0; // No lock for basic tests

    function setUp() public {
        vm.startPrank(admin);

        assetToken = new MockERC20("Asset Global", "Asset", 18);

        staking = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);

        staking.initialize(REWARD_BUCKET, APY_BPS, MIN_LOCK, MIN_STAKE);
        staking.setDirectActionsEnabled(true);

        staking.grantRole(staking.OPERATOR_ROLE(), operator);

        assetToken.mint(treasury, REWARD_BUCKET * 2);
        assetToken.mint(user1, 200_000_000e18);
        assetToken.mint(user2, 200_000_000e18);
        assetToken.mint(operator, 200_000_000e18);

        baseTime = block.timestamp;
        vm.stopPrank();
    }

    uint256 internal baseTime;

    function _initAndEnableDirect(
        FixedApyStaking s,
        uint256 _rewardBucket,
        uint256 _apyBps,
        uint256 _minLockDuration,
        uint256 _minStakeAmount
    ) internal {
        vm.prank(admin);
        s.initialize(_rewardBucket, _apyBps, _minLockDuration, _minStakeAmount);
        vm.prank(admin);
        s.setDirectActionsEnabled(true);
    }

    function _fundRewardBucket(uint256 amount) internal {
        vm.prank(treasury);
        assetToken.approve(address(staking), amount);
        vm.prank(treasury);
        staking.fundRewardBucket(amount);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Initialize() public {
        assertEq(staking.rewardBucket(), REWARD_BUCKET);
        assertEq(staking.apyBps(), APY_BPS);
        assertEq(staking.minStakeAmount(), MIN_STAKE);
        assertEq(staking.minLockDuration(), MIN_LOCK);
        assertGt(staking.maxStakeCapacity(), 0);
        assertGt(staking.monthlyEmissionCap(), 0);
    }

    function test_Initialize_MaxCapacityCorrect() public {
        uint256 expectedMaxCapacity = (REWARD_BUCKET * 10000) / APY_BPS;
        assertApproxEqAbs(staking.maxStakeCapacity(), expectedMaxCapacity, 1e18);
    }

    function test_RevertWhen_InitializeTwice() public {
        FixedApyStaking staking2 = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(staking2, REWARD_BUCKET, APY_BPS, MIN_LOCK, MIN_STAKE);
        vm.prank(admin);
        vm.expectRevert(FixedApyStaking.AlreadyInitialized.selector);
        staking2.initialize(REWARD_BUCKET, APY_BPS, MIN_LOCK, MIN_STAKE);
    }

    /*//////////////////////////////////////////////////////////////
                        CAPACITY LIMIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Stake_RejectsWhenCapacityFull() public {
        uint256 smallBucket = 40_000_000e18;
        FixedApyStaking stakingCap = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(stakingCap, smallBucket, APY_BPS, MIN_LOCK, MIN_STAKE);
        vm.prank(treasury);
        assetToken.approve(address(stakingCap), smallBucket);
        vm.prank(treasury);
        stakingCap.fundRewardBucket(smallBucket);

        uint256 maxCapacity = stakingCap.maxStakeCapacity();
        assertLe(maxCapacity, MAX_STAKE_PER_USER, "maxCapacity must be <= per-user cap for this test");

        vm.prank(user1);
        assetToken.approve(address(stakingCap), maxCapacity);
        vm.prank(user1);
        stakingCap.stake(maxCapacity);

        vm.prank(user2);
        assetToken.approve(address(stakingCap), MIN_STAKE);
        vm.prank(user2);
        vm.expectRevert(FixedApyStaking.CapacityFull.selector);
        stakingCap.stake(MIN_STAKE);
    }

    function test_Stake_AcceptsWhenCapacityReopensAfterUnstake() public {
        _fundRewardBucket(REWARD_BUCKET);
        uint256 stakeAmount = 50_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(user1);
        staking.unstake(stakeAmount);

        vm.prank(user2);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        assertEq(staking.totalStaked(), stakeAmount);
        (uint256 amt,,,,) = staking.stakes(user2);
        assertEq(amt, stakeAmount);
    }

    function test_Stake_RejectsBelowMinimum() public {
        _fundRewardBucket(REWARD_BUCKET);
        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE - 1);
        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.BelowMinimumStake.selector);
        staking.stake(MIN_STAKE - 1);
    }

    /// @dev One StakeInfo per user: later stakes add to amount and can extend lockUntil (max of prior lock and now+minLock).
    function test_MultipleStakes_MergeSinglePositionExtendLock() public {
        uint256 lockDur = 10 days;
        FixedApyStaking s = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(s, REWARD_BUCKET, APY_BPS, lockDur, MIN_STAKE);

        vm.prank(treasury);
        assetToken.approve(address(s), REWARD_BUCKET);
        vm.prank(treasury);
        s.fundRewardBucket(REWARD_BUCKET);

        uint256 t0 = block.timestamp;

        vm.startPrank(user1);
        assetToken.approve(address(s), 500e18);
        s.stake(100e18);

        (uint256 amt1,, uint256 lock1,) = s.getUserInfo(user1);
        assertEq(amt1, 100e18);
        assertEq(lock1, t0 + lockDur);

        vm.warp(t0 + 3 days);

        s.stake(200e18);

        (uint256 amt2,, uint256 lock2,) = s.getUserInfo(user1);
        assertEq(amt2, 300e18);
        assertEq(lock2, t0 + 3 days + lockDur);

        vm.expectRevert(FixedApyStaking.StillLocked.selector);
        s.unstake(1);

        vm.warp(lock2);

        s.unstake(100e18);

        (uint256 amt3,, uint256 lock3,) = s.getUserInfo(user1);
        assertEq(amt3, 200e18);
        assertEq(lock3, lock2);

        s.unstake(200e18);
        (uint256 amt4,, uint256 lock4,) = s.getUserInfo(user1);
        assertEq(amt4, 0);
        assertEq(lock4, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        APY ACCRUAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_APY_AccrualCorrectness() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);

        uint256 pending = staking.pendingRewards(user1);
        uint256 expectedReward = (stakeAmount * APY_BPS) / 10000;
        assertApproxEqAbs(pending, expectedReward, expectedReward / 100);
    }

    function test_Claim_TransfersRewards() public {
        _fundRewardBucket(REWARD_BUCKET);
        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);

        uint256 balanceBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        uint256 balanceAfter = assetToken.balanceOf(user1);

        assertGt(balanceAfter, balanceBefore);
        assertEq(staking.pendingRewards(user1), 0);
    }

    function test_Unstake_ClaimsRewardsFirst() public {
        _fundRewardBucket(REWARD_BUCKET);
        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 180 days);

        uint256 balanceBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(stakeAmount);
        uint256 balanceAfter = assetToken.balanceOf(user1);

        (,,,, uint256 claimed) = staking.stakes(user1);
        assertEq(balanceAfter - balanceBefore, stakeAmount + claimed);
    }

    /*//////////////////////////////////////////////////////////////
                        LIFETIME BUDGET GUARD
    //////////////////////////////////////////////////////////////*/

    function test_CumulativeDistributedNeverExceedsBucket() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);

        vm.prank(user1);
        staking.claim();

        assertLe(staking.cumulativeDistributed(), REWARD_BUCKET);
    }

    /*//////////////////////////////////////////////////////////////
                        LOCK PERIOD TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Unstake_RejectsWhenLocked() public {
        uint256 lockDuration = 180 days;
        FixedApyStaking stakingLocked = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(stakingLocked, REWARD_BUCKET, APY_BPS, lockDuration, MIN_STAKE);

        vm.prank(treasury);
        assetToken.approve(address(stakingLocked), REWARD_BUCKET);
        vm.prank(treasury);
        stakingLocked.fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(stakingLocked), stakeAmount);
        vm.prank(user1);
        stakingLocked.stake(stakeAmount);

        vm.warp(baseTime + 90 days);

        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.StillLocked.selector);
        stakingLocked.unstake(stakeAmount);
    }

    function test_Unstake_SucceedsAfterLockExpiry() public {
        uint256 lockDuration = 180 days;
        FixedApyStaking stakingLocked = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(stakingLocked, REWARD_BUCKET, APY_BPS, lockDuration, MIN_STAKE);

        vm.prank(treasury);
        assetToken.approve(address(stakingLocked), REWARD_BUCKET);
        vm.prank(treasury);
        stakingLocked.fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(stakingLocked), stakeAmount);
        vm.prank(user1);
        stakingLocked.stake(stakeAmount);

        vm.warp(baseTime + lockDuration + 1 days);

        vm.prank(user1);
        stakingLocked.unstake(stakeAmount);

        assertEq(stakingLocked.totalStaked(), 0);
        assertGe(assetToken.balanceOf(user1), 200_000_000e18, "User should receive principal + rewards");
    }

    /*//////////////////////////////////////////////////////////////
                        EDGE CASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Without funding, claim() is a no-op (does NOT revert). Accrued rewards are preserved
    ///      for a later claim once the treasury has funded the bucket. This is the partial-claim
    ///      behavior: `paid = min(reward, bucketRoom, monthlyRoom, fundingRoom)` -> fundingRoom = 0.
    function test_ClaimWithoutFunding_IsNoOp_PreservesAccrued() public {
        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        staking.stake(MIN_STAKE);

        vm.warp(baseTime + 365 days);

        uint256 pendingBefore = staking.pendingRewards(user1);
        assertGt(pendingBefore, 0, "should have accrued something");

        uint256 balBefore = assetToken.balanceOf(user1);

        vm.prank(user1);
        staking.claim();

        assertEq(assetToken.balanceOf(user1), balBefore, "no tokens transferred when unfunded");
        assertEq(staking.cumulativeDistributed(), 0, "nothing should be marked distributed");
        assertGe(
            staking.pendingRewards(user1),
            pendingBefore,
            "accrued rewards preserved (plus any new accrual in same block)"
        );
    }

    /// @dev After the bucket is funded later, the preserved accrued rewards are claimable.
    function test_ClaimAfterDelayedFunding_SucceedsWithPreservedAccrual() public {
        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        staking.stake(MIN_STAKE);

        vm.warp(baseTime + 30 days);

        uint256 accruedAtMonth1 = staking.pendingRewards(user1);
        assertGt(accruedAtMonth1, 0);

        uint256 balPreUnfundedClaim = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        assertEq(assetToken.balanceOf(user1), balPreUnfundedClaim, "no payout before funding");

        _fundRewardBucket(REWARD_BUCKET);

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        assertGt(assetToken.balanceOf(user1), balBefore, "payout after funding");
    }

    /// @dev When a user's single-claim reward would exceed `monthlyEmissionCap`, the claim pays
    ///      up to the cap and keeps the remainder as accrued. Subsequent epochs can drain it.
    function test_Claim_PartialPay_WhenRewardExceedsMonthlyCap() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = staking.maxStakeCapacity(); // full-capacity whale
        if (stakeAmount > MAX_STAKE_PER_USER) stakeAmount = MAX_STAKE_PER_USER;
        assetToken.mint(user1, stakeAmount);
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        // Skip ~2 months without claiming so that accrued > monthlyEmissionCap
        vm.warp(baseTime + 60 days);

        uint256 monthlyCap = staking.monthlyEmissionCap();
        uint256 pending = staking.pendingRewards(user1);
        assertGt(pending, monthlyCap, "need reward > monthly cap to exercise partial-pay path");

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        uint256 paid = assetToken.balanceOf(user1) - balBefore;

        assertEq(paid, monthlyCap, "should pay exactly monthly cap");
        assertGt(staking.pendingRewards(user1), 0, "leftover remains accrued for next epoch");
        assertEq(staking.cumulativeDistributed(), monthlyCap);
    }

    /// @dev After the next epoch rolls over, the leftover accrued from H1-partial-pay is claimable.
    function test_Claim_NextEpoch_DrainsLeftoverAccrued() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = staking.maxStakeCapacity();
        if (stakeAmount > MAX_STAKE_PER_USER) stakeAmount = MAX_STAKE_PER_USER;
        assetToken.mint(user1, stakeAmount);
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 60 days);
        vm.prank(user1);
        staking.claim(); // partial
        uint256 leftoverAfterFirstClaim = staking.pendingRewards(user1);
        assertGt(leftoverAfterFirstClaim, 0);

        // Advance past the next epoch boundary -> monthlyRoom refills
        vm.warp(block.timestamp + 30 days + 1);

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        uint256 paid = assetToken.balanceOf(user1) - balBefore;
        assertGt(paid, 0, "leftover should drain in next epoch (up to monthlyCap again)");
    }

    /// @dev `unstake` releases principal even when the accrued reward can't be paid out yet
    ///      (was a hard revert pre-H1). Any payable portion is transferred, the rest stays accrued.
    function test_Unstake_ReleasesPrincipal_EvenWhenRewardExceedsMonthlyCap() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = staking.maxStakeCapacity();
        if (stakeAmount > MAX_STAKE_PER_USER) stakeAmount = MAX_STAKE_PER_USER;
        assetToken.mint(user1, stakeAmount);
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 60 days); // accrue > monthlyCap

        uint256 monthlyCap = staking.monthlyEmissionCap();
        uint256 pendingBefore = staking.pendingRewards(user1);
        assertGt(pendingBefore, monthlyCap);

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(stakeAmount);
        uint256 netReceived = assetToken.balanceOf(user1) - balBefore;

        assertEq(netReceived, stakeAmount + monthlyCap, "principal + capped reward");
        assertGt(staking.pendingRewards(user1), 0, "leftover reward still owed");
        assertEq(staking.totalStaked(), 0);
    }

    function test_RevertWhen_DirectActionsDisabled() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(admin);
        staking.setDirectActionsEnabled(false);

        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.DirectActionsDisabled.selector);
        staking.stake(MIN_STAKE);
    }

    function test_StakeFor_WorksWhenDirectActionsDisabled() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(admin);
        staking.setDirectActionsEnabled(false);

        vm.prank(operator);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(operator);
        staking.stakeFor(user1, MIN_STAKE);

        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, MIN_STAKE);
    }

    function test_Stake_WorksWithSeparateDeployment() public {
        FixedApyStaking stakingNoCompliance =
            new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);

        _initAndEnableDirect(stakingNoCompliance, REWARD_BUCKET, APY_BPS, MIN_LOCK, MIN_STAKE);

        assetToken.mint(treasury, REWARD_BUCKET);
        vm.prank(treasury);
        assetToken.approve(address(stakingNoCompliance), REWARD_BUCKET);
        vm.prank(treasury);
        stakingNoCompliance.fundRewardBucket(REWARD_BUCKET);

        address anyUser = makeAddr("anyUser");
        assetToken.mint(anyUser, 1_000_000e18);

        vm.prank(anyUser);
        assetToken.approve(address(stakingNoCompliance), MIN_STAKE);
        vm.prank(anyUser);
        stakingNoCompliance.stake(MIN_STAKE);

        assertEq(stakingNoCompliance.totalStaked(), MIN_STAKE);
    }

    /*//////////////////////////////////////////////////////////////
                        DASHBOARD VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetCapacityInfo() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 10_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        (uint256 maxCap, uint256 total, uint256 available, uint256 utilizationBps) = staking.getCapacityInfo();

        assertEq(maxCap, staking.maxStakeCapacity());
        assertEq(total, stakeAmount);
        assertEq(available, maxCap - stakeAmount);
        assertGt(utilizationBps, 0);
    }

    function test_GetRewardInfo() public {
        _fundRewardBucket(REWARD_BUCKET);

        (uint256 bucket, uint256 distributed, uint256 remaining, uint256 apy) = staking.getRewardInfo();

        assertEq(bucket, REWARD_BUCKET);
        assertEq(distributed, 0);
        assertEq(remaining, REWARD_BUCKET);
        assertEq(apy, APY_BPS);
    }

    function test_GetEpochInfo() public {
        (uint256 epochStart, uint256 emissions, uint256 cap, uint256 nextEpoch) = staking.getEpochInfo();

        assertEq(epochStart, baseTime);
        assertEq(emissions, 0);
        assertGt(cap, 0);
        assertEq(nextEpoch, baseTime + 30 days);
    }

    function test_GetUserInfo() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        (uint256 staked, uint256 pending,, uint256 claimed) = staking.getUserInfo(user1);

        assertEq(staked, stakeAmount);
        assertGe(pending, 0);
        assertEq(claimed, 0);
    }

    /*//////////////////////////////////////////////////////////////
                        PAUSE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Pause_BlocksStake() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(admin);
        staking.pause();

        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        vm.expectRevert();
        staking.stake(MIN_STAKE);
    }

    function test_Unpause_AllowsStake() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(admin);
        staking.pause();
        vm.prank(admin);
        staking.unpause();

        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        staking.stake(MIN_STAKE);

        assertEq(staking.totalStaked(), MIN_STAKE);
    }

    /*//////////////////////////////////////////////////////////////
                        TREASURY / WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawUnallocatedRewards() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        uint256 treasuryBefore = assetToken.balanceOf(treasury);

        vm.prank(admin);
        staking.withdrawUnallocatedRewards(treasury);

        uint256 treasuryAfter = assetToken.balanceOf(treasury);
        assertGt(treasuryAfter, treasuryBefore);
    }

    /*//////////////////////////////////////////////////////////////
                        V2: EMERGENCY WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyWithdraw_ReturnsFullPrincipal() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(admin);
        staking.pause();

        vm.prank(user1);
        staking.emergencyWithdraw();

        assertEq(staking.totalStaked(), 0);
        assertEq(assetToken.balanceOf(user1), 200_000_000e18);
    }

    function test_EmergencyWithdraw_ForfeitsRewards() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);

        uint256 pendingBefore = staking.pendingRewards(user1);
        assertGt(pendingBefore, 0);

        vm.prank(user1);
        staking.emergencyWithdraw();

        assertEq(assetToken.balanceOf(user1), 200_000_000e18, "User gets only principal, no rewards");
    }

    function test_RevertWhen_EmergencyWithdraw_NothingStaked() public {
        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.NothingStaked.selector);
        staking.emergencyWithdraw();
    }

    /*//////////////////////////////////////////////////////////////
                        V2: DEPOSITS ENABLED TOGGLE
    //////////////////////////////////////////////////////////////*/

    function test_DepositsDisabled_BlocksStake() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(admin);
        staking.setDepositsEnabled(false);

        vm.prank(user1);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.DepositsDisabled.selector);
        staking.stake(MIN_STAKE);
    }

    function test_DepositsDisabled_AllowsUnstakeAndClaim() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.prank(admin);
        staking.setDepositsEnabled(false);

        vm.warp(baseTime + 365 days);

        vm.prank(user1);
        staking.claim();

        vm.prank(user1);
        staking.unstake(stakeAmount);

        assertEq(staking.totalStaked(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        V2: PER-USER CAP
    //////////////////////////////////////////////////////////////*/

    function test_Stake_RejectsWhenUserCapExceeded() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 userCap = 50_000_000e18;
        FixedApyStaking stakingCap = new FixedApyStaking(address(assetToken), admin, treasury, userCap);
        _initAndEnableDirect(stakingCap, REWARD_BUCKET, APY_BPS, MIN_LOCK, MIN_STAKE);
        vm.prank(treasury);
        assetToken.approve(address(stakingCap), REWARD_BUCKET);
        vm.prank(treasury);
        stakingCap.fundRewardBucket(REWARD_BUCKET);

        vm.prank(user1);
        assetToken.approve(address(stakingCap), userCap + 1);
        vm.prank(user1);
        stakingCap.stake(userCap);

        vm.prank(user1);
        vm.expectRevert(FixedApyStaking.UserCapExceeded.selector);
        stakingCap.stake(MIN_STAKE);
    }

    /*//////////////////////////////////////////////////////////////
                        V2: GUARDRAIL ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    function test_SetApyBps_RevertsWhenExceedsGuardrail() public {
        vm.prank(admin);
        vm.expectRevert(FixedApyStaking.ExceedsGuardrail.selector);
        staking.setApyBps(5001); // MAX_APY_BPS is 5000
    }

    function test_SetLockDuration_RevertsWhenExceedsGuardrail() public {
        vm.prank(admin);
        vm.expectRevert(FixedApyStaking.ExceedsGuardrail.selector);
        staking.setLockDuration(365 days + 1); // MAX_LOCK_DURATION is 365 days
    }

    /*//////////////////////////////////////////////////////////////
                        V2: SET REWARD BUCKET
    //////////////////////////////////////////////////////////////*/

    function test_SetRewardBucket_Success() public {
        uint256 newBucket = REWARD_BUCKET * 2;
        vm.prank(admin);
        staking.setRewardBucket(newBucket);

        assertEq(staking.rewardBucket(), newBucket);
        assertEq(staking.maxStakeCapacity(), (newBucket * 10000) / APY_BPS);
        assertEq(staking.monthlyEmissionCap(), newBucket / 12);
    }

    function test_SetRewardBucket_RevertsWhenBelowObligations() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);
        vm.prank(user1);
        staking.claim();
        uint256 distributed = staking.cumulativeDistributed();
        assertGt(distributed, 0);

        vm.prank(admin);
        vm.expectRevert(FixedApyStaking.InsufficientBucket.selector);
        staking.setRewardBucket(distributed - 1);
    }

    /*//////////////////////////////////////////////////////////////
                        V2: NON-RETROACTIVE LOCK
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                        STAKE-CLAIM-WITHDRAW-RESTAKE LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_StakeClaimWithdrawRestake_FullLifecycle() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;

        // ── Phase 1: Stake ──
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        assertEq(staking.totalStaked(), stakeAmount);
        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, stakeAmount);

        // ── Phase 2: Claim monthly for 5 months ──
        uint256 totalClaimed1;
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(baseTime + i * 30 days);

            uint256 pending = staking.pendingRewards(user1);
            assertGt(pending, 0, "Should have pending rewards each month");

            uint256 balBefore = assetToken.balanceOf(user1);
            vm.prank(user1);
            staking.claim();
            uint256 balAfter = assetToken.balanceOf(user1);

            uint256 claimedThisMonth = balAfter - balBefore;
            assertGt(claimedThisMonth, 0, "Should receive non-zero rewards");
            totalClaimed1 += claimedThisMonth;
        }

        uint256 expectedReward5Mo = (stakeAmount * APY_BPS * 150 days) / (10_000 * 365 days);
        assertApproxEqRel(totalClaimed1, expectedReward5Mo, 0.01e18);

        (,,, uint256 claimedLifetime1) = staking.getUserInfo(user1);
        assertEq(claimedLifetime1, totalClaimed1, "claimedLifetime should match sum of claims");

        // ── Phase 3: Full unstake (also claims any residual) ──
        uint256 balBeforeUnstake = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.unstake(stakeAmount);
        uint256 balAfterUnstake = assetToken.balanceOf(user1);

        uint256 unstakeReceived = balAfterUnstake - balBeforeUnstake;
        assertGe(unstakeReceived, stakeAmount, "Should get back at least the principal");

        assertEq(staking.totalStaked(), 0, "Pool should be empty after unstake");
        (uint256 stakedAfterUnstake,,,) = staking.getUserInfo(user1);
        assertEq(stakedAfterUnstake, 0, "User stake should be zero");

        // ── Phase 4: Re-stake the same amount ──
        uint256 restakeTime = baseTime + 150 days + 60 days;
        vm.warp(restakeTime);

        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        assertEq(staking.totalStaked(), stakeAmount);
        (uint256 restakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(restakedAmt, stakeAmount);

        // ── Phase 5: Claim monthly for another 5 months ──
        uint256 totalClaimed2;
        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(restakeTime + i * 30 days);

            uint256 pending = staking.pendingRewards(user1);
            assertGt(pending, 0, "Should have pending rewards in phase 2");

            uint256 balBefore = assetToken.balanceOf(user1);
            vm.prank(user1);
            staking.claim();
            uint256 balAfter = assetToken.balanceOf(user1);

            uint256 claimedThisMonth = balAfter - balBefore;
            assertGt(claimedThisMonth, 0, "Should receive non-zero rewards in phase 2");
            totalClaimed2 += claimedThisMonth;
        }

        assertApproxEqRel(totalClaimed2, expectedReward5Mo, 0.01e18);

        // ── Final assertions ──
        assertApproxEqRel(totalClaimed1, totalClaimed2, 0.01e18);

        (,,, uint256 claimedLifetimeFinal) = staking.getUserInfo(user1);
        uint256 residualFromUnstake = unstakeReceived - stakeAmount;
        assertApproxEqAbs(claimedLifetimeFinal, totalClaimed1 + residualFromUnstake + totalClaimed2, 1e15);

        assertLe(
            staking.cumulativeDistributed(), REWARD_BUCKET, "Cumulative distributed must never exceed reward bucket"
        );
    }

    function test_Stake1000_NoClaim12Months_SingleClaimCorrect() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000e18;

        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        vm.warp(baseTime + 365 days);

        uint256 pending = staking.pendingRewards(user1);
        uint256 expectedReward = (stakeAmount * APY_BPS) / 10_000; // 1000 * 20% = 200 tokens
        assertApproxEqRel(pending, expectedReward, 0.01e18, "Pending should match 20% APY for 1 year");

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        uint256 balAfter = assetToken.balanceOf(user1);

        uint256 claimed = balAfter - balBefore;
        assertApproxEqRel(claimed, expectedReward, 0.01e18, "Claimed amount should match expected annual yield");

        assertEq(staking.pendingRewards(user1), 0, "No pending rewards after claim");

        (uint256 staked, uint256 pendingAfter,, uint256 claimedLifetime) = staking.getUserInfo(user1);
        assertEq(staked, stakeAmount, "Stake should remain intact");
        assertEq(pendingAfter, 0, "Pending should be zero after claim");
        assertEq(claimedLifetime, claimed, "claimedLifetime should equal the single claim");

        assertLe(staking.cumulativeDistributed(), REWARD_BUCKET, "Must not exceed reward bucket");
    }

    /*//////////////////////////////////////////////////////////////
                        APY CHANGE MID-STAKE
    //////////////////////////////////////////////////////////////*/

    function test_ApyChange_MonthlyClaimMatchesSingleClaim() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000e18;
        uint256 oldApy = APY_BPS; // 2000 = 20%
        uint256 newApy = 1_000; // 10%

        // ── User A: will claim monthly ──
        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        // ── User B: will claim once at end ──
        vm.prank(user2);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user2);
        staking.stake(stakeAmount);

        // ── Months 1-6: claim monthly for User A at 20% APY ──
        uint256 totalClaimedA;
        for (uint256 i = 1; i <= 6; i++) {
            vm.warp(baseTime + i * 30 days);

            uint256 balBefore = assetToken.balanceOf(user1);
            vm.prank(user1);
            staking.claim();
            totalClaimedA += assetToken.balanceOf(user1) - balBefore;
        }

        // ── APY change at month 6: 20% -> 10% ──
        vm.warp(baseTime + 180 days);
        vm.prank(admin);
        staking.setApyBps(newApy);

        // ── Months 7-12: claim monthly for User A at 10% APY ──
        for (uint256 i = 7; i <= 12; i++) {
            vm.warp(baseTime + i * 30 days);

            uint256 balBefore = assetToken.balanceOf(user1);
            vm.prank(user1);
            staking.claim();
            totalClaimedA += assetToken.balanceOf(user1) - balBefore;
        }

        // ── User B: single claim at end of month 12 ──
        uint256 balBeforeB = assetToken.balanceOf(user2);
        vm.prank(user2);
        staking.claim();
        uint256 totalClaimedB = assetToken.balanceOf(user2) - balBeforeB;

        // ── Expected: 6 months at 20% + 6 months at 10% ──
        // Phase 1: 1000 * 20% * (180/365) ≈ 98.63
        // Phase 2: 1000 * 10% * (180/365) ≈ 49.31
        // Total ≈ 147.95
        uint256 expectedPhase1 = (stakeAmount * oldApy * 180 days) / (10_000 * 365 days);
        uint256 expectedPhase2 = (stakeAmount * newApy * 180 days) / (10_000 * 365 days);
        uint256 expectedTotal = expectedPhase1 + expectedPhase2;

        assertApproxEqRel(totalClaimedA, expectedTotal, 0.02e18, "User A monthly total should match expected");
        assertApproxEqRel(totalClaimedB, expectedTotal, 0.02e18, "User B single claim should match expected");
        assertApproxEqRel(totalClaimedA, totalClaimedB, 0.01e18, "Monthly vs single claim should be equal");

        // ── Verify phase 1 earned more than phase 2 ──
        assertGt(expectedPhase1, expectedPhase2, "20% phase should earn more than 10% phase");

        assertLe(staking.cumulativeDistributed(), REWARD_BUCKET, "Must not exceed reward bucket");
    }

    function test_Lock_NonRetroactive_AdminIncreasesLock() public {
        uint256 shortLock = 30 days;
        FixedApyStaking stakingLock = new FixedApyStaking(address(assetToken), admin, treasury, MAX_STAKE_PER_USER);
        _initAndEnableDirect(stakingLock, REWARD_BUCKET, APY_BPS, shortLock, MIN_STAKE);

        vm.prank(treasury);
        assetToken.approve(address(stakingLock), REWARD_BUCKET);
        vm.prank(treasury);
        stakingLock.fundRewardBucket(REWARD_BUCKET);

        vm.prank(user1);
        assetToken.approve(address(stakingLock), MIN_STAKE);
        vm.prank(user1);
        stakingLock.stake(MIN_STAKE);

        (,, uint256 lockUntil,) = stakingLock.getUserInfo(user1);
        uint256 expectedLockUntil = baseTime + 1 + shortLock;
        assertApproxEqAbs(lockUntil, expectedLockUntil, 2);

        vm.prank(admin);
        stakingLock.setLockDuration(180 days);

        (,, uint256 lockUntilAfter,) = stakingLock.getUserInfo(user1);
        assertEq(lockUntilAfter, lockUntil, "Existing user keeps original lock");
    }

    /*//////////////////////////////////////////////////////////////
                        OPERATOR DELEGATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StakeFor_CreditsUserPullsFromOperator() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;
        uint256 operatorBalBefore = assetToken.balanceOf(operator);
        uint256 userBalBefore = assetToken.balanceOf(user1);

        vm.prank(operator);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(operator);
        staking.stakeFor(user1, stakeAmount);

        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, stakeAmount, "Stake should be credited to user");
        assertEq(assetToken.balanceOf(operator), operatorBalBefore - stakeAmount, "Tokens pulled from operator");
        assertEq(assetToken.balanceOf(user1), userBalBefore, "User balance unchanged");
        assertEq(staking.totalStaked(), stakeAmount);
    }

    function test_UnstakeFor_RespectsLockSendsToOperator() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;

        vm.prank(operator);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(operator);
        staking.stakeFor(user1, stakeAmount);

        vm.warp(baseTime + 180 days);

        uint256 operatorBalBefore = assetToken.balanceOf(operator);
        vm.prank(operator);
        staking.unstakeFor(user1, stakeAmount);
        uint256 operatorBalAfter = assetToken.balanceOf(operator);

        uint256 received = operatorBalAfter - operatorBalBefore;
        assertGe(received, stakeAmount, "Operator should receive principal + rewards");
        assertEq(staking.totalStaked(), 0, "Pool should be empty");

        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, 0, "User stake should be zero");
    }

    function test_ClaimFor_RewardsGoToOperator() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;

        vm.prank(operator);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(operator);
        staking.stakeFor(user1, stakeAmount);

        vm.warp(baseTime + 180 days);

        uint256 operatorBalBefore = assetToken.balanceOf(operator);
        uint256 userBalBefore = assetToken.balanceOf(user1);

        vm.prank(operator);
        staking.claimFor(user1);

        uint256 operatorReward = assetToken.balanceOf(operator) - operatorBalBefore;
        assertGt(operatorReward, 0, "Operator should receive rewards");
        assertEq(assetToken.balanceOf(user1), userBalBefore, "User balance unchanged");

        (,,, uint256 claimedLifetime) = staking.getUserInfo(user1);
        assertEq(claimedLifetime, operatorReward, "claimedLifetime updated on user");

        assertEq(staking.pendingRewards(user1), 0, "No pending rewards after claim");
    }

    function test_EmergencyWithdrawFor_ForfeitsRewardsSendsToOperator() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;

        vm.prank(operator);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(operator);
        staking.stakeFor(user1, stakeAmount);

        vm.warp(baseTime + 365 days);

        uint256 pendingBefore = staking.pendingRewards(user1);
        assertGt(pendingBefore, 0, "Should have accrued rewards");

        uint256 operatorBalBefore = assetToken.balanceOf(operator);
        vm.prank(operator);
        staking.emergencyWithdrawFor(user1);
        uint256 operatorBalAfter = assetToken.balanceOf(operator);

        assertEq(operatorBalAfter - operatorBalBefore, stakeAmount, "Operator gets only principal");
        assertEq(staking.totalStaked(), 0);

        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, 0, "User stake should be zero");
    }

    function test_RevertWhen_NonOperatorCallsForFunctions() public {
        _fundRewardBucket(REWARD_BUCKET);

        vm.prank(user1);
        vm.expectRevert();
        staking.stakeFor(user1, MIN_STAKE);

        vm.prank(user1);
        vm.expectRevert();
        staking.unstakeFor(user1, MIN_STAKE);

        vm.prank(user1);
        vm.expectRevert();
        staking.claimFor(user1);

        vm.prank(user1);
        vm.expectRevert();
        staking.emergencyWithdrawFor(user1);
    }

    function test_SelfStakeUnaffectedByOperator() public {
        _fundRewardBucket(REWARD_BUCKET);

        uint256 stakeAmount = 1_000_000e18;

        vm.prank(user1);
        assetToken.approve(address(staking), stakeAmount);
        vm.prank(user1);
        staking.stake(stakeAmount);

        assertEq(staking.totalStaked(), stakeAmount);

        vm.warp(baseTime + 180 days);

        uint256 balBefore = assetToken.balanceOf(user1);
        vm.prank(user1);
        staking.claim();
        uint256 reward = assetToken.balanceOf(user1) - balBefore;
        assertGt(reward, 0, "User should receive rewards directly");

        vm.prank(user1);
        staking.unstake(stakeAmount);

        assertEq(staking.totalStaked(), 0);
        (uint256 stakedAmt,,,) = staking.getUserInfo(user1);
        assertEq(stakedAmt, 0);
    }

    function test_StakeFor_CreditsAnyUserAddress() public {
        _fundRewardBucket(REWARD_BUCKET);

        address attributedUser = makeAddr("attributedUser");

        vm.prank(operator);
        assetToken.approve(address(staking), MIN_STAKE);
        vm.prank(operator);
        staking.stakeFor(attributedUser, MIN_STAKE);

        (uint256 stakedAmt,,,) = staking.getUserInfo(attributedUser);
        assertEq(stakedAmt, MIN_STAKE);
    }
}
