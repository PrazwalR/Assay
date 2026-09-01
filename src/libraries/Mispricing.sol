// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Signed distance between a pool's price and a reference, in ticks.
/// @dev Ticks rather than a ratio: a tick difference is already a log price difference, so
///      this is one subtraction and a sign -- no division, nothing that can revert.
///
///      The sign is what makes it a per-swap quantity. Two swaps in one block trading
///      opposite directions against the same mispricing get opposite values: the one trading
///      toward the reference captures the drift, the one trading away does not.
library Mispricing {
    /// @dev Largest magnitude a single reading can report. Tick space spans roughly
    ///      +/-887272, so an unclamped difference cannot overflow int24 arithmetic once
    ///      widened to int256; this bound exists to keep one absurd reading from dominating
    ///      a fee quote, not to prevent overflow.
    int256 internal constant MAX_MISPRICING_TICKS = 200_000;

    /// @notice How far the pool sits from the reference, signed by whether this swap moves
    ///         toward the reference or away from it.
    /// @return capturedTicks Positive when the swap trades toward the reference, meaning it
    ///         captures the pool's drift; negative when it trades away from it.
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

        // A zeroForOne swap sells token0 and pushes the pool's tick down, so it moves toward
        // a reference that sits below the pool. The sign convention makes "capturing drift"
        // positive in both directions.
        return zeroForOne ? -gap : gap;
    }
}
