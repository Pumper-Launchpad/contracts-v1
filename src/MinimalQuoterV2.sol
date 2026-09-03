// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimalQuote {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice A from-scratch, single-purpose implementation of Uniswap
///         v3-periphery's `IQuoterV2.quoteExactInputSingle` -- the ONLY
///         quoter call this codebase makes (see App/src/config/quoterAbi.js
///         and TradePage.jsx's `quote?.[0]`, which is the only field of the
///         four the frontend actually reads: BuyPanel/SellPanel gate their
///         buy/sell buttons on `estimatedOut !== undefined`, so a missing or
///         broken quoter silently disables trading entirely -- see
///         Arc-testnet's own MinimalQuoterV2Adapter for the same lesson
///         learned there).
///
///         Unlike Arc testnet's adapter (which had to wrap UNITFLOW's
///         QuoterV1-shaped quoter into QuoterV2's struct shape), this one
///         talks directly to our own real, unmodified v3-core pools -- so it
///         reimplements the real QuoterV2's well-known "revert with the
///         result, catch it one frame up" trick directly against
///         `IUniswapV3Pool.swap`, using `factory.getPool` instead of
///         `v3-periphery`'s CREATE2 pool-address computation (avoids
///         depending on matching a hardcoded POOL_INIT_CODE_HASH, which this
///         repo doesn't need since it already has the real factory to ask).
///         Single-pool only -- no multi-hop path decoding, since nothing
///         here ever calls the multi-hop form.
///
///         `sqrtPriceX96After` is returned for interface compatibility;
///         `initializedTicksCrossed` and `gasEstimate` are NOT tracked (both
///         hardcoded to 0) since nothing in this codebase reads them --
///         only `amountOut` is load-bearing.
contract MinimalQuoterV2 {
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IUniswapV3FactoryMinimal public immutable factory;

    error UnexpectedRevertLength();
    error InvalidCallback();

    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    constructor(address factory_) {
        factory = IUniswapV3FactoryMinimal(factory_);
    }

    /// @notice Matches IQuoterV2.quoteExactInputSingle's signature exactly
    ///         (see App/src/config/quoterAbi.js) -- `nonpayable`, not `view`,
    ///         because the underlying trick genuinely writes and then
    ///         reverts pool state within the same call; callers (this
    ///         protocol's frontend included) invoke it via `eth_call`
    ///         (simulated, no real state change), same as the official
    ///         QuoterV2.
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        public
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        address pool = factory.getPool(params.tokenIn, params.tokenOut, params.fee);
        require(pool != address(0), "pool missing");

        uint256 gasBefore = gasleft();
        try IUniswapV3PoolMinimalQuote(pool).swap(
            address(this),
            zeroForOne,
            int256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(pool)
        ) {
            // A real quote always reverts from the callback below -- swap()
            // returning normally here means the pool had no liquidity to
            // move at all (amountOut == 0 by definition).
        } catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            (amountOut, sqrtPriceX96After) = _parseRevertReason(reason);
        }
        initializedTicksCrossed = 0;
    }

    /// @dev The pool calls back mid-`swap()` expecting payment; instead of
    ///      paying, this reverts with the swap's result ABI-encoded as the
    ///      revert reason, which `quoteExactInputSingle`'s try/catch above
    ///      decodes -- the real QuoterV2's exact technique, applied to a
    ///      single pool instead of a decoded multi-hop path.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external view {
        address pool = abi.decode(data, (address));
        if (msg.sender != pool) revert InvalidCallback();

        uint256 amountReceived = uint256(-(amount0Delta > 0 ? amount1Delta : amount0Delta));
        (uint160 sqrtPriceX96After,,,,,,) = IUniswapV3PoolMinimalQuote(pool).slot0();

        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountReceived)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            revert(ptr, 64)
        }
    }

    function _parseRevertReason(bytes memory reason) private pure returns (uint256 amount, uint160 sqrtPriceX96After) {
        if (reason.length != 64) revert UnexpectedRevertLength();
        (amount, sqrtPriceX96After) = abi.decode(reason, (uint256, uint160));
    }
}
