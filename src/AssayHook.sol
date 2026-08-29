// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayConfig, AssayConfigLib} from "./config/AssayConfig.sol";
import {IAssayErrors} from "./interfaces/IAssayErrors.sol";
import {IAssayEvents} from "./interfaces/IAssayEvents.sol";
import {IReferencePriceOracle} from "./interfaces/IReferencePriceOracle.sol";
import {FeeBlend} from "./libraries/FeeBlend.sol";
import {Mispricing} from "./libraries/Mispricing.sol";
import {PoolTwap} from "./libraries/PoolTwap.sol";
import {ToxicitySurcharge} from "./libraries/ToxicitySurcharge.sol";
import {PoolState} from "./types/PoolState.sol";

/// @title AssayHook
/// @notice A Uniswap v4 hook that prices adverse selection per swap rather than per pool.
/// @dev Every formula lives in a pure library; this contract reads state, delegates, writes
///      state and returns values. That separation is what makes the math independently
///      fuzzable without a PoolManager. The only arithmetic here is the `|` that sets v4's
///      fee-override flag and the `uint32(block.number)` narrowing used to detect a block
///      boundary; the only other control flow is the boolean combination in
///      `_advanceStateInPlace` that lets the deviation cap veto a reading `_readReference`
///      itself reported fresh. None of these is a formula, and all are covered by the tests
///      below.
///
///      The quoted fee is set from the drift a swap captures against a cached reference
///      price. Realised variance and order-flow imbalance were previously maintained here
///      and have been removed: calibration measured their incremental value over the
///      reference signal at -0.008 and -0.002 across two windows, so they were paying gas on
///      every swap to make the classifier no better. The libraries remain in the tree, pure
///      and tested, for the milestone that can show they earn their cost.
contract AssayHook is BaseHook, IAssayErrors, IAssayEvents {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    uint24 private immutable BASE_FEE_PIPS;
    uint24 private immutable MIN_FEE_PIPS;
    uint24 private immutable MAX_FEE_PIPS;
    uint24 private immutable CAPTURE_SHARE_BPS;
    IReferencePriceOracle private immutable REFERENCE_ORACLE;
    uint24 private immutable MAX_REFERENCE_DEVIATION_TICKS;
    uint64 private immutable TWAP_LAMBDA_X32;

    mapping(PoolId poolId => PoolState) private _poolState;

    /// @notice Deploys the hook against a PoolManager with validated parameters.
    /// @dev The address this deploys to must carry exactly the permission bits returned by
    ///      `getHookPermissions`; `BaseHook` enforces that in its constructor, so deployment
    ///      requires a mined CREATE2 salt.
    /// @param poolManager The v4 PoolManager singleton this hook serves.
    /// @param config Fee bounds and estimator parameters, validated before any immutable is set.
    constructor(IPoolManager poolManager, AssayConfig memory config) BaseHook(poolManager) {
        AssayConfigLib.validate(config);
        BASE_FEE_PIPS = config.baseFeePips;
        MIN_FEE_PIPS = config.minFeePips;
        MAX_FEE_PIPS = config.maxFeePips;
        CAPTURE_SHARE_BPS = config.captureShareBps;
        REFERENCE_ORACLE = IReferencePriceOracle(config.referenceOracle);
        MAX_REFERENCE_DEVIATION_TICKS = config.maxReferenceDeviationTicks;
        TWAP_LAMBDA_X32 = config.twapLambdaX32;
    }

    /// @notice The permissions this hook requires, and no others.
    /// @dev `afterSwapReturnDelta` carries the toxicity surcharge: `_donateCeilingOverflow`
    ///      returns a positive delta that repays the `donate` it just made. This is the only
    ///      path where the hook touches swapper funds and is the first thing to review.
    ///      Permission bits are encoded in the hook address, so a bit cannot be added later
    ///      without changing the address and invalidating every recorded deployment.
    /// @return permissions The v4 permission set, corresponding to address mask 0x30C4.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The fee bounds this hook was deployed with, in hundredths of a bip.
    /// @dev Exposed because a router or LP needs to know the worst fee a swap can be quoted
    ///      before routing into the pool.
    /// @return baseFeePips The fee quoted when no adverse-selection signal applies.
    /// @return minFeePips The floor of any quoted fee.
    /// @return maxFeePips The ceiling of any quoted fee.
    function feeBounds() external view returns (uint24 baseFeePips, uint24 minFeePips, uint24 maxFeePips) {
        return (BASE_FEE_PIPS, MIN_FEE_PIPS, MAX_FEE_PIPS);
    }

    /// @notice Current microstructure state for a pool.
    /// @param poolId The pool to read.
    /// @return state Last observed tick, the cached reference tick and its freshness, the
    ///         block that reference was last refreshed in, and the smoothed TWAP anchor the
    ///         deviation cap checks it against.
    function poolState(PoolId poolId) external view returns (PoolState memory state) {
        return _poolState[poolId];
    }

    /// @notice How far a pool sits from its reference price, signed for a given direction.
    /// @dev Serves the cached reading, so this is the same value the swap path would use.
    ///      A caller must check `fresh` before acting: a stale reference means the hook has
    ///      no view of the pool's drift, not that the drift is zero.
    /// @param poolId The pool to measure.
    /// @param zeroForOne Direction of the hypothetical swap.
    /// @return capturedTicks Positive when such a swap would trade toward the reference.
    /// @return fresh Whether the cached reference is usable.
    function signedMispricing(PoolId poolId, bool zeroForOne)
        external
        view
        returns (int256 capturedTicks, bool fresh)
    {
        PoolState memory state = _poolState[poolId];
        return (Mispricing.signedTicks(state.referenceTick, state.lastTick, zeroForOne), state.referenceFresh);
    }

    /// @notice The pool's smoothed tick anchor and how far the cached reference sits from it.
    /// @dev Exposes the deviation-cap inputs directly, so an operator or dashboard can see
    ///      why a reference was rejected rather than only that it was -- the same reasoning
    ///      that gives `ReferenceDeviationCapTripped` its own event instead of folding into
    ///      `ReferenceFreshnessChanged`.
    /// @param poolId The pool to read.
    /// @return twapTick The pool's smoothed tick anchor.
    /// @return deviationTicks Signed distance from that anchor to the cached reference tick.
    /// @return withinBound Whether that distance is inside the configured cap; always true
    ///         when the cap is disabled (`maxReferenceDeviationTicks == 0`).
    function referenceDeviation(PoolId poolId)
        external
        view
        returns (int24 twapTick, int256 deviationTicks, bool withinBound)
    {
        PoolState memory state = _poolState[poolId];
        twapTick = PoolTwap.tick(state.twapTickX32);
        deviationTicks = PoolTwap.deviationTicks(state.twapTickX32, state.referenceTick);
        withinBound =
            PoolTwap.withinBound(state.twapTickX32, state.referenceTick, MAX_REFERENCE_DEVIATION_TICKS);
    }

    /// @dev The fee a given state and direction imply. Kept in one place so the quote the
    ///      hook returns and the quote it reports in `SwapAssayed` cannot drift apart.
    function _quote(PoolState memory state, bool zeroForOne) private view returns (uint24) {
        return FeeBlend.quote(
            Mispricing.signedTicks(state.referenceTick, state.lastTick, zeroForOne),
            state.referenceFresh,
            BASE_FEE_PIPS,
            MIN_FEE_PIPS,
            MAX_FEE_PIPS,
            CAPTURE_SHARE_BPS
        );
    }

    /// @dev Reads the reference source, tolerating any failure as an unusable reading.
    ///      The oracle interface forbids reverting, but this hook cannot depend on a third
    ///      party honouring that, so the conversion is guarded here as well.
    function _readReference() private view returns (int24 referenceTick, bool fresh) {
        try REFERENCE_ORACLE.referenceSqrtPriceX96() returns (uint160 sqrtPriceX96, bool ok) {
            if (!ok || sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
                return (0, false);
            }
            return (TickMath.getTickAtSqrtPrice(sqrtPriceX96), true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Rejects pools this hook cannot price. Both reverts are safe because they run at
    ///      pool creation, before any liquidity exists; a revert on the swap path would brick
    ///      the pool for every liquidity provider, which is why this is the only place the
    ///      hook refuses anything.
    ///
    ///      v4 hooks are permissionless, so anyone may create a pool naming this one. The
    ///      reference source describes exactly one pair -- its decimal scaling encodes those
    ///      tokens -- so a pool of different assets would be quoted against a price for
    ///      something else, and the hook would report that reading as fresh while doing it.
    ///      Refusing at creation is the only point where refusal is free.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert AssayHook__PoolIsNotDynamicFee();

        (Currency expected0, Currency expected1) = REFERENCE_ORACLE.pricedCurrencies();
        if (
            Currency.unwrap(key.currency0) != Currency.unwrap(expected0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(expected1)
        ) {
            revert AssayHook__PoolDoesNotMatchReference(
                Currency.unwrap(expected0),
                Currency.unwrap(expected1),
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1)
            );
        }

        return this.beforeInitialize.selector;
    }

    /// @dev Seeds the pool's fee and the state the first swap will measure against.
    ///
    ///      The TWAP anchor is seeded from the same tick as `referenceTick`: a fresh oracle
    ///      reading if one is available, since that is the best information about the true
    ///      price that exists before any organic trading has happened on this pool, and the
    ///      pool's own initial tick otherwise. Seeding it from zero, or from the pool's
    ///      initial tick regardless of the oracle, would risk the deviation cap tripping on
    ///      the very first block against a reference that was correct all along -- there is
    ///      no trading history yet to have earned distrust of it.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        (int24 referenceTick, bool referenceFresh) = _readReference();
        int24 seedTick = referenceFresh ? referenceTick : tick;
        _poolState[poolId] = PoolState({
            lastTick: tick,
            referenceTick: seedTick,
            lastBlock: uint32(block.number),
            referenceFresh: referenceFresh,
            twapTickX32: PoolTwap.seed(seedTick)
        });

        emit PoolRegistered(poolId, BASE_FEE_PIPS);
        poolManager.updateDynamicLPFee(key, BASE_FEE_PIPS);
        return this.afterInitialize.selector;
    }

    /// @dev Quotes the fee for this swap.
    ///
    ///      Everything this needs is already in one storage word: the cached reference tick
    ///      and the pool's last tick. The mispricing is a subtraction and a sign, and the fee
    ///      is a multiply and a clamp. No external call, no oracle read, no second slot.
    ///
    ///      Returns no delta: Assay never takes custody of swap principal, which is the
    ///      highest-severity finding class in v4 hook audits.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            _quote(_poolState[key.toId()], params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Folds this swap into the pool's microstructure state.
    ///
    ///      The reference is refreshed at most once per block; everything else here advances
    ///      on every swap.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolState memory state = _poolState[poolId];

        // Snapshot the exact drift `beforeSwap` quoted against, before anything below
        // mutates it. This swap moves the tick toward the reference, and a block boundary
        // may refresh the reference itself, so measuring after would attribute a fee that
        // was never charged and would size the surcharge against the wrong drift.
        int256 quotedDrift = Mispricing.signedTicks(state.referenceTick, state.lastTick, params.zeroForOne);
        bool quotedFresh = state.referenceFresh;

        _advanceStateInPlace(poolId, state);
        _poolState[poolId] = state;

        emit SwapAssayed(
            poolId,
            sender,
            FeeBlend.quote(
                quotedDrift, quotedFresh, BASE_FEE_PIPS, MIN_FEE_PIPS, MAX_FEE_PIPS, CAPTURE_SHARE_BPS
            )
        );

        return (
            this.afterSwap.selector,
            _donateCeilingOverflow(poolId, key, params, delta, quotedDrift, quotedFresh)
        );
    }

    /// @dev Advances the pool's cached state, MUTATING `state` in place.
    ///
    ///      `state` is a memory reference, so every assignment below is visible to the
    ///      caller and there is no functional copy. Anything derived from the pre-swap
    ///      state must be extracted BEFORE this is called -- see `quotedDrift` in
    ///      `_afterSwap`. Taking a `PoolState memory` snapshot after this point aliases the
    ///      mutated struct and silently yields post-swap values.
    ///
    ///      Kept in its own frame so its locals do not compete for stack slots with the
    ///      attribution and surcharge work that follows.
    function _advanceStateInPlace(PoolId poolId, PoolState memory state) private {
        // slot0 also carries the price and both fee fields; only the tick is needed here and
        // the rest are deliberately discarded.
        // slither-disable-next-line unused-return
        (, int24 tickNow,,) = poolManager.getSlot0(poolId);

        // The reference is refreshed at most once per block rather than on every swap. A
        // live Chainlink read measures ~20,000 gas against the Base Sepolia aggregator, so
        // the cost is amortised across a block's swaps -- but the first swap of each block
        // still pays it in full, and that is the hook's most expensive path.
        if (state.lastBlock != uint32(block.number)) {
            state.lastBlock = uint32(block.number);

            // `state.lastTick` still holds wherever the pool stood at the end of the
            // previous block: this runs before it is overwritten below with the current
            // swap's own tick, so nothing this block's swaps have done can be reflected in
            // the sample folded in here. That is what keeps the average resistant to being
            // moved from inside the same block that needs it to look a certain way.
            state.twapTickX32 = PoolTwap.update(state.twapTickX32, state.lastTick, TWAP_LAMBDA_X32);

            (int24 referenceTick, bool referenceFresh) = _readReference();

            // A reading the oracle itself reports as fresh can still be rejected here: it
            // disagrees with where the pool has actually been trading by more than the
            // configured cap. Treating it identically to an unusable reading -- rather than
            // adopting it and letting `FeeBlend` price against it -- is what closes the gap
            // a compromised or misconfigured feed would otherwise leave: any error large
            // enough to matter shows up as a large, sustained gap against the pool's own
            // cost-to-manipulate trading history, not as a single flag this hook can miss.
            if (
                referenceFresh
                    && !PoolTwap.withinBound(state.twapTickX32, referenceTick, MAX_REFERENCE_DEVIATION_TICKS)
            ) {
                emit ReferenceDeviationCapTripped(
                    poolId, referenceTick, PoolTwap.tick(state.twapTickX32), MAX_REFERENCE_DEVIATION_TICKS
                );
                referenceFresh = false;
            }

            if (referenceFresh) {
                state.referenceTick = referenceTick;
            }
            if (state.referenceFresh != referenceFresh) {
                state.referenceFresh = referenceFresh;
                emit ReferenceFreshnessChanged(poolId, referenceFresh);
            }
        }

        state.lastTick = tickNow;
    }

    /// @dev Recovers the fee-cap overflow as a real token amount and routes it to in-range
    ///      liquidity providers via `donate`, funded entirely by the swapper.
    ///
    ///      The mechanics: `donate` immediately debits this contract's own balance in the
    ///      PoolManager's transient ledger. Returning the same amount as a positive
    ///      `int128` here credits it straight back -- v4 applies that credit to this
    ///      contract's address in the same ledger before the swapper's own delta is
    ///      finalised. The two cancel exactly, so the hook is never left holding a balance
    ///      and never needs `take`; the swapper's settlement absorbs the entire amount,
    ///      which is what actually funds the donation.
    ///
    ///      Zero on the overwhelming majority of swaps: `FeeBlend.ceilingOverflowPips` is
    ///      zero unless the uncapped formula would have asked for more than `maxFeePips`
    ///      already covers, which only happens on an extreme dislocation.
    function _donateCeilingOverflow(
        PoolId poolId,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        int256 quotedDrift,
        bool quotedFresh
    ) private returns (int128) {
        uint24 overflowPips = FeeBlend.ceilingOverflowPips(
            quotedDrift, quotedFresh, BASE_FEE_PIPS, MAX_FEE_PIPS, CAPTURE_SHARE_BPS
        );
        // Exact comparison on an exactly-computed integer, not on a balance or a price.
        // Zero here means the uncapped formula never reached the ceiling, which is the
        // common case and must short-circuit before any external call.
        // slither-disable-next-line incorrect-equality
        if (overflowPips == 0) return 0;

        // `donate` reverts outright when the pool has no in-range liquidity, because there
        // is nobody to credit the fee growth to. A swap that walks the price out of every
        // liquidity range would otherwise revert here, in `afterSwap`, bricking the pool for
        // the exact reason this hook is built never to do. Skipping the surcharge is the
        // only safe response: there are no liquidity providers in range to receive it.
        if (poolManager.getLiquidity(poolId) == 0) return 0;

        (bool currency0IsUnspecified, uint256 notional) = ToxicitySurcharge.unspecifiedAmount(params, delta);

        // `notional` is the magnitude of an int128 delta and `overflowPips` is bounded by
        // FeeBlend.MAX_OVERFLOW_PIPS, which equals the pips denominator, so the surcharge is
        // at most `notional` and therefore always fits int128. No range check is needed here
        // and adding one would be an unreachable branch.
        uint256 amount = ToxicitySurcharge.surchargeAmount(notional, overflowPips);
        // As above: an exact integer. `surchargeAmount` rounds up, so this is zero only when
        // the swap's unspecified side is itself zero -- a swap whose output rounded away
        // entirely. Donating zero would cost an external call and emit a meaningless event.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;

        emit ToxicitySurchargeDonated(poolId, amount, currency0IsUnspecified);

        // Emitted before the call rather than after. If `donate` reverts the whole
        // transaction reverts and the event never persists, so the ordering is equivalent
        // and the log cannot be observed mid-call by a reentrant party.
        //
        // The returned BalanceDelta is discarded deliberately: it is exactly `-amount` on
        // the donated side, which is already known here and is what the returned hook delta
        // credits straight back.
        if (currency0IsUnspecified) {
            // slither-disable-next-line unused-return
            poolManager.donate(key, amount, 0, "");
        } else {
            // slither-disable-next-line unused-return
            poolManager.donate(key, 0, amount, "");
        }

        // Bounded above by `notional`, itself an int128 magnitude, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int128(uint128(amount));
    }
}
