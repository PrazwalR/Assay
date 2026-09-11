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
/// @dev Every formula lives in a pure library, so the math is fuzzable without a PoolManager.
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

    /// @dev Stops an oracle burning gas instead of reverting from taking 63/64 of the
    ///      swapper's. An honest read is ~21,000.
    uint256 private constant ORACLE_READ_GAS_LIMIT = 150_000;

    /// @dev Seconds per block above which the chain is treated as halted rather than quiet.
    ///      Far above any real cadence (Base is ~2s) so it cannot misfire on jitter.
    uint256 private constant MAX_SECONDS_PER_BLOCK = 30;

    /// @dev Absolute slack on the halt test, so a single late block is never a halt.
    uint256 private constant HALT_GRACE_SECONDS = 90;

    /// @dev A halt freezes the pool tick and the feed's `updatedAt` together, so on resumption
    ///      they agree with each other while both disagree with the world.
    uint256 private constant POST_HALT_DISTRUST_SECONDS = 180;

    mapping(PoolId poolId => PoolState) private _poolState;

    /// @notice Deploys the hook against a PoolManager with validated parameters.
    /// @dev The address must carry the bits `getHookPermissions` returns, so deployment
    ///      requires a mined CREATE2 salt.
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
    /// @dev `afterSwapReturnDelta` carries the surcharge -- the only path touching swapper
    ///      funds. No liquidity permissions, so an LP can always withdraw.
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
    /// @dev Covers only the percentage fee; see `surchargeBounds` for the donate surcharge.
    function feeBounds() external view returns (uint24 baseFeePips, uint24 minFeePips, uint24 maxFeePips) {
        return (BASE_FEE_PIPS, MIN_FEE_PIPS, MAX_FEE_PIPS);
    }

    /// @notice The most this hook can take from a swap beyond the quoted LP fee.
    /// @dev An integrator sizing slippage from `feeBounds` alone misses this.
    /// @return maxSurchargePips Ceiling on the surcharge, as a share of notional.
    function surchargeBounds() external view returns (uint24 maxSurchargePips, uint24 maxTotalPips) {
        return (FeeBlend.MAX_OVERFLOW_PIPS, MAX_FEE_PIPS + FeeBlend.MAX_OVERFLOW_PIPS);
    }

    /// @notice Current microstructure state for a pool.
    function poolState(PoolId poolId) external view returns (PoolState memory state) {
        return _poolState[poolId];
    }

    /// @notice How far a pool sits from its reference price, signed for a given direction.
    /// @dev Check `fresh` first: stale means no view of the drift, not that it is zero.
    /// @return capturedTicks Positive when such a swap would trade toward the reference.
    function signedMispricing(PoolId poolId, bool zeroForOne)
        external
        view
        returns (int256 capturedTicks, bool fresh)
    {
        PoolState memory state = _poolState[poolId];
        return (Mispricing.signedTicks(state.referenceTick, state.lastTick, zeroForOne), state.referenceFresh);
    }

    /// @notice The pool's smoothed tick anchor and how far the cached reference sits from it.
    /// @dev Exposes the deviation-cap inputs, so an operator can see *why* one was rejected.
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

    /// @dev In one place so the returned quote and the one in `SwapAssayed` cannot diverge.
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

    /// @dev `responded` separates "answered unusably" from "the call failed": only the first
    ///      settles the block, or a caller metering gas could retire the refresh silently.
    function _readReference() private view returns (int24 referenceTick, bool fresh, bool responded) {
        try REFERENCE_ORACLE.referenceSqrtPriceX96{gas: ORACLE_READ_GAS_LIMIT}() returns (
            uint160 sqrtPriceX96, bool ok
        ) {
            if (!ok || sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
                return (0, false, true);
            }
            return (TickMath.getTickAtSqrtPrice(sqrtPriceX96), true, true);
        } catch {
            return (0, false, false);
        }
    }

    /// @dev v4 hooks are permissionless, so a pool of different assets would otherwise be
    ///      quoted against a price for something else and reported fresh. Safe to revert in:
    ///      it runs before any liquidity exists.
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

    /// @dev The TWAP anchor takes the same tick as `referenceTick`. Seeding from zero would
    ///      trip the deviation cap in the first block against a correct reference.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        (int24 referenceTick, bool referenceFresh,) = _readReference();
        int24 seedTick = referenceFresh ? referenceTick : tick;
        _poolState[poolId] = PoolState({
            lastTick: tick,
            referenceTick: seedTick,
            lastBlock: uint32(block.number),
            referenceFresh: referenceFresh,
            twapTickX32: PoolTwap.seed(seedTick),
            lastRefreshAt: uint32(block.timestamp),
            referenceDistrustedUntil: 0,
            lastSampleBlock: uint32(block.number)
        });

        emit PoolRegistered(poolId, BASE_FEE_PIPS);
        poolManager.updateDynamicLPFee(key, BASE_FEE_PIPS);
        return this.afterInitialize.selector;
    }

    /// @dev The refresh must happen here, not in `afterSwap`: a reference adopted after the
    ///      quote is one the quote could not see, so the swap capturing a dislocation would be
    ///      priced against the stale tick it is about to trade away from. Returns no delta --
    ///      the hook never takes custody of swap principal.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState memory state = _poolState[poolId];
        _advanceReferenceInPlace(poolId, state);
        _poolState[poolId] = state;

        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            _quote(state, params.zeroForOne) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Folds this swap into the pool's state. Everything here advances on every swap.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolState memory state = _poolState[poolId];

        // The exact drift `beforeSwap` quoted against: it wrote the reference back, and
        // `lastTick` is untouched until below.
        int256 quotedDrift = Mispricing.signedTicks(state.referenceTick, state.lastTick, params.zeroForOne);
        bool quotedFresh = state.referenceFresh;

        _recordTickInPlace(poolId, state);
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

    /// @dev `state` is a memory reference, so the assignment is visible to the caller.
    function _recordTickInPlace(PoolId poolId, PoolState memory state) private view {
        // slither-disable-next-line unused-return
        (, int24 tickNow,,) = poolManager.getSlot0(poolId);
        state.lastTick = tickNow;
    }

    /// @dev MUTATES `state` in place so the quote that follows sees it. Its own frame, so
    ///      locals do not compete for stack slots.
    function _advanceReferenceInPlace(PoolId poolId, PoolState memory state) private {
        // Its own tracker, so it fires once per block and never retries: `lastTick` holds the
        // previous block's close only on the first pass. Sharing the oracle's let a
        // manipulated same-block tick walk this anchor.
        if (state.lastSampleBlock != uint32(block.number)) {
            state.lastSampleBlock = uint32(block.number);
            state.twapTickX32 = PoolTwap.update(state.twapTickX32, state.lastTick, TWAP_LAMBDA_X32);
        }

        // Once per block, not per swap: a live Chainlink read is ~20,000 gas, so the first
        // swap of each block pays it in full and is the hook's most expensive path.
        if (state.lastBlock != uint32(block.number)) {
            // Many seconds across few blocks means the chain stopped, not that the pool was
            // quiet -- an untraded hour still advances ~1,800 Base blocks.
            uint32 nowTruncated = uint32(block.timestamp);
            uint256 secondsElapsed = uint256(nowTruncated - state.lastRefreshAt);
            uint256 blocksElapsed = uint256(uint32(block.number) - state.lastBlock);
            if (
                state.lastRefreshAt != 0
                    && secondsElapsed > blocksElapsed * MAX_SECONDS_PER_BLOCK + HALT_GRACE_SECONDS
            ) {
                // Meant to wrap with `nowTruncated`, which is how comparisons survive the epoch.
                // forge-lint: disable-next-line(unsafe-typecast)
                state.referenceDistrustedUntil = nowTruncated + uint32(POST_HALT_DISTRUST_SECONDS);
                emit ChainHaltDetected(poolId, secondsElapsed, blocksElapsed, state.referenceDistrustedUntil);
            }

            (int24 referenceTick, bool referenceFresh, bool responded) = _readReference();

            // Retired only once the oracle answered, so a failed call leaves the refresh owed.
            // Otherwise one dust swap per block could pin the pool at the ceiling.
            if (responded) {
                state.lastBlock = uint32(block.number);
                state.lastRefreshAt = nowTruncated;
            }

            // Inside the post-halt window the reading may predate the halt.
            if (referenceFresh && nowTruncated < state.referenceDistrustedUntil) {
                referenceFresh = false;
            }

            // The only defence against a compromised feed.
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
    }

    /// @dev `donate` debits this contract in the transient ledger; returning the same amount
    ///      as a positive `int128` credits it back. The two cancel exactly, so the hook never
    ///      holds a balance -- the swapper's settlement is what funds the donation. Zero on
    ///      nearly every swap; only an extreme dislocation reaches the ceiling.
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
        // The common case, short-circuiting before any external call.
        // slither-disable-next-line incorrect-equality
        if (overflowPips == 0) return 0;

        // `donate` reverts with no in-range liquidity, and reverting in `afterSwap` would
        // brick the pool. Skipping the surcharge is the only safe response.
        if (poolManager.getLiquidity(poolId) == 0) return 0;

        (bool currency0IsUnspecified, uint256 notional) = ToxicitySurcharge.unspecifiedAmount(params, delta);

        // `notional` is an int128 magnitude and `overflowPips` is bounded, so this fits.
        uint256 amount = ToxicitySurcharge.surchargeAmount(notional, overflowPips);
        // Rounds up, so zero means the unspecified side was itself zero.
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;

        emit ToxicitySurchargeDonated(poolId, amount, currency0IsUnspecified);

        // Emitted before the call: if `donate` reverts so does the transaction. The returned
        // delta is discarded -- it is `-amount`, already known here.
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
