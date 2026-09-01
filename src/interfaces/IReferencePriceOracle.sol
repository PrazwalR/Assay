// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

/// @notice A source of reference prices for measuring how far a pool has drifted.
/// @dev Implementations MUST NOT revert. This is read from the swap path, where a revert
///      would brick the pool for every liquidity provider. A source that cannot produce a
///      usable reading reports `fresh = false` and the hook degrades its quote accordingly.
interface IReferencePriceOracle {
    /// @notice The current reference price, expressed the way v4 expresses prices.
    /// @dev Returned as a square-root price so it is directly comparable with a pool's
    ///      `sqrtPriceX96` without any conversion at the call site.
    /// @return sqrtPriceX96 The reference price, or zero when no usable reading exists.
    function referenceSqrtPriceX96() external view returns (uint160 sqrtPriceX96, bool fresh);

    /// @notice The pool currencies this source prices.
    /// @dev A reference price is only meaningful for the pair it describes. The decimal
    ///      scaling an implementation applies encodes one specific pair, so a source must
    ///      state which, and a consumer must refuse pools that do not match. Without this a
    ///      hook prices whatever pool attaches to it against a reference for different
    ///      assets, and reports the reading as fresh while doing so.
    function pricedCurrencies() external view returns (Currency currency0, Currency currency1);
}
