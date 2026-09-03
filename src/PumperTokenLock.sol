// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./Interfaces.sol";

/// @notice Minimal view into a Pumper-style token's own holder-rewards system
///         (see PumperProtocolToken.sol) -- `claimRewards` pays out whatever
///         is owed to `msg.sender` (i.e. THIS contract, when it calls it) in
///         `rewardToken`. Not every locked token implements this -- calls
///         through this interface are always try/catch-guarded so locking a
///         plain, non-Pumper ERC20 never reverts because of it.
interface IPumperRewardToken {
    function claimRewards() external returns (uint256 amount);
    function pendingRewards(address user) external view returns (uint256);
    function rewardToken() external view returns (address);
}

/// @notice Permissionless ERC-20 time lock. Anyone -- a token's creator or any
///         community member -- can lock any amount of any token until a
///         timestamp of their own choosing, as a real, on-chain, enforced
///         commitment: once locked, nothing (not even this contract's own
///         code) can move the tokens out before `unlockTime`.
///
///         Locks are extend-only: `relock` can only push `unlockTime` further
///         into the future, never pull it back. Without that rule a "locked
///         until 2027" badge would mean nothing -- the locker could quietly
///         shorten it to tomorrow. Only the locker can extend or withdraw
///         their own lock; nobody else can touch it.
///
///         Reward pass-through: whether a locked balance keeps earning that
///         token's own holder rewards depends entirely on the TOKEN's own
///         reward-eligibility rule. Some Stable tokens (PUMPER included) pay
///         rewards on raw balance with no restriction, so THIS CONTRACT's
///         holding earns those rewards like any other holder -- but the token
///         pays out to whichever address calls `claimRewards`, which is this
///         contract, not the individual locker. `claimReward` closes that
///         gap: it calls the token's own `claimRewards()` on this contract's
///         behalf, then splits whatever comes back among that token's
///         lockers proportional to their locked amount, using the same
///         accumulator-per-share pattern the token itself uses internally.
///         Tokens launched from the current launchpad restrict rewards to
///         EOA-only balances, so a locked amount there simply never accrues
///         anything to claim -- not a bug here, just an already-deployed,
///         immutable rule on the token's side that no lock contract can work
///         around.
contract PumperTokenLock {
    struct Lock {
        address token;
        address locker;
        uint256 amount; // live outstanding balance; 0 once withdrawn
        uint64 unlockTime;
        uint64 createdAt; // set once at lock(), never touched again -- drives a progress bar
        bool withdrawn;
    }

    // A typo'd unlock timestamp (e.g. milliseconds instead of seconds) would
    // otherwise lock funds for millennia with no way back. This still allows
    // "as long as they want" for any realistic use while catching that class
    // of fat-finger mistake at the revert, not fifty years later.
    uint64 public constant MAX_LOCK_DURATION = 50 * 365 days;

    // Bounds how much gas a locked token's own (untrusted, arbitrary) code
    // can ever consume during a reward-interface call. Without this, a
    // token could deliberately burn nearly all of whatever gas the 63/64
    // rule forwards it -- a victim can usually outrun that by raising their
    // own transaction's gas limit (the guaranteed leftover scales with it
    // too), but only up to the chain's block gas limit. This contract's
    // whole point is that principal is unconditionally recoverable after
    // maturity, so that guarantee shouldn't depend on how high a block gas
    // limit happens to be. 200k is generous for the real token calls this
    // is meant for (a handful of SLOADs/SSTOREs and one inner ERC20
    // transfer) while tightly bounding a malicious one.
    uint256 private constant REWARD_CALL_GAS = 200_000;

    uint256 private constant ACC_PRECISION = 1e36;

    Lock[] private _locks;

    // Every lock ID that ever touched a given token, in creation order --
    // lets the frontend list every lock for a token with no off-chain indexer.
    mapping(address => uint256[]) private _lockIdsByToken;
    // Every lock ID a given address created, across all tokens.
    mapping(address => uint256[]) private _lockIdsByLocker;

    // Sum of every ACTIVE (not withdrawn) lock's amount, per token -- the
    // denominator for both the "locked score" and the reward-per-share split.
    // Kept as a running total rather than summed on read, since the reward
    // math needs to read AND write it inside a single state-changing call.
    mapping(address => uint256) private _totalLockedOf;

    // Per-token reward accumulator, scaled by ACC_PRECISION -- exactly the
    // token's own accRewardPerShare pattern, just re-keyed on "share of this
    // contract's locked balance" instead of "share of eligible supply".
    mapping(address => uint256) private _accRewardPerShare;
    mapping(uint256 => uint256) private _rewardDebt; // per lock
    mapping(uint256 => uint256) private _rewardOwed; // per lock, settled but unclaimed

    // The reward CURRENCY a locked token pays out in, pinned the first time a
    // real claim is verified for it and never trusted again after that. Two
    // things this closes at once: (1) `claimed` in _pokeRewards is measured
    // via this contract's own balance of THIS address, never taken from the
    // locked token's self-reported return value, so a fake token can't
    // fabricate a payout out of thin air; (2) claimReward always pays out in
    // whatever was pinned here, never a live re-query of the locked token's
    // `rewardToken()`, so a token can't legitimately back a tiny claim in a
    // worthless asset and then redirect the payout into something valuable
    // by the time it's claimed. Every locked-token's pool is its own asset,
    // permanently -- nothing here is ever shared across tokens by trust alone.
    mapping(address => address) private _rewardTokenOf;

    uint256 private _reentrancyStatus = 1;

    event Locked(
        uint256 indexed lockId, address indexed token, address indexed locker, uint256 amount, uint64 unlockTime
    );
    event LockIncreased(uint256 indexed lockId, uint256 addedAmount, uint256 newAmount);
    event LockExtended(uint256 indexed lockId, uint64 previousUnlockTime, uint64 newUnlockTime);
    event Withdrawn(uint256 indexed lockId, address indexed locker, uint256 amount);
    event RewardClaimed(uint256 indexed lockId, address indexed locker, address indexed rewardToken, uint256 amount);

    error ZeroAmount();
    error UnlockInPast();
    error UnlockTooFar();
    error NotLocker();
    error NotLater();
    error StillLocked(uint64 unlockTime);
    error AlreadyWithdrawn();
    error TransferFailed();
    error NothingToClaim();
    error Reentrant();

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert Reentrant();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    /// @notice Lock `amount` of `token`, pulled from the caller, until
    ///         `unlockTime`. Caller must have approved this contract for at
    ///         least `amount` first. The amount actually recorded is however
    ///         much this contract's balance of `token` went up by, not the
    ///         requested `amount` -- protects lockers of the same token from
    ///         a fee-on-transfer/deflationary token silently under-crediting
    ///         one lock while letting it withdraw against another's balance.
    function lock(address token, uint256 amount, uint64 unlockTime) external nonReentrant returns (uint256 lockId) {
        if (amount == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert UnlockInPast();
        if (unlockTime > block.timestamp + MAX_LOCK_DURATION) revert UnlockTooFar();

        uint256 received = _pull(token, amount);
        if (received == 0) revert ZeroAmount();

        lockId = _locks.length;
        _locks.push(
            Lock({
                token: token,
                locker: msg.sender,
                amount: 0,
                unlockTime: unlockTime,
                createdAt: uint64(block.timestamp),
                withdrawn: false
            })
        );
        _lockIdsByToken[token].push(lockId);
        _lockIdsByLocker[msg.sender].push(lockId);

        // Sync this token's reward accumulator using the supply BEFORE this
        // deposit joins it, so the new lock's debt baseline starts it earning
        // only from this point forward, never retroactively.
        uint256 acc = _pokeRewards(token);

        Lock storage l = _locks[lockId];
        l.amount = received;
        _totalLockedOf[token] += received;
        _rewardDebt[lockId] = (received * acc) / ACC_PRECISION;

        emit Locked(lockId, token, msg.sender, received, unlockTime);
    }

    /// @notice Add more of the same token to a lock you own, without
    ///         changing its unlock time.
    function increaseLock(uint256 lockId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Lock storage l = _locks[lockId];
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();

        address token = l.token;
        uint256 received = _pull(token, amount);
        if (received == 0) revert ZeroAmount();

        uint256 acc = _checkpoint(lockId, token); // settles pending at the OLD amount first

        l.amount += received;
        _totalLockedOf[token] += received;
        _rewardDebt[lockId] = (l.amount * acc) / ACC_PRECISION;

        emit LockIncreased(lockId, received, l.amount);
    }

    /// @notice Push a lock's unlock time further out. Reverts if
    ///         `newUnlockTime` is not strictly later than the current one --
    ///         locks can only ever get longer.
    function relock(uint256 lockId, uint64 newUnlockTime) external {
        Lock storage l = _locks[lockId];
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (newUnlockTime <= l.unlockTime) revert NotLater();
        if (newUnlockTime > block.timestamp + MAX_LOCK_DURATION) revert UnlockTooFar();

        uint64 previous = l.unlockTime;
        l.unlockTime = newUnlockTime;
        emit LockExtended(lockId, previous, newUnlockTime);
    }

    /// @notice Withdraw a fully-matured lock's principal back to its locker.
    ///         Any reward already settled (or settled by this call, for the
    ///         period up to withdrawal) stays claimable afterwards via
    ///         `claimReward` -- withdrawing principal and claiming rewards
    ///         are independent actions.
    function withdraw(uint256 lockId) external nonReentrant {
        Lock storage l = _locks[lockId];
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime);

        address token = l.token;
        _checkpoint(lockId, token); // bank any pending reward up to this exact moment

        uint256 amount = l.amount;
        _totalLockedOf[token] -= amount;

        // Effects before interaction: withdrawn + zeroed first, so a
        // reentrant call (from a malicious token's transfer hook) hits
        // AlreadyWithdrawn immediately rather than re-entering a still-
        // "active" lock, and so this lock stops accruing further reward share
        // the instant its principal leaves.
        l.withdrawn = true;
        l.amount = 0;
        _rewardDebt[lockId] = 0;

        // Some fee-on-transfer/reflection tokens deduct MORE than the
        // specified amount from the SENDER on every transfer, not just what
        // the recipient receives -- if that's quietly left this contract
        // holding less of `token` than `_totalLockedOf` assumes, sending the
        // full recorded `amount` could otherwise revert. Capping to whatever
        // this contract actually holds covers the common case (a flat %
        // deducted from the transfer amount itself) with a single real
        // transfer -- no repeated attempts, so there's no way for this to
        // ever move tokens more than once. A token whose tax is instead
        // charged ON TOP of the requested amount (so even the capped
        // `available` figure is untransferable) reverts here rather than
        // being probed for a smaller amount -- state is unwound on revert
        // (this lock is NOT marked withdrawn), so the locker simply retries
        // once the pool holds enough again, instead of risking an exploit
        // surface for the sake of an edge case this rare.
        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 payout = amount < available ? amount : available;
        if (payout > 0) _safeTransfer(token, msg.sender, payout);

        emit Withdrawn(lockId, msg.sender, payout);
    }

    /// @notice Claim this lock's share of whatever `token` has paid out
    ///         through its own holder-rewards system while locked here.
    ///         Callable while still locked (ongoing accrual) or after
    ///         withdrawal (final residual) -- always by the lock's owner only,
    ///         paid directly to them, never routed through anyone else.
    function claimReward(uint256 lockId) external nonReentrant returns (uint256 amount) {
        Lock storage l = _locks[lockId];
        if (msg.sender != l.locker) revert NotLocker();

        address token = l.token;
        _checkpoint(lockId, token);

        amount = _rewardOwed[lockId];
        if (amount == 0) revert NothingToClaim();
        _rewardOwed[lockId] = 0;

        // The PINNED currency, set by _pokeRewards the first time a claim
        // for this token was actually verified -- never a live call back to
        // `token`, which is untrusted and could report something different
        // by now. `amount` can only be nonzero here if `_rewardTokenOf[token]`
        // was already set (accrual is the only way `_rewardOwed` grows).
        address rewardToken = _rewardTokenOf[token];
        _safeTransfer(rewardToken, msg.sender, amount);

        emit RewardClaimed(lockId, msg.sender, rewardToken, amount);
    }

    /// @notice Permissionless: sync `token`'s reward accumulator without
    ///         claiming any individual lock. Useful for a keeper to keep
    ///         accounting fresh on a quiet token, but never required --
    ///         every mutating function pokes automatically before it needs
    ///         the accumulator to be current.
    function pokeRewards(address token) external nonReentrant {
        _pokeRewards(token);
    }

    /// @dev Claims `token`'s pending reward for this contract's WHOLE
    ///      balance (if any -- silently no-ops for tokens that don't
    ///      implement the reward interface, or have nothing pending) and
    ///      folds it into the per-share accumulator. Must run, in this order,
    ///      before ANY read/write of `_accRewardPerShare[token]` that needs
    ///      to be current.
    ///
    ///      `claimed` is always MEASURED (this contract's own balance of the
    ///      pinned reward currency, before vs. after) -- never taken from
    ///      `token.claimRewards()`'s return value. That return value is
    ///      exactly as trustworthy as `token` itself, and `token` can be
    ///      ANYTHING (locking is permissionless for any ERC20) -- trusting a
    ///      self-reported payout here would let a fake token credit itself an
    ///      arbitrary amount of a real, valuable asset out of thin air and
    ///      drain every other locker's actual unclaimed rewards.
    function _pokeRewards(address token) internal returns (uint256 acc) {
        acc = _accRewardPerShare[token];

        uint256 supply = _totalLockedOf[token];
        if (supply == 0) return acc;

        try IPumperRewardToken(token).pendingRewards{gas: REWARD_CALL_GAS}(address(this)) returns (uint256 pending) {
            if (pending == 0) return acc;

            address rewardTokenAddr;
            try IPumperRewardToken(token).rewardToken{gas: REWARD_CALL_GAS}() returns (address rt) {
                rewardTokenAddr = rt;
            } catch {
                return acc;
            }
            // A token paying rewards in itself would tangle this contract's
            // own locked-balance accounting with its reward accounting --
            // no real Pumper token does this; simply not supporting it is
            // safer than reasoning through that interaction.
            if (rewardTokenAddr == address(0) || rewardTokenAddr == token) return acc;

            address pinned = _rewardTokenOf[token];
            if (pinned != address(0) && pinned != rewardTokenAddr) {
                // Already pinned to a different currency than this call is
                // reporting -- refuse to accrue rather than risk crediting
                // the wrong asset. (Not pinning yet on the address(0) case:
                // see below -- that only happens once a claim is verified.)
                return acc;
            }

            uint256 before = IERC20(rewardTokenAddr).balanceOf(address(this));
            try IPumperRewardToken(token).claimRewards{gas: REWARD_CALL_GAS}() returns (uint256) {
                uint256 claimed = IERC20(rewardTokenAddr).balanceOf(address(this)) - before;
                if (claimed == 0) return acc;

                // Only pin AFTER a real, measured claim -- never from
                // pendingRewards()/rewardToken() alone, both of which can
                // resolve to something without a single token ever actually
                // moving (a bug, or a token deliberately reporting a
                // nonzero pending amount it never intends to pay). Pinning
                // on those alone would let one bad call permanently and
                // irreversibly block every future, correct claim for this
                // token via the mismatch check above.
                if (pinned == address(0)) {
                    _rewardTokenOf[token] = rewardTokenAddr;
                }

                acc += (claimed * ACC_PRECISION) / supply;
                _accRewardPerShare[token] = acc;
            } catch {
                // Reported pending but the actual claim failed -- leave the
                // accumulator (and the pin) untouched rather than reverting
                // the caller.
            }
        } catch {
            // `token` doesn't implement the reward interface at all -- this
            // contract locks any ERC20, not just reward-paying ones.
        }
    }

    /// @dev Syncs `token`'s accumulator, banks whatever `lockId` has newly
    ///      earned (at its balance BEFORE this call's caller mutates it) into
    ///      `_rewardOwed`, and rebases its debt to that same balance at the
    ///      now-current accumulator. Callers that are about to change
    ///      `l.amount` must re-set `_rewardDebt[lockId]` afterwards using the
    ///      NEW amount and the `acc` this function returns.
    function _checkpoint(uint256 lockId, address token) internal returns (uint256 acc) {
        acc = _pokeRewards(token);

        Lock storage l = _locks[lockId];
        uint256 accumulated = (l.amount * acc) / ACC_PRECISION;
        uint256 debt = _rewardDebt[lockId];
        if (accumulated > debt) {
            _rewardOwed[lockId] += accumulated - debt;
        }
        _rewardDebt[lockId] = accumulated;
    }

    /// @dev Pulls `amount` of `token` from the caller and returns how much
    ///      this contract's balance actually increased by.
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    /// @dev transfer/transferFrom that also accepts tokens which don't
    ///      return a bool at all (mainnet USDT being the canonical example)
    ///      -- IERC20's strict bool-returning signature would revert on
    ///      those even though the transfer itself succeeded. Empty
    ///      returndata is treated as success, matching the widely-used
    ///      SafeERC20 pattern for exactly this class of non-standard token.
    ///      Scoped to this contract rather than the shared IERC20 interface,
    ///      since supporting "any ERC20" is this contract's whole point.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev View-only counterpart of the pinning check in _pokeRewards --
    ///      used solely so `pendingReward` never projects an accrual that
    ///      claimReward would actually refuse to honour.
    function _tryRewardTokenMatches(address token, address pinned) internal view returns (bool) {
        try IPumperRewardToken(token).rewardToken{gas: REWARD_CALL_GAS}() returns (address rt) {
            return rt == pinned;
        } catch {
            return false;
        }
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //

    function lockCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        return _locks[lockId];
    }

    function lockIdsForToken(address token) external view returns (uint256[] memory) {
        return _lockIdsByToken[token];
    }

    function lockIdsForLocker(address locker) external view returns (uint256[] memory) {
        return _lockIdsByLocker[locker];
    }

    /// @notice The reward currency pinned for `token`, or address(0) if no
    ///         claim has ever been verified for it yet.
    function rewardTokenOf(address token) external view returns (address) {
        return _rewardTokenOf[token];
    }

    /// @notice Sum of every still-locked (not withdrawn) amount for `token` --
    ///         the raw number a "locked score" is built from.
    function totalLocked(address token) external view returns (uint256) {
        return _totalLockedOf[token];
    }

    /// @notice Live projection of what `claimReward(lockId)` would pay out
    ///         right now, including reward accrued since the last poke --
    ///         does not mutate state (can't actually call the token's own
    ///         `claimRewards`, since that's non-view), just estimates it.
    function pendingReward(uint256 lockId) external view returns (uint256) {
        Lock storage l = _locks[lockId];
        address token = l.token;
        uint256 acc = _accRewardPerShare[token];

        uint256 supply = _totalLockedOf[token];
        address pinned = _rewardTokenOf[token];
        if (supply > 0) {
            try IPumperRewardToken(token).pendingRewards{gas: REWARD_CALL_GAS}(address(this)) returns (uint256 pendingAtToken) {
                // Mirrors _pokeRewards' own trust rule: only project this as
                // real if the token's payout asset still matches whatever
                // was already verified, so this view never promises a
                // number claimReward would actually refuse to honour.
                bool consistent = pinned == address(0)
                    || _tryRewardTokenMatches(token, pinned);
                if (consistent) acc += (pendingAtToken * ACC_PRECISION) / supply;
            } catch {
                // Not a reward-paying token -- acc stays whatever it already was (0).
            }
        }

        uint256 accumulated = (l.amount * acc) / ACC_PRECISION;
        uint256 debt = _rewardDebt[lockId];
        uint256 unsettled = accumulated > debt ? accumulated - debt : 0;
        return _rewardOwed[lockId] + unsettled;
    }
}
