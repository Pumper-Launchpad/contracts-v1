// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3Factory, IRegistryOwner} from "./Interfaces.sol";
import {PumperRewardLocker} from "./PumperRewardLocker.sol";

/// @title PumperToken
/// @notice A launched Pumper token: a plain OpenZeppelin ERC-20 and nothing
///         more. Fixed supply, minted once to the launchpad at construction;
///         there is no mint entrypoint and `_mint` is never reachable again.
///
///         There is deliberately NO transfer-time logic -- no fee, burn, cap,
///         pause, blacklist, hook, or per-holder reward checkpoint. `_update`
///         is stock OZ, so `transfer(self, x)` and `transferFrom(x, _, x)` are
///         exact no-ops (OZ debits then re-reads the same slot before the
///         credit), which is precisely the aliasing class the previous custom
///         `_transfer` got wrong.
///
///         Holder rewards are not paid here. Each token deploys its OWN
///         `PumperRewardLocker` in this constructor (address fixed as
///         `rewardLocker`); the launchpad routes this token's buy/sell fee
///         skim and LP-fee harvest into it, and it streams the reward currency
///         to accounts that have staked this token there. A token that is
///         never staked earns nothing -- there is no balance-weighted accrual
///         to misaccount. While NOTHING is staked, reward deposits go straight
///         to `creator` (the locker's fallback recipient).
///
///         The only non-ERC-20 surface:
///           * `updateMetadata` -- protocol admin only (the registry owner),
///             for socials/logo/description. `name`/`symbol` are immutable.
///           * `burnFrom(uint256)` -- launchpad only, for burning the
///             token-side of an LP-fee harvest. It MOVES the tokens to the
///             conventional dead address rather than destroying supply, so the
///             burn is visible on explorers and in the app's burn stats (as
///             `balanceOf(DEAD_ADDRESS)`) and `totalSupply()` stays fixed at
///             the minted amount. No `account` parameter by design.
contract PumperToken is ERC20 {
    /// @notice Where `burnFrom` sends tokens -- the conventional dead address.
    ///         Moving here (rather than `_burn`) keeps `totalSupply()` constant
    ///         and makes every burn externally auditable as this address's
    ///         balance.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address public immutable launchpad;
    address public immutable registry;
    address public immutable creator;
    address public immutable weth;
    address public immutable v3Factory;
    uint24 public immutable feeTier;
    uint256 public immutable deploymentBlock;

    /// @notice This token's dedicated reward locker, deployed in the
    ///         constructor. Stake this token there to earn rewards.
    address public immutable rewardLocker;

    string public description;
    string public image; // ipfs://<CID>
    string public twitter;
    string public telegram;
    string public website;

    event MetadataUpdated(address indexed admin);

    error OnlyLaunchpad();
    error NotAdmin();

    struct InitParams {
        string name;
        string symbol;
        string description;
        string image;
        string twitter;
        string telegram;
        string website;
        uint256 totalSupply;
        address creator;
        address weth;
        address v3Factory;
        uint24 feeTier;
        address launchpad; // explicit: a factory, not the launchpad, may `new` this
        address registry; // gates updateMetadata() via registry.owner()
        address rewardToken; // reward currency the locker pays out (USDC / WgUSDT)
    }

    constructor(InitParams memory p) ERC20(p.name, p.symbol) {
        launchpad = p.launchpad;
        registry = p.registry;
        creator = p.creator;
        weth = p.weth;
        v3Factory = p.v3Factory;
        feeTier = p.feeTier;
        deploymentBlock = block.number;

        description = p.description;
        image = p.image;
        twitter = p.twitter;
        telegram = p.telegram;
        website = p.website;

        // Full supply, minted once, here and nowhere else.
        _mint(p.launchpad, p.totalSupply);

        // This token's own reward locker. Atomic with the token, so
        // `rewardLocker` is genuinely immutable and the locker's `stakeToken`
        // can only ever be this token. Fallback recipient is the creator:
        // deposits made while nothing is staked go straight to them.
        rewardLocker = address(new PumperRewardLocker(address(this), p.rewardToken, p.creator));
    }

    /// @notice Permanent burn of the caller's OWN balance. Launchpad only --
    ///         it calls this to burn the token-side fees harvested from the LP
    ///         position (see the launchpad's collectLpFees). A burn-any-wallet
    ///         signature is the exact backdoor pattern scanners flag, and this
    ///         contract has no legitimate use for one.
    ///
    ///         Sends the tokens to `DEAD_ADDRESS` instead of `_burn`ing them:
    ///         `totalSupply()` stays fixed and every burn is auditable on-chain
    ///         as `balanceOf(DEAD_ADDRESS)`, which is what explorers and the
    ///         app's burn stats read.
    function burnFrom(uint256 value) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _transfer(msg.sender, DEAD_ADDRESS, value);
    }

    /// @notice The canonical Uniswap V3 pool for this token against `weth` at
    ///         `feeTier`, resolved from the factory on each call.
    function pool() external view returns (address) {
        return IUniswapV3Factory(v3Factory).getPool(address(this), weth, feeTier);
    }

    /// @notice Update socials/logo/description. Gated on the REGISTRY owner
    ///         (not the launchpad), so it keeps working after a launchpad
    ///         redeploy. Only the protocol admin can call this -- not even the
    ///         token's own creator.
    function updateMetadata(
        string calldata newImage,
        string calldata newTwitter,
        string calldata newTelegram,
        string calldata newWebsite,
        string calldata newDescription
    ) external {
        if (msg.sender != IRegistryOwner(registry).owner()) revert NotAdmin();
        image = newImage;
        twitter = newTwitter;
        telegram = newTelegram;
        website = newWebsite;
        description = newDescription;
        emit MetadataUpdated(msg.sender);
    }
}
