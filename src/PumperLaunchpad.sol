// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {
    IERC20,
    IWETH,
    IUniswapV3Factory,
    IUniswapV3Pool,
    INonfungiblePositionManager,
    ISwapRouter02,
    ILiquidityLocker
} from "./Interfaces.sol";
import {PumperToken} from "./PumperToken.sol";
import {PumperTokenFactory} from "./PumperTokenFactory.sol";
import {PumperRewardLocker} from "./PumperRewardLocker.sol";
import {PumperProtocolRegistry} from "./PumperProtocolRegistry.sol";
import {TickMath} from "./TickMath.sol";

/// @title PumperLaunchpad
/// @notice Front-door router + factory, next generation. Every launch: deploys
///         a token, creates a Uniswap V3 pool at a fixed 1% fee tier, seeds
///         one-sided token liquidity across a 60/40 launch/continuation split
///         (RESERVE_BPS) sized to graduate smoothly, and locks the LP position.
///         Buys/sells are plain swap pass-throughs -- there is no separate
///         creator fee, or per-trade burn/reward skim. ALL protocol/reward
///         revenue comes from the pool's own native 1% swap fee (earned on
///         every trade, including ones that bypass this router entirely),
///         harvested via `collectLpFees`: the token-side fee (sell-side volume)
///         is burned permanently, and the WETH-side fee (buy-side volume)
///         splits four ways, fixed and hardcoded, no admin dial --
///         ADMIN_VAULT_BPS (10%) to `adminVault`, FEFER_VAULT_BPS (5%) to
///         `feferVault`, PUMPER_VAULT_BPS (5%) to `pumperVault`, the remaining
///         80% into the token's reward locker.
///
///         What changed from `PumperProtocolLaunchpad`:
///           * The launched token is a plain OpenZeppelin ERC-20
///             (`PumperToken`) -- no custom `_transfer`, no per-holder reward
///             checkpoint, no `tokenLock` field, no fee/pause/blacklist hooks.
///             `transfer(self, x)` is an exact no-op, closing the aliasing
///             class the old hand-rolled `_transfer` got wrong.
///           * Rewards are NOT paid per balance. Each token deploys its own
///             `PumperRewardLocker` in its constructor; this launchpad routes
///             the reward share into `PumperToken.rewardLocker()` via
///             `depositReward`, and it streams to accounts that have STAKED
///             (a.k.a. "locked") that token there. While nothing is staked,
///             the locker forwards deposits straight to the token's `creator`
///             (its fallback recipient) -- no balance-weighted accrual to
///             misaccount, no backlog for a 1-wei staker to sweep.
///           * Socials/logo/description stay updatable post-launch via
///             `PumperToken.updateMetadata`, gated on the REGISTRY owner (so it
///             keeps working across a launchpad redeploy). `name`/`symbol` are
///             immutable.
contract PumperLaunchpad {
    // ---------------------------------------------------------------- infra //
    IWETH public immutable WETH;
    IERC20 public immutable USDG;
    IUniswapV3Factory public immutable v3Factory;
    INonfungiblePositionManager public immutable positionManager;
    ISwapRouter02 public immutable swapRouter;
    ILiquidityLocker public immutable locker;
    PumperTokenFactory public immutable tokenFactory; // isolates token creation code (EIP-170)
    PumperProtocolRegistry public immutable registry; // permanent token directory, survives launchpad redeploys

    // Arc mainnet only: native gas balance and the real USDC ERC20 balance at
    // `WETH`/`USDG` are the SAME balance, synced by the chain itself -- confirmed
    // on-chain 2026-08-08 (a real transfer() on Arc's USDC moved the sender's
    // native balance too, with zero `deposit`/`withdraw` involved anywhere).
    // `WETH` there is real Circle USDC, which has no deposit()/withdraw() at all --
    // calling either always reverts. Everywhere else, WETH is a real wrap contract
    // and those calls are required. Derived from chainid rather than a constructor
    // arg: it's a fixed fact about a chain's own token semantics, not a per-deploy
    // choice, so there's nothing for a deploy script to accidentally get wrong.
    uint256 private constant ARC_MAINNET_CHAIN_ID = 5042;
    bool public immutable NATIVE_IS_QUOTE_TOKEN;

    // Only meaningful when NATIVE_IS_QUOTE_TOKEN -- native currency is always
    // 18-decimal by EVM convention, but the real ERC20 mirrored to it isn't
    // guaranteed to match (Arc's real USDC is 6dp). Read once at deploy time
    // via `decimals()`. Defaults to 18 everywhere else, making
    // `_nativeToQuoteAmount`/`_quoteToNativeAmount` below a no-op on every
    // other chain -- callable unconditionally, no extra branching needed.
    uint8 public immutable nativeQuoteTokenDecimals;

    uint24 public immutable usdgFeeTier; // fee tier of the WETH/USDG pool used to swap fee skim

    address public owner;

    /// @notice Where the protocol's flat deploy-fee revenue lands.
    /// @dev    Deliberately separate from `owner`: `owner` is the admin key
    ///         that controls the contract, `protocolFeeRecipient` is just a
    ///         payment destination -- letting the admin redirect protocol
    ///         revenue to a dedicated treasury/multisig without ever handing
    ///         out admin control of the launchpad itself. Defaults to the
    ///         deployer at construction, owner-adjustable anytime after via
    ///         `setProtocolFeeRecipient`.
    ///
    ///         Does NOT receive any part of `collectLpFees`'s harvest -- that
    ///         pays `adminVault`/`feferVault`/`pumperVault` and the token's
    ///         reward locker, see ADMIN_VAULT_BPS's doc.
    address public protocolFeeRecipient;

    uint16 public constant BPS = 10_000;

    // Every pool always uses this fee tier -- not creator- or even admin-configurable.
    uint24 public constant FEE_TIER = 10_000; // 1%

    /// @notice Fixed split of every harvested LP-position WETH-side fee (see
    ///         `collectLpFees`): ADMIN_VAULT_BPS to `adminVault`,
    ///         FEFER_VAULT_BPS to `feferVault`, PUMPER_VAULT_BPS to
    ///         `pumperVault`, and the remainder (80%) into the token's reward
    ///         locker -- same four-way cut for every token, hardcoded, no admin
    ///         dial.
    uint16 public constant ADMIN_VAULT_BPS = 1_000; // 10% -- protocol
    uint16 public constant FEFER_VAULT_BPS = 500; // 5% -- FEFER
    uint16 public constant PUMPER_VAULT_BPS = 500; // 5% -- PUMPER

    /// @notice Market cap a token graduates at, denominated in the PAIRING
    ///         asset — ETH on an ETH-paired chain, WgUSDT on Stable.
    /// @dev    Set in the constructor, not defaulted. A hardcoded ETH-calibrated
    ///         default silently produced a ~$15.79 target on Stable (where the
    ///         pairing asset is a $1 stablecoin). Making it a required
    ///         constructor argument means a deployment cannot forget to state it.
    uint256 public targetGraduationMcapWeth;

    // How much WETH raising should take to fully traverse the one-sided range (i.e.
    // roughly coincide with graduation). Both this AND the market cap above must be
    // real, non-extreme prices -- the WETH needed to fully drain a one-sided
    // position scales with sqrt(startPrice * endPrice), so anchoring startPrice at
    // Uniswap's extreme edge (near zero) makes that product near-zero regardless of
    // endPrice, letting a tiny trade blow through the entire position (the
    // 2026-07-23 incident). Solving for a real startPrice here, not just the end
    // price, is what actually fixes it.
    /// @notice Pairing-asset raise a token graduates at. Same units, same
    ///         reasoning as targetGraduationMcapWeth above.
    uint256 public graduationTargetWeth;

    // Flat ETH fee taken on launch(), paid straight to protocolFeeRecipient. The
    // remainder of msg.value (msg.value - deployFeeWei) funds the optional creator
    // initial buy. Admin-adjustable anytime; default 0 (no fee) until set.
    uint256 public deployFeeWei = 0;

    // ---------------------------------------------------------------- state //
    struct Launch {
        address token;
        address creator;
        address pool;
        uint256 tokenId; // LP position NFT
        uint24 feeTier; // always FEE_TIER
        bool live;
        uint256 graduationThreshold; // snapshotted from graduationTargetWeth at launch
        uint256 pairedPrincipal; // cumulative WETH ever paired in via buys (monotonic)
        bool graduated; // sticky once pairedPrincipal >= threshold; never resets
    }

    // --------------------------------------------- post-graduation reserve //

    /// @notice Share of supply reserved for the continuation range, in bps.
    /// @dev    60/40 launch/continuation split. The launch-range price curve
    ///         below is already parameterised by
    ///         `tokensForLiquidity = TOTAL_SUPPLY - reserved`, so it reshapes
    ///         consistently with whatever this is set to; no other math
    ///         depends on the specific split.
    uint16 public constant RESERVE_BPS = 4_000; // 40%

    /// @notice LP NFT of the continuation position that sits above the launch
    ///         range. Minted in the SAME transaction as the launch -- spot
    ///         starts at the bottom, so both ranges are above it and both are
    ///         single-sided token, and the reserve is never held as a
    ///         spendable balance.
    mapping(address => uint256) public continuationTokenId;

    // ------------------------------------------------------- reward routing //

    /// @notice A wallet that receives part of a token's non-locker reward share.
    struct Recipient {
        address to;
        uint16 bps;
    }

    /// @notice Share of a token's reward pot that flows to its LOCKER (and
    ///         thence to accounts staked there, or to the creator while none
    ///         are), in bps.
    /// @dev    The remainder goes to `payoutRecipients`, or to the creator when
    ///         that list is empty. Defaults to DEFAULT_HOLDER_SHARE_BPS at
    ///         launch.
    ///
    ///         This is the creator's dial, set at launch and changeable after.
    ///         It is deliberately NOT locked: the creator asked to be able to
    ///         add and remove wallets later, which means buyers must treat the
    ///         current split as the current split and nothing more. The
    ///         PayoutChanged event exists so a UI can show them when it moves.
    mapping(address => uint16) public holderShareBps;

    /// @notice Where a token's non-locker share goes, by weight.
    mapping(address => Recipient[]) public payoutRecipients;

    uint16 public constant DEFAULT_HOLDER_SHARE_BPS = 10_000; // launches route the full reward pot to the locker unless changed
    uint8 public constant MAX_RECIPIENTS = 10; // bounds gas in collectLpFees

    event PayoutChanged(address indexed token, uint16 holderShareBps, uint256 recipients);

    // token => launch
    mapping(address => Launch) public launches;
    address[] public allTokens;

    event CreatorSetByAdmin(address indexed token, address indexed previousCreator, address indexed newCreator);

    // ---------------------------------------------------------------- events //
    event Launched(address indexed token, address indexed creator, address pool, uint256 tokenId, uint24 feeTier);
    event Bought(address indexed token, address indexed buyer, uint256 wethIn, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, uint256 tokensIn, uint256 wethOut);
    event LpFeesCollected(
        address indexed token,
        uint256 amount0,
        uint256 amount1,
        uint256 tokenBurned,
        uint256 rewardUsdg,
        uint256 adminWeth,
        uint256 feferWeth,
        uint256 pumperWeth
    );
    event Graduated(address indexed token, uint256 pairedPrincipal);

    // ---------------------------------------------------------------- errors //
    error NotOwner();
    error NotLive();
    error ZeroAddress();
    error BadParams();
    error NotCreator();
    error Slippage();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice The three WETH-side fee sinks, paid their fixed cut in
    ///         `collectLpFees` -- see ADMIN_VAULT_BPS/FEFER_VAULT_BPS/
    ///         PUMPER_VAULT_BPS above for what each is paid. Fixed for the
    ///         lifetime of this launchpad version: a new launchpad version
    ///         carries new addresses; tokens launched from here keep pointing
    ///         at these (they are read from this contract at harvest time, and
    ///         this contract is immutable).
    address public immutable adminVault;
    address public immutable feferVault;
    address public immutable pumperVault;

    constructor(
        address _weth,
        address _usdg,
        address _v3Factory,
        address _positionManager,
        address _swapRouter,
        address _locker,
        address _tokenFactory,
        address _registry,
        uint24 _usdgFeeTier,
        uint256 _targetGraduationMcap,
        uint256 _graduationTarget,
        address _adminVault,
        address _feferVault,
        address _pumperVault
    ) {
        if (
            _weth == address(0) || _usdg == address(0) || _v3Factory == address(0) || _positionManager == address(0)
                || _swapRouter == address(0) || _tokenFactory == address(0) || _registry == address(0)
                || _adminVault == address(0) || _feferVault == address(0) || _pumperVault == address(0)
        ) revert ZeroAddress();
        // Zero here would make every launch graduate instantly.
        if (_targetGraduationMcap == 0 || _graduationTarget == 0) revert BadParams();

        WETH = IWETH(_weth);
        USDG = IERC20(_usdg);
        v3Factory = IUniswapV3Factory(_v3Factory);
        positionManager = INonfungiblePositionManager(_positionManager);
        swapRouter = ISwapRouter02(_swapRouter);
        locker = ILiquidityLocker(_locker); // may be address(0) if you burn/hold the NFT
        tokenFactory = PumperTokenFactory(_tokenFactory);
        registry = PumperProtocolRegistry(_registry);
        usdgFeeTier = _usdgFeeTier;
        targetGraduationMcapWeth = _targetGraduationMcap;
        graduationTargetWeth = _graduationTarget;
        adminVault = _adminVault;
        feferVault = _feferVault;
        pumperVault = _pumperVault;
        owner = msg.sender;
        protocolFeeRecipient = msg.sender; // defaults to owner; redirect anytime via setProtocolFeeRecipient
        NATIVE_IS_QUOTE_TOKEN = block.chainid == ARC_MAINNET_CHAIN_ID;
        nativeQuoteTokenDecimals = NATIVE_IS_QUOTE_TOKEN ? IERC20(_weth).decimals() : 18;
    }

    /// @dev Native currency is always 18-decimal by EVM convention; the real
    ///      ERC20 mirrored to it on a NATIVE_IS_QUOTE_TOKEN chain isn't
    ///      guaranteed to match. Converts a raw native amount into the
    ///      equivalent amount in that ERC20's own units. No-op everywhere
    ///      `nativeQuoteTokenDecimals == 18` (i.e. every chain except Arc).
    function _nativeToQuoteAmount(uint256 nativeAmount) internal view returns (uint256) {
        if (nativeQuoteTokenDecimals == 18) return nativeAmount;
        return nativeAmount / (10 ** (18 - nativeQuoteTokenDecimals));
    }

    /// @dev Inverse of `_nativeToQuoteAmount` -- converts an amount already
    ///      in the real ERC20's own units back into native-currency (18dp)
    ///      terms, for sending via a plain native value transfer.
    function _quoteToNativeAmount(uint256 quoteAmount) internal view returns (uint256) {
        if (nativeQuoteTokenDecimals == 18) return quoteAmount;
        return quoteAmount * (10 ** (18 - nativeQuoteTokenDecimals));
    }

    // =================================================================== //
    //                               LAUNCH                                //
    // =================================================================== //

    struct LaunchParams {
        string name;
        string symbol;
        string description;
        string image; // ipfs://<CID> logo pointer, stored on-chain
        string twitter; // full URL, empty string if unset
        string telegram;
        string website;
        /// Set true to honour `holderShareBps` verbatim, including 0. Left
        /// false, the launch takes DEFAULT_HOLDER_SHARE_BPS instead.
        ///
        /// This flag exists because 0 is a legitimate choice AND the value an
        /// omitted field decodes to. Without it, "route nothing to the locker"
        /// and "a client that didn't set the field" are indistinguishable, and
        /// the share is permanent -- so guessing wrong is unfixable.
        bool setRewardSplit;
        /// Share of THIS token's reward pot routed to its locker, in bps. The
        /// remainder goes to `payoutRecipients` (or the creator if empty).
        /// FIXED AT LAUNCH -- there is no setter.
        uint16 holderShareBps;
        /// Wallets splitting the non-locker share. Weights must total BPS.
        /// Empty means "pay the creator directly".
        Recipient[] payoutRecipients;
        // Total supply, liquidity share (always 100%), pool fee tier (always
        // FEE_TIER), and the anti-bundler cap are NOT creator-configurable -- fixed
        // protocol constants / admin-only defaults applied to every launch
        // uniformly, so calling launch() directly can't set arbitrary values
        // either. There is no separate creator fee, burn, or per-trade reward skim
        // -- see contract-level notice.
    }

    // Every launch mints exactly this many tokens (18 decimals) -- not creator- or
    // even admin-configurable.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    /// @dev Smallest multiple of `spacing` that is >= `tick`.
    function _ceilToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        if (mod != 0 && tick > 0) return tick + spacing - mod;
        return tick - mod;
    }

    /// @dev Largest multiple of `spacing` that is <= `tick`.
    function _floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 mod = tick % spacing;
        if (mod != 0 && tick < 0) return tick - spacing - mod;
        return tick - mod;
    }

    /// @dev Standard Babylonian integer square root (floor).
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Tick at which one whole token (1e18 units) is worth `priceWei` wei of
    ///      WETH, given whether the new token is token0 or token1. Both tokens are
    ///      18 decimals, so the raw price ratio is exactly `priceWei / 1e18` (or its
    ///      reciprocal). Clamped to Uniswap's valid sqrt-ratio bounds since
    ///      `getTickAtSqrtRatio` reverts outside them.
    function _tickForPrice(uint256 priceWei, bool tokenIsToken0) internal pure returns (int24) {
        uint256 pendWei = priceWei == 0 ? 1 : priceWei;
        uint256 Q96 = 1 << 96;
        uint256 sqrtP;
        if (tokenIsToken0) {
            // price (token1/token0 = WETH/token) = pendWei / 1e18
            sqrtP = (_sqrt(pendWei) * Q96) / 1e9;
        } else {
            // price (token1/token0 = token/WETH) = 1e18 / pendWei
            sqrtP = (1e9 * Q96) / _sqrt(pendWei);
        }
        if (sqrtP <= TickMath.MIN_SQRT_RATIO) sqrtP = TickMath.MIN_SQRT_RATIO + 1;
        if (sqrtP >= TickMath.MAX_SQRT_RATIO) sqrtP = TickMath.MAX_SQRT_RATIO - 1;
        return TickMath.getTickAtSqrtRatio(uint160(sqrtP));
    }

    /// @notice Deploy a token, create + initialize its V3 pool, seed one-sided
    ///         (token-only) liquidity anchored at the extreme edge of the valid tick
    ///         range, and lock the position NFT.
    /// @dev The token always starts at the most extreme valid price (effectively
    ///      zero value) regardless of whether it lands as token0 or token1 relative
    ///      to WETH -- that ordering isn't knowable before the transaction lands (it
    ///      depends on the deployed token address), so the anchor is picked on-chain
    ///      after the token exists, using TickMath directly rather than a
    ///      creator-supplied price. Real price is discovered entirely by buys
    ///      consuming the one-sided range from there.
    function launch(LaunchParams calldata p) external payable returns (address token) {
        // Launch shape is fixed by protocol constants/admin-only defaults, not the
        // caller: fixed total supply, always 100% of it as liquidity, always
        // FEE_TIER (1%).
        uint256 reserved = (TOTAL_SUPPLY * RESERVE_BPS) / BPS;
        uint256 tokensForLiquidity = TOTAL_SUPPLY - reserved;

        int24 spacing = 200; // tick spacing for FEE_TIER (1%)

        // 1) deploy token (CREATE2 so addresses are pre-computable, as in the ref)
        bytes32 salt = keccak256(abi.encode(msg.sender, p.name, p.symbol, block.number));
        PumperToken.InitParams memory tp = PumperToken.InitParams({
            name: p.name,
            symbol: p.symbol,
            description: p.description,
            image: p.image,
            twitter: p.twitter,
            telegram: p.telegram,
            website: p.website,
            totalSupply: TOTAL_SUPPLY,
            creator: msg.sender,
            weth: address(WETH),
            v3Factory: address(v3Factory),
            feeTier: FEE_TIER,
            launchpad: address(this),
            registry: address(registry),
            rewardToken: address(USDG)
        });
        token = tokenFactory.createToken(tp, salt);

        // 2) create + initialize the pool, anchored one-sided per token0/token1 order
        address pool = v3Factory.getPool(token, address(WETH), FEE_TIER);
        if (pool == address(0)) {
            pool = v3Factory.createPool(token, address(WETH), FEE_TIER);
        }

        (address token0, address token1) = token < address(WETH) ? (token, address(WETH)) : (address(WETH), token);

        // Both bounds of the one-sided range are sized to REAL prices -- not
        // Uniswap's extreme representable edge, which made the WETH needed to fully
        // drain the position near-zero regardless of the far bound (see the
        // 2026-07-23 incident). Solved so that raising ~graduationTargetWeth of WETH
        // roughly coincides with fully consuming tokensForLiquidity:
        //   pUpper = target market cap / totalSupply
        //   pLower = (graduationTargetWeth * 1e18 / tokensForLiquidity)^2 / pUpper
        uint256 pUpper = (targetGraduationMcapWeth * 1e18) / TOTAL_SUPPLY;
        uint256 kTerm = (graduationTargetWeth * 1e18) / tokensForLiquidity;
        uint256 pLower = (kTerm * kTerm) / pUpper;
        if (pLower == 0) pLower = 1;
        if (pLower >= pUpper) pLower = pUpper / 2; // defensive: keep a real range on extreme inputs

        int24 tickLower;
        int24 tickUpper;
        uint160 initSqrtPriceX96;
        if (token0 == token) {
            // new token is token0: start at pLower, range extends up to pUpper.
            int24 anchor = _ceilToSpacing(_tickForPrice(pLower, true), spacing);
            tickLower = anchor + spacing;
            tickUpper = _ceilToSpacing(_tickForPrice(pUpper, true), spacing);
            if (tickUpper <= tickLower) tickUpper = tickLower + spacing;
            int24 maxTick = _floorToSpacing(TickMath.MAX_TICK, spacing);
            if (tickUpper > maxTick) tickUpper = maxTick;
            initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(anchor);
        } else {
            // WETH is token0, new token is token1: start at pLower (a high tick,
            // since cheap token1 means a large token/WETH ratio), range extends down
            // to pUpper. Guard the absolute ceiling: getSqrtRatioAtTick(MAX_TICK)
            // returns exactly MAX_SQRT_RATIO, but pool.initialize() requires strictly
            // less than that.
            int24 anchor = _floorToSpacing(_tickForPrice(pLower, false), spacing);
            int24 ceilBound = _floorToSpacing(TickMath.MAX_TICK, spacing) - spacing;
            if (anchor > ceilBound) anchor = ceilBound;
            tickUpper = anchor;
            tickLower = _floorToSpacing(_tickForPrice(pUpper, false), spacing);
            if (tickLower >= tickUpper) tickLower = tickUpper - spacing;
            int24 minTick = _ceilToSpacing(TickMath.MIN_TICK, spacing);
            if (tickLower < minTick) tickLower = minTick;
            initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(anchor);
        }

        IUniswapV3Pool(pool).initialize(initSqrtPriceX96);

        // 3) seed liquidity (token-only range).
        IERC20(token).approve(address(positionManager), tokensForLiquidity);

        (uint256 amt0, uint256 amt1) =
            token0 == token ? (tokensForLiquidity, uint256(0)) : (uint256(0), tokensForLiquidity);

        (uint256 tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );

        // 4) lock the LP position permanently (or hand to a time-lock locker)
        if (address(locker) != address(0)) {
            positionManager.safeTransferFrom(address(this), address(locker), tokenId);
            locker.lock(address(positionManager), tokenId, msg.sender);
        }

        Launch memory L = Launch({
            token: token,
            creator: msg.sender,
            pool: pool,
            tokenId: tokenId,
            feeTier: FEE_TIER,
            live: true,
            graduationThreshold: graduationTargetWeth,
            pairedPrincipal: 0,
            graduated: false
        });
        launches[token] = L;
        allTokens.push(token);
        registry.register(token, msg.sender, pool);

        /**
         * The locker's share, fixed here and never again.
         *
         * Deliberately immutable: it is the one term a buyer prices in before
         * buying, and a creator who could lower it afterwards could promise 90%
         * to lockers to attract them and cut it to 0% once they had. The creator
         * keeps control of their OWN share only -- `setPayoutRecipients` divides
         * the remainder among their wallets and can be changed freely, because
         * it cannot take anything away from lockers.
         */
        if (p.holderShareBps > BPS) revert BadParams();
        holderShareBps[token] = p.setRewardSplit ? p.holderShareBps : DEFAULT_HOLDER_SHARE_BPS;
        if (p.payoutRecipients.length > 0) _storeRecipients(token, p.payoutRecipients);

        // Continuation range: starts exactly where the launch range ends and
        // runs to the tick extreme, so there is no price above which buying
        // stops working. Single-sided token, like the launch range, because it
        // sits entirely beyond the starting price.
        _mintContinuation(token, token0, token1, reserved, spacing, tickLower, tickUpper);

        emit Launched(token, msg.sender, pool, tokenId, FEE_TIER);

        // 5) flat deploy fee to protocolFeeRecipient, then the remainder optionally
        // funds a creator initial buy in the same atomic transaction -- no slippage
        // protection needed on that buy since nothing can be interleaved with it.
        if (msg.value < deployFeeWei) revert BadParams();
        if (deployFeeWei > 0) {
            (bool ok,) = protocolFeeRecipient.call{value: deployFeeWei}("");
            require(ok, "deploy fee send");
        }
        uint256 initialBuyEth = msg.value - deployFeeWei;
        if (initialBuyEth > 0) {
            _executeBuy(token, L, initialBuyEth, 0, msg.sender);
        }
    }

    // =================================================================== //
    //                                 BUY                                 //
    // =================================================================== //

    /// @notice Buy `token` with ETH -- a plain WETH -> token swap, no fee skim.
    ///         All protocol/reward revenue comes from harvesting the pool's own
    ///         native swap fee via `collectLpFees`, not from a per-trade cut here.
    function buy(address token, uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        Launch memory L = launches[token];
        if (!L.live) revert NotLive();
        if (msg.value == 0) revert BadParams();
        tokensOut = _executeBuy(token, L, msg.value, minTokensOut, msg.sender);
    }

    /// @dev Shared by `buy()` and `launch()`'s optional creator initial buy: wraps
    ///      `ethIn` and swaps the whole amount for `token`, delivered to `recipient`.
    function _executeBuy(address token, Launch memory L, uint256 ethIn, uint256 minTokensOut, address recipient)
        internal
        returns (uint256 tokensOut)
    {
        if (!NATIVE_IS_QUOTE_TOKEN) {
            WETH.deposit{value: ethIn}();
        }
        uint256 quoteAmount = _nativeToQuoteAmount(ethIn);

        WETH.approve(address(swapRouter), quoteAmount);
        tokensOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: token,
                fee: L.feeTier,
                recipient: recipient,
                amountIn: quoteAmount,
                amountOutMinimum: minTokensOut,
                sqrtPriceLimitX96: 0
            })
        );
        if (tokensOut < minTokensOut) revert Slippage();

        uint256 principal = launches[token].pairedPrincipal + quoteAmount;
        launches[token].pairedPrincipal = principal;
        if (!launches[token].graduated && principal >= L.graduationThreshold) {
            launches[token].graduated = true;
            emit Graduated(token, principal);
        }

        emit Bought(token, recipient, quoteAmount, tokensOut);
    }

    // =================================================================== //
    //                                SELL                                 //
    // =================================================================== //

    /// @notice Sell `token` for ETH -- a plain token -> WETH swap, no fee skim, no
    ///         burn. All protocol/reward revenue comes from harvesting the pool's
    ///         own native swap fee via `collectLpFees`, not from a per-trade cut here.
    function sell(address token, uint256 amountIn, uint256 minEthOut) external returns (uint256 ethOut) {
        Launch memory L = launches[token];
        if (!L.live) revert NotLive();
        if (amountIn == 0) revert BadParams();

        require(IERC20(token).transferFrom(msg.sender, address(this), amountIn), "token transferFrom");

        IERC20(token).approve(address(swapRouter), amountIn);
        uint256 wethOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(WETH),
                fee: L.feeTier,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        if (wethOut < minEthOut) revert Slippage();

        uint256 nativeOut = _quoteToNativeAmount(wethOut);

        if (!NATIVE_IS_QUOTE_TOKEN) {
            WETH.withdraw(wethOut);
        }
        (bool ok,) = msg.sender.call{value: nativeOut}("");
        require(ok, "eth send");
        ethOut = nativeOut;

        emit Sold(token, msg.sender, amountIn, ethOut);
    }

    // =================================================================== //
    //                          reward fee routing                        //
    // =================================================================== //

    /// @dev Swaps `wethAmt` WETH -> USDG and deposits the proceeds into `token`'s
    ///      reward LOCKER (`PumperToken.rewardLocker()`). Isolated so a
    ///      shallow/missing WETH-USDG pool, or a reverting locker, can't revert
    ///      the whole harvest -- reward routing is best-effort, never blocks the
    ///      trade or the fee collection.
    ///
    ///      The locker itself decides where the deposit lands: to stakers if any
    ///      have locked this token, otherwise straight to the token's `creator`
    ///      (the locker's fallback recipient). This function does not branch on
    ///      that -- it just funds the locker.
    function _swapWethToUsdgAndDeposit(address token, uint256 wethAmt) internal returns (uint256 usdgOut) {
        address rl = PumperToken(token).rewardLocker();

        // On chains where the pairing asset IS the reward stablecoin (e.g. Stable
        // network, where both roles are WgUSDT), there's nothing to swap -- the
        // harvested fee already is the reward. Deposit it directly instead.
        if (address(WETH) == address(USDG)) {
            USDG.approve(rl, wethAmt);
            try PumperRewardLocker(rl).depositReward(wethAmt) {
                usdgOut = wethAmt;
            } catch {
                USDG.approve(rl, 0);
                usdgOut = 0;
            }
            return usdgOut;
        }

        WETH.approve(address(swapRouter), wethAmt);
        try swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(USDG),
                fee: usdgFeeTier,
                recipient: address(this),
                amountIn: wethAmt,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        ) returns (
            uint256 out
        ) {
            usdgOut = out;
        } catch {
            WETH.approve(address(swapRouter), 0);
            return 0;
        }

        if (usdgOut == 0) return 0;

        USDG.approve(rl, usdgOut);
        try PumperRewardLocker(rl).depositReward(usdgOut) {
        // deposited (accrued to stakers, or forwarded to creator by the locker)
        }
        catch {
            USDG.approve(rl, 0);
            usdgOut = 0;
        }
    }

    // =================================================================== //
    //                          LP position fees                          //
    // =================================================================== //

    /// @notice Harvest the locked LP position's accumulated Uniswap swap fees --
    ///         accrued from ALL trading on the pool, not just launchpad-routed
    ///         buys/sells, since it's the pool's own fee tier revenue. Permissionless
    ///         (anyone can trigger a harvest). The token-side fee is burned
    ///         permanently (deflationary, funded by sell-side volume, see
    ///         PumperToken.burnFrom); the WETH-side fee splits four ways --
    ///         ADMIN_VAULT_BPS/FEFER_VAULT_BPS/PUMPER_VAULT_BPS to
    ///         `adminVault`/`feferVault`/`pumperVault`, the remainder into the
    ///         token's reward locker.
    function collectLpFees(address token) external returns (uint256 amount0, uint256 amount1) {
        Launch memory L = launches[token];
        if (L.token == address(0)) revert BadParams();

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: L.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        /**
         * The continuation range earns fees too, and once price trades above the
         * launch range it earns essentially ALL of them. Harvesting only the
         * launch position left those fees locked in an NFT with no path out.
         */
        uint256 contId = continuationTokenId[token];
        if (contId != 0) {
            (uint256 c0, uint256 c1) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: contId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            amount0 += c0;
            amount1 += c1;
        }

        if (amount0 == 0 && amount1 == 0) return (0, 0);

        bool tokenIsToken0 = token < address(WETH);
        uint256 tokenAmt = tokenIsToken0 ? amount0 : amount1;
        uint256 wethAmt = tokenIsToken0 ? amount1 : amount0;

        if (tokenAmt > 0) PumperToken(token).burnFrom(tokenAmt);

        // Fixed four-way split of the WETH-side fee: ADMIN_VAULT_BPS +
        // FEFER_VAULT_BPS + PUMPER_VAULT_BPS to the launchpad's vault
        // addresses, the remainder to the reward locker. The remainder is
        // computed by subtraction (not its own bps cut) so integer division
        // never strands dust between the four shares.
        uint256 adminWeth = (wethAmt * ADMIN_VAULT_BPS) / BPS;
        uint256 feferWeth = (wethAmt * FEFER_VAULT_BPS) / BPS;
        uint256 pumperWeth = (wethAmt * PUMPER_VAULT_BPS) / BPS;
        uint256 rewardWeth = wethAmt - adminWeth - feferWeth - pumperWeth;

        // The creator's dial splits the reward pot between the locker and wallets.
        uint256 holderWeth = (rewardWeth * holderShareBps[token]) / BPS;
        uint256 walletWeth = rewardWeth - holderWeth;

        uint256 rewardUsdg = holderWeth > 0 ? _swapWethToUsdgAndDeposit(token, holderWeth) : 0;

        // A locker deposit can legitimately fail -- a shallow WETH/USDG pool on a
        // non-stablecoin chain, say. Rather than strand it here, the unspent
        // amount falls through to the wallet payout.
        if (holderWeth > 0 && rewardUsdg == 0) walletWeth += holderWeth;

        if (walletWeth > 0) _payRecipients(token, walletWeth);
        // Paid to this launchpad version's own immutable vault addresses. A
        // future launchpad redeploy pointing at new vaults never retroactively
        // redirects an already-launched token's fees, because this contract --
        // which those tokens' harvests always route through -- is immutable.
        if (adminWeth > 0) {
            require(WETH.transfer(adminVault, adminWeth), "admin vault transfer");
        }
        if (feferWeth > 0) {
            require(WETH.transfer(feferVault, feferWeth), "fefer vault transfer");
        }
        if (pumperWeth > 0) {
            require(WETH.transfer(pumperVault, pumperWeth), "pumper vault transfer");
        }

        emit LpFeesCollected(token, amount0, amount1, tokenAmt, rewardUsdg, adminWeth, feferWeth, pumperWeth);
    }

    /// @dev Pays `amount` to the token's configured wallets, or to the creator
    ///      when none are set.
    ///
    ///      Pays in WETH (WgUSDT on Stable), not native value. That matters for
    ///      safety here: an ERC-20 transfer invokes no code on the recipient, so
    ///      a hostile or broken payout wallet cannot revert and brick
    ///      collectLpFees -- which is permissionless and must keep working for
    ///      the pool, the lockers and everyone else. A native `.call` would have
    ///      needed a stipend and a try/catch to get the same guarantee.
    ///
    ///      The last recipient takes the remainder rather than its exact bps, so
    ///      integer division never strands dust in this contract.
    function _payRecipients(address token, uint256 amount) internal {
        Recipient[] storage rs = payoutRecipients[token];

        if (rs.length == 0) {
            // Return value ignored deliberately: see the note above. A require()
            // here would let one unpayable recipient revert a permissionless
            // harvest for the pool and every locker.
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            WETH.transfer(launches[token].creator, amount);
            return;
        }

        uint256 paid;
        for (uint256 i; i < rs.length; ++i) {
            uint256 cut = i + 1 == rs.length ? amount - paid : (amount * rs[i].bps) / BPS;
            if (cut == 0) continue;
            paid += cut;
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            WETH.transfer(rs[i].to, cut);
        }
    }

    // =================================================================== //
    //                       post-graduation liquidity                     //
    // =================================================================== //

    /// @dev Second half of the launch's liquidity, covering everything above the
    ///      launch range. Split into its own function purely to keep `launch`
    ///      under the stack limit.
    function _mintContinuation(
        address token,
        address token0,
        address token1,
        uint256 amount,
        int24 spacing,
        int24 launchLower,
        int24 launchUpper
    ) internal {
        if (amount == 0) return;

        int24 lower;
        int24 upper;
        if (token0 == token) {
            lower = launchUpper;
            upper = _floorToSpacing(TickMath.MAX_TICK, spacing);
        } else {
            // Token is token1: it appreciates as the tick falls, so the
            // continuation sits below the launch range.
            upper = launchLower;
            lower = _ceilToSpacing(TickMath.MIN_TICK, spacing);
        }
        // Nothing sensible to mint (a launch range already spanning the extreme)
        // — leave the tokens with the launchpad rather than reverting the launch.
        if (upper <= lower) return;

        IERC20(token).approve(address(positionManager), amount);
        (uint256 amt0, uint256 amt1) = token0 == token ? (amount, uint256(0)) : (uint256(0), amount);

        (uint256 tokenId,,,) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        continuationTokenId[token] = tokenId;
    }

    // =================================================================== //
    //                          creator: reward routing                    //
    // =================================================================== //

    modifier onlyTokenCreator(address token) {
        if (launches[token].token == address(0)) revert BadParams();
        if (msg.sender != launches[token].creator) revert NotCreator();
        _;
    }

    /// @dev Shared by launch() and setPayoutRecipients so the two can never
    ///      disagree about what a valid recipient set is.
    function _storeRecipients(address token, Recipient[] calldata rs) internal {
        if (rs.length > MAX_RECIPIENTS) revert BadParams();

        uint256 total;
        for (uint256 i; i < rs.length; ++i) {
            if (rs[i].to == address(0)) revert BadParams();
            total += rs[i].bps;
        }
        if (rs.length > 0 && total != BPS) revert BadParams();

        delete payoutRecipients[token];
        for (uint256 i; i < rs.length; ++i) {
            payoutRecipients[token].push(rs[i]);
        }
    }

    /// @notice Replace the wallets receiving the creator's own share.
    /// @dev    There is deliberately no counterpart for `holderShareBps`: that
    ///         is fixed at launch so lockers can rely on it. This only moves
    ///         the creator's own portion around, which takes nothing from them.
    function setPayoutRecipients(address token, Recipient[] calldata rs) external onlyTokenCreator(token) {
        _storeRecipients(token, rs);
        emit PayoutChanged(token, holderShareBps[token], rs.length);
    }

    function payoutRecipientCount(address token) external view returns (uint256) {
        return payoutRecipients[token].length;
    }

    // =================================================================== //
    //                       creator: admin reassignment                   //
    // =================================================================== //

    /// @notice Admin-only: reassign `token`'s creator (a CTO, lost-key
    ///         recovery, an abandoned launch). Reassigns reward-routing control
    ///         ONLY -- `launches[token].creator`, read by `onlyTokenCreator`,
    ///         `_payRecipients`'s default payout, and (off-chain) the locker's
    ///         fallback recipient. `holderShareBps` (the lockers' fixed share
    ///         of the reward pot) is untouched by this or any other function.
    ///
    ///         Also clears `payoutRecipients[token]` -- see the long-form note
    ///         in `PumperProtocolLaunchpad.setCreator` for why (old creator's
    ///         economic claim outliving their control; a front-runnable
    ///         `setPayoutRecipients` in the mempool). Resetting to the "pay the
    ///         creator directly" default closes both paths at once.
    ///
    ///         NOTE: the per-token `PumperRewardLocker.fallbackRecipient` is
    ///         immutable and still points at the ORIGINAL creator. A CTO'd
    ///         token whose locker has nothing staked keeps forwarding deposits
    ///         to the original creator until something is staked. This is the
    ///         same "fixed at launch" guarantee everything else here has; a
    ///         reassignment that needs to redirect an empty locker's stream
    ///         should stake a dust amount to switch accrual on.
    function setCreator(address token, address newCreator) external onlyOwner {
        if (launches[token].token == address(0)) revert BadParams();
        if (newCreator == address(0)) revert ZeroAddress();

        address previous = launches[token].creator;
        if (newCreator == previous) return;

        launches[token].creator = newCreator;
        delete payoutRecipients[token];
        emit CreatorSetByAdmin(token, previous, newCreator);
        emit PayoutChanged(token, holderShareBps[token], 0);
    }

    // =================================================================== //
    //                                admin                                //
    // =================================================================== //

    /// @notice Sets the flat ETH deploy fee taken on launch() (paid to
    ///         `protocolFeeRecipient`). The remainder of msg.value funds the
    ///         optional creator initial buy.
    function setDeployFeeWei(uint256 fee) external onlyOwner {
        deployFeeWei = fee;
    }

    /// @notice Redirects where the protocol's own flat deploy-fee revenue is
    ///         paid, without touching who controls the contract. Takes effect
    ///         immediately. Does NOT affect `collectLpFees`'s vault cuts.
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
    }

    /// @notice Sets the target graduation market cap (in wei of WETH) used to size
    ///         FUTURE launches' one-sided liquidity range. Baked into each launch's
    ///         tick range at creation time -- never affects already-launched pools.
    function setTargetGraduationMcapWeth(uint256 wei_) external onlyOwner {
        if (wei_ == 0) revert BadParams();
        targetGraduationMcapWeth = wei_;
    }

    /// @notice Sets how much WETH raising should take to fully traverse FUTURE
    ///         launches' one-sided range. Baked in at creation time -- never affects
    ///         already-launched pools.
    function setGraduationTargetWeth(uint256 wei_) external onlyOwner {
        if (wei_ == 0) revert BadParams();
        graduationTargetWeth = wei_;
    }

    function setLive(address token, bool live) external onlyOwner {
        launches[token].live = live;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function totalLaunches() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Graduation is a status marker only -- it confirms cumulative paired
    ///         WETH crossed the launch's threshold, nothing more. It isn't a quality
    ///         signal and doesn't guarantee future liquidity, price, or an exit.
    function graduationStatus(address token)
        external
        view
        returns (uint256 pairedPrincipal, uint256 threshold, bool graduated)
    {
        Launch storage L = launches[token];
        return (L.pairedPrincipal, L.graduationThreshold, L.graduated);
    }

    /// @notice Recover WETH (or any ERC20) that got stuck here because a reward-fee
    ///         swap failed (see `_swapWethToUsdgAndDeposit`'s try/catch) -- e.g. no
    ///         WETH/USDG pool existed yet at `usdgFeeTier`. Never touches launched
    ///         tokens' own balances beyond whatever dust the contract itself holds.
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        require(IERC20(tokenAddr).transfer(to, amount), "rescue transfer");
    }

    receive() external payable {}
}
