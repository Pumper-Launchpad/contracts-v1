// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20, ISwapRouter02} from "./Interfaces.sol";

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimal {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @notice A from-scratch, single-purpose implementation of `ISwapRouter02`'s
///         `exactInputSingle` -- the ONLY router function PumperProtocolLaunchpad
///         calls (see its buy/sell/_swapWethToUsdgAndDeposit). Built for chains
///         whose only available Uniswap V3 deployment ships a V1-style
///         SwapRouter (with a `deadline` param) rather than SwapRouter02: rather
///         than pull in the official SwapRouter02's full dependency tree (V2
///         routing, Multicall, SelfPermit, ApproveAndCall -- none of which this
///         protocol uses, and all pinned to an older solc than this repo's
///         0.8.30), this is the same well-known Uniswap V3 swap+callback
///         pattern used by Uniswap's own reference router, trimmed to exactly
///         the one code path this protocol needs.
///
///         NOT generic across "any V3 fork" -- it targets Arc testnet's real
///         UNITFLOW V3 deployment specifically, whose pools call back under a
///         renamed `unitFlowV3SwapCallback` rather than the standard
///         `uniswapV3SwapCallback` (discovered by fork-testing against it, see
///         test/ArcMinimalSwapRouterFork.t.sol -- a vanilla-Uniswap assumption
///         here would have silently reverted every real swap). Pointing this
///         same contract at a genuinely standard V3 fork elsewhere would need
///         that callback name changed back.
///
///         Deliberately does NOT support exactOutputSingle, multi-hop paths,
///         V2 fallback routing, or a deadline parameter -- adding any of those
///         back is exactly re-deriving SwapRouter02, at which point vendoring
///         the real one becomes the better trade-off.
contract MinimalSwapRouter02 is ISwapRouter02 {
    // Same MIN/MAX sqrt-ratio constants as Uniswap v3-core's TickMath -- a
    // caller passing sqrtPriceLimitX96 == 0 (i.e. "no limit", the value every
    // call site in this protocol uses) needs a real bound one tick inside
    // the valid range in whichever direction the swap moves price, since the
    // pool itself requires a nonzero, in-range limit.
    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    IUniswapV3FactoryMinimal public immutable factory;

    error TooLittleReceived();
    error InvalidCallback();

    struct CallbackData {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address payer;
    }

    constructor(address factory_) {
        factory = IUniswapV3FactoryMinimal(factory_);
    }

    /// @inheritdoc ISwapRouter02
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        address pool = factory.getPool(params.tokenIn, params.tokenOut, params.fee);

        (int256 amount0, int256 amount1) = IUniswapV3PoolMinimal(pool).swap(
            params.recipient,
            zeroForOne,
            int256(params.amountIn),
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(CallbackData({tokenIn: params.tokenIn, tokenOut: params.tokenOut, fee: params.fee, payer: msg.sender}))
        );

        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    /// @dev Called by the pool mid-`swap()`, expecting this contract to pay in
    ///      whichever token the swap consumed. Re-derives the pool address
    ///      from the callback data instead of trusting msg.sender's identity
    ///      any other way -- the ONLY thing standing between "pull tokens
    ///      from whoever approved this router" and an attacker calling this
    ///      function directly to drain an arbitrary payer's approval.
    ///
    ///      Named `unitFlowV3SwapCallback`, NOT the standard
    ///      `uniswapV3SwapCallback` -- confirmed against Arc testnet's real,
    ///      live UNITFLOW V3 pools (test/ArcMinimalSwapRouterFork.t.sol),
    ///      whose pools call back under this exact name instead. A pool built
    ///      against vanilla Uniswap v3-core would never reach this function at
    ///      all (it calls the standard name), so this router is UNITFLOW-V3
    ///      specific, not a generic "any V3 fork" router.
    function unitFlowV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        CallbackData memory cb = abi.decode(data, (CallbackData));
        address pool = factory.getPool(cb.tokenIn, cb.tokenOut, cb.fee);
        if (msg.sender != pool) revert InvalidCallback();

        bool tokenInIsToken0 = cb.tokenIn < cb.tokenOut;
        uint256 amountToPay = uint256(tokenInIsToken0 ? amount0Delta : amount1Delta);
        require(IERC20(cb.tokenIn).transferFrom(cb.payer, msg.sender, amountToPay), "pay pool");
    }
}
