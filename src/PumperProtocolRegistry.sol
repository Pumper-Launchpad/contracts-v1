// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title PumperProtocolRegistry
/// @notice The one contract in this system meant to never be redeployed.
///         Every launchpad instance (current and future) registers the tokens
///         it creates here, so token discovery (Explore, the indexer, Stats)
///         survives a launchpad redeploy instead of silently losing history.
///         It also anchors `PumperProtocolToken.updateMetadata`'s admin check: that
///         function trusts THIS contract's `owner`, not whichever launchpad
///         happens to be live, so admin control over socials/logo keeps
///         working correctly across future launchpad redeploys too.
contract PumperProtocolRegistry {
    address public owner;

    // Launchpads allowed to register new tokens. Without this gate anyone
    // could spam-register fake tokens claiming legitimacy.
    mapping(address => bool) public authorizedLaunchpads;

    struct TokenRecord {
        address creator;
        address pool;
        address launchpad; // which launchpad instance manages this token's live trading state
    }

    mapping(address => TokenRecord) public tokens;
    address[] public allTokens;

    event TokenRegistered(address indexed token, address indexed creator, address pool, address indexed launchpad);
    event LaunchpadAuthorized(address indexed launchpad, bool authorized);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotAuthorized();
    error ZeroAddress();
    error AlreadyRegistered();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Called by an authorized launchpad for every new token it launches.
    function register(address token, address creator, address pool) external {
        if (!authorizedLaunchpads[msg.sender]) revert NotAuthorized();
        _register(token, creator, pool, msg.sender);
    }

    /// @notice Owner-only backfill for tokens that predate the registry (or a
    ///         given launchpad's authorization). Emits the same event as
    ///         `register` so the indexer treats history identically.
    function registerExisting(address token, address creator, address pool, address launchpad) external onlyOwner {
        _register(token, creator, pool, launchpad);
    }

    function _register(address token, address creator, address pool, address launchpad) internal {
        if (token == address(0) || creator == address(0) || launchpad == address(0)) revert ZeroAddress();
        if (tokens[token].launchpad != address(0)) revert AlreadyRegistered();

        tokens[token] = TokenRecord({creator: creator, pool: pool, launchpad: launchpad});
        allTokens.push(token);

        emit TokenRegistered(token, creator, pool, launchpad);
    }

    function setLaunchpadAuthorized(address launchpad, bool authorized) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        authorizedLaunchpads[launchpad] = authorized;
        emit LaunchpadAuthorized(launchpad, authorized);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function totalTokens() external view returns (uint256) {
        return allTokens.length;
    }
}
