// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Signed distance between a pool's price and a reference, in ticks.
/// @dev A tick difference is already a log price difference: one subtraction and a sign.
library Mispricing {
    /// @dev Keeps one absurd reading from dominating a quote; not an overflow guard.
    int256 internal constant MAX_MISPRICING_TICKS = 200_000;

    /// @notice How far the pool sits from the reference, signed by the swap's direction.
    /// @return capturedTicks Positive when trading toward the reference, negative away.
    function signedTicks(int24 referenceTick, int24 poolTick, bool zeroForOne)
        internal
        pure
        returns (int256 capturedTicks)
    {
        int256 gap = int256(referenceTick) - int256(poolTick);

        if (gap > MAX_MISPRICING_TICKS) {
            gap = MAX_MISPRICING_TICKS;
        } else if (gap < -MAX_MISPRICING_TICKS) {
            gap = -MAX_MISPRICING_TICKS;
        }

        // zeroForOne sells token0 and pushes the tick down, toward a reference below the
        // pool -- so this makes "capturing drift" positive in both directions.
        return zeroForOne ? -gap : gap;
    }
}
