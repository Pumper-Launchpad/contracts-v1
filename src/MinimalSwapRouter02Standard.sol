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

/// @notice Same trimmed `exactInputSingle`-only router as MinimalSwapRouter02
///         (see that file's doc comment for the full rationale), but calling
///         back under the STANDARD `uniswapV3SwapCallback` name instead of
///         UNITFLOW's renamed `unitFlowV3SwapCallback`. Pairs with real,
///         verbatim Uniswap v3-core pools (see MinimalPositionManager.sol and
///         DeployLaunchpadArcMainnetV1.s.sol) deployed from our own
///         UniswapV3Factory, which use the interface's real callback name --
///         reusing MinimalSwapRouter02 unmodified here would silently revert
///         every swap, exactly the bug that file's own doc comment warns a
///         "vanilla-Uniswap assumption" would cause on UNITFLOW.
contract MinimalSwapRouter02Standard is ISwapRouter02 {
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

    /// @dev Standard `uniswapV3SwapCallback` -- see MinimalSwapRouter02's own
    ///      callback for the security rationale (re-derive pool from data,
    ///      never trust msg.sender's identity any other way).
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        CallbackData memory cb = abi.decode(data, (CallbackData));
        address pool = factory.getPool(cb.tokenIn, cb.tokenOut, cb.fee);
        if (msg.sender != pool) revert InvalidCallback();

        bool tokenInIsToken0 = cb.tokenIn < cb.tokenOut;
        uint256 amountToPay = uint256(tokenInIsToken0 ? amount0Delta : amount1Delta);
        require(IERC20(cb.tokenIn).transferFrom(cb.payer, msg.sender, amountToPay), "pay pool");
    }
}
