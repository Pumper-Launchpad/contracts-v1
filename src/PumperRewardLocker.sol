// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PumperRewardLocker
/// @notice One per launched token, deployed by the token itself in its
///         constructor. Holds fixed-term locks of that ONE token and streams
///         the protocol's reward currency (USDC, or WgUSDT on Stable) to
///         lockers, weighted by how long they committed.
///
///         FIXED-TERM, TIME-WEIGHTED. A stake picks one of four tiers; the
///         principal is frozen until that term elapses, and the longer the
///         term the more reward weight each token carries:
///
///             tier      term      boost
///             ----      ----      -----
///             T30       30 days   1.0x
///             T90       90 days   1.5x
///             T180     180 days   2.5x
///             T365     365 days   4.0x
///
///         weight = amount * boost. Rewards accrue per unit of WEIGHT, so a
///         365-day locker earns 4x what a 30-day locker earns on the same
///         principal. The boost is FLAT for the whole term (no ve-style decay)
///         and drops to zero at withdrawal.
///
///         EARLY EXIT. `requestUnlock` starts a EARLY_UNLOCK_COOLDOWN (7-day)
///         timer and IMMEDIATELY zeroes the lock's weight -- from that moment
///         it earns nothing (rewards already banked stay claimable). After the
///         7 days the principal can be withdrawn. That is the whole penalty:
///         a week of no earnings, no forfeit of what was already earned, no
///         cut to principal. A lock that reaches its natural `unlockTime`
///         first can just withdraw -- no request, no cooldown, full earnings
///         to the end.
///
///         MasterChef accounting (single pool, `weight` in place of balance):
///           depositReward(amt): accRewardPerShare += amt * ACC_PRECISION / totalWeight
///           claimable(lock)   = lock.weight * accRewardPerShare / ACC_PRECISION
///                                 - lock.rewardDebt   (+ previously banked `owed`)
///
///         Rewards are NOT locked -- only principal is. A lock can `claim` its
///         accrued reward currency at any time, including before its term ends.
///
///         Funding is push, not pull: the launchpad (or anyone) calls
///         `depositReward` and transfers the reward currency in. If nothing is
///         locked, the deposit goes to `fallbackRecipient` -- there is no one
///         to accrue it to, and parking it would let the first locker sweep
///         the backlog. `PumperToken` wires this to the token's `creator`.
///
///         Immutable and admin-free. `stakeToken`, `rewardToken`,
///         `fallbackRecipient` and the tier table are all fixed forever.
contract PumperRewardLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Generous headroom: a 6-decimal reward token against an 18-decimal
    ///      stake token differ by 1e12, and `amt * PREC / totalWeight` must not
    ///      round to zero for a realistic deposit against a large weight. 1e36
    ///      covers it regardless of decimals.
    uint256 private constant ACC_PRECISION = 1e36;

    /// @dev Boost is expressed in basis points of principal: 10_000 = 1.0x.
    uint256 private constant BOOST_ONE = 10_000;

    /// @notice Wait between `requestUnlock` and being able to `withdraw` a
    ///         still-immature lock. The lock earns nothing for this whole
    ///         window (its weight is zeroed the instant `requestUnlock` runs).
    uint64 public constant EARLY_UNLOCK_COOLDOWN = 7 days;

    enum Tier {
        T30,
        T90,
        T180,
        T365
    }

    /// @notice The token locked in this contract. Fixed forever.
    IERC20 public immutable stakeToken;

    /// @notice The reward currency payouts are made in (USDC / WgUSDT).
    IERC20 public immutable rewardToken;

    /// @notice Receives a `depositReward` that lands while `totalWeight == 0`.
    address public immutable fallbackRecipient;

    struct Lock {
        address owner;
        uint256 amount; // principal, in stakeToken units
        uint256 weight; // amount * boost / BOOST_ONE; 0 once withdrawn OR unlocking
        uint64 unlockTime; // block.timestamp + tier term
        uint8 tier; // Tier enum value, for UIs
        bool withdrawn; // principal returned
        bool unlocking; // early exit requested; weight already zeroed
        uint64 cooldownEnd; // when an early-exit withdraw becomes allowed
        uint256 rewardDebt; // weight * accRewardPerShare / ACC_PRECISION at last touch
        uint256 owed; // settled but unclaimed reward currency
    }

    uint256 public totalWeight; // sum of every active lock's weight
    uint256 public totalPrincipal; // sum of every active lock's principal (info only)
    uint256 public accRewardPerShare; // scaled by ACC_PRECISION, per unit weight
    uint256 public rewardsFunded; // lifetime reward currency accrued to lockers

    uint256 public nextLockId = 1;
    mapping(uint256 lockId => Lock) private _locks;
    mapping(address user => uint256[] lockIds) private _userLocks; // active only; pruned on withdraw

    /// @notice Cap on concurrent (un-withdrawn) locks per wallet -- bounds the
    ///         gas of the sum/enumeration views and of a `claimMany` over a
    ///         wallet's whole set. Re-lock after withdrawing to free a slot.
    uint256 public constant MAX_LOCKS_PER_USER = 64;

    /// @notice Smallest principal a single lock may hold (post-transfer, so it
    ///         is the amount actually received). Not a UX gate -- 0.001 token
    ///         is nothing for a real locker -- it exists to keep `totalWeight`
    ///         off pathologically small values. A sole locker with a 1-wei
    ///         weight would let one permissionless `depositReward` push
    ///         `accRewardPerShare` up by `amount * ACC_PRECISION`, far enough
    ///         that a later honest lock's `weight * accRewardPerShare` overflows
    ///         uint256 in `_settle`/`pendingReward` and bricks its withdrawal.
    ///         A floor here removes that cheap path (it does not, by itself,
    ///         prove no overflow at every input -- see the note on
    ///         `depositReward`). Tune per launch against real supply/price.
    uint256 public constant MIN_STAKE = 1e15; // 0.001 token (18dp)

    event Locked(
        address indexed user, uint256 indexed lockId, uint8 tier, uint256 amount, uint256 weight, uint64 unlockTime
    );
    event UnlockRequested(address indexed user, uint256 indexed lockId, uint64 cooldownEnd);
    event Withdrawn(address indexed user, uint256 indexed lockId, uint256 amount);
    event RewardClaimed(address indexed user, uint256 indexed lockId, uint256 amount);
    event RewardDeposited(address indexed from, uint256 amount);
    event RewardRoutedToFallback(address indexed from, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error SameToken();
    error BelowMinStake();
    error NotLockOwner();
    error StillLocked();
    error AlreadyWithdrawn();
    error AlreadyUnlocking();
    error AlreadyMatured();
    error NothingToClaim();
    error TooManyLocks();
    error UnknownLock();

    constructor(address _stakeToken, address _rewardToken, address _fallbackRecipient) {
        if (_stakeToken == address(0) || _rewardToken == address(0) || _fallbackRecipient == address(0)) {
            revert ZeroAddress();
        }
        // Principal and rewards must live in two distinct balances. This
        // contract measures each independently (`stakeToken.balanceOf(this)` in
        // `stake`, `rewardToken.balanceOf(this)` in `depositReward`); one token
        // for both roles turns each of those reads into a moving target.
        if (_stakeToken == _rewardToken) revert SameToken();
        stakeToken = IERC20(_stakeToken);
        rewardToken = IERC20(_rewardToken);
        fallbackRecipient = _fallbackRecipient;
    }

    // --------------------------------------------------------------------- //
    //                              Tier table                             //
    // --------------------------------------------------------------------- //

    /// @notice Term length and reward boost for a tier. `boost` is in bps of
    ///         principal (10_000 = 1.0x).
    function tierInfo(Tier tier) public pure returns (uint64 term, uint256 boost) {
        if (tier == Tier.T30) return (30 days, 10_000); // 1.0x
        if (tier == Tier.T90) return (90 days, 15_000); // 1.5x
        if (tier == Tier.T180) return (180 days, 25_000); // 2.5x
        return (365 days, 40_000); // T365 -- 4.0x
    }

    // --------------------------------------------------------------------- //
    //                               Locking                              //
    // --------------------------------------------------------------------- //

    /// @notice Lock `amount` of the token for the given `tier`. The principal
    ///         is frozen until the tier's term elapses (or, via `requestUnlock`,
    ///         until a 7-day cooldown ends). Reward weight is `amount * boost`,
    ///         flat for the term. The amount credited is this contract's actual
    ///         balance increase, so a fee-on-transfer token can never
    ///         over-credit a lock. Reverts if that credited amount is below
    ///         `MIN_STAKE`. Returns the new lock's id.
    function stake(uint256 amount, Tier tier) external nonReentrant returns (uint256 lockId) {
        if (amount == 0) revert ZeroAmount();
        if (_userLocks[msg.sender].length >= MAX_LOCKS_PER_USER) revert TooManyLocks();

        uint256 before = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakeToken.balanceOf(address(this)) - before;
        if (received < MIN_STAKE) revert BelowMinStake();

        (uint64 term, uint256 boost) = tierInfo(tier);
        uint256 weight = (received * boost) / BOOST_ONE;
        uint64 unlockTime = uint64(block.timestamp) + term;

        totalWeight += weight;
        totalPrincipal += received;

        lockId = nextLockId++;
        _locks[lockId] = Lock({
            owner: msg.sender,
            amount: received,
            weight: weight,
            unlockTime: unlockTime,
            tier: uint8(tier),
            withdrawn: false,
            unlocking: false,
            cooldownEnd: 0,
            rewardDebt: (weight * accRewardPerShare) / ACC_PRECISION,
            owed: 0
        });
        _userLocks[msg.sender].push(lockId);

        emit Locked(msg.sender, lockId, uint8(tier), received, weight, unlockTime);
    }

    /// @notice Begin an early exit on a still-immature lock. Starts the 7-day
    ///         `EARLY_UNLOCK_COOLDOWN` and IMMEDIATELY zeroes the lock's weight
    ///         -- it earns nothing from here on. Rewards already banked stay
    ///         claimable. After the cooldown, call `withdraw`. There is no
    ///         un-doing this and no way to shorten the wait; a lock past its
    ///         natural `unlockTime` should just `withdraw` directly.
    function requestUnlock(uint256 lockId) external nonReentrant {
        Lock storage l = _locks[lockId];
        if (l.owner == address(0)) revert UnknownLock();
        if (l.owner != msg.sender) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (l.unlocking) revert AlreadyUnlocking();
        if (block.timestamp >= l.unlockTime) revert AlreadyMatured();

        _settle(l); // bank everything earned up to now, at full weight

        totalWeight -= l.weight;
        l.weight = 0; // stops earning immediately
        l.rewardDebt = 0;
        l.unlocking = true;
        l.cooldownEnd = uint64(block.timestamp) + EARLY_UNLOCK_COOLDOWN;

        emit UnlockRequested(msg.sender, lockId, l.cooldownEnd);
    }

    /// @notice Return a lock's principal to its owner. Allowed once the lock
    ///         reaches its natural `unlockTime`, OR (after `requestUnlock`) once
    ///         its `cooldownEnd` passes. Rewards already earned stay claimable
    ///         via `claim` afterwards.
    function withdraw(uint256 lockId) public nonReentrant {
        Lock storage l = _locks[lockId];
        if (l.owner == address(0)) revert UnknownLock();
        if (l.owner != msg.sender) revert NotLockOwner();
        if (l.withdrawn) revert AlreadyWithdrawn();

        bool matured = block.timestamp >= l.unlockTime;
        bool cooled = l.unlocking && block.timestamp >= l.cooldownEnd;
        if (!matured && !cooled) revert StillLocked();

        _settle(l); // no-op if already unlocking (weight 0); banks the term otherwise

        uint256 amount = l.amount;
        if (l.weight != 0) {
            totalWeight -= l.weight;
            l.weight = 0; // no further accrual
        }
        totalPrincipal -= amount;
        l.withdrawn = true;
        _removeUserLock(msg.sender, lockId);

        // Interaction last. A reentrant stake token re-entering any function
        // here hits the nonReentrant guard; state is already fully updated.
        stakeToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, lockId, amount);
    }

    /// @notice Claim all settled reward currency for one lock. Callable any
    ///         time, including before the lock matures -- only principal is
    ///         time-locked, rewards are not.
    function claim(uint256 lockId) public nonReentrant returns (uint256 amount) {
        Lock storage l = _locks[lockId];
        if (l.owner == address(0)) revert UnknownLock();
        if (l.owner != msg.sender) revert NotLockOwner();

        _settle(l);
        l.rewardDebt = (l.weight * accRewardPerShare) / ACC_PRECISION;

        amount = l.owed;
        if (amount == 0) revert NothingToClaim();
        l.owed = 0;

        rewardToken.safeTransfer(msg.sender, amount);
        emit RewardClaimed(msg.sender, lockId, amount);
    }

    /// @notice Claim across several of the caller's locks in one call. Skips
    ///         (rather than reverts on) a lock with nothing owed, so a mixed
    ///         set still pays out. Reverts only if the total is zero.
    function claimMany(uint256[] calldata lockIds) external nonReentrant returns (uint256 total) {
        for (uint256 i; i < lockIds.length; ++i) {
            Lock storage l = _locks[lockIds[i]];
            if (l.owner != msg.sender) revert NotLockOwner();

            _settle(l);
            l.rewardDebt = (l.weight * accRewardPerShare) / ACC_PRECISION;

            uint256 owed = l.owed;
            if (owed == 0) continue;
            l.owed = 0;
            total += owed;
            emit RewardClaimed(msg.sender, lockIds[i], owed);
        }
        if (total == 0) revert NothingToClaim();
        rewardToken.safeTransfer(msg.sender, total);
    }

    /// @notice Withdraw a matured lock's principal AND claim its rewards in one
    ///         call. Skips the claim leg (rather than reverting) when nothing
    ///         is owed.
    function exit(uint256 lockId) external {
        withdraw(lockId); // settles rewards into `owed`, reverts if still locked
        if (_locks[lockId].owed > 0) claim(lockId);
    }

    // --------------------------------------------------------------------- //
    //                            Reward funding                            //
    // --------------------------------------------------------------------- //

    /// @notice Fund the reward pool with reward currency pulled from the
    ///         caller (approve first). The launchpad calls this from its
    ///         buy/sell fee skim and LP-fee harvest; anyone may also top up.
    ///
    ///         If nothing is locked, the funds go to `fallbackRecipient`
    ///         instead of accruing -- there is no one to credit, and parking
    ///         it would let the first unit of weight claim the whole backlog.
    ///
    ///         `accRewardPerShare` grows by `received * ACC_PRECISION /
    ///         totalWeight`. `MIN_STAKE` keeps `totalWeight` large enough that
    ///         a later lock's `weight * accRewardPerShare` stays well inside
    ///         uint256 for any realistic lifetime deposit total; there is no
    ///         per-deposit cap (it would complicate the permissionless funding
    ///         path for a bound `MIN_STAKE` already makes unreachable).
    function depositReward(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 before = rewardToken.balanceOf(address(this));
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = rewardToken.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        if (totalWeight == 0) {
            rewardToken.safeTransfer(fallbackRecipient, received);
            emit RewardRoutedToFallback(msg.sender, received);
            return;
        }

        accRewardPerShare += (received * ACC_PRECISION) / totalWeight;
        rewardsFunded += received;
        emit RewardDeposited(msg.sender, received);
    }

    // --------------------------------------------------------------------- //
    //                              Internals                               //
    // --------------------------------------------------------------------- //

    /// @dev Bank whatever `l` has earned since its last touch into `l.owed`, at
    ///      its CURRENT weight. Caller updates `l.rewardDebt` afterwards.
    ///      `accRewardPerShare` only ever grows and `rewardDebt` was last set
    ///      from a value <= it, so the subtraction cannot underflow; guarded
    ///      anyway.
    function _settle(Lock storage l) internal {
        if (l.weight == 0) return;
        uint256 accumulated = (l.weight * accRewardPerShare) / ACC_PRECISION;
        if (accumulated > l.rewardDebt) {
            l.owed += accumulated - l.rewardDebt;
        }
    }

    /// @dev Swap-and-pop `lockId` out of the owner's active list. Order is not
    ///      meaningful (lockIds are the stable keys); this just keeps the list
    ///      to the concurrent-lock count so the views and `MAX_LOCKS_PER_USER`
    ///      stay meaningful.
    function _removeUserLock(address user, uint256 lockId) internal {
        uint256[] storage ids = _userLocks[user];
        uint256 n = ids.length;
        for (uint256 i; i < n; ++i) {
            if (ids[i] == lockId) {
                ids[i] = ids[n - 1];
                ids.pop();
                return;
            }
        }
    }

    // --------------------------------------------------------------------- //
    //                                Views                                 //
    // --------------------------------------------------------------------- //

    /// @notice Reward currency `lockId` could claim right now.
    function pendingReward(uint256 lockId) external view returns (uint256) {
        Lock storage l = _locks[lockId];
        uint256 accumulated = (l.weight * accRewardPerShare) / ACC_PRECISION;
        uint256 unsettled = accumulated > l.rewardDebt ? accumulated - l.rewardDebt : 0;
        return l.owed + unsettled;
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        return _locks[lockId];
    }

    /// @notice Timestamp at which `lockId`'s principal becomes withdrawable:
    ///         its natural `unlockTime`, or the earlier `cooldownEnd` once an
    ///         early exit has been requested. 0 for an unknown/withdrawn lock.
    function unlockAt(uint256 lockId) external view returns (uint64) {
        Lock storage l = _locks[lockId];
        if (l.owner == address(0) || l.withdrawn) return 0;
        if (l.unlocking && l.cooldownEnd < l.unlockTime) return l.cooldownEnd;
        return l.unlockTime;
    }

    /// @notice The caller-supplied wallet's active (un-withdrawn) lock ids.
    function lockIdsOf(address user) external view returns (uint256[] memory) {
        return _userLocks[user];
    }

    function lockCount(address user) external view returns (uint256) {
        return _userLocks[user].length;
    }

    /// @notice Sum of `user`'s active locks' reward weight.
    function weightOf(address user) external view returns (uint256 w) {
        uint256[] storage ids = _userLocks[user];
        for (uint256 i; i < ids.length; ++i) {
            w += _locks[ids[i]].weight;
        }
    }

    /// @notice Sum of `user`'s active locks' principal.
    function stakedOf(address user) external view returns (uint256 amount) {
        uint256[] storage ids = _userLocks[user];
        for (uint256 i; i < ids.length; ++i) {
            amount += _locks[ids[i]].amount;
        }
    }

    /// @notice Total reward currency `user` could claim right now across all
    ///         their active locks.
    function pendingRewardOf(address user) external view returns (uint256 total) {
        uint256[] storage ids = _userLocks[user];
        for (uint256 i; i < ids.length; ++i) {
            Lock storage l = _locks[ids[i]];
            uint256 accumulated = (l.weight * accRewardPerShare) / ACC_PRECISION;
            uint256 unsettled = accumulated > l.rewardDebt ? accumulated - l.rewardDebt : 0;
            total += l.owed + unsettled;
        }
    }
}
