// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Q32.32 fixed-point arithmetic: a real number `r` is stored as `r * 2**32`.
/// @dev Q64.64 needs 128 bits and would not fit the packed pool state; Q32.32 does.
library Q32x32 {
    /// @dev 1.0 in Q32.32.
    uint64 internal constant ONE = 1 << 32;

    /// @dev Inputs are bounded by +/-ONE by the caller, so the intermediate cannot exceed 2**65.
    function blendSigned(int64 previous, int64 sample, uint64 lambda) internal pure returns (int64) {
        unchecked {
            int256 weighted = int256(uint256(lambda)) * previous + int256(uint256(ONE - lambda)) * sample;
            // A convex combination of two int64s divided by ONE stays inside int64.
            // forge-lint: disable-next-line(unsafe-typecast)
            return int64(weighted / int256(uint256(ONE)));
        }
    }
}
