# Pangea Fee Hook V2

The Uniswap v4 hook for [Pangea](https://www.pangea.trade) launch pools, with a **changeable trading fee**.
Pangea is a launchpad. Each token it launches trades in a Uniswap v4 pool (native coin / token) that uses this
hook, with single-sided launch liquidity.

This repository holds the exact sources of the deployed contract, byte for byte:
- `src/v3/PangeaFeeHookV2M.sol`
- `src/v3/V3Shared.sol`
- `src/FactoryList.sol`
- the Uniswap v4-core and OpenZeppelin files they import

Each file's keccak256 matches the build metadata in `metadata.json`. `forge build` reproduces the verified
creation bytecode. The on-chain init code is that bytecode plus the 224-byte constructor arguments.

## Deployment

The hook has the same address on every chain (CreateX CREATE3, deployer-guarded salt):

**`0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc`**

| Chain | Chain id | Verified source |
|---|---|---|
| Ethereum | 1 | [etherscan.io](https://etherscan.io/address/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc#code) · [Sourcify](https://repo.sourcify.dev/1/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc) |
| Base | 8453 | [basescan.org](https://basescan.org/address/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc#code) · [Sourcify](https://repo.sourcify.dev/8453/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc) |
| BNB Chain | 56 | [bscscan.com](https://bscscan.com/address/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc#code) · [Sourcify](https://repo.sourcify.dev/56/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc) |
| Robinhood Chain | 4663 | [Blockscout](https://robinhoodchain.blockscout.com/address/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc?tab=contract) · [Sourcify](https://repo.sourcify.dev/4663/0x1AEF1467B4e4723996C01D31043D146c0CF6e8Cc) |
| Elysium | 99901 | deployed from the same init code |

The constructor takes `(poolManager, deployer, devBuyer, launchBuyer, locker, core, feeDelayBlocks)`. Four of
these are the same on every chain:
- `deployer` = `0x7794De82aa21CE22863102fB07E319daf85dd1c5` (also the first `factoryAdmin`)
- `core` = `0x9A8b8d44BA267B2Be3c5dc8A8CAE173870458e9b`, which gives `coreBuyer` = `0xfeC6A2D15E879a7bb654d353cc1b9EE7DA6A4595`
- `feeDelayBlocks` = `0` (a fee change takes effect at once)
- `locker` = `0xbebe68fBfB62E18FBFEbf4365970D192C5f34DC1`, except on Elysium (see below)

| Chain | `poolManager` | `devBuyer` | `launchBuyer` |
|---|---|---|---|
| Ethereum | `0x000000000004444c5dc75cB358380D2e3dE08A90` | `0x79d9a01B6ADB4938761e7D4fb29a802ea709F0Ec` | `0xd9Ac4C249097ec487e3f40Bc897871f17565423A` |
| Base | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | `0x7cb08218648433bbC9671f885E15954756717BCa` | `0x735192F90d49DA81A702cFeb9335331F3B361968` |
| BNB Chain | `0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF` | `0xcDB037B5B4b58e3C89d632463656D889123a7c04` | `0xc455Cf5B2d0cA8d92c439BB4Ab7e046d9410ADdE` |
| Robinhood Chain | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0xcDB037B5B4b58e3C89d632463656D889123a7c04` | `0x0aBDD848773616af3954A161F2f153BB2e7413C3` |
| Elysium | `0xE2e105d3F7209A9DA11f83cCf3E7398a753823F1` | `0x101c50201A6Bff01b4D197392aD1418276DcD8cf` | `0x8C127d90A3C857C947e758e6a51669D21E56295B` |

On Elysium the locker is `0x0Ea7fb46415270f33fdD2fde7aA3e0Dc46E2E2BC`.

## The fee model

Hook permissions (address bits `0x28CC`):
- `beforeInitialize`
- `beforeAddLiquidity`
- `beforeSwap`
- `afterSwap`
- `beforeSwapReturnDelta`
- `afterSwapReturnDelta`

**A trading fee in the quote asset, on buys and on sells.**
- The pool's own LP fee is 0. The hook takes the fee from the quote side of every swap through return deltas:
  `beforeSwap` for exact-in buys, `afterSwap` for sells and exact-out swaps. So the fee is always paid in the quote
  asset (ETH/BNB), never in the token.
- Each fee is minted as an ERC-6909 claim and booked to the pool. `redeem` pays it to the pool's fee splitter
  (creator + platform).
- No dynamic LP fee is used, and the protocol fee is never touched.

**The fee can change, inside fixed bounds.** Each pool is registered once by a listed factory, with a starting fee.
`setFee(key, bps)` moves the fee anywhere in **0.3%–5%**. These bounds (`MIN_FEE_BPS` 30, `MAX_FEE_BPS` 500) are
constants. The rules for a change:
- **Who can change it:** only the pool's payee (its splitter's `creator`) or the platform admin (`factoryAdmin`).
- **Old fees are settled first.** The hook redeems every claim earned at the old rate, then the splitter pays out at
  the old rate and switches, and only then is the new rate stored. Fees earned at one rate are never divided at
  another.
- **One change per pool per block.** With `feeDelayBlocks` = 0 (as deployed), a change takes effect in the
  transaction that makes it. A hook built with a delay N instead schedules the change N blocks ahead
  (`pendingFeeOf`, `applyFee`, `cancelPendingFee`).
- **Swaps and fee changes never overlap.** No swap runs during a fee change, and no fee change runs inside a swap
  (transient reentrancy guard plus an in-swap counter).
- `feeOf(poolId)` is the rate a swap pays now.

**The rest of the hook:**
- **Fee-free buyers.** Pangea's own launch buyers pay no fee: `devBuyer`, `launchBuyer` and the v4 core's
  `coreBuyer`.
- **Liquidity.** Only the locker, or an adder the admin lists, can add liquidity.
- **Price range.** A swap cannot end past the launch range's edge (`OutOfRange`), and a quote-specified swap fills
  completely or reverts (`PartialFill`).
- **Price record.** `afterSwap` calls `recordPrice(poolId, sqrtBefore, sqrtAfter, feeBps)` on the pool's token, with
  250,000 gas (`RECORD_GAS`). This feeds Pangea's cross-chain price-gap fee. The result is ignored, but a swap must
  leave at least that much gas.
- **hookData.** None is needed.
- **Not upgradeable.** There is no proxy, no `delegatecall` and no `selfdestruct`. `factoryAdmin` can only list
  factories and liquidity adders, set or cancel fees within the bounds, and hand its role on.

## Build

```
forge build
```

Compiler settings (also in `metadata.json`):
- solc 0.8.30
- optimizer 200 runs
- via-IR
- EVM `cancun`
- bytecode hash `ipfs`

`remappings.txt` is the full list the deployed build was compiled with. The remappings are part of the metadata
hash, so keep them all, including the ones that name folders this repository does not need.

## Licences

These files are published as source for review and verification; all rights reserved:
- `src/v3/PangeaFeeHookV2M.sol`
- `src/v3/V3Shared.sol`
- `src/FactoryList.sol`

The files under `lib/uniswap-v4-core/` are Uniswap Labs' v4-core sources under their own SPDX licences (MIT, and
BUSL-1.1 for `Position.sol`). The files under `lib/openzeppelin-contracts/` are MIT.
