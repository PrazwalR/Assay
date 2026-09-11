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
/// @dev Every failure is reported as `fresh = false`, never raised: a feed outage must not be
///      able to halt a pool.
contract ChainlinkReferenceAdapter is IReferencePriceOracle {
    /// @dev `10 ** (token1Decimals - token0Decimals + feedDecimals)`, computed off chain.
    uint256 public immutable PRICE_NUMERATOR;

    /// @dev Largest answer `_toSqrtPriceX96` cannot divide by. Chainlink's own `minAnswer`
    ///      sentinel of 1 sits inside this range at the deployed scaling.
    uint256 public immutable MIN_DIVISIBLE_ANSWER;

    /// @dev Stops a gas-burning feed taking 63/64 of the swapper's. Honest call is ~21,000.
    uint256 internal constant FEED_GAS_LIMIT = 100_000;

    IAggregatorV3 public immutable FEED;
    uint256 public immutable MAX_AGE_SECONDS;

    /// @dev The pair `PRICE_NUMERATOR` was computed for, so a consumer can refuse others.
    Currency public immutable PRICED_CURRENCY0;
    Currency public immutable PRICED_CURRENCY1;

    error ChainlinkReferenceAdapter__FeedIsZeroAddress();
    error ChainlinkReferenceAdapter__MaxAgeIsZero();
    error ChainlinkReferenceAdapter__PriceNumeratorIsZero();
    error ChainlinkReferenceAdapter__CurrenciesOutOfOrder(address currency0, address currency1);

    /// @dev The mistake that decodes an answer wrong by orders of magnitude.
    error ChainlinkReferenceAdapter__PriceNumeratorMismatch(uint256 provided, uint256 expected);

    /// @notice Binds the adapter to one feed and one pool orientation.
    /// @dev The decimal arguments are not stored: they let the constructor recompute
    ///      `priceNumerator` and reject a hand-typed value that disagrees.
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

        // Decimals sit in 0-18, so this cannot underflow; if it did, the constructor reverts.
        uint256 expectedNumerator =
            10 ** (uint256(currency1Decimals) + uint256(feed.decimals()) - uint256(currency0Decimals));
        if (priceNumerator != expectedNumerator) {
            revert ChainlinkReferenceAdapter__PriceNumeratorMismatch(priceNumerator, expectedNumerator);
        }

        // v4 keys carry currency0 < currency1, so a backwards deployment fails now rather
        // than silently matching no pool.
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
    /// @dev `roundId`/`answeredInRound` are discarded: that idiom gives false assurance on
    ///      OCR feeds. A proposer nudging `block.timestamp` is immaterial here.
    // slither-disable-next-line timestamp,unused-return
    function referenceSqrtPriceX96() external view returns (uint160 sqrtPriceX96, bool fresh) {
        // A misbehaving feed is a stale reading, not an error.
        try FEED.latestRoundData{gas: FEED_GAS_LIMIT}() returns (
            uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80
        ) {
            if (answer <= 0 || startedAt == 0 || updatedAt == 0) return (0, false);
            // A future stamp means the feed is wrong about the time. Testing it first also
            // stops the subtraction underflowing.
            if (updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_AGE_SECONDS) {
                return (0, false);
            }
            // Guarded above: answer > 0, so both casts are exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (uint256(answer) <= MIN_DIVISIBLE_ANSWER) return (0, false);
            // forge-lint: disable-next-line(unsafe-typecast)
            return _toSqrtPriceX96(uint256(answer));
        } catch {
            return (0, false);
        }
    }

    /// @dev `sqrtPriceX96 = sqrt(PRICE_NUMERATOR * 2**192 / answer)`, via a 512-bit
    ///      intermediate because `PRICE_NUMERATOR * 2**192` alone overflows uint256.
    function _toSqrtPriceX96(uint256 answer) private view returns (uint160 sqrtPriceX96, bool fresh) {
        uint256 ratioX192 = FullMath.mulDiv(PRICE_NUMERATOR, 1 << 192, answer);
        uint256 root = FixedPointMathLib.sqrt(ratioX192);

        // Outside the representable range, reported unusable rather than clamped.
        if (root < TickMath.MIN_SQRT_PRICE || root >= TickMath.MAX_SQRT_PRICE) return (0, false);
        // The branch above rejects anything at or beyond MAX_SQRT_PRICE, which fits uint160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(root), true);
    }
}
