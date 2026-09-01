// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IReferencePriceOracle} from "../interfaces/IReferencePriceOracle.sol";

/// @notice Minimal view of a Chainlink aggregator.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkReferenceAdapter
/// @notice Presents a Chainlink price feed as a v4 square-root price.
/// @dev Every failure mode is reported as `fresh = false` rather than raised. This is read
///      from `afterSwap`, so a revert here would revert the swap, and a feed outage must not
///      be able to halt a pool. The caller decides what an unusable reading means for its
///      quote; this contract's only job is to never be the reason a swap fails.
contract ChainlinkReferenceAdapter is IReferencePriceOracle {
    /// @dev Scales a feed answer into the pool's raw price ratio. For a pool of
    ///      token0/token1 and a feed quoting token0 per token1 with `feedDecimals`, this is
    ///      10 ** (token1Decimals - token0Decimals + feedDecimals). Computed and validated
    ///      off chain at deployment, so no exponentiation happens at read time.
    uint256 public immutable PRICE_NUMERATOR;

    /// @dev Largest answer `_toSqrtPriceX96` cannot divide by: `FullMath.mulDiv` requires the
    ///      denominator to exceed the product's high 256 bits, which for `PRICE_NUMERATOR <<
    ///      192` is `PRICE_NUMERATOR >> 64`. Screened here so the never-reverts contract holds
    ///      in this contract, not merely because the caller wraps it. Chainlink's own
    ///      `minAnswer` sentinel of 1 sits inside this range at the deployed scaling.
    uint256 public immutable MIN_DIVISIBLE_ANSWER;

    /// @dev A feed that burns gas rather than reverting would otherwise take 63/64 of the
    ///      swapper's gas and leave too little to finish the swap. Honest call is ~21,000.
    uint256 internal constant FEED_GAS_LIMIT = 100_000;

    IAggregatorV3 public immutable FEED;
    uint256 public immutable MAX_AGE_SECONDS;

    /// @dev The pair `PRICE_NUMERATOR` was computed for. Declared here rather than left
    ///      implicit so a consumer can refuse pools this adapter cannot describe.
    Currency public immutable PRICED_CURRENCY0;
    Currency public immutable PRICED_CURRENCY1;

    error ChainlinkReferenceAdapter__FeedIsZeroAddress();
    error ChainlinkReferenceAdapter__MaxAgeIsZero();
    error ChainlinkReferenceAdapter__PriceNumeratorIsZero();
    error ChainlinkReferenceAdapter__CurrenciesOutOfOrder(address currency0, address currency1);

    /// @dev `provided` is the caller's argument; `expected` is derived from the feed's own
    ///      `decimals()` plus the two decimal arguments, at construction time. A mismatch
    ///      means the numerator was computed for a different decimal configuration than the
    ///      one actually deployed -- exactly the mistake that decodes a feed answer into a
    ///      reference price wrong by orders of magnitude.
    error ChainlinkReferenceAdapter__PriceNumeratorMismatch(uint256 provided, uint256 expected);

    /// @notice Binds the adapter to one feed and one pool orientation.
    /// @dev `currency0Decimals` and `currency1Decimals` are not stored; they exist only to
    ///      let the constructor recompute `priceNumerator` independently and reject a caller
    ///      whose value does not match. Deriving it here rather than trusting a hand-typed
    ///      argument is what closes the mistake: a numerator computed for the wrong feed or
    ///      token decimals used to deploy silently and price every swap against a reference
    ///      that was not the price of anything.
    constructor(
        IAggregatorV3 feed,
        uint256 maxAgeSeconds,
        uint256 priceNumerator,
        Currency currency0,
        uint8 currency0Decimals,
        Currency currency1,
        uint8 currency1Decimals
    ) {
        if (address(feed) == address(0)) {
            revert ChainlinkReferenceAdapter__FeedIsZeroAddress();
        }
        if (maxAgeSeconds == 0) revert ChainlinkReferenceAdapter__MaxAgeIsZero();
        if (priceNumerator == 0) revert ChainlinkReferenceAdapter__PriceNumeratorIsZero();

        // Decimals sit in 0-18 for every token and feed this is deployed against, so the
        // subtraction cannot underflow in practice; if it ever did, the constructor reverts,
        // which fails as safely as the explicit checks around it.
        uint256 expectedNumerator =
            10 ** (uint256(currency1Decimals) + uint256(feed.decimals()) - uint256(currency0Decimals));
        if (priceNumerator != expectedNumerator) {
            revert ChainlinkReferenceAdapter__PriceNumeratorMismatch(priceNumerator, expectedNumerator);
        }

        // v4 pool keys always carry currency0 < currency1. Enforcing the same ordering here
        // means a consumer can compare the two directly rather than sorting first, and a
        // deployment that supplies them backwards fails immediately instead of silently
        // never matching any pool.
        if (Currency.unwrap(currency0) >= Currency.unwrap(currency1)) {
            revert ChainlinkReferenceAdapter__CurrenciesOutOfOrder(
                Currency.unwrap(currency0), Currency.unwrap(currency1)
            );
        }

        FEED = feed;
        MAX_AGE_SECONDS = maxAgeSeconds;
        PRICE_NUMERATOR = priceNumerator;
        MIN_DIVISIBLE_ANSWER = priceNumerator >> 64;
        PRICED_CURRENCY0 = currency0;
        PRICED_CURRENCY1 = currency1;
    }

    /// @inheritdoc IReferencePriceOracle
    function pricedCurrencies() external view returns (Currency, Currency) {
        return (PRICED_CURRENCY0, PRICED_CURRENCY1);
    }

    /// @inheritdoc IReferencePriceOracle
    /// @dev `roundId`/`answeredInRound` are discarded: the `answeredInRound >= roundId` idiom
    ///      applied to legacy aggregators and would give false assurance on OCR feeds.
    ///      Staleness is a wall-clock question, so `block.timestamp` is the only answer
    ///      available; a proposer can nudge it by seconds, immaterial against a bound in
    ///      minutes, and the worst outcome is a reading marked unusable.
    // slither-disable-next-line timestamp,unused-return
    function referenceSqrtPriceX96() external view returns (uint160 sqrtPriceX96, bool fresh) {
        // A feed that reverts, returns a non-positive answer, or has stopped updating is a
        // stale reading, not an error. try/catch keeps a misbehaving external contract from
        // propagating a revert into the swap that triggered this read.
        try FEED.latestRoundData{gas: FEED_GAS_LIMIT}() returns (
            uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || startedAt == 0 || updatedAt == 0) return (0, false);
            // A reading stamped in the future is not evidence of freshness, it is evidence
            // the feed is wrong about the time. Testing it first also keeps the subtraction
            // below from underflowing.
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_AGE_SECONDS) {
                return (0, false);
            }
            // The guard above has established answer > 0, so the cast is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint256(answer) <= MIN_DIVISIBLE_ANSWER) return (0, false);
            // The guard above has established answer > 0, so the cast is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            return _toSqrtPriceX96(uint256(answer));
        } catch {
            return (0, false);
        }
    }

    /// @dev Converts a feed answer into `sqrt(price) * 2**96`.
    ///      `price = PRICE_NUMERATOR / answer`, so
    ///      `sqrtPriceX96 = sqrt(PRICE_NUMERATOR * 2**192 / answer)`. The multiplication is
    ///      done with a 512-bit intermediate because `PRICE_NUMERATOR * 2**192` alone
    ///      overflows uint256 for any realistic decimal scaling.
    function _toSqrtPriceX96(uint256 answer) private view returns (uint160 sqrtPriceX96, bool fresh) {
        uint256 ratioX192 = FullMath.mulDiv(PRICE_NUMERATOR, 1 << 192, answer);
        uint256 root = FixedPointMathLib.sqrt(ratioX192);

        // A reading outside the representable price range cannot be compared against a pool
        // tick, so it is reported unusable rather than clamped into a misleading value.
        if (root < TickMath.MIN_SQRT_PRICE || root >= TickMath.MAX_SQRT_PRICE) return (0, false);
        // MAX_SQRT_PRICE fits uint160, and the branch above rejects anything at or beyond it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(root), true);
    }
}
