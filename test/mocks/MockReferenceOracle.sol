// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

import {IReferencePriceOracle} from "../../src/interfaces/IReferencePriceOracle.sol";

/// @notice Test double for a hostile or malfunctioning reference source.
/// @dev Test infrastructure only; never imported by src/ or by a deployment script.
///      `ChainlinkReferenceAdapter` is well behaved by construction, so the hook's own
///      defences against a source that reverts or returns nonsense cannot be reached
///      through it. A third-party oracle is under no obligation to honour the interface,
///      which is exactly why those defences exist and must be exercised.
contract MockReferenceOracle is IReferencePriceOracle {
    uint160 private _sqrtPriceX96;
    bool private _fresh;
    bool private _shouldRevert;
    Currency private _currency0;
    Currency private _currency1;

    constructor(uint160 sqrtPriceX96, bool fresh, Currency currency0, Currency currency1) {
        _sqrtPriceX96 = sqrtPriceX96;
        _fresh = fresh;
        _currency0 = currency0;
        _currency1 = currency1;
    }

    function pricedCurrencies() external view returns (Currency, Currency) {
        return (_currency0, _currency1);
    }

    function set(uint160 sqrtPriceX96, bool fresh) external {
        _sqrtPriceX96 = sqrtPriceX96;
        _fresh = fresh;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function referenceSqrtPriceX96() external view returns (uint160, bool) {
        require(!_shouldRevert, "MockReferenceOracle: forced revert");
        return (_sqrtPriceX96, _fresh);
    }
}
