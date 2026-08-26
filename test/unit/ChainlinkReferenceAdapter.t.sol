// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkReferenceAdapterTest is Test {
    uint256 internal constant MAX_AGE = 3600;
    uint256 internal constant NUMERATOR = 1e8;

    Currency internal constant C0 = Currency.wrap(address(1));
    Currency internal constant C1 = Currency.wrap(address(2));

    MockAggregatorV3 internal feed;
    ChainlinkReferenceAdapter internal adapter;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregatorV3(int256(1e8), block.timestamp);
        adapter = new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C0, C1);
    }

    function test_Constructor_RejectsZeroFeed() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__FeedIsZeroAddress.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(0)), MAX_AGE, NUMERATOR, C0, C1);
    }

    function test_Constructor_RejectsZeroMaxAge() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__MaxAgeIsZero.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), 0, NUMERATOR, C0, C1);
    }

    function test_Constructor_RejectsZeroNumerator() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__PriceNumeratorIsZero.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, 0, C0, C1);
    }

    /// @dev v4 pool keys always carry currency0 < currency1, so an adapter supplied with
    ///      them backwards could never match any pool. Failing at construction surfaces that
    ///      immediately rather than as a pool that mysteriously refuses to initialise.
    function test_Constructor_RejectsCurrenciesOutOfOrder() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__CurrenciesOutOfOrder.selector,
                address(2),
                address(1)
            )
        );
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C1, C0);
    }

    function test_Constructor_RejectsIdenticalCurrencies() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__CurrenciesOutOfOrder.selector,
                address(1),
                address(1)
            )
        );
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C0, C0);
    }

    function test_PricedCurrencies_ReportsTheConfiguredPair() public view {
        (Currency c0, Currency c1) = adapter.pricedCurrencies();
        assertEq(Currency.unwrap(c0), Currency.unwrap(C0));
        assertEq(Currency.unwrap(c1), Currency.unwrap(C1));
    }

    /// @dev A price of 1.0 between two equal-decimal tokens is tick 0, which anchors the
    ///      whole decimal-scaling argument. If this drifts, every mispricing reading is wrong
    ///      by a constant offset and nothing else in the suite would notice.
    function test_UnitPrice_MapsToTickZero() public view {
        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        assertTrue(fresh);
        assertEq(TickMath.getTickAtSqrtPrice(sqrtPriceX96), 0, "price 1.0 must be tick 0");
    }

    function test_HigherPrice_MapsToLowerTick() public {
        (uint160 atOne,) = adapter.referenceSqrtPriceX96();
        feed.setAnswer(int256(2e8));
        (uint160 atTwo,) = adapter.referenceSqrtPriceX96();
        assertLt(atTwo, atOne, "doubling the quoted price must lower the sqrt price");
    }

    function test_AgeExactlyAtBoundIsStillFresh() public {
        feed.setUpdatedAt(block.timestamp - MAX_AGE);
        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertTrue(fresh, "a reading exactly at the bound is still usable");
    }

    function test_AgeOnePastBoundIsStale() public {
        feed.setUpdatedAt(block.timestamp - MAX_AGE - 1);
        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertFalse(fresh, "one second past the bound must be unusable");
    }

    function test_RevertingFeedReportsUnusable() public {
        feed.setShouldRevert(true);
        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        assertFalse(fresh);
        assertEq(sqrtPriceX96, 0);
    }

    function test_UnsetRoundReportsUnusable() public {
        feed.setUpdatedAt(0);
        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertFalse(fresh, "a round that never updated is not a price");
    }

    /// @dev Total over the whole domain: this is called from the swap path.
    function testFuzz_NeverReverts(int256 answer, uint256 updatedAt, bool feedReverts) public {
        feed.setAnswer(answer);
        feed.setUpdatedAt(bound(updatedAt, 0, type(uint64).max));
        feed.setShouldRevert(feedReverts);

        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        if (fresh) {
            assertGe(sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
            assertLt(sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        } else {
            assertEq(sqrtPriceX96, 0, "an unusable reading must not carry a price");
        }
    }
}
