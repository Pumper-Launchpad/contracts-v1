// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20, INonfungiblePositionManager} from "./Interfaces.sol";
import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";

interface IUniswapV3FactoryMinimal {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3PoolMinimal {
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    function burn(int24 tickLower, int24 tickUpper, uint128 amount) external returns (uint256 amount0, uint256 amount1);

    function collect(address recipient, int24 tickLower, int24 tickUpper, uint128 amount0Requested, uint128 amount1Requested)
        external
        returns (uint128 amount0, uint128 amount1);
}

interface IERC721ReceiverMinimal {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

/// @notice A from-scratch, single-purpose implementation of
///         `INonfungiblePositionManager` -- `mint`, `collect`, and
///         `safeTransferFrom` are the ONLY position-manager calls
///         PumperProtocolLaunchpad makes (see its `_createPoolAndSeedLiquidity`
///         and fee-collection paths). Built for Arc mainnet, which -- unlike
///         every other chain this protocol runs on -- has no already-live,
///         reusable NonfungiblePositionManager to point at (see
///         DeployLaunchpadArcMainnetV1.s.sol's doc comment for how that was
///         established). Rather than vendor the official Uniswap
///         v3-periphery NonfungiblePositionManager -- which drags in
///         NFTDescriptor (a huge tokenURI-rendering library historically
///         bumping into the 24KB contract-size limit on its own), Multicall,
///         SelfPermit, and a full ERC-721 enumerable implementation, none of
///         which this protocol's launch/collect/lock flow ever touches, and
///         all pinned to solc 0.7.6 like v3-core itself -- this is the same
///         mint/collect/callback pattern trimmed to exactly what's called,
///         with real, verbatim Uniswap v3-core pools underneath (see
///         UniswapV3Factory.sol, deployed unmodified from
///         github.com/Uniswap/v3-core tag v1.0.0 in ./v3core-deploy/).
///
///         Deliberately NOT a general "any amount0Desired/amount1Desired"
///         position manager: the liquidity math below only implements the
///         two single-sided special cases (`getLiquidityForAmount0`/
///         `getLiquidityForAmount1` from Uniswap's own LiquidityAmounts.sol),
///         because every call site in this protocol always passes exactly
///         one of amount0Desired/amount1Desired as zero (a token-only
///         liquidity range -- see PumperProtocolLaunchpad's "seed liquidity"
///         and fee-reinvestment steps). A two-sided mint would need the full
///         `getLiquidityForAmounts` (min of both single-sided liquidities
///         plus current-price-in-range handling), which nothing here calls.
///
///         Also deliberately NOT a full ERC-721: no `approve`/
///         `getApproved`/`setApprovalForAll`/`ownerOf` enumeration,
///         `tokenURI`, or `supportsInterface`. `safeTransferFrom` (used to
///         hand a freshly minted position to a locker, when one is
///         configured) and a plain `positions(tokenId)` getter are all any
///         caller in this protocol needs; `owner` tracking and the
///         ERC-721-`safe` receiver check are still implemented properly
///         since a future locker deploy could depend on them.
contract MinimalPositionManager is INonfungiblePositionManager {
    IUniswapV3FactoryMinimal public immutable factory;

    uint256 private constant Q96 = 0x1000000000000000000000000;

    struct Position {
        address pool;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        address owner;
    }

    uint256 private _nextId = 1;
    mapping(uint256 => Position) public positions;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    error Expired();
    error PriceSlippage();
    error InvalidCallback();
    error NotOwner();
    error UnsafeRecipient();
    error ZeroAmounts();

    struct MintCallbackData {
        address token0;
        address token1;
        uint24 fee;
        address payer;
    }

    constructor(address factory_) {
        factory = IUniswapV3FactoryMinimal(factory_);
    }

    /// @dev Single-sided liquidity for a given amount of token0, holding the
    ///      price range [sqrtRatioAX96, sqrtRatioBX96] fixed. Verbatim formula
    ///      from Uniswap v3-periphery's LiquidityAmounts.getLiquidityForAmount0.
    function _liquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        private
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        uint256 liquidity = FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96);
        // Uniswap's own SafeCast.toUint128 reverts rather than truncate here --
        // an explicit `uint128(x)` cast in Solidity silently wraps on overflow
        // (unlike the checked +,-,*,/ operators), so this guard is load-bearing.
        require(liquidity <= type(uint128).max, "liquidity overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity);
    }

    /// @dev Single-sided liquidity for a given amount of token1. Verbatim
    ///      formula from LiquidityAmounts.getLiquidityForAmount1.
    function _liquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        private
        pure
        returns (uint128)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 liquidity = FullMath.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96);
        require(liquidity <= type(uint128).max, "liquidity overflow");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(liquidity);
    }

    /// @inheritdoc INonfungiblePositionManager
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert Expired();
        if (params.amount0Desired != 0 && params.amount1Desired != 0) revert ZeroAmounts();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        address pool = factory.getPool(params.token0, params.token1, params.fee);
        require(pool != address(0), "pool missing");

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(params.tickUpper);

        liquidity = params.amount0Desired != 0
            ? _liquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired)
            : _liquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, params.amount1Desired);

        (amount0, amount1) = IUniswapV3PoolMinimal(pool).mint(
            address(this),
            params.tickLower,
            params.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({token0: params.token0, token1: params.token1, fee: params.fee, payer: msg.sender}))
        );
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert PriceSlippage();

        tokenId = _nextId++;
        positions[tokenId] = Position({
            pool: pool,
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            owner: params.recipient
        });
        emit Transfer(address(0), params.recipient, tokenId);
    }

    /// @inheritdoc INonfungiblePositionManager
    /// @dev Same single-sided-only constraint as `mint` above, for the same
    ///      reason -- nothing in this protocol's launch/fee-reinvestment
    ///      flow ever calls this with both amounts nonzero, so the full
    ///      two-sided getLiquidityForAmounts isn't implemented here either.
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (block.timestamp > params.deadline) revert Expired();
        if (params.amount0Desired != 0 && params.amount1Desired != 0) revert ZeroAmounts();
        if (params.amount0Desired == 0 && params.amount1Desired == 0) revert ZeroAmounts();

        Position memory pos = positions[params.tokenId];
        require(pos.pool != address(0), "position missing");

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(pos.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(pos.tickUpper);

        liquidity = params.amount0Desired != 0
            ? _liquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, params.amount0Desired)
            : _liquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, params.amount1Desired);

        (amount0, amount1) = IUniswapV3PoolMinimal(pos.pool).mint(
            address(this),
            pos.tickLower,
            pos.tickUpper,
            liquidity,
            abi.encode(MintCallbackData({token0: pos.token0, token1: pos.token1, fee: pos.fee, payer: msg.sender}))
        );
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) revert PriceSlippage();
    }

    /// @dev Called by the pool mid-`mint()`, expecting this contract to pay in
    ///      whichever token(s) the position consumed. Re-derives the pool
    ///      address from the callback data rather than trusting msg.sender's
    ///      identity any other way -- same pattern as MinimalSwapRouter02's
    ///      swap callback, applied to mint instead.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        MintCallbackData memory cb = abi.decode(data, (MintCallbackData));
        address pool = factory.getPool(cb.token0, cb.token1, cb.fee);
        if (msg.sender != pool) revert InvalidCallback();

        if (amount0Owed > 0) require(IERC20(cb.token0).transferFrom(cb.payer, msg.sender, amount0Owed), "pay0");
        if (amount1Owed > 0) require(IERC20(cb.token1).transferFrom(cb.payer, msg.sender, amount1Owed), "pay1");
    }

    /// @inheritdoc INonfungiblePositionManager
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1) {
        Position memory pos = positions[params.tokenId];
        if (msg.sender != pos.owner) revert NotOwner();

        // Sync tokensOwed (fees accrued since the last touch) before collecting --
        // burn(0) is the standard V3 idiom for this, see IUniswapV3PoolActions.burn's
        // own doc: "Can be used to trigger a recalculation of fees owed ... by
        // calling with an amount of 0".
        IUniswapV3PoolMinimal(pos.pool).burn(pos.tickLower, pos.tickUpper, 0);

        (uint128 collected0, uint128 collected1) = IUniswapV3PoolMinimal(pos.pool).collect(
            params.recipient, pos.tickLower, pos.tickUpper, params.amount0Max, params.amount1Max
        );
        amount0 = collected0;
        amount1 = collected1;
    }

    /// @inheritdoc INonfungiblePositionManager
    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        Position storage pos = positions[tokenId];
        if (pos.owner != from) revert NotOwner();
        if (msg.sender != from) revert NotOwner();
        require(to != address(0), "to=0");

        pos.owner = to;
        emit Transfer(from, to, tokenId);

        if (to.code.length > 0) {
            try IERC721ReceiverMinimal(to).onERC721Received(msg.sender, from, tokenId, "") returns (bytes4 retval) {
                if (retval != IERC721ReceiverMinimal.onERC721Received.selector) revert UnsafeRecipient();
            } catch {
                revert UnsafeRecipient();
            }
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return positions[tokenId].owner;
    }
}
