// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q32x32} from "./Q32x32.sol";

/// @notice Exponentially weighted realised variance, estimated from tick movement.
/// @dev Two properties of this estimator are security-critical rather than statistical.
///
///      It is sampled once per *block*, never per swap. Sampling per swap lets an attacker
///      move the price up and down inside one block, inflate the variance estimate, and so
///      choose their own fee. Sampling at block boundaries means the only observable is the
///      block's net move, which costs real money to produce and is the quantity the theory
///      is about.
///
///      The tick delta is clamped. Without it a single flash-loan-driven move would poison
///      the estimate for the whole decay window.
library VarianceEwma {
    /// @dev Largest permitted clamp. `delta^2 << 32` must stay inside uint64: with
    ///      |delta| <= 2**15, delta^2 <= 2**30 and the shifted sample is at most 2**62,
    ///      leaving two bits of headroom. Config validation rejects anything larger, so the
    ///      update below cannot overflow for any reachable input.
    int24 internal constant MAX_TICK_DELTA_CLAMP = 32_768;

    /// @dev Folds one block's realised move into the estimate.
    /// @return updated The new variance in Q32.32, in squared ticks.
    /// @return clamped Whether the observed move exceeded `maxTickDelta`.
    function update(uint64 varEwmaX32, int24 tickNow, int24 tickLast, int24 maxTickDelta, uint64 lambdaX32)
        internal
        pure
        returns (uint64 updated, bool clamped)
    {
        // The library enforces its own ceiling rather than trusting the caller's bound.
        // Config validation already rejects a larger clamp, but the failure mode if it were
        // bypassed is silent: `uint64(squared)` truncates and `<< 32` is never
        // overflow-checked, so an out-of-range clamp yields a *smaller* variance for a
        // larger move, quietly inverting monotonicity.
        int24 bound = maxTickDelta > MAX_TICK_DELTA_CLAMP ? MAX_TICK_DELTA_CLAMP : maxTickDelta;
        int256 delta = int256(tickNow) - int256(tickLast);

        if (delta > bound) {
            delta = bound;
            clamped = true;
        } else if (delta < -int256(bound)) {
            delta = -int256(bound);
            clamped = true;
        }

        unchecked {
            // |delta| <= maxTickDelta <= MAX_TICK_DELTA_CLAMP = 2**15, so the square is at
            // most 2**30 and the shift below cannot exceed 2**62.
            // A square is non-negative, so the cast is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 squared = uint256(delta * delta);
            // squared <= MAX_TICK_DELTA_CLAMP^2 = 2**30, so the cast is lossless and the
            // shifted sample is at most 2**62.
            // forge-lint: disable-next-line(unsafe-typecast)
            updated = Q32x32.blend(varEwmaX32, uint64(squared) << 32, lambdaX32);
        }
    }
}
