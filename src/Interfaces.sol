// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IUniswapV3Pool {
    function initialize(uint160 sqrtPriceX96) external;
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    // Permissionless -- grows the pool's own oracle ring buffer. A no-op if
    // `observationCardinalityNext` is already >= the requested value.
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;

    // Reverts if any `secondsAgo` entry asks for more history than the pool
    // has actually recorded yet (see slot0's observationCardinality/Index).
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

    function observations(uint256 index)
        external
        view
        returns (
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint160 secondsPerLiquidityCumulativeX128,
            bool initialized
        );
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    // Unlike decreaseLiquidity/collect/burn, increaseLiquidity has no
    // isAuthorizedForToken check -- anyone can add liquidity to any
    // existing position by tokenId, funds pulled from msg.sender, the
    // resulting liquidity credited to whoever already owns the NFT. That's
    // what makes a one-sided top-up zapper for an existing position
    // possible without any approval/operator dance on the NFT itself.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice Standard Uniswap V2 router surface (DYORswap on Stable is a
///         verbatim fork) -- just the two functions any caller here has
///         needed so far.
interface IUniswapV2Router02 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Standard Uniswap V2 pair surface -- just what PumperLendingOracle
///         needs to run its own cumulative-price TWAP (see that contract's
///         own doc for why V2 needs this instead of V3's `observe()`).
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @notice A minimal LP-lock target. The launchpad transfers the position NFT here
///         so liquidity is permanently locked (or time-locked, per your locker).
interface ILiquidityLocker {
    function lock(address positionManager, uint256 tokenId, address owner) external;
}

/// @notice Minimal one-way view into PumperProtocolRegistry's owner, used by
///         PumperProtocolToken to gate `updateMetadata` on the registry's admin
///         specifically (not whichever launchpad happens to be current), so
///         admin control survives future launchpad redeploys.
interface IRegistryOwner {
    function owner() external view returns (address);
}

/// @notice Minimal view into RewardEligibilityRegistry -- see that contract's
///         own doc. PumperProtocolToken checks this as a fallback in
///         `isRewardEligible` for any address that isn't a plain EOA/7702
///         wallet, so an admin can approve (or revoke) a contract as reward-
///         eligible at any time without a token or launchpad redeploy.
interface IRewardEligibilityRegistry {
    function isEligible(address contractAddr) external view returns (bool);
}
