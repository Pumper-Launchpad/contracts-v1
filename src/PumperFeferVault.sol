// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./Interfaces.sol";

/// @notice The one PumperAggregator entry point this contract calls. Kept
///         narrow and local, mirroring the exact same interface
///         PumperZapper.sol declares for itself -- matches the single-
///         purpose-interface convention already used across this codebase
///         (ILiquidityLocker in Interfaces.sol, PumperZapper's own
///         IPumperAggregator) rather than importing a shared one.
interface IPumperAggregator {
    struct Hop {
        uint16 venueId;
        address tokenIn;
        address tokenOut;
        uint24 fee; // UNIV3 only
        address pool; // SELF_POOLED only
    }

    function swap(Hop[] calldata hops, uint256 amountIn, uint256 minOut, address recipient, bool unwrapOut)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice The one already-deployed PumperZapper entry point this contract
///         calls -- swap a portion of the input for the other side via
///         PumperAggregator, then addLiquidity on DYORswap V2, atomically,
///         one approval. See PumperZapper.sol's own doc for why the route is
///         a caller-supplied parameter (on-chain V3 quoting isn't possible;
///         the caller eth_calls PumperAggregator.quoteRoute off-chain first).
interface IPumperZapper {
    function zapV2(
        address tokenIn,
        uint256 amountIn,
        IPumperAggregator.Hop[] calldata swapHops,
        uint256 swapAmountIn,
        uint256 minSwapOut,
        address tokenOut,
        uint256 amountAMin,
        uint256 amountBMin,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @notice Minimal view into PumperAdminVault -- this vault has no admin list
///         of its own; `setMode` defers to the SAME admin registry the
///         protocol's other vault uses, rather than duplicating admin
///         bookkeeping in a second place.
interface IPumperAdminVault {
    function isAdmin(address) external view returns (bool);
}

/// @title PumperFeferVault
/// @notice Receives a fixed slice of every PumperProtocolLaunchpad token's
///         LP-fee harvest (see PumperProtocolToken.feferVault and
///         PumperProtocolLaunchpad.collectLpFees, FEFER_VAULT_BPS) as WgUSDT,
///         and permanently destroys value on behalf of FEFER holders one of
///         two ways -- whichever the admin has toggled on:
///
///           1. `buyAndBurn` -- swap the vault's whole WgUSDT balance for
///              FEFER (best route, quoted off-chain, executed via
///              PumperAggregator), send everything received to the dead
///              address.
///           2. `addLiquidityAndBurn` -- swap a caller-chosen portion of the
///              WgUSDT balance for FEFER via the already-deployed
///              PumperZapper.zapV2, mint a DYORswap V2 LP position, send the
///              resulting LP tokens to the dead address -- permanently
///              deepening FEFER's liquidity instead of burning supply.
///
///         Both functions are permissionless (anyone can trigger one,
///         anytime) but only one is EVER callable at a time -- `activeMode`,
///         admin-toggleable via `setMode`. Neither function holds funds
///         between calls beyond dust: the vault's balance is either fully
///         swapped-and-burned or fully zapped-and-burned every call.
///
/// @dev    FEFER (0xeaf7...a7b83) has no Uniswap V3 pool against WgUSDT --
///         only against USDT0 -- so a genuinely one-sided V3 range isn't
///         reachable here without first creating a brand-new, unproven pool
///         (this codebase has a documented incident of exactly that going
///         wrong, a pool mispriced ~65,000,000x at creation). DYORswap's real,
///         liquid FEFER/WgUSDT V2 pair is used instead via PumperZapper.
contract PumperFeferVault {
    address public constant FEFER = 0xeaf7aC0FdF150CDD89340fB762D83848De6A7b83;
    address public constant WGUSDT = 0x817997Ca8394E26CCE3dE3A076a4889b27DbF9dE;
    // DYORswap V2 FEFER/WgUSDT pair -- the deepest of FEFER's pools (~85k
    // WgUSDT reserve as of 2026-08-16, per Server/lib/chains.js). Its LP
    // token is a standard ERC20 (DYORswap is a verbatim UniswapV2 fork), so a
    // plain `transfer` to DEAD_ADDRESS is a real, permanent burn of the
    // position -- V2 pairs have no NFT the way a V3 position would.
    address public constant FEFER_WGUSDT_PAIR = 0x3dea4Be5615974f31624404Ef288BA3b36dfeb83;
    address public constant AGGREGATOR = 0xecFA63AdCCd8546225bcde29d84e765ddFCfA52c;
    address public constant ZAPPER = 0xeA3c6218C3b5B3aB2Aa0b9E36DafC382a8cffC3E;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable adminVault;

    enum Mode {
        BuyBurn,
        AddLiquidityBurn
    }

    /// @notice Which of the two functions is currently callable. Starts at
    ///         BuyBurn -- the simpler, single-hop action, and a reasonable
    ///         default until an admin actively chooses otherwise.
    Mode public activeMode;

    error NotAdmin();
    error WrongMode();
    error BadRoute();
    error NothingToDo();
    error Expired();
    error Reentrancy();
    error ZeroAddress();

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    modifier notExpired(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    modifier onlyAdmin() {
        if (!IPumperAdminVault(adminVault).isAdmin(msg.sender)) revert NotAdmin();
        _;
    }

    event ModeChanged(Mode indexed newMode, address indexed changedBy);
    event BoughtAndBurned(uint256 wgusdtIn, uint256 feferBurned);
    event AddedLiquidityAndBurned(uint256 wgusdtIn, uint256 feferAdded, uint256 lpBurned);

    constructor(address _adminVault) {
        if (_adminVault == address(0)) revert ZeroAddress();
        adminVault = _adminVault;
    }

    /// @notice Admin-only: choose which of the two burn actions is currently
    ///         callable. Idempotent -- setting the mode that's already active
    ///         just re-emits the event rather than reverting.
    function setMode(Mode m) external onlyAdmin {
        activeMode = m;
        emit ModeChanged(m, msg.sender);
    }

    /// @notice Swap this vault's ENTIRE current WgUSDT balance for FEFER via
    ///         PumperAggregator's caller-supplied best route, then send
    ///         everything received to the dead address. Permissionless --
    ///         `hops`/`minFeferOut` are supplied by the caller after
    ///         eth_calling PumperAggregator.quoteRoute off-chain, same
    ///         pattern as every other swap entrypoint in this codebase
    ///         (PumperZapper, the launchpad's own buy()/sell()). Only
    ///         callable while `activeMode == BuyBurn`.
    function buyAndBurn(IPumperAggregator.Hop[] calldata hops, uint256 minFeferOut, uint256 deadline)
        external
        nonReentrant
        notExpired(deadline)
    {
        if (activeMode != Mode.BuyBurn) revert WrongMode();
        if (hops.length == 0 || hops[0].tokenIn != WGUSDT || hops[hops.length - 1].tokenOut != FEFER) {
            revert BadRoute();
        }

        uint256 balance = IERC20(WGUSDT).balanceOf(address(this));
        if (balance == 0) revert NothingToDo();

        _approve(WGUSDT, AGGREGATOR, balance);
        IPumperAggregator(AGGREGATOR).swap(hops, balance, minFeferOut, address(this), false);

        uint256 feferReceived = IERC20(FEFER).balanceOf(address(this));
        require(IERC20(FEFER).transfer(DEAD_ADDRESS, feferReceived), "burn transfer");

        emit BoughtAndBurned(balance, feferReceived);
    }

    /// @notice Swap a caller-chosen portion of this vault's ENTIRE current
    ///         WgUSDT balance for FEFER and add liquidity to the real
    ///         FEFER/WgUSDT DYORswap V2 pair via the already-deployed
    ///         PumperZapper (one approval, atomic swap + addLiquidity), then
    ///         send the resulting LP tokens to the dead address -- giving up
    ///         that liquidity forever. Permissionless -- every swap/liquidity
    ///         parameter is caller-supplied, same off-chain-quote pattern as
    ///         `buyAndBurn`. Only callable while `activeMode ==
    ///         AddLiquidityBurn`.
    function addLiquidityAndBurn(
        IPumperAggregator.Hop[] calldata swapHops,
        uint256 swapAmountIn,
        uint256 minSwapOut,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) external nonReentrant notExpired(deadline) {
        if (activeMode != Mode.AddLiquidityBurn) revert WrongMode();
        if (swapHops.length == 0 || swapHops[0].tokenIn != WGUSDT || swapHops[swapHops.length - 1].tokenOut != FEFER)
        {
            revert BadRoute();
        }

        uint256 balance = IERC20(WGUSDT).balanceOf(address(this));
        if (balance == 0) revert NothingToDo();

        _approve(WGUSDT, ZAPPER, balance);
        (, uint256 feferAdded, uint256 liquidity) = IPumperZapper(ZAPPER).zapV2(
            WGUSDT, balance, swapHops, swapAmountIn, minSwapOut, FEFER, amountAMin, amountBMin, address(this), deadline
        );

        // zapV3/zapV2 refund any leftover dust straight to msg.sender (this
        // vault) rather than leaving it stuck mid-call -- nothing extra
        // needed here to recover it, it's already back in this contract's
        // WGUSDT/FEFER balance for the NEXT call to pick up.
        require(IERC20(FEFER_WGUSDT_PAIR).transfer(DEAD_ADDRESS, liquidity), "burn transfer");

        emit AddedLiquidityAndBurned(balance, feferAdded, liquidity);
    }

    function _approve(address token, address spender, uint256 amount) private {
        // Reset first: some tokens revert on a non-zero to non-zero approve.
        (bool ok, ) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        ok;
        (bool ok2, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok2 && (data.length == 0 || abi.decode(data, (bool))), "approve");
    }

    /// @notice Not expected to ever hold native currency -- fees arrive as an
    ///         ERC20 WgUSDT transfer -- but accepting rather than reverting
    ///         on a stray send keeps this from being an accidental burn trap.
    receive() external payable {}
}
