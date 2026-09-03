// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20, INonfungiblePositionManager} from "./Interfaces.sol";

/// @notice Minimal ERC721 view used to confirm this contract actually holds a
///         position before recording a lock for it. Declared locally so the
///         guard does not depend on `INonfungiblePositionManager` exposing
///         `ownerOf` in Interfaces.sol.
interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Permissionless LP lock, no rewards. Sibling to PumperTokenLock.sol
///         (same nonReentrant/MAX_LOCK_DURATION/fee-on-transfer-safe-pull
///         conventions, same extend-only `relock` rule) but stripped of all
///         reward-accumulator/claim machinery -- an LP token or position has
///         nothing to claim through this contract, so none of that plumbing
///         is carried over.
///
///         Locks TWO different kinds of asset through one lock-id space:
///           - ERC20 (a Uniswap V2 LP token, or any plain ERC20): approve +
///             `lockERC20`, same UX as PumperTokenLock.
///           - ERC721 (a Uniswap V3 position NFT): locked via a single
///             `positionManager.safeTransferFrom(owner, address(this), tokenId,
///             abi.encode(uint64 unlockTime))` -- no separate approval step.
///             The `data` payload MUST be exactly `abi.encode(uint64)` (32
///             bytes); any other non-empty length reverts the transfer
///             (`BadLockData`). The receiving `onERC721Received` hook decodes
///             `unlockTime` and records `asset = msg.sender` (the calling
///             contract, which for a standard ERC721 IS the NFT contract
///             itself -- never trusted from calldata), so this locks any
///             V3-style position manager permissionlessly, not just one
///             hardcoded address.
///
///         PHANTOM-LOCK GUARD. `onERC721Received` is externally callable, so
///         before recording anything it requires that this contract genuinely
///         owns `tokenId` on the calling manager (`ownerOf == address(this)`).
///         A real transfer moves the token before invoking the hook, so it
///         passes; a bare direct call (no transfer) from an EOA or unrelated
///         contract reverts (`NotHeld`) and cannot create a backing-less entry
///         in a real manager's namespace. A contract that lies about `ownerOf`
///         can still only create entries in ITS OWN (msg.sender) namespace --
///         harmless to every real lock, and the enumeration-spam residual is
///         handled by the paginated `*Range` views rather than by any admin.
///
///         A locked V3 position keeps earning trading fees the whole time it's
///         locked; `collectFeesNFT` lets the locker claim those at any point
///         (even while still locked) without touching the position itself --
///         only withdrawing the NFT is gated on `unlockTime`.
///
///         Also implements `ILiquidityLocker`'s `lock(positionManager, tokenId,
///         owner)` signature (see Interfaces.sol). That flow transfers the NFT
///         with NO calldata first, then calls `lock` in a separate call within
///         the same transaction; `onERC721Received` handles the empty-data
///         case by holding the NFT in escrow, attributed to nobody, until
///         `lock` is called by that EXACT depositor -- closing off the
///         griefing hole a permissionless `lock()` would otherwise open.
///         An escrowed-but-not-yet-locked NFT can be pulled back out at any
///         time by that same depositor via `reclaimPending`, so a bare
///         (no-data) transfer is never an irreversible commitment.
contract PumperLPLocker {
    enum Kind {
        ERC20,
        ERC721
    }

    struct Lock {
        Kind kind;
        address asset; // ERC20: the LP token. ERC721: the position manager.
        uint256 amountOrId; // ERC20: live locked amount (0 once withdrawn). ERC721: the tokenId.
        address locker;
        uint64 unlockTime;
        uint64 createdAt; // set once at lock time, never touched again -- drives a progress bar
        bool withdrawn;
    }

    // Same fat-finger guard as PumperTokenLock: a typo'd unlock timestamp
    // shouldn't be able to lock funds for millennia with no way back.
    uint64 public constant MAX_LOCK_DURATION = 50 * 365 days;

    Lock[] private _locks;

    mapping(address => uint256[]) private _lockIdsByToken; // ERC20 only
    mapping(address => uint256[]) private _lockIdsByLocker; // both kinds
    mapping(address => uint256) private _totalLockedOf; // ERC20 only, sum of active locks

    // keccak256(positionManager, tokenId) -> lockId + 1 (0 = not locked / already withdrawn)
    mapping(bytes32 => uint256) private _lockIdForPosition;
    // Same key -- set only for the "bare transferFrom, `lock()` comes next in
    // the same tx" flow, cleared the instant `lock()` or `reclaimPending`
    // succeeds.
    mapping(bytes32 => address) private _pendingDepositor;

    uint256 private _reentrancyStatus = 1;

    event LockedERC20(uint256 indexed lockId, address indexed token, address indexed locker, uint256 amount, uint64 unlockTime);
    event LockedNFT(
        uint256 indexed lockId, address indexed positionManager, uint256 indexed tokenId, address locker, uint64 unlockTime
    );
    event LockIncreased(uint256 indexed lockId, uint256 addedAmount, uint256 newAmount);
    event LockExtended(uint256 indexed lockId, uint64 previousUnlockTime, uint64 newUnlockTime);
    event WithdrawnERC20(uint256 indexed lockId, address indexed locker, uint256 amount);
    event WithdrawnNFT(uint256 indexed lockId, address indexed locker, uint256 tokenId);
    event FeesCollected(uint256 indexed lockId, address indexed recipient, uint256 amount0, uint256 amount1);
    event PendingReclaimed(address indexed positionManager, uint256 indexed tokenId, address indexed depositor);

    error ZeroAmount();
    error ZeroAddress();
    error UnlockInPast();
    error UnlockTooFar();
    error NotLocker();
    error NotLater();
    error StillLocked(uint64 unlockTime);
    error AlreadyWithdrawn();
    error AlreadyLocked();
    error WrongKind();
    error TransferFailed();
    error Reentrant();
    error NotHeld();
    error BadLockData();
    error NothingPending();

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert Reentrant();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    // --------------------------------------------------------------------- //
    //                          V2 / ERC20 LP path                           //
    // --------------------------------------------------------------------- //

    /// @notice Lock `amount` of `token`, pulled from the caller, until
    ///         `unlockTime`. Caller must have approved this contract first.
    ///         The amount actually recorded is however much this contract's
    ///         balance went up by, not the requested `amount` -- protects
    ///         against a fee-on-transfer/deflationary LP token under-crediting.
    function lockERC20(address token, uint256 amount, uint64 unlockTime) external nonReentrant returns (uint256 lockId) {
        if (amount == 0) revert ZeroAmount();
        _checkUnlockTime(unlockTime);

        uint256 received = _pull(token, amount);
        if (received == 0) revert ZeroAmount();

        lockId = _locks.length;
        _locks.push(
            Lock({
                kind: Kind.ERC20,
                asset: token,
                amountOrId: received,
                locker: msg.sender,
                unlockTime: unlockTime,
                createdAt: uint64(block.timestamp),
                withdrawn: false
            })
        );
        _lockIdsByToken[token].push(lockId);
        _lockIdsByLocker[msg.sender].push(lockId);
        _totalLockedOf[token] += received;

        emit LockedERC20(lockId, token, msg.sender, received, unlockTime);
    }

    /// @notice Add more of the same token to a lock you own, without changing
    ///         its unlock time.
    function increaseLockERC20(uint256 lockId, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Lock storage l = _locks[lockId];
        if (l.kind != Kind.ERC20) revert WrongKind();
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();

        address token = l.asset;
        uint256 received = _pull(token, amount);
        if (received == 0) revert ZeroAmount();

        l.amountOrId += received;
        _totalLockedOf[token] += received;

        emit LockIncreased(lockId, received, l.amountOrId);
    }

    /// @notice Withdraw a fully-matured ERC20 lock's principal back to its locker.
    function withdrawERC20(uint256 lockId) external nonReentrant {
        Lock storage l = _locks[lockId];
        if (l.kind != Kind.ERC20) revert WrongKind();
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime);

        address token = l.asset;
        uint256 amount = l.amountOrId;
        _totalLockedOf[token] -= amount;

        // Effects before interaction, same reasoning as PumperTokenLock.
        l.withdrawn = true;
        l.amountOrId = 0;

        // Capped to actual balance for the same fee-on-transfer reason as
        // PumperTokenLock's withdraw -- see that contract's doc comment.
        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 payout = amount < available ? amount : available;
        if (payout > 0) _safeTransfer(token, msg.sender, payout);

        emit WithdrawnERC20(lockId, msg.sender, payout);
    }

    // --------------------------------------------------------------------- //
    //                        V3 / ERC721 position path                     //
    // --------------------------------------------------------------------- //

    /// @notice ERC721 receiver hook. Rejects (`NotHeld`) unless this contract
    ///         genuinely owns `tokenId` on the calling manager -- see the
    ///         PHANTOM-LOCK GUARD note in the contract doc. Then two cases:
    ///           - `data` is exactly `abi.encode(uint64 unlockTime)` (32 bytes)
    ///             -> lock created immediately, owned by `from`.
    ///           - `data` is empty -> held in escrow, unattributed, until
    ///             `lock()` is called by this exact `from` (the
    ///             ILiquidityLocker/launchpad flow), or pulled back out by
    ///             `from` via `reclaimPending`.
    ///         Any other `data` length reverts (`BadLockData`).
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data) external nonReentrant returns (bytes4) {
        address positionManager = msg.sender;

        // Only record a position this contract actually now holds. Blocks
        // backing-less "phantom" entries created by a direct call that never
        // transferred a token in.
        if (IERC721Like(positionManager).ownerOf(tokenId) != address(this)) revert NotHeld();

        bytes32 key = _positionKey(positionManager, tokenId);
        if (_lockIdForPosition[key] != 0) revert AlreadyLocked();

        if (data.length == 0) {
            if (_pendingDepositor[key] != address(0)) revert AlreadyLocked();
            _pendingDepositor[key] = from;
            return this.onERC721Received.selector;
        }

        if (data.length != 32) revert BadLockData();
        uint64 unlockTime = abi.decode(data, (uint64));
        _createNFTLock(positionManager, tokenId, from, unlockTime);
        return this.onERC721Received.selector;
    }

    /// @notice ILiquidityLocker-compatible entrypoint -- finishes locking an
    ///         NFT that was deposited via a bare (no-data) safeTransferFrom,
    ///         crediting it to `owner` with a max-duration lock. Callable ONLY
    ///         by the same address that performed that deposit -- not by anyone
    ///         else, and not usable for a position that was deposited WITH lock
    ///         data already (that one locked itself atomically).
    function lock(address positionManager, uint256 tokenId, address owner) external nonReentrant {
        if (owner == address(0)) revert ZeroAddress();
        bytes32 key = _positionKey(positionManager, tokenId);
        if (_pendingDepositor[key] != msg.sender) revert NotLocker();
        delete _pendingDepositor[key];
        _createNFTLock(positionManager, tokenId, owner, uint64(block.timestamp) + MAX_LOCK_DURATION);
    }

    /// @notice Pull back an NFT that was bare-transferred into escrow but never
    ///         finalized with `lock()`. Callable only by the exact depositor
    ///         recorded for that position. Makes a no-data deposit fully
    ///         reversible -- it is never a forced commitment to a max-duration
    ///         lock. Only touches the escrow record; a position that has
    ///         already been locked has no pending entry and is unaffected.
    function reclaimPending(address positionManager, uint256 tokenId) external nonReentrant {
        bytes32 key = _positionKey(positionManager, tokenId);
        address depositor = _pendingDepositor[key];
        if (depositor == address(0)) revert NothingPending();
        if (depositor != msg.sender) revert NotLocker();

        // Effects before interaction.
        delete _pendingDepositor[key];

        INonfungiblePositionManager(positionManager).safeTransferFrom(address(this), msg.sender, tokenId);
        emit PendingReclaimed(positionManager, tokenId, msg.sender);
    }

    /// @notice Withdraw a fully-matured NFT lock's position back to its locker.
    function withdrawNFT(uint256 lockId) external nonReentrant {
        Lock storage l = _locks[lockId];
        if (l.kind != Kind.ERC721) revert WrongKind();
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < l.unlockTime) revert StillLocked(l.unlockTime);

        address positionManager = l.asset;
        uint256 tokenId = l.amountOrId;

        l.withdrawn = true;
        _lockIdForPosition[_positionKey(positionManager, tokenId)] = 0;

        INonfungiblePositionManager(positionManager).safeTransferFrom(address(this), msg.sender, tokenId);

        emit WithdrawnNFT(lockId, msg.sender, tokenId);
    }

    /// @notice Collect accrued trading fees from a locked V3 position, straight
    ///         to `recipient`. Callable anytime by the lock's owner, locked or
    ///         matured, right up until the position itself is withdrawn -- the
    ///         position keeps trading and earning fees the whole time it's
    ///         locked, this just lets the owner actually claim them without
    ///         waiting for `unlockTime`.
    function collectFeesNFT(uint256 lockId, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        Lock storage l = _locks[lockId];
        if (l.kind != Kind.ERC721) revert WrongKind();
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (recipient == address(0)) revert ZeroAddress();

        (amount0, amount1) = INonfungiblePositionManager(l.asset).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: l.amountOrId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit FeesCollected(lockId, recipient, amount0, amount1);
    }

    function _createNFTLock(address positionManager, uint256 tokenId, address owner, uint64 unlockTime) internal {
        _checkUnlockTime(unlockTime);
        bytes32 key = _positionKey(positionManager, tokenId);
        if (_lockIdForPosition[key] != 0) revert AlreadyLocked();

        uint256 lockId = _locks.length;
        _locks.push(
            Lock({
                kind: Kind.ERC721,
                asset: positionManager,
                amountOrId: tokenId,
                locker: owner,
                unlockTime: unlockTime,
                createdAt: uint64(block.timestamp),
                withdrawn: false
            })
        );
        _lockIdsByLocker[owner].push(lockId);
        _lockIdForPosition[key] = lockId + 1;

        emit LockedNFT(lockId, positionManager, tokenId, owner, unlockTime);
    }

    // --------------------------------------------------------------------- //
    //                                 Shared                                //
    // --------------------------------------------------------------------- //

    /// @notice Push a lock's unlock time further out, either kind. Reverts if
    ///         `newUnlockTime` is not strictly later than the current one --
    ///         locks can only ever get longer, never shorter.
    function relock(uint256 lockId, uint64 newUnlockTime) external nonReentrant {
        Lock storage l = _locks[lockId];
        if (msg.sender != l.locker) revert NotLocker();
        if (l.withdrawn) revert AlreadyWithdrawn();
        if (newUnlockTime <= l.unlockTime) revert NotLater();
        if (newUnlockTime > block.timestamp + MAX_LOCK_DURATION) revert UnlockTooFar();

        uint64 previous = l.unlockTime;
        l.unlockTime = newUnlockTime;
        emit LockExtended(lockId, previous, newUnlockTime);
    }

    function _checkUnlockTime(uint64 unlockTime) internal view {
        if (unlockTime <= block.timestamp) revert UnlockInPast();
        if (unlockTime > block.timestamp + MAX_LOCK_DURATION) revert UnlockTooFar();
    }

    function _positionKey(address positionManager, uint256 tokenId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(positionManager, tokenId));
    }

    /// @dev Pulls `amount` of `token` from the caller and returns how much
    ///      this contract's balance actually increased by.
    function _pull(address token, uint256 amount) internal returns (uint256 received) {
        uint256 before = IERC20(token).balanceOf(address(this));
        _safeTransferFrom(token, msg.sender, address(this), amount);
        received = IERC20(token).balanceOf(address(this)) - before;
    }

    /// @dev transfer/transferFrom that also accepts tokens which don't return
    ///      a bool at all -- same SafeERC20-style pattern as PumperTokenLock.
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
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

    /// @notice Number of lock ids recorded for a token / a locker. Use with the
    ///         `*Range` views to page a list that may have been spammed large
    ///         (see the PHANTOM-LOCK GUARD note) instead of pulling it whole.
    function tokenLockCount(address token) external view returns (uint256) {
        return _lockIdsByToken[token].length;
    }

    function lockerLockCount(address locker) external view returns (uint256) {
        return _lockIdsByLocker[locker].length;
    }

    /// @notice A page `[start, start+count)` (clamped) of a token's lock ids.
    function lockIdsForTokenRange(address token, uint256 start, uint256 count) external view returns (uint256[] memory) {
        return _page(_lockIdsByToken[token], start, count);
    }

    /// @notice A page `[start, start+count)` (clamped) of a locker's lock ids.
    ///         Front-ends should page this and filter each lock's `asset`
    ///         against known position managers, since anyone can attribute
    ///         entries here (residual of permissionless locking).
    function lockIdsForLockerRange(address locker, uint256 start, uint256 count) external view returns (uint256[] memory) {
        return _page(_lockIdsByLocker[locker], start, count);
    }

    function _page(uint256[] storage arr, uint256 start, uint256 count) private view returns (uint256[] memory page) {
        uint256 n = arr.length;
        if (start >= n) return new uint256[](0);
        uint256 end = start + count;
        if (end > n) end = n;
        page = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = arr[i];
        }
    }

    /// @notice Whether `tokenId` on `positionManager` is currently locked
    ///         here, and its lockId if so.
    function lockIdForPosition(address positionManager, uint256 tokenId) external view returns (bool locked, uint256 lockId) {
        uint256 stored = _lockIdForPosition[_positionKey(positionManager, tokenId)];
        if (stored == 0) return (false, 0);
        return (true, stored - 1);
    }

    /// @notice The depositor of a bare-transferred NFT awaiting `lock()` /
    ///         `reclaimPending`, or address(0) if none.
    function pendingDepositor(address positionManager, uint256 tokenId) external view returns (address) {
        return _pendingDepositor[_positionKey(positionManager, tokenId)];
    }
}
