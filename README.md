<div align="center">

<img src="logo.png" alt="Pumper Protocol" width="120" />

# Pumper Protocol — Contracts (V1)

<img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=20&pause=1200&color=34C98F&center=true&vCenter=true&width=780&lines=Fixed-supply+launches+on+Uniswap+V3.;No+bonding+curve.+No+per-trade+tax.;Liquidity+locked+forever+at+launch.;Every+trade+funds+stakers+and+a+PUMPER+buy-and-burn." alt="Pumper Protocol V1" />

<br/>

![Solidity](https://img.shields.io/badge/Solidity-0.8.35-363636?logo=solidity)
![Network](https://img.shields.io/badge/network-Stable%20(988)-34C98F)
![License](https://img.shields.io/badge/license-MIT%20%2B%20GPL--2.0--or--later-blue)

</div>

---

Pumper Protocol is a permissionless token launchpad. Every launch mints a **fixed
1,000,000,000 supply** straight into a **Uniswap V3** pool as one-sided token
liquidity, **locks the LP position permanently**, and never touches it again.
There is no bonding curve and no per-trade tax — buys and sells are plain V3
swaps. All protocol and reward revenue comes from the pool's own **1% swap fee**,
harvested after the fact: the token-side portion is burned to the dead address,
and the quote-side portion is split four ways — protocol, FEFER, a **PUMPER
buy-and-burn**, and stakers.

This repository publishes the launchpad family
(`PumperLaunchpad` / `PumperToken` / `PumperTokenFactory` / `PumperRewardLocker`) —
Solidity sources in [`src/`](src/), ABIs in [`abi/`](abi/), and the deployment +
build manifest in [`contract-meta.json`](contract-meta.json).

## Table of contents

- [Deployed contracts](#deployed-contracts)
- [How a launch works](#how-a-launch-works)
- [The fee split](#the-fee-split)
- [Staking &amp; rewards](#staking--rewards)
- [Contract reference](#contract-reference)
  - [Core launch stack](#core-launch-stack)
  - [Revenue &amp; treasury](#revenue--treasury)
  - [Locks](#locks)
  - [Vendored Uniswap V3](#vendored-uniswap-v3)
- [Design notes](#design-notes)
- [Invariants &amp; guardrails](#invariants--guardrails)
- [Repository layout](#repository-layout)
- [ABIs &amp; build settings](#abis--build-settings)
- [License](#license)
- [Security](#security)

## Deployed contracts

The **registry is the source of truth**. It is deployed once and never
redeployed; the launchpad registers every token it creates there, and each
token's own record names the launchpad that manages it. To enumerate the live
system, read `PumperProtocolRegistry`:

```
registry.allTokens(i)                 -> every launched token
registry.tokens(token).launchpad      -> the launchpad managing that token
registry.authorizedLaunchpads(addr)   -> is this a sanctioned launchpad
```

Each token also deploys its **own** `PumperRewardLocker` — read
`PumperToken(token).rewardLocker()` to find it.

| Contract | Address |
| --- | --- |
| `PumperLaunchpad` | `0x8792312795eba629ca661B0aF1ca162adE84D0FE` |
| `PumperTokenFactory` | `0xFC29C5b1AAEAab74Fd8741EfdC40916fac76eC1C` |
| `PumperProtocolRegistry` | `0x7Cd190e5Ba34C1Ec8FE07F78EddB026719940492` |
| `PumperAdminVault` | `0xb961cE542585F15DC447eF97a11A3392DbD11F06` |
| `PumperFeferVault` | `0x18318aeF89d4D84f2f2a87764179142fF267e1b9` |
| `PumperBuybackVault` (PUMPER buy-and-burn) | `0x59084fD740552807891f80F836011EBE5995685e` |
| `PumperTokenLock` | `0xCdf08BaFF586BEF22DD1a845911df3dbE6CEe58A` |
| `PumperLPLocker` | `0x1ED94C0b0A8c9d0a91BB4DEB20677C90580D8366` |
| Quote / reward asset (`WETH` = `USDG` = WgUSDT) | `0x817997Ca8394E26CCE3dE3A076a4889b27DbF9dE` |

All contracts are verified on **Sourcify**. Reproduce their bytecode from the
sources in [`src/`](src/) using the settings in
[`contract-meta.json`](contract-meta.json) (see
[ABIs &amp; build settings](#abis--build-settings)).

## How a launch works

`PumperLaunchpad.launch(LaunchParams)` — one transaction:

1. **Deploy the token.** `PumperTokenFactory.createToken` runs
   `new PumperToken{salt}(...)` in its own contract, so the token's init code —
   and the `PumperRewardLocker` its constructor `new`s — never inflate the
   launchpad's runtime size past EIP-170.
2. **Create the pool** at the fixed `FEE_TIER = 10000` (1%) and initialise its
   price.
3. **Seed one-sided liquidity.** The whole `TOTAL_SUPPLY` (1e9 · 1e18) is minted
   as token-only V3 liquidity across two adjacent ranges: `BPS − RESERVE_BPS`
   (60%) in the "launch range" up to the graduation market cap, `RESERVE_BPS`
   (40%) in an open-ended "continuation range" above it.
4. **Lock the LP NFT** — sent to the configured `locker`, or held/burned. It is
   never withdrawn.
5. **Register** the token in `PumperProtocolRegistry` so the indexer, Explore and
   Stats pick it up permanently.
6. *(optional)* fold the creator's first buy into the same transaction.

After that, `buy` / `sell` are ordinary V3 swaps (routable through this contract
or any aggregator). "Graduation" is a **status milestone** (cumulative buys
crossing the target mcap), emitted as `Graduated` — nothing migrates; the pool
and its locked liquidity are unchanged.

## The fee split

Revenue is realised separately and permissionlessly. `collectLpFees(token)` pulls
the position's accrued 1% fees and:

- sends the **token-side** fee to `0x…dEaD` (permanent, explorer-visible burn;
  `totalSupply()` stays fixed), and
- splits the **quote-side** fee, fixed and hardcoded — no admin dial:

  | Share | Bps | Destination |
  | --- | --- | --- |
  | Protocol | `ADMIN_VAULT_BPS` = 1000 (**10%**) | `PumperAdminVault` |
  | FEFER | `FEFER_VAULT_BPS` = 500 (**5%**) | `PumperFeferVault` → FEFER buy-and-burn |
  | PUMPER | `PUMPER_VAULT_BPS` = 500 (**5%**) | `PumperBuybackVault` → **PUMPER buy-and-burn** |
  | Stakers | remainder (**80%**) | the token's `PumperRewardLocker` |

The same skim also runs on the buy/sell fee taken by the router. When **nothing
is staked** in a token's locker, its 80% share forwards straight to that token's
`creator` (the locker's fallback recipient) — no balance-weighted backlog for a
1-wei staker to sweep later.

## Staking &amp; rewards

Rewards are **not** paid per balance. Each `PumperToken` deploys its own
`PumperRewardLocker` in its constructor; holders **stake** (lock) the token there
to earn the reward currency (WgUSDT on Stable).

Fixed-term, time-weighted — a stake picks one of four tiers, principal frozen for
the term:

| Tier | Term | Boost |
| --- | --- | --- |
| `T30` | 30 days | 1.0× |
| `T90` | 90 days | 1.5× |
| `T180` | 180 days | 2.5× |
| `T365` | 365 days | 4.0× |

`weight = amount × boost`; rewards accrue per unit of weight (MasterChef
accounting, `accRewardPerShare`). The boost is flat for the whole term and drops
to zero at withdrawal. Accrued rewards can be `claim`ed at any time — only
principal is time-locked.

**Early exit:** `requestUnlock` starts a 7-day `EARLY_UNLOCK_COOLDOWN` and
immediately zeroes the lock's weight (it earns nothing from that moment; already-
banked rewards stay claimable). After 7 days the principal is withdrawable. A
lock that reaches its natural `unlockTime` just withdraws — no request, no
cooldown, full earnings to the end.

## Contract reference

### Core launch stack

| Contract | Role |
| --- | --- |
| **`PumperLaunchpad.sol`** | Front-door router + factory. Deploys the token, creates & seeds the V3 pool, locks the LP, registers the token, and exposes `buy` / `sell` / `collectLpFees`. `TOTAL_SUPPLY`, `FEE_TIER`, `RESERVE_BPS` and the four-way fee split are hardcoded constants — not creator- or admin-configurable. Owner can only set the flat deploy fee, the protocol-fee recipient, graduation targets, a per-token `live` flag, and reassign a token's `creator`. |
| **`PumperToken.sol`** | The launched ERC-20 — plain OpenZeppelin `ERC20` and nothing more. Fixed supply, minted once to the launchpad; `_mint` is never reachable again. **No** transfer-time logic: no fee, burn, cap, pause, blacklist, hook or reward checkpoint, so `transfer(self, x)` is an exact no-op. Deploys its own `rewardLocker` in the constructor. Only non-ERC-20 surface: `updateMetadata` (registry-owner-gated, socials/logo only — `name`/`symbol` immutable) and `burnFrom` (launchpad-only, moves the token-side fee harvest to `0x…dEaD`). |
| **`PumperTokenFactory.sol`** | Nothing but `new PumperToken{salt}(...)`, isolated so the token's (and its nested locker's) creation bytecode stays out of the launchpad's runtime size. Holds no funds; trusts its caller to set `p.launchpad`. |
| **`PumperRewardLocker.sol`** | One per launched token, deployed by the token itself. Fixed-term time-weighted staking of that one token (T30/T90/T180/T365 → 1.0×–4.0×), MasterChef-by-weight reward streaming, 7-day early-exit cooldown. Immutable and admin-free — `stakeToken`, `rewardToken`, `fallbackRecipient` and the tier table are fixed forever. `depositReward` is push-funded and permissionless; with nothing staked it forwards to `fallbackRecipient` (the token's `creator`). |
| **`PumperProtocolRegistry.sol`** | The one contract meant never to be redeployed. `authorizedLaunchpads` gates registration; `TokenRegistered` is the indexer's single source of discovery; `registerExisting` back-fills pre-registry tokens with an identical event. Also anchors `PumperToken.updateMetadata`'s admin check, so metadata edits keep working across a launchpad redeploy. |

### Revenue &amp; treasury

| Contract | Role |
| --- | --- |
| **`PumperAdminVault.sol`** | Shared multi-admin pot. Any admin may withdraw any token or native amount at any time — no equal-split accounting, no per-admin claim tracking. Receives `ADMIN_VAULT_BPS` (10%) of every harvest. |
| **`PumperBuybackVault.sol`** | Receives `PUMPER_VAULT_BPS` (5%) of every harvest as WgUSDT. Immutable and admin-free — no owner, no mode toggle, no rescue path. Permissionless `buyAndBurn` swaps the whole balance for **PUMPER** through one Uniswap V3 pool and sends it all to `0x…dEaD` (caller supplies the slippage bound). |
| **`PumperFeferVault.sol`** | Receives `FEFER_VAULT_BPS` (5%) of every harvest as WgUSDT and permanently destroys value for FEFER holders — `buyAndBurn` / `addLiquidityAndBurn` route through `PumperAggregator` / `PumperZapper` (caller supplies the off-chain-quoted route and slippage bound). Admin list is borrowed from `PumperAdminVault`. |
| **`FeferVault.sol`** | A stricter treasury variant: **no** single-admin withdraw. Every spend *and* every admin-set change goes through a proposal resolved by a live strict majority of the current admin set. Tallies and threshold are recomputed from scratch on each call; admin tenure is session-scoped so re-adding never resurrects old votes. |

### Locks

| Contract | Role |
| --- | --- |
| **`PumperTokenLock.sol`** | Permissionless ERC-20 time lock, separate from staking. Anyone can lock any token until any timestamp (`MAX_LOCK_DURATION = 50 years` guards fat-fingered ms-vs-s). Locks are **extend-only** — `relock` can only push `unlockTime` forward. `claimReward` pulls a locked token's own holder rewards (if it has any) to the contract and splits them among that token's lockers pro-rata. |
| **`PumperLPLocker.sol`** | Sibling of `PumperTokenLock`, no reward plumbing. One lock-id space for two asset kinds: ERC-20 LP tokens (`approve` + `lockERC20`) and Uniswap V3 position NFTs (a single `safeTransferFrom` with the unlock time in `data`). |

### Vendored Uniswap V3

Minimal, dependency-free reimplementations of Uniswap V3 periphery, plus the two
`v3-core` math libraries the launchpad needs at launch time.

| File | Upstream analogue |
| --- | --- |
| `TickMath.sol` | `Uniswap/v3-core` `TickMath` — ported verbatim (pragma only). **GPL-2.0-or-later.** |
| `FullMath.sol` | `Uniswap/v3-core` `FullMath` — ported verbatim (pragma + `unchecked`). MIT upstream. |
| `MinimalPositionManager.sol` | `NonfungiblePositionManager` — mint / increase / decrease / collect |
| `MinimalSwapRouter02.sol`, `MinimalSwapRouter02Standard.sol` | `SwapRouter02` — `exactInputSingle` and friends |
| `MinimalQuoterV2.sol`, `MinimalQuoterV2Adapter.sol` | `QuoterV2` — off-chain `eth_call` price quotes |
| `Interfaces.sol` | shared external interfaces (`IUniswapV3Factory/Pool`, `INonfungiblePositionManager`, `ISwapRouter02`, `IWETH`, `ILiquidityLocker`, …) |

These exist because Uniswap V3 periphery has no canonical deployment on the
target chain.

## Design notes

- **No bonding curve.** Seeding the entire supply as one-sided V3 liquidity from
  block one is economically curve-like (price rises as buyers consume the range)
  but *is* the AMM — nothing to migrate, no graduation handoff to get wrong.
- **Locked liquidity, always.** The LP position is never withdrawable by anyone,
  including the protocol. Rug-by-liquidity-pull is structurally impossible.
- **Revenue only from the pool's own fee.** No creator fee, no per-trade skim, no
  transfer tax. `collectLpFees` earns on *every* trade including ones that never
  touch this router, so the fee split can't be dodged by routing around it.
- **Clean token.** A Uniswap V3 pool cannot custody a fee-/burn-on-transfer
  token, so all economics live in the router, the vaults and the reward locker —
  never in `_update`.
- **No idle reward backlog.** With nothing staked, the reward share forwards to
  the creator instead of parking in the locker, so a first staker can't sweep a
  backlog it didn't earn.
- **Registry-anchored permanence.** Launchpads are meant to be replaced. The
  registry and each token's immutable `rewardLocker` / vault pointers mean a
  future launchpad redeploy never retroactively redirects an already-launched
  token's fees or admin authority.
- **Fixed 1B supply.** Not a parameter — uniform, predictable distribution across
  every launch.
- **EIP-170 by construction.** `via_ir = true`, and token + locker creation is
  isolated in its own factory so neither contract approaches the 24 KB runtime
  limit.

## Invariants &amp; guardrails

- `TOTAL_SUPPLY`, `FEE_TIER`, `RESERVE_BPS`, `ADMIN_VAULT_BPS`, `FEFER_VAULT_BPS`,
  `PUMPER_VAULT_BPS` and `MAX_RECIPIENTS` are `constant` — unreachable by any
  caller, owner included. The four-way split cannot be re-weighted.
- A launch's reward split (`holderShareBps` + `payoutRecipients`) is **fixed at
  launch** — there is no setter. `setRewardSplit` disambiguates "route 0% to the
  locker" from "field omitted".
- `PumperRewardLocker`: immutable — no owner, no rescue path; the tier table is
  fixed; the early-exit penalty is *only* a 7-day no-earnings window (principal
  and banked rewards are never forfeited).
- `PumperBuybackVault`: immutable — `token`, `wgusdt`, `swapRouter`, `poolFee`
  fixed forever; `buyAndBurn` is permissionless and every burn goes to
  `0x…dEaD`.
- `PumperTokenLock` / `PumperLPLocker`: `relock` is extend-only; only the locker
  can extend or withdraw; `MAX_LOCK_DURATION` caps a typo'd timestamp.
- `PumperProtocolRegistry`: only `authorizedLaunchpads` may `register`;
  double-registration reverts (`AlreadyRegistered`).
- `FeferVault`: `MIN_ADMINS = 3` is re-checked at execute, so no single key and
  no strict minority can ever move funds; a removed admin's past votes stop
  counting immediately (session-scoped tenure).
- Slippage bounds are always caller-supplied (`minTokensOut`, `minOut`); no code
  path swaps against a hardcoded zero minimum.

## Repository layout

```
.
├── README.md
├── contract-meta.json        deployment + build manifest (addresses, compiler settings, source list)
├── logo.png
├── abi/                       one JSON ABI per contract
│   ├── PumperLaunchpad.json
│   ├── PumperToken.json
│   ├── PumperRewardLocker.json
│   └── … (one per contract in src/)
└── src/                       Solidity sources
    ├── PumperLaunchpad.sol               launchpad (router + factory)
    ├── PumperToken.sol                   launched token (plain OZ ERC-20)
    ├── PumperTokenFactory.sol            EIP-170 isolation of `new PumperToken`
    ├── PumperRewardLocker.sol            per-token fixed-term staking + reward stream
    ├── PumperProtocolRegistry.sol        permanent token directory
    ├── PumperAdminVault.sol              10% fee sink (shared admin pot)
    ├── PumperBuybackVault.sol            5% fee sink -> PUMPER buy-and-burn
    ├── PumperFeferVault.sol / FeferVault.sol   5% fee sink / majority-vote treasury
    ├── PumperTokenLock.sol               permissionless ERC-20 time lock
    ├── PumperLPLocker.sol                permissionless LP / V3-NFT lock
    ├── TickMath.sol · FullMath.sol       vendored Uniswap V3 math
    ├── Minimal{PositionManager,SwapRouter02,QuoterV2}*.sol   vendored V3 periphery
    └── Interfaces.sol                    shared external interfaces
```

## ABIs &amp; build settings

Each contract's ABI is in [`abi/`](abi/), one JSON file per contract.
[`contract-meta.json`](contract-meta.json) is the machine-readable manifest:
deployed addresses, the per-launch contracts (`PumperToken` /
`PumperRewardLocker`, which have no fixed address), the fee split in bps, and the
exact settings the deployed bytecode was compiled with —

| Setting | Value |
| --- | --- |
| solc | `0.8.35` |
| optimizer | enabled, `200` runs |
| EVM version | `osaka` |
| via-IR | `true` |
| dependency | `@openzeppelin/contracts@5.1.0` |

`Interfaces.sol`, `TickMath.sol` and `FullMath.sol` are vendored into `src/`;
`@openzeppelin/contracts` is the one external import (`ERC20` for `PumperToken`;
`SafeERC20` / `ReentrancyGuard` for `PumperRewardLocker`).

## License

- `src/TickMath.sol` — **GPL-2.0-or-later**, as required for derivative work of
  `Uniswap/v3-core`.
- Everything else in `src/` — **MIT** (see each file's SPDX header).
- `@openzeppelin/contracts` — MIT (upstream).

## Security

These contracts are **unaudited**. Trade at your own risk.

Found a vulnerability? Please disclose privately via the contact form at
[pumper.tools](https://app.pumper.tools) (footer → mail icon) rather than opening
a public issue. Reproduce against deployed bytecode where possible — a "spec"
bug and a "deployed" bug are not the same thing.
