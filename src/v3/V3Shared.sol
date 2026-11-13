// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title V3Shared -- the interfaces every factory-v3 piece builds against (docs/factory-v3.md)
/// @notice FIXED ON DAY 0. A change here is a change to every piece (EVM factory, hook, splitter,
///         LaunchBuys, Solana splitter, scripts, web) and goes through the lead.

/// @notice One wallet's launch buy: `amount` of `eid`'s pool quote (wei for a native pool, the
///         asset's own units otherwise) spent for `recipient` in the launch transaction on `eid`.
///         The whole list, every chain's entries, is hashed into the token's CREATE2 salt
///         (`TermsV3.buysHash` -> `TermsV3.launchSaltV3`), so the signed token address signs it.
struct LaunchBuy {
    uint32 eid;
    address recipient;
    uint256 amount;
}

/// @notice One leg's own launch fee in a creator self-launch (owner decision 2026-10-28: a split fee
///         per chain): at least `feeMin` held for the launch id by `payer` in `eid`'s collector
///         (on EVM a left-padded address, on Solana a 32-byte key).
struct LegFee {
    uint32 eid;
    uint256 feeMin;
    bytes32 payer;
}

/// @notice The launch terms v3: v2's eight fields and the creator self-launch (owner 2026-10-28):
///         `selfUntil` and `legFees`. (Moon mode's `poolBps` was removed, owner scope cut
///         2026-10-29: every chain's whole slice is its pool.)
struct LaunchTermsV3 {
    bytes32 payeeSolana;
    uint32 feeEid;
    uint256 feeMin;
    bytes32 payer;
    bytes32 metadata;
    bytes32 creatorSolana;
    bytes32 quoteSolana;
    /// @notice 0: today's flow (one pay chain, the platform sends every other leg). Otherwise a
    ///         creator SELF-LAUNCH on its self legs (those with a `legFees` entry): each is paid on
    ///         its own chain, the creator may send it, and the platform's launcher only from this
    ///         unix time on. Option C (2026-10-29): with a strict subset of the legs listed, the
    ///         others are ordinary legs (the pay chain, never a self leg, and platform-only legs).
    uint32 selfUntil;
    /// @notice With `selfUntil` 0: zero. Otherwise TermsV3.legFeesHash of the self legs' LegFee
    ///         rows (every leg's, or a non-empty subset's: the signed per-leg self mask).
    bytes32 legFees;
}

library TermsV3 {
    /// @notice The most launch-buy entries one launch may carry, over all its chains.
    uint256 internal constant MAX_LAUNCH_BUYS = 32;

    /// @notice A self-launch's leg fees are not one per leg in strictly ascending eid (at `index`).
    error LegFeesNotAscending(uint256 index);

    /// @notice The version word every v3 (gap fee) launch's terms end with (audit r1 L-3, v3c).
    uint256 internal constant GAP_TERMS_VERSION = 3;

    /// @notice The terms hash: v2's words and then `uint256 GAP_TERMS_VERSION` (3). With
    ///         `selfUntil == 0` (today's flow; `legFees` is then zero, and not hashed) nine words:
    ///         keccak256(abi.encode(address payee, bytes32 payeeSolana, uint32 feeEid, uint256 feeMin,
    ///         bytes32 payer, bytes32 metadata, bytes32 creatorSolana, bytes32 quoteSolana, uint256 3)).
    ///         A SELF-LAUNCH (`selfUntil != 0`) eleven: those eight, `uint32 selfUntil`, `bytes32
    ///         legFees`, then the version (Moon mode's `poolBps` word removed, 2026-10-29, decision (a)).
    ///         The version word binds a signed snapshot to the v3 gap-fee token: a snapshot signed
    ///         for the v2 factory (eight words) never verifies here, and on Solana a v3-signed launch
    ///         is the only one that opens a v3 store (price.rs `terms_hash_v3`, which reproduces
    ///         both forms), so a store and its EVM peers always speak the same codec.
    function termsHash(address payee, LaunchTermsV3 memory t) internal pure returns (bytes32) {
        if (t.selfUntil != 0) {
            return keccak256(
                abi.encode(
                    payee,
                    t.payeeSolana,
                    t.feeEid,
                    t.feeMin,
                    t.payer,
                    t.metadata,
                    t.creatorSolana,
                    t.quoteSolana,
                    t.selfUntil,
                    t.legFees,
                    GAP_TERMS_VERSION
                )
            );
        }
        return keccak256(
            abi.encode(
                payee,
                t.payeeSolana,
                t.feeEid,
                t.feeMin,
                t.payer,
                t.metadata,
                t.creatorSolana,
                t.quoteSolana,
                GAP_TERMS_VERSION
            )
        );
    }

    /// @notice A self-launch's `legFees`: keccak256(abi.encode(LegFee[] fees)), the fees listed by
    ///         strictly ascending `eid` (one per leg), so one set of fees has one hash. Reverts
    ///         `LegFeesNotAscending` otherwise, and on an empty list.
    function legFeesHash(LegFee[] memory fees) internal pure returns (bytes32) {
        if (fees.length == 0) revert LegFeesNotAscending(0);
        for (uint256 i = 1; i < fees.length; i++) {
            if (fees[i].eid <= fees[i - 1].eid) revert LegFeesNotAscending(i);
        }
        return keccak256(abi.encode(fees));
    }

    /// @notice Zero for no launch buys, else keccak256(abi.encode(LaunchBuy[] buys)).
    function buysHash(LaunchBuy[] memory buys) internal pure returns (bytes32) {
        if (buys.length == 0) return bytes32(0);
        return keccak256(abi.encode(buys));
    }

    /// @notice The CREATE2 salt a v3 token is deployed with: v2's `launchSalt` (salt, eids,
    ///         foreign, quotes), then keccak256(abi.encode(bytes32 v2Salt, address hook, bytes32
    ///         buysHash)). Binds the launch's hook and its launch buys under the signature (the
    ///         signer signs every EVM token address) without touching the Solana-reproduced terms.
    function launchSaltV3(bytes32 v2Salt, address hook, bytes32 buysHash_) internal pure returns (bytes32) {
        return keccak256(abi.encode(v2Salt, hook, buysHash_));
    }

    /// @notice The permission bits every launch hook's address carries -- PangeaFeeHook's mined
    ///         flags. A hook with any other set is refused by `setLaunchHook`.
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
}

/// @notice What the v3 factory asks of a launch hook. The live PangeaFeeHook answers all of it
///         (v1 hook); PangeaFeeHookV2 adds `IPangeaLaunchHookV2`. `configs` keeps its five-field
///         shape: TokenomicsVault reads it.
interface IPangeaLaunchHook {
    function poolManager() external view returns (IPoolManager);
    function locker() external view returns (address);
    function devBuyer() external view returns (address);
    function isFactory(address) external view returns (bool);
    function factoryOf(PoolId) external view returns (address);
    function configs(PoolId)
        external
        view
        returns (address splitter, bool quoteIsCurrency0, uint16 feeBps, bool registered, int24 edgeTick);
    function register(PoolKey calldata key, address splitter, bool quoteIsCurrency0, uint16 feeBps, int24 edgeTick)
        external;
    function redeem(PoolKey calldata key) external returns (uint256 amount0, uint256 amount1);
}

/// @notice PangeaFeeHookV2's additions: a per-pool fee the payee (the splitter's `creator`) or the
///         platform admin changes -- with no delay by default (constructor feeDelayBlocks = 0; a one-block-delay build schedules it instead, see PangeaFeeHookV2) -- inside [MIN_FEE_BPS, MAX_FEE_BPS]; fees already
///         earned are settled at the old rate first (redeem -> splitter.setFeeBps). `launchBuyer`
///         is fee-free like `devBuyer`.
interface IPangeaLaunchHookV2 is IPangeaLaunchHook {
    event FeeChanged(PoolId indexed id, uint16 fromBps, uint16 toBps, address by);

    function launchBuyer() external view returns (address);
    function setFee(PoolKey calldata key, uint16 feeBps) external;
}

/// @notice FeeSplitterV3 = FeeSplitterV2 + a fee its pool's hook may change. `setFeeBps` is the
///         hook's alone: it releases every native and `quote` balance at the old rate, then
///         switches. With the v1 hook nobody calls it and it is FeeSplitterV2 exactly.
interface IFeeSplitterV3 {
    function hook() external view returns (address);
    function feeBps() external view returns (uint16);
    function creator() external view returns (address);
    function factory() external view returns (address);
    function setFeeBps(address quote, uint16 feeBps) external;
}

/// @notice The launch-buys escrow (one per EVM chain). Payers deposit per-launch lines before the
///         launch; the factory calls `onLaunch` after `feeCollector.onLaunch`, inside try/catch,
///         so a failing buy never blocks a launch. It spends ONLY `payer`'s lines for `launchId`,
///         at most `cap` in total, executes only `buys` entries whose `eid` is this chain, and
///         leaves everything unspent reclaimable by its payer.
interface ILaunchBuys {
    function onLaunch(bytes32 launchId, address payer, address token, LaunchBuy[] calldata buys, uint256 cap)
        external;
}
