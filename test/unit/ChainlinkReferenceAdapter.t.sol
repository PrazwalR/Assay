// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkReferenceAdapterTest is Test {
    uint256 internal constant MAX_AGE = 3600;
    // 10 ** (0 - 0 + 8): equal-decimal currencies against the mock's default 8-decimal feed.
    uint256 internal constant NUMERATOR = 1e8;

    Currency internal constant C0 = Currency.wrap(address(1));
    Currency internal constant C1 = Currency.wrap(address(2));

    MockAggregatorV3 internal feed;
    ChainlinkReferenceAdapter internal adapter;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new MockAggregatorV3(int256(1e8), block.timestamp);
        adapter =
            new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C0, 0, C1, 0);
    }

    function test_Constructor_RejectsZeroFeed() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__FeedIsZeroAddress.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(0)), MAX_AGE, NUMERATOR, C0, 0, C1, 0);
    }

    function test_Constructor_RejectsZeroMaxAge() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__MaxAgeIsZero.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), 0, NUMERATOR, C0, 0, C1, 0);
    }

    function test_Constructor_RejectsZeroNumerator() public {
        vm.expectRevert(ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__PriceNumeratorIsZero.selector);
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, 0, C0, 0, C1, 0);
    }

    /// @dev Regression test for the pass-2 M-1 finding. The deployed numerator (1e20) is
    ///      correct only for an 8-decimal feed; the same numerator against a feed that
    ///      reports 18 decimals used to deploy without complaint and decode a reference price
    ///      ten orders of magnitude too high. Mirrors the finding's own proof-of-concept table.
    function test_Constructor_RejectsNumeratorComputedForADifferentFeedDecimals() public {
        feed.setDecimals(18);
        uint256 wrongNumerator = 1e20; // correct for an 8-decimal feed, not this 18-decimal one
        uint256 expected = 10 ** (18 + 18 - 6); // currency1=18dec, feed=18dec, currency0=6dec
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__PriceNumeratorMismatch.selector,
                wrongNumerator,
                expected
            )
        );
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, wrongNumerator, C0, 6, C1, 18);
    }

    /// @dev The other direction of the same finding: a feed reporting fewer decimals than
    ///      the numerator assumed. Same wrong numerator, same currency pair, different feed.
    function test_Constructor_RejectsNumeratorComputedForADifferentFeedDecimals_LowerCase() public {
        feed.setDecimals(6);
        uint256 wrongNumerator = 1e20; // correct for an 8-decimal feed, not this 6-decimal one
        uint256 expected = 10 ** (18 + 6 - 6); // currency1=18dec, feed=6dec, currency0=6dec
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__PriceNumeratorMismatch.selector,
                wrongNumerator,
                expected
            )
        );
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, wrongNumerator, C0, 6, C1, 18);
    }

    /// @dev The positive case: a numerator correctly derived from real, unequal decimals (a
    ///      6-decimal currency0, an 18-decimal currency1, an 8-decimal feed -- the same shape
    ///      as the deployed USDC/WETH configuration) is accepted, not just rejected when wrong.
    function test_Constructor_AcceptsNumeratorCorrectlyDerivedFromUnequalDecimals() public {
        // feed.decimals() defaults to 8.
        uint256 correctNumerator = 10 ** (18 + 8 - 6);
        ChainlinkReferenceAdapter deployed = new ChainlinkReferenceAdapter(
            IAggregatorV3(address(feed)), MAX_AGE, correctNumerator, C0, 6, C1, 18
        );
        assertEq(deployed.PRICE_NUMERATOR(), correctNumerator);
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
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C1, 0, C0, 0);
    }

    function test_Constructor_RejectsIdenticalCurrencies() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ChainlinkReferenceAdapter.ChainlinkReferenceAdapter__CurrenciesOutOfOrder.selector,
                address(1),
                address(1)
            )
        );
        new ChainlinkReferenceAdapter(IAggregatorV3(address(feed)), MAX_AGE, NUMERATOR, C0, 0, C0, 0);
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

    /// @dev Regression test for the pass-2 L-2 finding. `startedAt == 0` is now checked
    ///      independently of `updatedAt`, which stays nonzero here -- a shape `updatedAt ==
    ///      0` alone cannot exercise.
    function test_RoundThatNeverStartedReportsUnusable() public {
        feed.setStartedAt(0);
        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertFalse(fresh, "a round that never started is not a price");
    }

    /// @dev Total over the whole domain: this is called from the swap path.
    function testFuzz_NeverReverts(int256 answer, uint256 startedAt, uint256 updatedAt, bool feedReverts)
        public
    {
        feed.setAnswer(answer);
        feed.setStartedAt(bound(startedAt, 0, type(uint64).max));
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
