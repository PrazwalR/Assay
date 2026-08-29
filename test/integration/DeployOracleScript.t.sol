// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {DeployOracle} from "../../script/DeployOracle.s.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @dev Regression coverage for the pass-2 M-1 finding: the script itself must derive the
///      decimal scaling from live `decimals()` calls, not merely accept whatever an operator
///      types. `deploy` is exercised directly, the same split `DeployAssay` uses, so this runs
///      without `vm.env*` and without touching the process environment.
contract DeployOracleScriptTest is Test {
    uint256 internal constant MAX_AGE = 3600;

    MockAggregatorV3 internal feed;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregatorV3(int256(1e8), block.timestamp); // 8 decimals, the default
    }

    function _sortedPair(uint8 decimalsA, uint8 decimalsB) internal returns (Currency lower, Currency upper) {
        MockERC20 a = new MockERC20("Token A", "TKA", decimalsA);
        MockERC20 b = new MockERC20("Token B", "TKB", decimalsB);
        (lower, upper) = address(a) < address(b)
            ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
    }

    /// @dev Mirrors the deployed USDC(6)/WETH(18) shape against an 8-decimal feed: 10 ** (18 -
    ///      6 + 8) = 1e20. The script must derive exactly this without being told the value.
    function test_Deploy_DerivesTheNumeratorFromLiveDecimals() public {
        (Currency c0, Currency c1) = _sortedPair(6, 18);
        uint8 dec0 = MockERC20(Currency.unwrap(c0)).decimals();
        uint8 dec1 = MockERC20(Currency.unwrap(c1)).decimals();
        uint256 expected = 10 ** (uint256(dec1) + 8 - uint256(dec0));

        ChainlinkReferenceAdapter adapter =
            new DeployOracle().deploy(IAggregatorV3(address(feed)), MAX_AGE, c0, c1);

        assertEq(adapter.PRICE_NUMERATOR(), expected);
        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertTrue(fresh, "deployed adapter must produce a usable reading immediately");
    }

    /// @dev Equal-decimal pair, so the derived numerator is just the feed's own scale --
    ///      the simplest case, kept separate from the unequal one above so a regression in
    ///      either the addition or the subtraction half of the exponent is caught on its own.
    function test_Deploy_HandlesEqualDecimalPair() public {
        (Currency c0, Currency c1) = _sortedPair(18, 18);
        ChainlinkReferenceAdapter adapter =
            new DeployOracle().deploy(IAggregatorV3(address(feed)), MAX_AGE, c0, c1);
        assertEq(adapter.PRICE_NUMERATOR(), 1e8);
    }

    /// @dev Native ETH has no ERC-20 contract to query; the script must treat it as 18
    ///      decimals rather than reverting on a call to an address with no code. The zero
    ///      address always sorts below a real token address, so native is always currency0
    ///      here -- paired with an 18-decimal currency1 so the exponent stays non-negative.
    function test_Deploy_TreatsNativeCurrencyAsEighteenDecimals() public {
        MockERC20 token = new MockERC20("Token", "TKN", 18);
        Currency native = Currency.wrap(address(0));
        Currency other = Currency.wrap(address(token));
        ChainlinkReferenceAdapter adapter =
            new DeployOracle().deploy(IAggregatorV3(address(feed)), MAX_AGE, native, other);

        uint256 expected = 10 ** (18 + 8 - 18);
        assertEq(adapter.PRICE_NUMERATOR(), expected);
    }
}
