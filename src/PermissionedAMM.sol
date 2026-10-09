// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IImpactPolicy} from "./interfaces/IImpactPolicy.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";

/**
 * @title PermissionedAMM
 * @notice Managed Vault AMM for Platform token presale on Base
 * @dev Implements a constant product (x·y=k) AMM with:
 *      - Treasury-owned liquidity (no LP tokens)
 *      - Impact guardrails via ImpactPolicy
 *      - Compliance checks via ComplianceRegistry
 *      - Admin restrictions (treasury cannot swap)
 *      - Timelock-gated liquidity operations
 *
 * Pool Phases:
 *   1. UNINITIALIZED - Contract deployed, awaiting initialization
 *   2. SEED - Admin initializing pool with target price
 *   3. ACTIVE - Pool open for compliant users to swap
 *   4. PAUSED - Temporarily halted (emergency or maintenance)
 *   5. DEPRECATED - Pool being wound down
 */
contract PermissionedAMM is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin role - can manage pool parameters
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Treasury role - owns liquidity, CANNOT swap
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    /// @notice Operator role - can execute backend operations
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Timelock role - for privileged operations
    bytes32 public constant TIMELOCK_ROLE = keccak256("TIMELOCK_ROLE");

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool phase enum
    enum PoolPhase {
        UNINITIALIZED,
        SEED,
        ACTIVE,
        PAUSED,
        DEPRECATED
    }

    /// @notice Current pool phase
    PoolPhase public phase;

    /// @notice Asset token (the presale token)
    IERC20 public immutable assetToken;

    /// @notice Stable stablecoin (the quote token)
    IERC20 public immutable stableToken;

    /// @notice Asset token reserves in the vault
    uint256 public reserveAsset;

    /// @notice Stable token reserves in the vault
    uint256 public reserveStable;

    /// @notice Impact policy contract
    IImpactPolicy public impactPolicy;

    /// @notice Compliance registry contract
    IComplianceRegistry public complianceRegistry;

    /// @notice Swap fee in basis points (default 30 = 0.3%)
    uint256 public swapFeeBps = 30;

    /// @notice Maximum swap fee allowed (5%)
    uint256 public constant MAX_SWAP_FEE_BPS = 500;

    /// @notice Minimum liquidity to prevent division by zero attacks
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Accumulated fees in Asset
    uint256 public accumulatedFeesAsset;

    /// @notice Accumulated fees in Stable
    uint256 public accumulatedFeesStable;

    /// @notice Total volume in USD (18 decimals)
    uint256 public totalVolumeUSD;

    /// @notice Total number of swaps
    uint256 public totalSwapCount;

    /// @notice Whether direct user swaps via swap() are enabled
    bool public directSwapEnabled;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when pool is initialized
    event PoolInitialized(uint256 assetAmount, uint256 stableAmount, uint256 targetPrice, uint256 timestamp);

    /// @notice Emitted when pool phase changes
    event PhaseChanged(PoolPhase oldPhase, PoolPhase newPhase);

    /// @notice Emitted on every swap
    event Swap(
        address indexed user,
        bool assetIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 spotPriceBefore,
        uint256 spotPriceAfter,
        uint256 slippageBps
    );

    /// @notice Emitted when liquidity is added
    event LiquidityAdded(uint256 assetAmount, uint256 stableAmount, uint256 newReserveAsset, uint256 newReserveStable);

    /// @notice Emitted when liquidity is removed
    event LiquidityRemoved(
        uint256 assetAmount, uint256 stableAmount, uint256 newReserveAsset, uint256 newReserveStable
    );

    /// @notice Emitted when rebalance occurs (single-sided liquidity add)
    event Rebalanced(address indexed token, uint256 amount, uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when fees are collected
    event FeesCollected(address indexed to, uint256 assetAmount, uint256 stableAmount);

    /// @notice Emitted when swap is executed on behalf of user
    event SwapOnBehalf(
        address indexed user, address indexed operator, bool assetIn, uint256 amountIn, uint256 amountOut
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PermissionedAMM__InvalidPhase(PoolPhase current, PoolPhase required);
    error PermissionedAMM__NotCompliant(address user);
    error PermissionedAMM__TreasuryCannotSwap();
    error PermissionedAMM__InsufficientLiquidity();
    error PermissionedAMM__SlippageExceeded(uint256 actual, uint256 maximum);
    error PermissionedAMM__InvalidAmount();
    error PermissionedAMM__InsufficientOutput(uint256 actual, uint256 minimum);
    error PermissionedAMM__ZeroAddress();
    error PermissionedAMM__InvalidFee(uint256 fee);
    error PermissionedAMM__DailyLimitExceeded(address user, uint256 remaining);
    error PermissionedAMM__DirectSwapDisabled();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploys the PermissionedAMM
     * @param _assetToken Address of the Asset token
     * @param _stableToken Address of the Stable stablecoin
     * @param _impactPolicy Address of the impact policy contract
     * @param _complianceRegistry Address of the compliance registry
     * @param _admin Admin address
     * @param _treasury Treasury address
     * @param _timelock Timelock contract address
     */
    constructor(
        address _assetToken,
        address _stableToken,
        address _impactPolicy,
        address _complianceRegistry,
        address _admin,
        address _treasury,
        address _timelock
    ) {
        if (_assetToken == address(0)) revert PermissionedAMM__ZeroAddress();
        if (_stableToken == address(0)) revert PermissionedAMM__ZeroAddress();
        if (_admin == address(0)) revert PermissionedAMM__ZeroAddress();
        if (_treasury == address(0)) revert PermissionedAMM__ZeroAddress();

        assetToken = IERC20(_assetToken);
        stableToken = IERC20(_stableToken);
        impactPolicy = IImpactPolicy(_impactPolicy);
        complianceRegistry = IComplianceRegistry(_complianceRegistry);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(TREASURY_ROLE, _treasury);
        _grantRole(OPERATOR_ROLE, _admin);

        if (_timelock != address(0)) {
            _grantRole(TIMELOCK_ROLE, _timelock);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the pool at a target price
     * @dev Seeds the pool with Asset and Stable to achieve target price
     *      Price = reserveStable / reserveAsset
     *      To seed at $1.00 with 1M Asset, deposit 1M Asset and 1M Stable
     * @param assetAmount Amount of Asset tokens to seed
     * @param stableAmount Amount of Stable to seed
     */
    function initialize(uint256 assetAmount, uint256 stableAmount) external onlyRole(ADMIN_ROLE) {
        if (phase != PoolPhase.UNINITIALIZED) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.UNINITIALIZED);
        }
        if (assetAmount < MINIMUM_LIQUIDITY || stableAmount < MINIMUM_LIQUIDITY) {
            revert PermissionedAMM__InvalidAmount();
        }

        assetToken.safeTransferFrom(msg.sender, address(this), assetAmount);
        stableToken.safeTransferFrom(msg.sender, address(this), stableAmount);

        reserveAsset = assetAmount;
        reserveStable = stableAmount;

        uint256 targetPrice = (stableAmount * 1e18) / assetAmount;

        phase = PoolPhase.SEED;

        emit PoolInitialized(assetAmount, stableAmount, targetPrice, block.timestamp);
        emit PhaseChanged(PoolPhase.UNINITIALIZED, PoolPhase.SEED);
    }

    /**
     * @notice Activates the pool for trading
     */
    function activate() external onlyRole(ADMIN_ROLE) {
        if (phase != PoolPhase.SEED) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.SEED);
        }

        PoolPhase oldPhase = phase;
        phase = PoolPhase.ACTIVE;

        emit PhaseChanged(oldPhase, PoolPhase.ACTIVE);
    }

    /**
     * @notice Swaps Asset for Stable or vice versa
     * @dev Gated by directSwapEnabled (default: false). Use swapOnBehalf for operator flow.
     * @param assetIn True if swapping Asset for Stable, false otherwise
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum output amount (slippage protection)
     * @return amountOut Actual output amount
     */
    function swap(bool assetIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (!directSwapEnabled) revert PermissionedAMM__DirectSwapDisabled();
        return _swap(msg.sender, msg.sender, assetIn, amountIn, minAmountOut, false);
    }

    /**
     * @notice Executes a swap on behalf of a user (custodial operator flow)
     * @dev Tokens flow operator -> vault -> operator. The user param is for
     *      event attribution only; no tokens touch the user's wallet.
     *      Mirrors the stakeFor/unstakeFor pattern in FixedApyStaking.
     * @param user The user to attribute the swap to (for on-chain audit trail)
     * @param assetIn True if swapping Asset for Stable
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum output amount
     */
    function swapOnBehalf(address user, bool assetIn, uint256 amountIn, uint256 minAmountOut)
        external
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        returns (uint256 amountOut)
    {
        if (user == address(0)) revert PermissionedAMM__ZeroAddress();

        if (assetIn) {
            assetToken.safeTransferFrom(msg.sender, address(this), amountIn);
        } else {
            stableToken.safeTransferFrom(msg.sender, address(this), amountIn);
        }

        return _swap(user, msg.sender, assetIn, amountIn, minAmountOut, true);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds balanced liquidity to increase pool depth
     * @dev Can only be called by timelock for transparency
     * @param assetAmount Amount of Asset to add
     * @param stableAmount Amount of Stable to add
     */
    function addLiquidity(uint256 assetAmount, uint256 stableAmount) external onlyRole(TIMELOCK_ROLE) {
        if (phase == PoolPhase.UNINITIALIZED || phase == PoolPhase.DEPRECATED) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.ACTIVE);
        }

        if (assetAmount > 0) {
            assetToken.safeTransferFrom(msg.sender, address(this), assetAmount);
            reserveAsset += assetAmount;
        }
        if (stableAmount > 0) {
            stableToken.safeTransferFrom(msg.sender, address(this), stableAmount);
            reserveStable += stableAmount;
        }

        emit LiquidityAdded(assetAmount, stableAmount, reserveAsset, reserveStable);
    }

    /**
     * @notice Removes liquidity from the pool
     * @dev Can only be called by timelock for transparency
     * @param assetAmount Amount of Asset to remove
     * @param stableAmount Amount of Stable to remove
     * @param to Address to send tokens to
     */
    function removeLiquidity(uint256 assetAmount, uint256 stableAmount, address to) external onlyRole(TIMELOCK_ROLE) {
        if (to == address(0)) revert PermissionedAMM__ZeroAddress();
        if (assetAmount > reserveAsset - MINIMUM_LIQUIDITY) revert PermissionedAMM__InsufficientLiquidity();
        if (stableAmount > reserveStable - MINIMUM_LIQUIDITY) revert PermissionedAMM__InsufficientLiquidity();

        if (assetAmount > 0) {
            reserveAsset -= assetAmount;
            assetToken.safeTransfer(to, assetAmount);
        }
        if (stableAmount > 0) {
            reserveStable -= stableAmount;
            stableToken.safeTransfer(to, stableAmount);
        }

        emit LiquidityRemoved(assetAmount, stableAmount, reserveAsset, reserveStable);
    }

    /**
     * @notice Rebalances the pool by adding single-sided liquidity
     * @dev Shifts the price. Can only be called via timelock.
     *      - Adding Asset decreases price (more Asset per Stable)
     *      - Adding Stable increases price (more Stable per Asset)
     * @param token The token to add (Asset or Stable address)
     * @param amount Amount to add
     */
    function rebalance(address token, uint256 amount) external onlyRole(TIMELOCK_ROLE) {
        if (phase == PoolPhase.UNINITIALIZED || phase == PoolPhase.DEPRECATED) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.ACTIVE);
        }
        if (amount == 0) revert PermissionedAMM__InvalidAmount();

        uint256 oldPrice = getSpotPrice();

        if (token == address(assetToken)) {
            assetToken.safeTransferFrom(msg.sender, address(this), amount);
            reserveAsset += amount;
        } else if (token == address(stableToken)) {
            stableToken.safeTransferFrom(msg.sender, address(this), amount);
            reserveStable += amount;
        } else {
            revert PermissionedAMM__ZeroAddress();
        }

        uint256 newPrice = getSpotPrice();

        emit Rebalanced(token, amount, oldPrice, newPrice);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the swap fee
     * @param newFeeBps New fee in basis points
     */
    function setSwapFee(uint256 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > MAX_SWAP_FEE_BPS) revert PermissionedAMM__InvalidFee(newFeeBps);
        swapFeeBps = newFeeBps;
    }

    /**
     * @notice Updates the impact policy contract
     */
    function setImpactPolicy(address newPolicy) external onlyRole(ADMIN_ROLE) {
        impactPolicy = IImpactPolicy(newPolicy);
    }

    /**
     * @notice Updates the compliance registry
     */
    function setComplianceRegistry(address newRegistry) external onlyRole(ADMIN_ROLE) {
        complianceRegistry = IComplianceRegistry(newRegistry);
    }

    /**
     * @notice Enables or disables direct user swaps via swap()
     * @param enabled True to allow direct swaps, false to restrict to operator-only
     */
    function setDirectSwapEnabled(bool enabled) external onlyRole(ADMIN_ROLE) {
        directSwapEnabled = enabled;
    }

    /**
     * @notice Pauses the pool
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
        emit PhaseChanged(phase, PoolPhase.PAUSED);
    }

    /**
     * @notice Unpauses the pool
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Sets pool to deprecated phase
     */
    function deprecate() external onlyRole(ADMIN_ROLE) {
        PoolPhase oldPhase = phase;
        phase = PoolPhase.DEPRECATED;
        emit PhaseChanged(oldPhase, PoolPhase.DEPRECATED);
    }

    /**
     * @notice Collects accumulated fees
     * @param to Address to send fees to
     */
    function collectFees(address to) external onlyRole(TREASURY_ROLE) {
        if (to == address(0)) revert PermissionedAMM__ZeroAddress();

        uint256 feesAsset = accumulatedFeesAsset;
        uint256 feesStable = accumulatedFeesStable;

        accumulatedFeesAsset = 0;
        accumulatedFeesStable = 0;

        if (feesAsset > 0) {
            reserveAsset -= feesAsset;
            assetToken.safeTransfer(to, feesAsset);
        }
        if (feesStable > 0) {
            reserveStable -= feesStable;
            stableToken.safeTransfer(to, feesStable);
        }

        emit FeesCollected(to, feesAsset, feesStable);
    }

    /**
     * @notice Emergency withdrawal of all funds
     * @dev Only for emergencies. Pool must be deprecated.
     */
    function emergencyWithdraw(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (phase != PoolPhase.DEPRECATED) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.DEPRECATED);
        }
        if (to == address(0)) revert PermissionedAMM__ZeroAddress();

        uint256 assetBalance = assetToken.balanceOf(address(this));
        uint256 stableBalance = stableToken.balanceOf(address(this));

        if (assetBalance > 0) {
            assetToken.safeTransfer(to, assetBalance);
        }
        if (stableBalance > 0) {
            stableToken.safeTransfer(to, stableBalance);
        }

        reserveAsset = 0;
        reserveStable = 0;
        accumulatedFeesAsset = 0;
        accumulatedFeesStable = 0;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the current spot price of Asset in Stable
     * @return price Price scaled by 1e18
     */
    function getSpotPrice() public view returns (uint256 price) {
        if (reserveAsset == 0) return 0;
        return (reserveStable * 1e18) / reserveAsset;
    }

    /**
     * @notice Calculates output amount for a given input using constant product
     * @param amountIn Input amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Output amount after fees
     * @return feeAmount Fee taken from input
     */
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        if (amountIn == 0) revert PermissionedAMM__InvalidAmount();
        if (reserveIn == 0 || reserveOut == 0) revert PermissionedAMM__InsufficientLiquidity();

        feeAmount = (amountIn * swapFeeBps) / 10000;
        uint256 amountInWithFee = amountIn - feeAmount;

        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /**
     * @notice Calculates input amount needed for a given output
     * @param amountOut Desired output amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountIn Required input amount including fees
     */
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        public
        view
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert PermissionedAMM__InvalidAmount();
        if (reserveIn == 0 || reserveOut == 0) revert PermissionedAMM__InsufficientLiquidity();
        if (amountOut >= reserveOut) revert PermissionedAMM__InsufficientLiquidity();

        uint256 numerator = reserveIn * amountOut;
        uint256 denominator = reserveOut - amountOut;
        uint256 amountInBeforeFee = (numerator / denominator) + 1;

        amountIn = (amountInBeforeFee * 10000) / (10000 - swapFeeBps);
    }

    /**
     * @notice Gets the current reserves
     * @return _reserveAsset Asset reserve
     * @return _reserveStable Stable reserve
     */
    function getReserves() external view returns (uint256 _reserveAsset, uint256 _reserveStable) {
        return (reserveAsset, reserveStable);
    }

    /**
     * @notice Gets pool statistics
     */
    function getPoolStats()
        external
        view
        returns (
            uint256 _totalVolumeUSD,
            uint256 _totalSwapCount,
            uint256 _accumulatedFeesAsset,
            uint256 _accumulatedFeesStable,
            uint256 _spotPrice
        )
    {
        return (totalVolumeUSD, totalSwapCount, accumulatedFeesAsset, accumulatedFeesStable, getSpotPrice());
    }

    /**
     * @notice Quotes a swap without executing
     * @param assetIn True if swapping Asset for Stable
     * @param amountIn Input amount
     * @return amountOut Output amount
     * @return priceImpactBps Price impact in basis points
     */
    function quoteSwap(bool assetIn, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 priceImpactBps)
    {
        uint256 feeAmount;
        if (assetIn) {
            (amountOut, feeAmount) = getAmountOut(amountIn, reserveAsset, reserveStable);
        } else {
            (amountOut, feeAmount) = getAmountOut(amountIn, reserveStable, reserveAsset);
        }

        uint256 spotPrice = getSpotPrice();
        if (address(impactPolicy) != address(0)) {
            (, priceImpactBps) = impactPolicy.validateImpact(amountIn, amountOut, spotPrice, assetIn);
        }
    }

    /**
     * @notice Gets the k constant (product of reserves)
     */
    function getK() external view returns (uint256) {
        return reserveAsset * reserveStable;
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @param user Address attributed in events and checked for compliance/treasury
     * @param recipient Address that receives the output tokens
     * @param assetIn True if swapping Asset for Stable
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum acceptable output
     * @param isOnBehalf True when caller already transferred input tokens (skips transferFrom)
     */
    function _swap(
        address user,
        address recipient,
        bool assetIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bool isOnBehalf
    ) internal returns (uint256 amountOut) {
        if (phase != PoolPhase.ACTIVE) {
            revert PermissionedAMM__InvalidPhase(phase, PoolPhase.ACTIVE);
        }

        if (hasRole(TREASURY_ROLE, user)) {
            revert PermissionedAMM__TreasuryCannotSwap();
        }

        if (address(complianceRegistry) != address(0) && !hasRole(OPERATOR_ROLE, msg.sender)) {
            if (!complianceRegistry.isCompliant(user)) {
                revert PermissionedAMM__NotCompliant(user);
            }
        }

        uint256 spotPriceBefore = getSpotPrice();

        uint256 feeAmount;
        if (assetIn) {
            (amountOut, feeAmount) = getAmountOut(amountIn, reserveAsset, reserveStable);
        } else {
            (amountOut, feeAmount) = getAmountOut(amountIn, reserveStable, reserveAsset);
        }

        if (amountOut < minAmountOut) {
            revert PermissionedAMM__InsufficientOutput(amountOut, minAmountOut);
        }

        if (address(impactPolicy) != address(0)) {
            (bool valid, uint256 slippageBps) =
                impactPolicy.validateImpact(amountIn, amountOut, spotPriceBefore, assetIn);
            if (!valid) {
                uint256 maxSlippage =
                    impactPolicy.getMaxSlippage(assetIn ? (amountIn * spotPriceBefore) / 1e18 : amountIn);
                revert PermissionedAMM__SlippageExceeded(slippageBps, maxSlippage);
            }
        }

        uint256 volumeUSD = assetIn ? (amountIn * spotPriceBefore) / 1e18 : amountIn;

        if (assetIn) {
            if (!isOnBehalf) {
                assetToken.safeTransferFrom(user, address(this), amountIn);
            }
            stableToken.safeTransfer(recipient, amountOut);

            reserveAsset += amountIn;
            reserveStable -= amountOut;
            accumulatedFeesAsset += feeAmount;
        } else {
            if (!isOnBehalf) {
                stableToken.safeTransferFrom(user, address(this), amountIn);
            }
            assetToken.safeTransfer(recipient, amountOut);

            reserveStable += amountIn;
            reserveAsset -= amountOut;
            accumulatedFeesStable += feeAmount;
        }

        if (
            !isOnBehalf && address(complianceRegistry) != address(0) && !hasRole(OPERATOR_ROLE, msg.sender)
                && !complianceRegistry.recordDailyVolume(user, volumeUSD)
        ) {
            revert PermissionedAMM__DailyLimitExceeded(user, complianceRegistry.getRemainingDailyLimit(user));
        }

        totalVolumeUSD += volumeUSD;
        totalSwapCount++;

        uint256 spotPriceAfter = getSpotPrice();
        uint256 actualSlippage;
        if (address(impactPolicy) != address(0)) {
            (, actualSlippage) = impactPolicy.validateImpact(amountIn, amountOut, spotPriceBefore, assetIn);
        }

        emit Swap(user, assetIn, amountIn, amountOut, feeAmount, spotPriceBefore, spotPriceAfter, actualSlippage);

        if (isOnBehalf) {
            emit SwapOnBehalf(user, msg.sender, assetIn, amountIn, amountOut);
        }

        return amountOut;
    }
}
