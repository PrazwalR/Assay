// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {FeeBlend} from "./FeeBlend.sol";

/// @notice Turns a fee-cap overflow into an amount in the swap's unspecified currency.
/// @dev Recovers what `FeeBlend.quote` discards at its cap, the way v4 computes its LP fee.
library ToxicitySurcharge {
    /// @dev The unspecified currency is the side `amountSpecified` does not name.
    /// @return currency0IsUnspecified Whether currency0 is the unspecified side.
    /// @return magnitude The unspecified side's notional, always non-negative.
    function unspecifiedAmount(SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (bool currency0IsUnspecified, uint256 magnitude)
    {
        bool specifiedIsToken0 = (params.amountSpecified < 0 == params.zeroForOne);
        int128 raw = specifiedIsToken0 ? delta.amount1() : delta.amount0();

        unchecked {
            // Two's-complement negation: `-raw` overflows on type(int128).min, and this runs
            // on the swap path. Both branches reinterpret the full word.
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = raw < 0 ? uint256(uint128(~raw)) + 1 : uint256(uint128(raw));
        }
        return (!specifiedIsToken0, magnitude);
    }

    /// @notice The surcharge amount to donate, in the unspecified currency.
    /// @dev Bounded to 2% of notional, which keeps the int128 cast at the call site exact.
    ///      Rounds up: a fee that rounds down leaks value on every swap.
    function surchargeAmount(uint256 notional, uint24 overflowPips) internal pure returns (uint256 amount) {
        return FullMath.mulDivRoundingUp(notional, overflowPips, FeeBlend.PIPS_DENOMINATOR);
    }
}
