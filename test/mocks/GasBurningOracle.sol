// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

import {IReferencePriceOracle} from "../../src/interfaces/IReferencePriceOracle.sol";

/// @notice An oracle that consumes everything it is given and then reverts.
/// @dev Stands in for a compromised feed proxy. Reverting alone is already covered by
///      `MockReferenceOracle`; what this adds is the cost of getting there, which is the
///      part `try/catch` does not bound and a gas stipend does.
contract GasBurningOracle is IReferencePriceOracle {
    Currency private immutable CURRENCY0;
    Currency private immutable CURRENCY1;

    constructor(Currency currency0, Currency currency1) {
        CURRENCY0 = currency0;
        CURRENCY1 = currency1;
    }

    function pricedCurrencies() external view returns (Currency, Currency) {
        return (CURRENCY0, CURRENCY1);
    }

    function referenceSqrtPriceX96() external view returns (uint160, bool) {
        uint256 burned;
        while (gasleft() > 2000) {
            burned++;
        }
        revert("burned");
    }
}
