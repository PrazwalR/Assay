// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

/// @notice A source of reference prices for measuring how far a pool has drifted.
/// @dev Implementations MUST NOT revert: this is read from the swap path, where a revert
///      would brick the pool. An unusable reading reports `fresh = false` instead.
interface IReferencePriceOracle {
    /// @notice The current reference price, as a sqrt price comparable with a pool's own.
    /// @return sqrtPriceX96 The reference price, or zero when no usable reading exists.
    function referenceSqrtPriceX96() external view returns (uint160 sqrtPriceX96, bool fresh);

    /// @notice The pool currencies this source prices.
    /// @dev Decimal scaling encodes one pair, so a consumer must refuse any other.
    function pricedCurrencies() external view returns (Currency currency0, Currency currency1);
}
