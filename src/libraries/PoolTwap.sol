// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q32x32} from "./Q32x32.sol";

/// @notice Exponentially weighted average of a pool's own tick, sampled once per block.
/// @dev The trust anchor for the deviation cap. Sampling the *block-open* tick, not the
///      current one, is what makes it resistant to manipulation from inside the same block:
///      the folded sample is where the pool closed the previous block.
library PoolTwap {
    /// @dev Seeds at the first observation; zero would assert a price of `1.0001**0`.
    function seed(int24 poolTick) internal pure returns (int64 twapTickX32) {
        // MAX_TICK is 887,272, so the scaled value is ~3.81e15 -- far inside int64.
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

    /// @dev Safe to narrow: `blendSigned` is convex and every folded value is a real tick,
    ///      so by induction this stays inside +/-887,272.
    function tick(int64 twapTickX32) internal pure returns (int24) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(twapTickX32 / int64(Q32x32.ONE));
    }

    /// @notice Signed distance from the stored average to `referenceTick`.
    /// @dev Separate from `withinBound` so a caller can report *how far*, not just whether.
    function deviationTicks(int64 twapTickX32, int24 referenceTick) internal pure returns (int256) {
        return int256(referenceTick) - int256(tick(twapTickX32));
    }

    /// @notice Whether `referenceTick` sits within `maxDeviationTicks` of the stored average.
    /// @dev `maxDeviationTicks == 0` means "no cap", letting a deployment opt out entirely.
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
