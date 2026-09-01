// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q32x32} from "./Q32x32.sol";

/// @notice Exponentially weighted average of a pool's own tick, sampled once per block.
/// @dev Serves as the trust anchor for a reference-price deviation cap: a reading that
///      disagrees with this by more than a configured bound is treated as unusable, the same
///      as a stale or reverting one. See `AssayHook._advanceStateInPlace` for the caller.
///
///      The anchor has to be something an attacker cannot move cheaply within the same
///      transaction that needs it to look a certain way, which a per-swap or per-transaction
///      price is not.
///      estimator. Sampling the *block-open* tick specifically, not the current one, is what
///      makes this resistant to being moved from inside the very block whose deviation check
///      it feeds: by the time any swap in a new block reads this, the sample already folded
///      in is the tick the pool closed the previous block at, which nothing in the current
///      block can have touched yet.
library PoolTwap {
    /// @dev Seeds the average at a known-good starting tick. Used at pool initialisation,
    ///      when no organic trading history exists yet to build trust from -- an EWMA with no
    ///      history is defined to equal its first observation, not zero, since zero would
    ///      assert a price of `1.0001**0` regardless of where the pool or reference actually
    ///      sit.
    function seed(int24 poolTick) internal pure returns (int64 twapTickX32) {
        // The largest possible tick is TickMath.MAX_TICK (887,272), so the scaled value is
        // at most ~3.81e15 in magnitude -- far inside int64's ~9.22e18 range.
        return int64(poolTick) * int64(Q32x32.ONE);
    }

    /// @dev Folds one block's opening tick into the average.
    function update(int64 twapTickX32, int24 blockOpenTick, uint64 lambdaX32)
        internal
        pure
        returns (int64 updated)
    {
        return Q32x32.blendSigned(twapTickX32, seed(blockOpenTick), lambdaX32);
    }

    /// @dev The stored average, rounded toward zero to the nearest tick.
    ///
    ///      Safe to narrow to `int24`: `blendSigned` returns a convex combination of its two
    ///      inputs (up to a sub-integer truncation nudge, per its own documentation), and
    ///      every value ever folded in by `seed` or `update` originates from a real pool
    ///      tick, which `TickMath` bounds to +/-887,272. By induction, `twapTickX32` can
    ///      therefore never leave that same range scaled by `Q32x32.ONE`, and dividing back
    ///      out returns a value that fits `int24` (max ~8.39e6) with wide margin.
    function tick(int64 twapTickX32) internal pure returns (int24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(twapTickX32 / int64(Q32x32.ONE));
    }

    /// @notice Signed distance from the stored average to `referenceTick`.
    /// @dev Positive when the reference sits above the pool's own smoothed tick. Exposed
    ///      separately from `withinBound` so a caller can report *how far*, not just whether.
    function deviationTicks(int64 twapTickX32, int24 referenceTick) internal pure returns (int256) {
        return int256(referenceTick) - int256(tick(twapTickX32));
    }

    /// @notice Whether `referenceTick` sits within `maxDeviationTicks` of the stored average.
    /// @dev `maxDeviationTicks == 0` is defined as "no cap": every reference passes. That is
    ///      the natural reading of an unset threshold and lets a deployment opt out of this
    ///      check entirely, the same way `captureShareBps == 0` opts out of the surcharge.
    function withinBound(int64 twapTickX32, int24 referenceTick, uint24 maxDeviationTicks)
        internal
        pure
        returns (bool)
    {
        if (maxDeviationTicks == 0) return true;

        int256 gap = deviationTicks(twapTickX32, referenceTick);
        if (gap < 0) gap = -gap;
        return gap <= int256(uint256(maxDeviationTicks));
    }
}
