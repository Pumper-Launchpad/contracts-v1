// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./Interfaces.sol";

/// @title FeferVault
/// @notice A treasury holding any ERC20 asset and native currency, with NO way
///         to move funds out except a proposal every admin can see and vote on,
///         resolved by a strict majority of the CURRENT admin set. There is no
///         owner tier, no single-admin withdraw, no emergency escape hatch --
///         the admin set itself changes only through the same
///         proposal-and-vote machinery, so a live majority of admins is the
///         only authority that can ever exist over this contract.
///
/// @dev DESIGN INVARIANTS (each earned by a bug found in a prior revision):
///
///   A. ADMIN CHANGES GO THROUGH A PROPOSAL, NOT onlyAdmin add/remove.
///      A lone admin who could unilaterally add an admin could add an address
///      they also control, manufacturing a second "vote" and defeating the
///      majority requirement on every future spend. AddAdmin/RemoveAdmin share
///      the exact same vote machinery as Spend.
///
///   B. TALLIES AND THRESHOLD ARE COMPUTED LIVE, NEVER SNAPSHOTTED.
///      Snapshotting a running counter had two holes: (1) a removed admin's
///      old yes-vote kept counting forever, letting a proposal execute on
///      votes from people no longer admins; (2) a threshold frozen while the
///      set was small stayed low as the set grew, so a stale proposal could be
///      drained by a tiny minority. Here `approve`/`deny`/`execute` recount
///      from scratch via `_tally`, counting only ballots from addresses that
///      are admins RIGHT NOW and were cast in their CURRENT tenure (see D),
///      and the threshold is `_admins.length / 2 + 1` computed fresh each call.
///
///   C. MIN_ADMINS IS A HARD FLOOR, CHECKED AT PROPOSE AND EXECUTE.
///      The set can move between a RemoveAdmin proposal opening and clearing,
///      so the floor is re-checked at execution, not only at propose time.
///      Because the floor is 3, `_requiredApprovals()` is always >= 2: no
///      single key, and no strict minority, can ever move funds.
///
///   D. ADMIN TENURE IS SESSION-SCOPED, SO RE-ADDING RESETS VOTES.
///      `voteOf` is never erased (the historical record stays complete), but
///      each admin holds a monotonically increasing `adminSession` id that is
///      reset when they are removed and freshly assigned when (re-)added. A
///      ballot records the voter's session at cast time; `_tally` counts it
///      only if that session still matches. So an admin removed and later
///      re-added does NOT silently resurrect their old ballots, and may vote
///      afresh in their new tenure on any still-open proposal.
///
///   E. EXECUTE-TIME RE-CHECKS FOR ADMIN MUTATIONS.
///      Propose-time `!isAdmin` / `isAdmin` guards are necessary but not
///      sufficient: two AddAdmin(X) (or two RemoveAdmin(X)) proposals can both
///      pass their propose-time check while neither has executed. Without a
///      re-check, the second execution would push X into `_admins` twice
///      (corrupting the `_admins`-array == `isAdmin`-map invariant and leaving
///      a permanent ghost entry after a later removal), or emit a misleading
///      AdminRemoved for a non-admin. Both mutations re-validate at execute.
///
///   F. PROPOSAL_TTL bounds proposal lifetime as defense in depth, and a
///      standalone `execute` lets any admin finalize a proposal that has
///      enough live approvals but never re-triggered execution inside an
///      `approve` call (e.g. the threshold dropped after the last vote).
contract FeferVault {
    /// Below this the set could be walked down to one and trivially captured.
    /// Keeps "multi-sig" meaningfully plural forever, and guarantees
    /// `_requiredApprovals()` >= 2. Enforced at RemoveAdmin propose AND execute.
    uint256 public constant MIN_ADMINS = 3;

    /// How long a proposal stays actionable after opening. Defense in depth on
    /// top of the live threshold -- a proposal open for years is a bad shape
    /// regardless of whether its threshold can drift.
    uint256 public constant PROPOSAL_TTL = 14 days;

    enum ProposalKind {
        Spend,
        AddAdmin,
        RemoveAdmin
    }

    enum ProposalStatus {
        Pending,
        Executed,
        Rejected
    }

    enum Vote {
        None,
        Approved,
        Denied
    }

    struct Proposal {
        ProposalKind kind;
        ProposalStatus status;
        // Spend only. token == address(0) means native currency.
        address token;
        // Spend: recipient. AddAdmin/RemoveAdmin: the admin in question.
        address target;
        // Spend only.
        uint256 amount;
        address proposer;
        uint64 createdAt;
    }

    address[] private _admins;
    mapping(address => bool) public isAdmin;

    /// Monotonic tenure id per admin. Assigned on add, reset to 0 on remove.
    /// A vote counts in `_tally` only while the voter's recorded session still
    /// equals this -- see invariant D.
    mapping(address => uint256) public adminSession;
    uint256 private _sessionCounter;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => Vote)) public voteOf;
    /// The admin session in which each ballot was cast, keyed proposal=>voter.
    mapping(uint256 => mapping(address => uint256)) private _voteSession;
    /// Everyone who has ever voted on a proposal, in vote order, deduplicated
    /// (an address appears at most once). Walked by `_tally`. Never pruned: a
    /// vote from someone later removed just stops counting, it isn't deleted.
    mapping(uint256 => address[]) private _voters;

    uint256 private _locked = 1;

    event AdminProposed(uint256 indexed id, ProposalKind kind, address indexed target, address indexed proposer);
    event SpendProposed(uint256 indexed id, address indexed token, address indexed to, uint256 amount, address proposer);
    event Voted(uint256 indexed id, address indexed admin, bool approved);
    event ProposalExecuted(uint256 indexed id);
    event ProposalRejected(uint256 indexed id);
    event AdminAdded(address indexed admin, uint256 indexed proposalId);
    event AdminRemoved(address indexed admin, uint256 indexed proposalId);
    event Spent(address indexed token, address indexed to, uint256 amount, uint256 indexed proposalId);
    event NativeReceived(address indexed from, uint256 amount);

    error NotAdmin();
    error ZeroAddress();
    error ZeroAmount();
    error AlreadyAdmin();
    error NotCurrentAdmin();
    error TooFewAdmins();
    error BadProposal();
    error AlreadyVoted();
    error ProposalNotPending();
    error ProposalExpired();
    error NotExecutable();
    error InsufficientBalance();
    error NativeTransferFailed();
    error Reentrancy();

    modifier onlyAdmin() {
        if (!isAdmin[msg.sender]) revert NotAdmin();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address[] memory initialAdmins) {
        if (initialAdmins.length < MIN_ADMINS) revert TooFewAdmins();
        for (uint256 i; i < initialAdmins.length; ++i) {
            address a = initialAdmins[i];
            if (a == address(0)) revert ZeroAddress();
            if (isAdmin[a]) revert AlreadyAdmin();
            _addAdmin(a);
        }
    }

    // ------------------------------------------------------------- propose

    /// @notice Propose sending `amount` of `token` (address(0) = native) to
    ///         `to`. The proposer's own approval is cast in this same tx.
    function proposeSpend(address token, address to, uint256 amount) external onlyAdmin returns (uint256 id) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        id = _openProposal(ProposalKind.Spend, token, to, amount);
        emit SpendProposed(id, token, to, amount, msg.sender);
    }

    /// @notice Propose adding `newAdmin`. Re-validated at execute (invariant E).
    function proposeAddAdmin(address newAdmin) external onlyAdmin returns (uint256 id) {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (isAdmin[newAdmin]) revert AlreadyAdmin();

        id = _openProposal(ProposalKind.AddAdmin, address(0), newAdmin, 0);
        emit AdminProposed(id, ProposalKind.AddAdmin, newAdmin, msg.sender);
    }

    /// @notice Propose removing `admin`. Refused if it would drop below
    ///         MIN_ADMINS; re-validated at execute (invariants C, E).
    function proposeRemoveAdmin(address admin) external onlyAdmin returns (uint256 id) {
        if (!isAdmin[admin]) revert NotCurrentAdmin();
        if (_admins.length <= MIN_ADMINS) revert TooFewAdmins();

        id = _openProposal(ProposalKind.RemoveAdmin, address(0), admin, 0);
        emit AdminProposed(id, ProposalKind.RemoveAdmin, admin, msg.sender);
    }

    function _openProposal(ProposalKind kind, address token, address target, uint256 amount)
        internal
        returns (uint256 id)
    {
        id = _proposals.length;
        _proposals.push(
            Proposal({
                kind: kind,
                status: ProposalStatus.Pending,
                token: token,
                target: target,
                amount: amount,
                proposer: msg.sender,
                createdAt: uint64(block.timestamp)
            })
        );
        // Record the proposer's approval. MIN_ADMINS >= 3 => required >= 2, so
        // opening never auto-executes.
        voteOf[id][msg.sender] = Vote.Approved;
        _voteSession[id][msg.sender] = adminSession[msg.sender];
        _voters[id].push(msg.sender);
        emit Voted(id, msg.sender, true);
    }

    // ----------------------------------------------------------------- vote

    /// @notice Approve a pending proposal. Executes immediately, in this same
    ///         call, if a live recount then shows approvals at or above a
    ///         strict majority of the current admin set.
    function approve(uint256 id) external onlyAdmin nonReentrant {
        Proposal storage p = _castVote(id, true);
        (uint256 approvals, ) = _tally(id);
        if (approvals >= _requiredApprovals()) _execute(id, p);
    }

    /// @notice Deny a pending proposal. If the remaining possible yes-votes
    ///         could never reach a current majority, close it as Rejected
    ///         rather than leave it dangling.
    function deny(uint256 id) external onlyAdmin nonReentrant {
        _castVote(id, false);
        (uint256 approvals, uint256 denials) = _tally(id);
        uint256 required = _requiredApprovals();
        // `_tally` counts only current admins, so approvals+denials can never
        // exceed _admins.length: the subtraction below cannot underflow.
        uint256 remainingVoters = _admins.length - (approvals + denials);
        if (approvals + remainingVoters < required) {
            _proposals[id].status = ProposalStatus.Rejected;
            emit ProposalRejected(id);
        }
    }

    /// @notice Finalize a proposal that already has enough live approvals but
    ///         never re-triggered execution inside an `approve` call -- e.g.
    ///         the threshold dropped after an admin was removed. Callable by
    ///         any admin; does not cast a vote. Reverts if not yet executable.
    function execute(uint256 id) external onlyAdmin nonReentrant {
        if (id >= _proposals.length) revert BadProposal();
        Proposal storage p = _proposals[id];
        if (p.status != ProposalStatus.Pending) revert ProposalNotPending();
        if (block.timestamp > p.createdAt + PROPOSAL_TTL) revert ProposalExpired();
        (uint256 approvals, ) = _tally(id);
        if (approvals < _requiredApprovals()) revert NotExecutable();
        _execute(id, p);
    }

    function _castVote(uint256 id, bool approved) internal returns (Proposal storage p) {
        if (id >= _proposals.length) revert BadProposal();
        p = _proposals[id];
        if (p.status != ProposalStatus.Pending) revert ProposalNotPending();
        if (block.timestamp > p.createdAt + PROPOSAL_TTL) revert ProposalExpired();

        uint256 session = adminSession[msg.sender]; // > 0: caller passed onlyAdmin
        bool hadEntry = voteOf[id][msg.sender] != Vote.None;
        // Block re-voting only within the CURRENT tenure. A prior-tenure ballot
        // no longer counts (invariant D), so a re-added admin may vote again.
        if (hadEntry && _voteSession[id][msg.sender] == session) revert AlreadyVoted();

        voteOf[id][msg.sender] = approved ? Vote.Approved : Vote.Denied;
        _voteSession[id][msg.sender] = session;
        // Push only on first-ever entry, keeping `_voters` free of duplicates
        // so `_tally` (which reads per-address state) can't double-count.
        if (!hadEntry) _voters[id].push(msg.sender);
        emit Voted(id, msg.sender, approved);
    }

    /// Recount from scratch, counting only ballots from addresses that are
    /// admins right now AND cast the ballot in their current tenure.
    function _tally(uint256 id) internal view returns (uint256 approvals, uint256 denials) {
        address[] storage voters = _voters[id];
        uint256 len = voters.length;
        for (uint256 i; i < len; ++i) {
            address v = voters[i];
            if (!isAdmin[v]) continue;
            if (_voteSession[id][v] != adminSession[v]) continue; // prior tenure
            Vote vt = voteOf[id][v];
            if (vt == Vote.Approved) approvals += 1;
            else if (vt == Vote.Denied) denials += 1;
        }
    }

    function _requiredApprovals() internal view returns (uint256) {
        return _admins.length / 2 + 1; // strict majority of the current set
    }

    // -------------------------------------------------------------- execute

    function _execute(uint256 id, Proposal storage p) internal {
        p.status = ProposalStatus.Executed; // effects before any external call

        if (p.kind == ProposalKind.Spend) {
            _release(p.token, p.target, p.amount);
            emit Spent(p.token, p.target, p.amount, id);
        } else if (p.kind == ProposalKind.AddAdmin) {
            // Re-check: two AddAdmin(X) can both pass propose-time. Without
            // this the second would push X twice (invariant E).
            if (isAdmin[p.target]) revert AlreadyAdmin();
            _addAdmin(p.target);
            emit AdminAdded(p.target, id);
        } else {
            // RemoveAdmin. Re-check the floor and that the target is still an
            // admin (the set can move since propose; two RemoveAdmin(X) can
            // both pass propose-time) -- invariants C, E.
            if (!isAdmin[p.target]) revert NotCurrentAdmin();
            if (_admins.length <= MIN_ADMINS) revert TooFewAdmins();
            _removeAdmin(p.target);
            emit AdminRemoved(p.target, id);
        }

        emit ProposalExecuted(id);
    }

    function _addAdmin(address a) internal {
        isAdmin[a] = true;
        adminSession[a] = ++_sessionCounter; // fresh tenure
        _admins.push(a);
    }

    function _removeAdmin(address a) internal {
        isAdmin[a] = false;
        adminSession[a] = 0; // ends the tenure; a future re-add gets a new one
        uint256 len = _admins.length;
        for (uint256 i; i < len; ++i) {
            if (_admins[i] == a) {
                _admins[i] = _admins[len - 1];
                _admins.pop();
                break;
            }
        }
    }

    function _release(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            if (address(this).balance < amount) revert InsufficientBalance();
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientBalance();
            // Tolerant of non-standard tokens (USDT & friends) that return no
            // data on success -- a strict typed call would revert decoding a
            // missing bool and strand those funds.
            (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
            require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer");
        }
    }

    // ------------------------------------------------------------------- views

    function admins() external view returns (address[] memory) {
        return _admins;
    }

    function adminCount() external view returns (uint256) {
        return _admins.length;
    }

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        if (id >= _proposals.length) revert BadProposal();
        return _proposals[id];
    }

    /// @notice Live counts (current-admin, current-tenure ballots only), the
    ///         majority threshold against the current admin set, and whether
    ///         the voting window has closed.
    function tally(uint256 id)
        external
        view
        returns (uint256 approvals, uint256 denials, uint256 required, bool expired)
    {
        if (id >= _proposals.length) revert BadProposal();
        (approvals, denials) = _tally(id);
        required = _requiredApprovals();
        expired = block.timestamp > _proposals[id].createdAt + PROPOSAL_TTL;
    }

    function votersOf(uint256 id) external view returns (address[] memory) {
        return _voters[id];
    }

    // ------------------------------------------------------------- receive

    /// Deposits are permissionless: anyone may send native currency or, via a
    /// plain transfer, ERC20 tokens in. Only a passed majority proposal moves
    /// them out.
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }
}
