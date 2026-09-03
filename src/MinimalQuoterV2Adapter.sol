// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IQuoterV1Minimal {
    function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96)
        external
        returns (uint256 amountOut);
}

/// @notice Adapts Arc testnet's real UNITFLOW V3 Quoter -- QuoterV1-shaped
///         (flat args: tokenIn, tokenOut, fee, amountIn, sqrtPriceLimitX96;
///         confirmed live via `cast call`, see the deploy script's own
///         comment) -- to the QuoterV2 struct-shaped interface this
///         codebase's frontend hardcodes (App/src/config/quoterAbi.js).
///
///         Every call site that reads this router's output only ever reads
///         index [0] (`amountOut` -- see useQuote.js's `quote?.[0]`), so
///         `sqrtPriceX96After`/`initializedTicksCrossed`/`gasEstimate` are
///         returned as zero rather than genuinely computed; they exist only
///         to satisfy the struct's shape, not because anything reads them.
///         If that ever changes, this adapter needs those fields computed
///         for real, not just the amountOut passthrough.
///
///         Like MinimalSwapRouter02, this is nonpayable rather than view --
///         matches the real QuoterV2's own ABI shape (which relies on
///         eth_call/simulation rather than a genuine view call), and the
///         underlying UNITFLOW quoter itself is nonpayable too.
contract MinimalQuoterV2Adapter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    IQuoterV1Minimal public immutable quoterV1;

    constructor(address quoterV1_) {
        quoterV1 = IQuoterV1Minimal(quoterV1_);
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut, uint160, uint32, uint256)
    {
        amountOut = quoterV1.quoteExactInputSingle(
            params.tokenIn, params.tokenOut, params.fee, params.amountIn, params.sqrtPriceLimitX96
        );
    }
}
