// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IImpactPolicy} from "./interfaces/IImpactPolicy.sol";

/**
 * @title ImpactPolicy
 * @notice Enforces price impact/slippage limits on swaps
 * @dev Uses tiered slippage limits based on trade size to protect users
 *
 * Trade-size bands default to $1k / $10k / $100k boundaries; the owner may change
 * these via setTierThresholds. Slippage caps per band are set via setSlippageLimits.
 */
contract ImpactPolicy is IImpactPolicy, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Defaults used at deploy (USD, 18 decimals)
    uint256 public constant DEFAULT_TIER_1_THRESHOLD = 1_000e18;
    uint256 public constant DEFAULT_TIER_2_THRESHOLD = 10_000e18;
    uint256 public constant DEFAULT_TIER_3_THRESHOLD = 100_000e18;

    /// @notice Upper bound (exclusive) of "small" band: tradeValueUSD < tier1ThresholdUSD → tier0 slippage cap
    uint256 public tier1ThresholdUSD;

    /// @notice Upper bound (exclusive) of "medium" band
    uint256 public tier2ThresholdUSD;

    /// @notice Upper bound (exclusive) of "large" band; ≥ this uses tier3 cap until whale tier
    uint256 public tier3ThresholdUSD;

    /// @notice Maximum slippage per tier in basis points (1 bp = 0.01%)
    uint256 public tier0MaxSlippage = 300; // 3.00% for trades < $1k
    uint256 public tier1MaxSlippage = 200; // 2.00% for trades $1k-$10k
    uint256 public tier2MaxSlippage = 100; // 1.00% for trades $10k-$100k
    uint256 public tier3MaxSlippage = 50; // 0.50% for trades > $100k

    /// @notice Emergency pause flag
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when slippage limits are updated
    event SlippageLimitsUpdated(uint256 tier0, uint256 tier1, uint256 tier2, uint256 tier3);

    /// @notice Emitted when USD tier boundaries are updated
    event TierThresholdsUpdated(uint256 tier1ThresholdUSD, uint256 tier2ThresholdUSD, uint256 tier3ThresholdUSD);

    /// @notice Emitted when policy is paused/unpaused
    event PauseStatusChanged(bool paused);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ImpactPolicy__PolicyPaused();
    error ImpactPolicy__InvalidSlippageLimits();
    error ImpactPolicy__InvalidThresholds();
    error ImpactPolicy__SlippageExceeded(uint256 actual, uint256 maximum);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address admin) Ownable(admin) {
        tier1ThresholdUSD = DEFAULT_TIER_1_THRESHOLD;
        tier2ThresholdUSD = DEFAULT_TIER_2_THRESHOLD;
        tier3ThresholdUSD = DEFAULT_TIER_3_THRESHOLD;
    }

    /*//////////////////////////////////////////////////////////////
                     USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the slippage limits for each tier
     * @param _tier0 New limit for trades < $1k (basis points)
     * @param _tier1 New limit for trades $1k-$10k (basis points)
     * @param _tier2 New limit for trades $10k-$100k (basis points)
     * @param _tier3 New limit for trades > $100k (basis points)
     */
    function setSlippageLimits(uint256 _tier0, uint256 _tier1, uint256 _tier2, uint256 _tier3) external onlyOwner {
        if (_tier0 < _tier1 || _tier1 < _tier2 || _tier2 < _tier3) {
            revert ImpactPolicy__InvalidSlippageLimits();
        }
        if (_tier0 > 1000) revert ImpactPolicy__InvalidSlippageLimits();

        tier0MaxSlippage = _tier0;
        tier1MaxSlippage = _tier1;
        tier2MaxSlippage = _tier2;
        tier3MaxSlippage = _tier3;

        emit SlippageLimitsUpdated(_tier0, _tier1, _tier2, _tier3);
    }

    /**
     * @notice Pauses or unpauses the policy
     * @param _paused New pause state
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /**
     * @notice Sets USD boundaries between trade-size bands (18 decimals). Must satisfy 0 < t1 < t2 < t3.
     * @dev Bands: [<t1) tier0 max slippage, [t1,t2) tier1, [t2,t3) tier2, [t3,∞) tier3.
     */
    function setTierThresholds(uint256 tier1USD, uint256 tier2USD, uint256 tier3USD) external onlyOwner {
        if (tier1USD == 0 || tier2USD == 0 || tier3USD == 0) revert ImpactPolicy__InvalidThresholds();
        if (!(tier1USD < tier2USD && tier2USD < tier3USD)) revert ImpactPolicy__InvalidThresholds();

        tier1ThresholdUSD = tier1USD;
        tier2ThresholdUSD = tier2USD;
        tier3ThresholdUSD = tier3USD;

        emit TierThresholdsUpdated(tier1USD, tier2USD, tier3USD);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates that a swap doesn't exceed the maximum allowed slippage
     * @param amountIn The input amount (in token decimals)
     * @param amountOut The actual output amount (in token decimals)
     * @param spotPrice The current spot price before swap (scaled by 1e18)
     * @param isAssetInput True if Asset token is the input (selling Asset)
     * @return valid True if the swap passes the impact check
     * @return slippageBps The calculated slippage in basis points
     */
    function validateImpact(uint256 amountIn, uint256 amountOut, uint256 spotPrice, bool isAssetInput)
        external
        view
        override
        returns (bool valid, uint256 slippageBps)
    {
        if (paused) revert ImpactPolicy__PolicyPaused();

        uint256 expectedOut;
        if (isAssetInput) {
            expectedOut = (amountIn * spotPrice) / 1e18;
        } else {
            expectedOut = (amountIn * 1e18) / spotPrice;
        }

        if (amountOut >= expectedOut) {
            return (true, 0);
        }

        slippageBps = ((expectedOut - amountOut) * 10000) / expectedOut;

        uint256 tradeValueUSD;
        if (isAssetInput) {
            tradeValueUSD = (amountIn * spotPrice) / 1e18;
        } else {
            tradeValueUSD = amountIn;
        }

        uint256 maxSlippage = getMaxSlippage(tradeValueUSD);
        valid = slippageBps <= maxSlippage;

        return (valid, slippageBps);
    }

    /**
     * @notice Gets the maximum allowed slippage for a given trade size
     * @param tradeValueUSD The trade value in USD (18 decimals)
     * @return maxSlippageBps Maximum allowed slippage in basis points
     */
    function getMaxSlippage(uint256 tradeValueUSD) public view override returns (uint256 maxSlippageBps) {
        if (tradeValueUSD < tier1ThresholdUSD) {
            return tier0MaxSlippage;
        } else if (tradeValueUSD < tier2ThresholdUSD) {
            return tier1MaxSlippage;
        } else if (tradeValueUSD < tier3ThresholdUSD) {
            return tier2MaxSlippage;
        } else {
            return tier3MaxSlippage;
        }
    }
}
