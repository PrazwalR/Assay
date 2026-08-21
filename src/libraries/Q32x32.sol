// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {IAssayErrors} from "../interfaces/IAssayErrors.sol";

/// @notice Q32.32 fixed-point arithmetic: a real number `r` is stored as `r * 2**32`.
/// @dev Q64.64 is the conventional choice but needs 128 bits, which does not fit the packed
///      pool state. Q32.32 covers integer magnitudes to 4.29e9 with a resolution of 2.3e-10,
///      which is ample for both quantities stored here and leaves the state in one slot.
library Q32x32 {
    /// @dev 1.0 in Q32.32.
    uint64 internal constant ONE = 1 << 32;

    /// @dev Upper bound on any variance value. Enforced by the tick-delta clamp rather than
    ///      checked at runtime: see VarianceEwma for the argument that it cannot be exceeded.
    uint64 internal constant MAX_VARIANCE = uint64(1) << 62;

    /// @dev Blends two Q32.32 values by weight `lambda`, which MUST be in [0, ONE]. Above
    ///      ONE the `ONE - lambda` subtraction wraps and every bound below collapses; config
    ///      validation is what upholds this, since checking on the swap path costs gas on
    ///      every swap to guard a constructor-set immutable.
    ///      Returns `lambda*previous + (ONE-lambda)*sample`, a convex combination, so the
    ///      result never exceeds the larger input. That is what bounds the EWMA.
    function blend(uint64 previous, uint64 sample, uint64 lambda) internal pure returns (uint64) {
        unchecked {
            // lambda <= ONE = 2**32 and both inputs are bounded by 2**62 (MAX_VARIANCE), so
            // each product is at most 2**94 and the sum at most 2**95 -- far inside uint256.
            uint256 weighted = uint256(lambda) * previous + uint256(ONE - lambda) * sample;
            // weighted >> 32 is a convex combination of two uint64 values, so it lies
            // between them and cannot exceed type(uint64).max for any input.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint64(weighted >> 32);
        }
    }

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

    /// @dev Converts an integer to Q32.32, reverting rather than truncating on overflow.
    function fromUint(uint256 value) internal pure returns (uint64) {
        if (value > type(uint32).max) revert IAssayErrors.AssayHook__FixedPointOverflow(value);
        unchecked {
            // The guard above has established value <= type(uint32).max, so the cast is
            // lossless and the shift stays inside uint64.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint64(value) << 32;
        }
    }

    /// @dev Divides two same-signed-scale integers into a Q32.32 ratio, saturating at `ONE`.
    ///      Saturation rather than revert because this runs on the swap path, where a revert
    ///      would brick the pool; a ratio above one only means the order exceeded measured
    ///      depth, and clamping it loses no information the fee curve can act on.
    function ratio(uint256 numerator, uint256 denominator) internal pure returns (uint64) {
        if (denominator == 0) return 0;
        // Saturate before any shift. Solidity never overflow-checks shifts, so
        // `(numerator << 32) / denominator` silently discards the top bits for
        // numerator >= 2**224 -- and because the discarded bits are the high ones it fails
        // *downward*, under-reporting toxicity, which is the LP-adverse direction.
        if (numerator >= denominator) return ONE;
        // numerator < denominator makes the quotient strictly less than ONE = 2**32, so the
        // cast is exact; mulDiv carries a 512-bit intermediate over the full domain.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(FullMath.mulDiv(numerator, ONE, denominator));
    }
}
