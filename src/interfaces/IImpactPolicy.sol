// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title IImpactPolicy
 * @notice Interface for the impact/slippage policy checker
 */
interface IImpactPolicy {
    /// @notice Validates that a swap doesn't exceed the maximum allowed slippage
    /// @param amountIn The input amount
    /// @param amountOut The actual output amount
    /// @param spotPrice The current spot price (scaled by 1e18)
    /// @param isAssetInput True if Asset token is the input
    /// @return valid True if the swap passes the impact check
    /// @return slippageBps The calculated slippage in basis points
    function validateImpact(uint256 amountIn, uint256 amountOut, uint256 spotPrice, bool isAssetInput)
        external
        view
        returns (bool valid, uint256 slippageBps);

    /// @notice Gets the maximum allowed slippage for a given trade size
    /// @param tradeValueUSD The trade value in USD (18 decimals)
    /// @return maxSlippageBps Maximum allowed slippage in basis points
    function getMaxSlippage(uint256 tradeValueUSD) external view returns (uint256 maxSlippageBps);
}

