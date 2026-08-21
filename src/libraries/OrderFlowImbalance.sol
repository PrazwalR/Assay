// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {Q32x32} from "./Q32x32.sol";

/// @notice Exponentially weighted signed order-flow imbalance.
/// @dev A streaming approximation of VPIN. The microstructure result it encodes is that
///      informed flow is persistent and one-directional, while uninformed flow is roughly
///      balanced, so a sustained imbalance is evidence of information.
///
///      Each swap contributes its size as a fraction of active depth, signed by direction.
///      Normalising by depth rather than by a constant is what makes the measure comparable
///      across pools and across liquidity regimes, and it is the same quantity Kyle's model
///      identifies as the one informed traders scale with.
library OrderFlowImbalance {
    /// @dev The Q96 scale v4 stores square-root prices in.
    uint256 private constant Q96 = 1 << 96;

    /// @dev Active token1 depth, from the v3/v4 identity `L * sqrtP = virtual token1 reserve`.
    /// @dev `uint128 * uint160` reaches 288 bits and would revert a plain multiplication in
    ///      checked arithmetic -- on the swap path, bricking the pool. `FullMath.mulDiv`
    ///      carries a 512-bit intermediate, so the full domain is safe: the worst case
    ///      `mulDiv(2**128-1, MAX_SQRT_PRICE, 2**96)` is about 2**192, leaving 2**64 of
    ///      headroom in the uint256 result.
    function virtualReserve(uint128 liquidity, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(uint256(liquidity), uint256(sqrtPriceX96), Q96);
    }

    /// @dev Folds one swap into the estimate.
    /// @param ofiEwmaX32 Previous imbalance, Q32.32 in [-1, 1].
    /// @param signedAmount Swapper-perspective token1 delta; positive means token1 was bought.
    /// @param depth Active token1 depth, from `virtualReserve` above.
    /// @return updated The new imbalance, Q32.32, bounded to [-1, 1] by construction.
    function update(int64 ofiEwmaX32, int256 signedAmount, uint256 depth, uint64 lambdaX32)
        internal
        pure
        returns (int64 updated)
    {
        // Two's-complement negation rather than unary minus: -x overflows for
        // type(int256).min, whereas ~x + 1 yields the correct magnitude across the whole
        // domain. Reachable inputs are int128-bounded today, but the signature is not.
        uint256 magnitude;
        unchecked {
            // Both branches reinterpret the full 256-bit word; neither truncates.
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = signedAmount < 0 ? uint256(~signedAmount) + 1 : uint256(signedAmount);
        }
        uint64 fraction = Q32x32.ratio(magnitude, depth);

        // Q32x32.ratio saturates at ONE = 2**32, well inside int64, so both the cast and
        // the negation are exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 sample = signedAmount < 0 ? -int64(fraction) : int64(fraction);
        updated = Q32x32.blendSigned(ofiEwmaX32, sample, lambdaX32);
    }
}
