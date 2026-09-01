// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Q32.32 fixed-point arithmetic: a real number `r` is stored as `r * 2**32`.
/// @dev Q64.64 is the conventional choice but needs 128 bits, which does not fit the packed
///      pool state. Q32.32 covers integer magnitudes to 4.29e9 with a resolution of 2.3e-10,
///      which is ample for both quantities stored here and leaves the state in one slot.
library Q32x32 {
    /// @dev 1.0 in Q32.32.
    uint64 internal constant ONE = 1 << 32;

    /// @dev Signed counterpart of `blend`. Inputs are bounded by +/-ONE by the caller, so the
    ///      intermediate cannot exceed 2**65 in magnitude.
    function blendSigned(int64 previous, int64 sample, uint64 lambda) internal pure returns (int64) {
        unchecked {
            int256 weighted = int256(uint256(lambda)) * previous + int256(uint256(ONE - lambda)) * sample;
            // Division, not an arithmetic shift. `>> 32` floors toward negative infinity,
            // which makes a sell's contribution one unit larger in magnitude than an equal
            // buy's and biases the imbalance estimate downward over time. Signed division
            // truncates toward zero, so equal and opposite flow cancels exactly.
            // Convexity still holds: truncating toward zero moves the result no further than
            // the nearest integer, and both bounds are themselves integers.
            // forge-lint: disable-next-line(unsafe-typecast)
            return int64(weighted / int256(uint256(ONE)));
        }
    }
}
