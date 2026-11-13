// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FactoryList} from "../FactoryList.sol";
import {TermsV3, IFeeSplitterV3, IPangeaLaunchHookV2} from "./V3Shared.sol";

/// @title PangeaFeeHookV2M -- Hook V2 (hookv2-ready-20261107 @ 807b71cc6) merged with the v4 hook (PangeaFeeHookV4)
/// @notice MERGE (owner 2026-11-12): this file is src/v3/PangeaFeeHookV2.sol at 807b71cc6 with exactly these changes:
///   1. a THIRD fee-free swapper, `coreBuyer` = LaunchCoreV4's own BridgeBuyerV4 (`buyerOf(core)`: the first contract
///      the core proxy CREATEs, nonce 1), exactly as PangeaFeeHookV4 derives it -- so the v4 core's launch buys and
///      creator first buys pay no fee on this hook as they did on 0x2243..8cC. `core` and `coreBuyer` are immutable,
///      constructor-derived; no config value or admin can name another. `_free` = devBuyer || launchBuyer || coreBuyer.
///   2. the constructor takes `core_` (nonzero) after `locker_`.
///   `launchBuyer` keeps Hook V2's meaning (the chain's v3 LaunchBuys), which factory v3's allowLaunchHook checks.
///   Nothing else changed: fee model, setFee/delay machinery, gap record, range edge, flags, storage order.
///
/// (Hook V2's notes follow.)
/// @title PangeaFeeHookV2
/// @notice PangeaFeeHook with a fee that can move. Everything the live hook does, it does the same
///         way, with the same six permission bits, the same `register`, and `configs`/`factoryOf`
///         in the same shape (TokenomicsVault reads them). Three things are new:
///
///   1. `setFee(key, feeBps)`: the pool's payee (its splitter's `creator`) or the platform admin
///      (`factoryAdmin`) moves the pool's fee anywhere in [MIN_FEE_BPS, MAX_FEE_BPS].
///   2. A second fee-free swapper, `launchBuyer` (this chain's LaunchBuys), beside `devBuyer`.
///   3. `feeDelayBlocks`, fixed at construction: 0 (the default) and a change takes effect in the
///      transaction that makes it; N and it takes effect N blocks later. The second is the
///      fallback kept ready in case Uniswap's hook review objects to an instant change.
///
/// The live hook's notes, all still true here, are in src/venues/PangeaFeeHook.sol and
/// FEE-HOOK-REVIEW.md. What follows is only what changed.
///
/// A FEE CHANGE NEVER RE-PRICES WHAT WAS ALREADY EARNED. The splitter divides what it holds by its
/// own rate: the platform takes a fifth of the fee or 0.2% of volume, whichever is more, and it
/// works volume out from the amount and the rate. So fees earned at 0.3% and divided at 5% would
/// give the platform a fifth of them instead of two thirds -- 0.06% of that volume rather than
/// 0.2%. A change therefore runs in this order, and never another:
///
///   1. every claim this pool has earned at the old rate is redeemed to its splitter;
///   2. `splitter.setFeeBps(quote, new)`: the splitter pays out everything it holds at the old
///      rate, then switches;
///   3. the hook stores the new rate, and every swap from then on is charged it.
///
/// No fee earned at one rate reaches the splitter while it is dividing at the other.
///
/// WITH A DELAY, THE SAME ORDER, LATER. `setFee` only schedules the new rate (`pendingFeeOf`), for
/// `block.number + feeDelayBlocks`. From that block every swap is charged it -- but a swap runs
/// inside the PoolManager's lock, where nothing can be redeemed, so the claims earned at the new
/// rate before the switch has been settled are kept apart (`owedAtPending`). The switch itself --
/// steps 1 to 3 above, then the kept-apart claims joining `owed` -- runs on the next `applyFee`,
/// `redeem` or `setFee` for the pool, whichever comes first; `applyFee` is anyone's. Until it runs
/// `configs(id).feeBps` still shows the old rate; `feeOf(id)` is the rate a swap pays now.
///
/// A SPLITTER THAT REFUSES THE SWITCH LOCKS NOTHING. `redeem` runs the settlement as its own call
/// (`settleDue`) and, if the splitter refuses, rolls back only that: it still redeems every
/// old-rate claim to the splitter (which still divides at the old rate) and keeps the new-rate
/// claims held in `owedAtPending` until a settlement goes through. `applyFee` and a payee's next
/// `setFee` revert while the splitter refuses. The platform admin may `cancelPendingFee`: the
/// scheduled rate is dropped and its held claims join `owed`, to be divided at the rate the
/// splitter is still on -- the one remedy left when a splitter will not switch, and the admin's.
///
/// NO SWAP RUNS WHILE A FEE IS MOVING. `setFee`, `applyFee`, `redeem` and `cancelPendingFee`
/// call out (the PoolManager, the splitter, and through it the payee). A swap from inside one of
/// them would be charged at one rate between the redeem and the store and divided at the other, so
/// `beforeSwap` refuses every swap while any of them is running. And the other way round: none of
/// them runs while a swap is between its `beforeSwap` and its `afterSwap` (`FeeChangeDuringSwap`):
/// the swap's one external call (the token's price record) could otherwise settle or move the rate
/// after the swap was charged one and before its other half is booked (hookv2-ready I-1).
///
/// THE DELAY COUNTS `block.number`, WHICH IS NOT THE SAME CLOCK EVERYWHERE. On Ethereum, Base and
/// BSC it is the chain's own block (about 12 s, 2 s and under a second). On Robinhood Chain, an
/// Arbitrum chain, `block.number` is the PARENT chain's block number as last seen by the
/// sequencer, so many of its own blocks share one value and "one block" is one parent block, about
/// 12 s. Blocks rather than seconds on purpose: what the fallback promises is that a change never
/// applies in the block (by `block.number`) that made it -- so a trade sent before or alongside
/// a change, and every quote taken in that block, pays the rate it saw -- and `block.number`
/// gives exactly that on all four chains. A timestamp would need a number of seconds chosen per
/// chain, and on Arbitrum many blocks share a timestamp too. The default is no delay at all.
///
/// ONE CHANGE PER POOL PER BLOCK, WITH NO DELAY. Without it a payee contract could, in one
/// transaction, drop its pool to 0.3%, trade, and put it back to 5%: its own trades charged at the
/// floor -- where the platform's cut is 0.2% of volume, against a fifth of 5% at the ceiling -- on a
/// pool everybody else sees at 5%. So a no-delay `setFee` is refused in a block where the pool's
/// fee already changed (`lastChangeBlock`), whoever makes it: payee and admin share the count. With
/// a delay the rule is not needed (nothing takes effect inside the block that schedules it) and
/// scheduling, replacing and cancelling within a block stay possible.
///
/// THE PAYEE AND THE ADMIN ARE PEERS: LAST WRITER WINS. Either may change the fee, and the later
/// change replaces the earlier -- nothing gives one precedence. A change scheduled (delay mode) by
/// a payee the platform has since rotated out of the splitter still applies when it falls due; the
/// admin can `cancelPendingFee` it, and the new payee can replace it.
///
/// WHO MAY CHANGE IT, AND WHAT THAT MEANS FOR A TRADER. The payee -- the address the pool's fees
/// are for -- and the platform admin. Neither can take more than MAX_FEE_BPS, change where the
/// fees go, touch the range, the liquidity or a registered pool's splitter. What an instant change
/// does allow is a payee raising the fee in front of a pending trade; the trader's own slippage
/// bound (every router sets one) caps what that can cost them, and the delay mode takes it away.
///
/// TWO SWAPPERS PAY NOTHING. `devBuyer` (this chain's LaunchFeeCollector, the dev buy) as before,
/// and `launchBuyer` (this chain's LaunchBuys, the launch buys a creator pays for with the launch).
/// Both are constructor arguments, immutable, and part of the init code. Why that is safe is the
/// same for both: `sender` is the address that called `poolManager.swap`, which nobody can
/// pretend to be, and each of the two swaps only from its own unlock callback, inside a launch,
/// for that launch's pool -- neither swaps for a caller or takes a pool key from one.
///
/// Why a constructor argument and not "settable once". Under CREATE3 the address does not depend
/// on the init code, so a constructor argument costs the mined address nothing; it keeps the
/// exemption a storage-free compare on every swap; and it leaves no window in which an admin key
/// could exempt an address of its choosing. The cost: LaunchBuys must exist first, and a new
/// LaunchBuys means a new hook.
/// @dev Implements IPangeaLaunchHookV2 (and so IPangeaLaunchHook) without naming it as a base: the
///      interface declares `isFactory(address)` and FactoryList answers it with a public mapping,
///      which Solidity will not let a contract inherit alongside the interface's function, and
///      FactoryList is shared with the live hook, locker and collector, whose code hashes a change
///      there would move. The conformance is pinned by test instead (selector for selector, the
///      interface ids, and every call through the interface); `FeeChanged` is the interface's own
///      event, emitted by its qualified name, so it cannot drift.
contract PangeaFeeHookV2M is IHooks, IUnlockCallback, ReentrancyGuardTransient, FactoryList {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice The six permissions this hook needs, which its address must encode: exactly the
    ///         live hook's, which is what `setLaunchHook` on factory v3 requires.
    uint160 public constant MINED_FLAGS = TermsV3.HOOK_FLAGS;

    uint256 internal constant BPS = 10_000;

    /// @notice The bounds a pool's fee must sit within, at registration and at every change. The
    ///         same two numbers the splitter enforces.
    uint16 public constant MIN_FEE_BPS = 30;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice The most of a splitter's revert reason `SettleFailed` carries.
    uint256 internal constant MAX_REASON_BYTES = 256;

    /// @notice The longest delay a hook may be built with: a day of 12-second blocks.
    uint256 public constant MAX_FEE_DELAY_BLOCKS = 7_200;

    IPoolManager public immutable poolManager;

    /// @notice The key that deployed this hook, and its first `factoryAdmin`. Under CREATE3 the
    ///         deploying contract is CreateX's proxy, so this is an argument, not `msg.sender`.
    address public immutable deployer;

    // Storage in the live hook's order (FactoryList's three slots, then these), so a reader of
    // its slots -- and the tests that read them -- reads this one the same way.

    /// @notice The factory that registered each pool. Written once, with the pool's config.
    mapping(PoolId => address) public factoryOf;

    struct Config {
        /// @notice Where this pool's fees go: a FeeSplitterV3 whose `hook` is this contract.
        address splitter;
        /// @notice Which side of the pair is the money.
        bool quoteIsCurrency0;
        /// @notice The fee the pool's splitter divides by, in bps. With no delay, the fee every
        ///         swap is charged. The pool itself charges nothing.
        uint16 feeBps;
        bool registered;
        /// @notice The edge of the launch's range on its empty side (see PangeaFeeHook).
        int24 edgeTick;
    }

    mapping(PoolId => Config) public configs;

    /// @notice Addresses besides the locker that may ADD liquidity, set by `factoryAdmin`.
    mapping(address => bool) public isLiquidityAdder;

    /// @notice Claims accrued per pool, per currency, at the pool's `configs` rate, waiting to be
    ///         redeemed into real tokens.
    mapping(PoolId => mapping(Currency => uint256)) public owed;

    /// @notice Delay mode only: claims accrued at a pending rate that has taken effect, before the
    ///         switch has been settled with the splitter. They join `owed` when it is.
    mapping(PoolId => mapping(Currency => uint256)) public owedAtPending;

    struct PendingFee {
        /// @notice The rate scheduled. Meaningless when `fromBlock` is zero.
        uint16 feeBps;
        /// @notice The first block that is charged it. Zero: nothing scheduled.
        uint64 fromBlock;
        /// @notice Who scheduled it, for the `FeeChanged` event when the switch is settled.
        address by;
    }

    /// @notice Delay mode only: each pool's scheduled rate.
    mapping(PoolId => PendingFee) public pendingFee;

    /// @notice No delay only: the block of each pool's last fee change. See "ONE CHANGE PER POOL
    ///         PER BLOCK".
    mapping(PoolId => uint256) public lastChangeBlock;

    /// @notice Whether a pool's fee has ever been changed since it was registered: a `setFee` that
    ///         moved the rate (no delay) or scheduled a change (delay mode). A setFee to the rate in
    ///         force, or one that only cancels a pending change, leaves it as it was (xa-dvn-hooks I-4). The v3 token prices the gap fee's allowance at the
    ///         fee in force at its price records; before its first record it has none, and this
    ///         says whether the registered (launch) fee still stands (round-4 audit M-1).
    mapping(PoolId => bool) public feeChanged;

    /// @notice The only address that may add liquidity besides `isLiquidityAdder`: this chain's
    ///         LiquidityLocker.
    address public immutable locker;

    /// @notice This chain's LaunchFeeCollector, which makes each launch's dev buy: charged nothing.
    address public immutable devBuyer;

    /// @notice This chain's LaunchBuys, which makes each launch's launch buys: charged nothing.
    address public immutable launchBuyer;

    /// @notice Blocks between `setFee` and the first swap charged the new rate. 0: none.
    uint256 public immutable feeDelayBlocks;

    /// @notice MERGE: the LaunchCoreV4 (proxy) whose own buyer is free, and that buyer (CREATE by `core`, nonce 1).
    address public immutable core;
    address public immutable coreBuyer;

    event Registered(PoolId indexed id, address splitter, uint16 feeBps, bool quoteIsCurrency0, int24 edgeTick);
    event Redeemed(PoolId indexed id, Currency currency, uint256 amount, address to);
    event FeeTaken(PoolId indexed id, Currency currency, uint256 amount);
    event LiquidityAdderSet(address indexed adder, bool allowed);
    // FeeChanged(id, fromBps, toBps, by) is IPangeaLaunchHookV2's: the rate the splitter divides by
    // (and, with no delay, every swap is charged) moved. In delay mode it is emitted when the
    // switch is settled, with `by` the address that scheduled it.
    /// @notice Delay mode: `toBps` is charged from block `fromBlock`.
    event FeeScheduled(PoolId indexed id, uint16 fromBps, uint16 toBps, uint64 fromBlock, address by);
    /// @notice Delay mode: the scheduled rate `bps` was dropped -- by scheduling the rate in force,
    ///         or by the admin (`cancelPendingFee`).
    event FeeChangeCancelled(PoolId indexed id, uint16 bps, address by);
    /// @notice Delay mode: `redeem` could not settle a due change (the splitter refused the
    ///         switch). The old-rate claims were redeemed anyway; the new-rate ones stay held.
    event SettleFailed(PoolId indexed id, bytes reason);

    error NotPoolManager();
    error NotFactory();
    error NotDeployer();
    error AlreadyRegistered();
    error NotRegistered();
    error WrongFlags(uint160 have, uint160 want);
    error HookNotImplemented();
    error NothingOwed();
    error ZeroSplitter();
    error PartialFill(uint256 asked, uint256 traded);
    error ZeroAddress();
    error NothingSwapped();
    error WrongHook(address hooks);
    error PoolFeeNotZero(uint24 fee);
    error FeeOutOfRange(uint16 feeBps);
    error OnlyLocker(address sender);
    error OutOfRange(int24 tick, int24 edgeTick);
    error OpensOutOfRange(uint160 sqrtPriceX96, int24 edgeTick);
    /// @notice `setFee` from someone who is neither the pool's payee nor the platform admin.
    error NotPayeeOrAdmin(address caller);
    /// @notice The pool's splitter does not name this hook, so it would refuse `setFeeBps`.
    error SplitterNotOurs(address splitter);
    error DelayTooLong(uint256 blocks);
    /// @notice `applyFee` with nothing scheduled that has taken effect.
    error NothingToApply();
    /// @notice `cancelPendingFee` with nothing scheduled.
    error NothingPending();
    /// @notice A second no-delay fee change on one pool in one block.
    error OneChangePerBlock();
    /// @notice `settleDue` from anyone but this contract.
    error NotSelf();
    /// @notice A swap while this hook is changing, settling or redeeming a pool's fee: it would be
    ///         charged one rate and divided at another.
    error SwapDuringFeeChange();
    /// @notice `setFee`, `applyFee`, `redeem` or `cancelPendingFee` from inside a swap on this hook
    ///         (between its beforeSwap and its afterSwap): see "NO SWAP RUNS WHILE A FEE IS MOVING".
    error FeeChangeDuringSwap();

    /// @dev How many swaps on this hook are between their beforeSwap and their afterSwap (transient:
    ///      this transaction only, and a reverted swap rolls its count back). A count, not a flag, so a
    ///      swap nested inside another's price record does not clear the outer one's.
    uint256 private transient _swapsOpen;

    /// @dev The fee functions refuse to run inside a swap (hookv2-ready I-1).
    modifier notInSwap() {
        if (_swapsOpen != 0) revert FeeChangeDuringSwap();
        _;
    }

    constructor(
        address poolManager_,
        address deployer_,
        address devBuyer_,
        address launchBuyer_,
        address locker_,
        address core_,
        uint256 feeDelayBlocks_
    ) {
        uint160 flags = uint160(address(this)) & Hooks.ALL_HOOK_MASK;
        if (flags != MINED_FLAGS) revert WrongFlags(flags, MINED_FLAGS);

        if (
            poolManager_ == address(0) || deployer_ == address(0) || devBuyer_ == address(0)
                || launchBuyer_ == address(0) || locker_ == address(0) || core_ == address(0)
        ) revert ZeroAddress();
        if (feeDelayBlocks_ > MAX_FEE_DELAY_BLOCKS) revert DelayTooLong(feeDelayBlocks_);
        poolManager = IPoolManager(poolManager_);
        deployer = deployer_;
        devBuyer = devBuyer_;
        launchBuyer = launchBuyer_;
        locker = locker_;
        feeDelayBlocks = feeDelayBlocks_;
        core = core_;
        coreBuyer = buyerOf(core_);
        _initFactoryAdmin(deployer_);
    }

    /// @notice Allow or stop `adder` adding liquidity to the pools this hook serves. The factory
    ///         admin only. As on the live hook.
    function setLiquidityAdder(address adder, bool allowed) external onlyFactoryAdmin {
        if (adder == address(0)) revert ZeroAddress();
        isLiquidityAdder[adder] = allowed;
        emit LiquidityAdderSet(adder, allowed);
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Record a pool, exactly as the live hook does. Once only; the splitter, the side and
    ///         the edge are fixed from then on. The fee is the starting fee; `setFee` moves it.
    function register(
        PoolKey calldata key,
        address splitter,
        bool quoteIsCurrency0,
        uint16 feeBps,
        int24 edgeTick
    ) external {
        if (!isFactory[msg.sender]) revert NotFactory();
        if (splitter == address(0)) revert ZeroSplitter();
        if (address(key.hooks) != address(this)) revert WrongHook(address(key.hooks));
        if (key.fee != 0) revert PoolFeeNotZero(key.fee);
        if (feeBps < MIN_FEE_BPS || feeBps > MAX_FEE_BPS) revert FeeOutOfRange(feeBps);

        PoolId id = key.toId();
        if (configs[id].registered) revert AlreadyRegistered();

        configs[id] = Config({
            splitter: splitter,
            quoteIsCurrency0: quoteIsCurrency0,
            feeBps: feeBps,
            registered: true,
            edgeTick: edgeTick
        });
        factoryOf[id] = msg.sender;
        emit Registered(id, splitter, feeBps, quoteIsCurrency0, edgeTick);
    }

    // ------------------------------------------------------------ the fee

    /// @notice Move a pool's fee to `feeBps`, inside [MIN_FEE_BPS, MAX_FEE_BPS]. The pool's payee
    ///         (its splitter's `creator`) or the platform admin (`factoryAdmin`) only.
    /// @dev With no delay: redeem, `splitter.setFeeBps`, store -- see "A FEE CHANGE NEVER
    ///      RE-PRICES". With a delay: settle any scheduled rate that has already taken effect, then
    ///      schedule this one, replacing one that has not. Scheduling the rate already in force
    ///      cancels a pending change (`FeeChangeCancelled`). While a due change cannot be settled
    ///      (its splitter refuses) this reverts; see "A SPLITTER THAT REFUSES".
    ///
    ///      Reverts inside a PoolManager unlock when the pool has claims to redeem (v4 refuses a
    ///      nested unlock); there is nothing to settle at the old rate in the case it lets through.
    function setFee(PoolKey calldata key, uint16 feeBps) external nonReentrant notInSwap {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        if (feeBps < MIN_FEE_BPS || feeBps > MAX_FEE_BPS) revert FeeOutOfRange(feeBps);
        // Read live: a payee the platform has moved (the splitter's two-step) moves this right too.
        if (msg.sender != IFeeSplitterV3(c.splitter).creator() && msg.sender != factoryAdmin) {
            revert NotPayeeOrAdmin(msg.sender);
        }
        // The splitter takes `setFeeBps` from its own hook only. Checked here so a pool whose
        // splitter is not ours fails at the change rather than, in delay mode, at a later redeem.
        if (IFeeSplitterV3(c.splitter).hook() != address(this)) revert SplitterNotOurs(c.splitter);

        if (feeDelayBlocks == 0) {
            // The rate in force: nothing to do (hookv2-ready I-2). It neither uses the block's one
            // change nor redeems, and it leaves `feeChanged` as it was (xa-dvn-hooks I-4).
            if (feeBps == c.feeBps) return;
            if (lastChangeBlock[id] == block.number) revert OneChangePerBlock();
            lastChangeBlock[id] = block.number;
            if (!feeChanged[id]) feeChanged[id] = true;
            _switch(key, id, c, feeBps, msg.sender);
            return;
        }

        if (_due(pendingFee[id])) (c,) = _applyDue(key, id, c);
        if (feeBps == c.feeBps) {
            // The rate in force: nothing to schedule, and a pending change is cancelled.
            PendingFee memory p = pendingFee[id];
            if (p.fromBlock != 0) {
                delete pendingFee[id];
                emit FeeChangeCancelled(id, p.feeBps, msg.sender);
            }
            return;
        }
        // A change is scheduled: the pool is marked (a cancel-only call above never marks it).
        if (!feeChanged[id]) feeChanged[id] = true;
        uint64 fromBlock = uint64(block.number + feeDelayBlocks);
        pendingFee[id] = PendingFee({feeBps: feeBps, fromBlock: fromBlock, by: msg.sender});
        emit FeeScheduled(id, c.feeBps, feeBps, fromBlock, msg.sender);
    }

    /// @notice Delay mode: settle a scheduled rate that has taken effect -- redeem what was earned
    ///         at the old rate, switch the splitter, store the rate. Anyone may call it; `redeem`
    ///         and `setFee` do it too.
    function applyFee(PoolKey calldata key) external nonReentrant notInSwap {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        if (!_due(pendingFee[id])) revert NothingToApply();
        _applyDue(key, id, c);
    }

    /// @notice Delay mode: drop a pool's scheduled rate, due or not. The platform admin only -- the
    ///         remedy for a splitter that refuses the switch. Claims already charged at the
    ///         scheduled rate join `owed`, divided at the rate the splitter is on.
    function cancelPendingFee(PoolKey calldata key) external nonReentrant notInSwap onlyFactoryAdmin {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        PendingFee memory p = pendingFee[id];
        if (p.fromBlock == 0) revert NothingPending();
        delete pendingFee[id];
        _joinOwed(key, id, c);
        emit FeeChangeCancelled(id, p.feeBps, msg.sender);
    }

    /// @notice `redeem`'s settlement of a due change, as a call of its own so a splitter that
    ///         refuses rolls back the settlement only. This contract alone may call it.
    /// @dev Not `nonReentrant`: it runs inside `redeem`, which holds the guard.
    function settleDue(PoolKey calldata key) external returns (bool switched) {
        if (msg.sender != address(this)) revert NotSelf();
        PoolId id = key.toId();
        (, switched) = _applyDue(key, id, configs[id]);
    }

    /// @notice The rate a swap on this pool is charged now (before any exemption): THE read for
    ///         anyone pricing a trade or showing the fee. `configs(id).feeBps` is the rate the
    ///         splitter divides by, which lags it in delay mode until a change is settled.
    function feeOf(PoolId id) external view returns (uint16) {
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        (uint16 f,) = _feeNow(id, c.feeBps);
        return f;
    }

    /// @notice Every claim the pool has earned and not yet redeemed, in `currency`: `owed` plus,
    ///         in delay mode, what is held at a pending rate (`owedAtPending`).
    function owedNow(PoolId id, Currency currency) external view returns (uint256) {
        return owed[id][currency] + owedAtPending[id][currency];
    }

    /// @notice The rate scheduled for a pool and the first block charged it, or (0, 0).
    function pendingFeeOf(PoolId id) external view returns (uint16 feeBps, uint64 fromBlock) {
        PendingFee memory p = pendingFee[id];
        return p.fromBlock == 0 ? (uint16(0), uint64(0)) : (p.feeBps, p.fromBlock);
    }

    /// @dev Delay mode: the scheduled rate has taken effect but has not been settled.
    function _due(PendingFee memory p) internal view returns (bool) {
        return p.fromBlock != 0 && block.number >= p.fromBlock;
    }

    /// @dev The rate charged now, and whether it is a pending one that has taken effect (whose
    ///      claims go to `owedAtPending`). With no delay, `configs` and nothing else, for no
    ///      storage read beyond the one every swap already makes.
    function _feeNow(PoolId id, uint16 configured) internal view returns (uint16, bool) {
        if (feeDelayBlocks == 0) return (configured, false);
        PendingFee memory p = pendingFee[id];
        if (_due(p)) return (p.feeBps, true);
        return (configured, false);
    }

    /// @dev Settle the due pending rate: the old-rate claims out, the splitter switched, the rate
    ///      stored, and the claims earned at the new rate since it took effect moved into `owed`.
    ///      A pending rate equal to the one in force (`setFee` no longer schedules one, but the
    ///      rule holds whatever got there) has nothing to settle: its claims just join `owed`.
    ///      Returns whether the switch -- and with it the redeem of the old-rate claims -- ran.
    function _applyDue(PoolKey calldata key, PoolId id, Config memory c) internal returns (Config memory, bool switched) {
        PendingFee memory p = pendingFee[id];
        delete pendingFee[id];
        switched = p.feeBps != c.feeBps;
        if (switched) _switch(key, id, c, p.feeBps, p.by);
        _joinOwed(key, id, c);
        c.feeBps = p.feeBps;
        return (c, switched);
    }

    /// @dev The claims held at a pending rate join `owed`.
    function _joinOwed(PoolKey calldata key, PoolId id, Config memory c) internal {
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;
        uint256 later = owedAtPending[id][quote];
        if (later != 0) {
            owedAtPending[id][quote] = 0;
            owed[id][quote] += later;
        }
    }

    /// @dev Steps 1 to 3: redeem at the old rate, the splitter settles and switches, store.
    function _switch(PoolKey calldata key, PoolId id, Config memory c, uint16 feeBps, address by) internal {
        _redeem(key, id, c.splitter);
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;
        IFeeSplitterV3(c.splitter).setFeeBps(Currency.unwrap(quote), feeBps);
        configs[id].feeBps = feeBps;
        emit IPangeaLaunchHookV2.FeeChanged(id, c.feeBps, feeBps, by);
    }

    // ------------------------------------------------------------ redeeming

    /// @notice Turn a pool's accrued claims into real tokens, sent to its splitter. Permissionless,
    ///         as on the live hook. In delay mode a rate that has taken effect is settled first,
    ///         and the amounts returned include the old-rate claims that settlement redeemed.
    /// @dev `NothingOwed` only when nothing was redeemed AND nothing was settled. A settlement with
    ///      nothing else owed is a redeem that did its work: reverting it would roll the switch
    ///      back, and a caller that tries it and ignores failure -- TokenomicsVault's `_pull` -- would
    ///      leave the change unsettled and the old-rate claims in the hook. A settlement the
    ///      splitter refuses is rolled back alone (`settleDue` is its own call): the old-rate claims
    ///      are still redeemed, and `SettleFailed` says why the switch did not happen.
    function redeem(PoolKey calldata key) external nonReentrant notInSwap returns (uint256 amount0, uint256 amount1) {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        bool settled;
        uint256 old0;
        uint256 old1;
        if (feeDelayBlocks != 0 && _due(pendingFee[id])) {
            // What the settlement's own redeem sends: everything owed at the old rate, now.
            old0 = owed[id][key.currency0];
            old1 = owed[id][key.currency1];
            try this.settleDue(key) returns (bool switched) {
                settled = true;
                // Only a switch redeemed them; a same-rate entry left them in `owed` for below.
                if (!switched) (old0, old1) = (0, 0);
            } catch (bytes memory reason) {
                // Rolled back: the old-rate claims are still in `owed` and go out below, at the
                // rate the splitter is still on; the new-rate ones stay held.
                (old0, old1) = (0, 0);
                // At most 256 bytes of whatever the splitter reverted with.
                if (reason.length > MAX_REASON_BYTES) {
                    assembly ("memory-safe") {
                        mstore(reason, MAX_REASON_BYTES)
                    }
                }
                emit SettleFailed(id, reason);
            }
        }
        (amount0, amount1) = _redeem(key, id, c.splitter);
        amount0 += old0;
        amount1 += old1;
        if (!settled && amount0 == 0 && amount1 == 0) revert NothingOwed();
    }

    /// @dev Everything `owed` for the pool, to its splitter. Nothing owed: nothing done.
    function _redeem(PoolKey calldata key, PoolId id, address splitter) internal returns (uint256 amount0, uint256 amount1) {
        amount0 = owed[id][key.currency0];
        amount1 = owed[id][key.currency1];
        if (amount0 == 0 && amount1 == 0) return (0, 0);

        // Cleared before the unlock, so a currency that re-enters cannot be redeemed twice.
        if (amount0 > 0) owed[id][key.currency0] = 0;
        if (amount1 > 0) owed[id][key.currency1] = 0;

        poolManager.unlock(abi.encode(key, splitter, amount0, amount1));

        if (amount0 > 0) emit Redeemed(id, key.currency0, amount0, splitter);
        if (amount1 > 0) emit Redeemed(id, key.currency1, amount1, splitter);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, address to, uint256 amount0, uint256 amount1) =
            abi.decode(data, (PoolKey, address, uint256, uint256));

        if (amount0 > 0) {
            poolManager.burn(address(this), key.currency0.toId(), amount0);
            poolManager.take(key.currency0, to, amount0);
        }
        if (amount1 > 0) {
            poolManager.burn(address(this), key.currency1.toId(), amount1);
            poolManager.take(key.currency1, to, amount1);
        }
        return "";
    }

    // ------------------------------------------------------------ the swap

    /// @dev The dev buy, the launch buys and (MERGE) the v4 core's launch / dev buys pay nothing.
    function _free(address sender) internal view returns (bool) {
        return sender == devBuyer || sender == launchBuyer || sender == coreBuyer;
    }

    /// @notice MERGE (as PangeaFeeHookV4.buyerOf): the core's own BridgeBuyerV4, the first contract `core_` CREATEs
    ///         (nonce 1).
    function buyerOf(address core_) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), core_, bytes1(0x01))))));
    }

    /// @dev Mint `fee` of `quote` as this contract's claim and book it: to `owed`, or, for a
    ///      pending rate in force but not yet settled, to `owedAtPending`.
    function _take(PoolId id, Currency quote, uint256 fee, bool atPending) internal {
        poolManager.mint(address(this), quote.toId(), fee);
        if (atPending) owedAtPending[id][quote] += fee;
        else owed[id][quote] += fee;
        emit FeeTaken(id, quote, fee);
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee when the quote is the specified currency -- a buy, for an exact-in swap.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // See "NO SWAP RUNS WHILE A FEE IS MOVING": the guard is held by setFee, applyFee, redeem
        // and cancelPendingFee, and by nothing on the swap path.
        if (_reentrancyGuardEntered()) revert SwapDuringFeeChange();
        // Open until this swap's afterSwap (every swap on this hook reaches it: both flags are mined).
        _swapsOpen += 1;
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();
        // The price before this swap, for the token's record in afterSwap (transient: this swap only).
        {
            (uint160 pre,,,) = poolManager.getSlot0(id);
            bytes32 slot = _preSlot(id);
            assembly ("memory-safe") {
                tstore(slot, pre)
            }
        }

        bool exactIn = params.amountSpecified < 0;
        Currency specified = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;

        if (Currency.unwrap(specified) != Currency.unwrap(quote)) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        if (_free(sender)) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        (uint16 feeBps, bool atPending) = _feeNow(id, c.feeBps);
        uint256 amount = uint256(exactIn ? -params.amountSpecified : params.amountSpecified);
        uint256 fee = _fee(amount, feeBps, !exactIn);
        if (fee == 0) return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);

        _take(id, quote, fee, atPending);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @inheritdoc IHooks
    /// @dev Takes the fee when the quote is the unspecified currency -- a sell, for an exact-in
    ///      swap -- and holds every swap to the launch's range.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        Config memory c = configs[id];
        if (!c.registered) revert NotRegistered();

        if (delta.amount0() == 0 && delta.amount1() == 0) revert NothingSwapped();

        // The same block as beforeSwap, so the same rate; read ONCE, before the record's external
        // call, and nothing can move it during that call (notInSwap; hookv2-ready I-1).
        (uint16 feeBps, bool atPending) = _feeNow(id, c.feeBps);
        {
            (uint160 post, int24 tick,,) = poolManager.getSlot0(id);
            if (c.quoteIsCurrency0 ? tick >= c.edgeTick : tick < c.edgeTick) revert OutOfRange(tick, c.edgeTick);
            _record(key, id, c.quoteIsCurrency0, post, feeBps);
        }
        // The record was the swap's last call out: the swap is closed for the fee functions again.
        _swapsOpen -= 1;

        bool exactIn = params.amountSpecified < 0;
        Currency specified = exactIn
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        Currency quote = c.quoteIsCurrency0 ? key.currency0 : key.currency1;
        bool free = _free(sender);

        if (Currency.unwrap(specified) == Currency.unwrap(quote)) {
            _requireFullFill(params.amountSpecified, c.quoteIsCurrency0 ? delta.amount0() : delta.amount1(), free ? 0 : feeBps);
            return (IHooks.afterSwap.selector, 0);
        }

        int128 quoteDelta = c.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        uint256 moved = uint256(uint128(quoteDelta < 0 ? -quoteDelta : quoteDelta));
        if (moved == 0 || free) return (IHooks.afterSwap.selector, 0);

        uint256 fee = _fee(moved, feeBps, !exactIn);
        if (fee == 0) return (IHooks.afterSwap.selector, 0);

        _take(id, quote, fee, atPending);
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    // ------------------------------------------------------------- the v3 gap fee's price record

    /// @notice The gas `recordPrice` is given on every swap: a v3 token's first record copies its
    ///         official pool from the registry (and reads its quote's decimals) and writes five slots.
    uint256 public constant RECORD_GAS = 250_000;

    /// @notice A swap left with less gas than its record needs reverts (`RecordGasTooLow`): a record
    ///         can never be skipped by the gas the swapper chose (owner 2026-10-28, v3 audit H-1/H-2).
    error RecordGasTooLow(uint256 needed, uint256 left);

    /// @dev `token.recordPrice(poolId, sqrtBefore, sqrtAfter, feeBps)` (PangeaOFTV3, through its gap
    ///      module), `feeBps` the rate this swap is charged (round-4 audit M-1: the token prices
    ///      the gap fee's allowance at the lowest of the fee now and the fees at its two closes):
    ///      the v3 gap fee's price record, made HERE, at swap time, so a record is a real swap's
    ///      outcome in the order the swaps ran -- never a transfer the swapper orders. Called on every
    ///      swap of every pool on this hook, with RECORD_GAS and its result ignored: a token that is
    ///      not a v3 token, or a pool that is not its official one, answers with a revert, which
    ///      changes nothing. The gas is required up front, so the call cannot be starved.
    function _record(PoolKey calldata key, PoolId id, bool quoteIsCurrency0, uint160 post, uint16 feeBps) internal {
        uint256 need = (RECORD_GAS * 64) / 63 + 5_000;
        uint256 left = gasleft();
        if (left < need) revert RecordGasTooLow(need, left);
        address token = Currency.unwrap(quoteIsCurrency0 ? key.currency1 : key.currency0);
        bytes32 slot = _preSlot(id);
        uint160 pre;
        assembly ("memory-safe") {
            pre := tload(slot)
        }
        bytes memory data = abi.encodeWithSelector(RECORD_PRICE, PoolId.unwrap(id), pre, post, feeBps);
        assembly ("memory-safe") {
            pop(call(RECORD_GAS, token, 0, add(data, 32), mload(data), 0, 0))
        }
    }

    /// @dev recordPrice(bytes32,uint160,uint160,uint16).
    bytes4 internal constant RECORD_PRICE = bytes4(keccak256("recordPrice(bytes32,uint160,uint160,uint16)"));

    /// @dev Where beforeSwap leaves the pool's pre-swap price for afterSwap (transient storage).
    function _preSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(id), "pangea.hook.v2.pre"));
    }

    /// @dev A quote-specified swap must trade exactly the request less (exact-in) or plus
    ///      (exact-out) the fee charged on it up front. See PangeaFeeHook.
    function _requireFullFill(int256 amountSpecified, int128 quoteDelta, uint16 feeBps) internal pure {
        bool exactIn = amountSpecified < 0;
        uint256 asked = uint256(exactIn ? -amountSpecified : amountSpecified);
        uint256 fee = _fee(asked, feeBps, !exactIn);
        uint256 traded = uint256(uint128(quoteDelta < 0 ? -quoteDelta : quoteDelta));
        if (traded != (exactIn ? asked - fee : asked + fee)) revert PartialFill(asked, traded);
    }

    /// @dev `feeBps` of the gross amount, given either the gross amount itself or the net one.
    ///      Rounds down both ways, so the trader is never charged more than the rate.
    function _fee(uint256 amount, uint16 feeBps, bool amountIsNet) internal pure returns (uint256) {
        return amountIsNet ? (amount * feeBps) / (BPS - feeBps) : (amount * feeBps) / BPS;
    }

    // ------------------------------------------------------- initialization

    /// @inheritdoc IHooks
    /// @dev Refuses a pool the factory has not registered, and a pool opening on the empty side of
    ///      its edge. As on the live hook.
    function beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        Config memory c = configs[key.toId()];
        if (!c.registered) revert NotRegistered();
        uint160 edge = TickMath.getSqrtPriceAtTick(c.edgeTick);
        if (c.quoteIsCurrency0 ? sqrtPriceX96 >= edge : sqrtPriceX96 < edge) {
            revert OpensOutOfRange(sqrtPriceX96, c.edgeTick);
        }
        return IHooks.beforeInitialize.selector;
    }

    // ------------------------------------------- everything v4 may still call

    /// @dev v4 calls only what a hook's address advertises, so these can never be reached; they
    ///      revert so that a mis-mined address fails loudly.

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @notice Only the locker adds liquidity, and whoever the admin has named. As on the live hook.
    function beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (sender != locker && !isLiquidityAdder[sender]) revert OnlyLocker(sender);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
