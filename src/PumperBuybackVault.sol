// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20, ISwapRouter02} from "./Interfaces.sol";

/// @title PumperBuybackVault
/// @notice Receives a fixed slice of every next-gen `PumperLaunchpad` token's
///         LP-fee harvest (see `PumperLaunchpad.collectLpFees`,
///         `PUMPER_VAULT_BPS`) as WgUSDT, and permanently destroys value on
///         behalf of a single target token's holders: swap the vault's whole
///         WgUSDT balance for that token through one Uniswap V3 pool, then
///         send everything received to the dead address.
///
///         Conceptually this is the PUMPER-side counterpart of
///         `PumperFeferVault` -- same "collect fees, buy back, burn" role --
///         but far simpler, because the target token (PUMPER,
///         0xd868...0Bf82) DOES have a direct Uniswap V3 pool against WgUSDT
///         (the 1% pool 0xE545...4eb2), so no off-chain aggregator route or
///         V2 zap is needed: a single `exactInputSingle` does it.
///
///         IMMUTABLE AND ADMIN-FREE, exactly like `PumperRewardLocker`. There
///         is no mode toggle, no owner, no rescue path -- `token`, `wgusdt`,
///         `swapRouter` and `poolFee` are fixed forever at construction. The
///         only state-changing entry point, `buyAndBurn`, is permissionless:
///         anyone may trigger a burn at any time. The caller supplies the
///         slippage bound (eth_call a quoter first, as elsewhere in this
///         codebase), so a sandwich cannot force a bad fill through a
///         hardcoded zero-minimum.
///
///         Token-agnostic by construction (constructor args, no hardcoded
///         token) so the same bytecode can back a buy-back for any token that
///         has a WgUSDT V3 pool; this deployment is pinned to PUMPER.
contract PumperBuybackVault {
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The token bought back and burned. Fixed forever.
    address public immutable token;

    /// @notice The currency fees arrive in / the buy is funded with (WgUSDT).
    address public immutable wgusdt;

    /// @notice Uniswap V3 SwapRouter02 the buy routes through.
    ISwapRouter02 public immutable swapRouter;

    /// @notice Fee tier of the `wgusdt`/`token` V3 pool the buy routes through.
    uint24 public immutable poolFee;

    error ZeroAddress();
    error SameToken();
    error NothingToDo();
    error Reentrancy();

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    event BoughtAndBurned(address indexed caller, uint256 wgusdtIn, uint256 tokenBurned);

    constructor(address _token, address _wgusdt, address _swapRouter, uint24 _poolFee) {
        if (_token == address(0) || _wgusdt == address(0) || _swapRouter == address(0)) {
            revert ZeroAddress();
        }
        if (_token == _wgusdt) revert SameToken();
        token = _token;
        wgusdt = _wgusdt;
        swapRouter = ISwapRouter02(_swapRouter);
        poolFee = _poolFee;
    }

    /// @notice Swap this vault's ENTIRE current WgUSDT balance for `token`
    ///         through the `poolFee` V3 pool and send everything received to
    ///         the dead address. Permissionless -- anyone may call, any time.
    ///
    /// @param  minTokenOut       Revert if the swap yields less than this.
    ///                           Quote off-chain (eth_call the quoter) and
    ///                           pass a sane bound -- a zero here invites a
    ///                           sandwich.
    /// @param  sqrtPriceLimitX96 Optional V3 price limit (0 = none).
    /// @return bought             Amount of `token` bought and burned.
    function buyAndBurn(uint256 minTokenOut, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
        returns (uint256 bought)
    {
        uint256 balance = IERC20(wgusdt).balanceOf(address(this));
        if (balance == 0) revert NothingToDo();

        _approve(wgusdt, address(swapRouter), balance);
        bought = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: wgusdt,
                tokenOut: token,
                fee: poolFee,
                recipient: DEAD_ADDRESS,
                amountIn: balance,
                amountOutMinimum: minTokenOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        emit BoughtAndBurned(msg.sender, balance, bought);
    }

    /// @notice WgUSDT this vault currently holds, i.e. what the next
    ///         `buyAndBurn` would spend. Convenience for keepers / UIs.
    function pendingWgusdt() external view returns (uint256) {
        return IERC20(wgusdt).balanceOf(address(this));
    }

    function _approve(address t, address spender, uint256 amount) private {
        // Reset first: some tokens revert on a non-zero -> non-zero approve.
        (bool ok,) = t.call(abi.encodeWithSelector(IERC20.approve.selector, spender, 0));
        ok;
        (bool ok2, bytes memory data) = t.call(abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
        require(ok2 && (data.length == 0 || abi.decode(data, (bool))), "approve");
    }

    /// @notice Fees arrive as an ERC20 WgUSDT transfer, never native -- but
    ///         accept a stray send rather than revert, so this can't become
    ///         an accidental value trap.
    receive() external payable {}
}
