// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {IReferencePriceOracle} from "../interfaces/IReferencePriceOracle.sol";

/// @notice Minimal view of a Chainlink aggregator.
interface IAggregatorV3 {
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

    /// @notice Binds the adapter to one feed and one pool orientation.
    /// @param feed The Chainlink aggregator to read.
    /// @param maxAgeSeconds How old a reading may be before it stops counting as fresh.
    /// @param priceNumerator Decimal scaling for this pool's token pair and this feed.
    /// @param currency0 Lower-sorted currency of the pair this scaling describes.
    /// @param currency1 Higher-sorted currency of that pair.
    constructor(
        IAggregatorV3 feed,
        uint256 maxAgeSeconds,
        uint256 priceNumerator,
        Currency currency0,
        Currency currency1
    ) {
        if (address(feed) == address(0)) {
            revert ChainlinkReferenceAdapter__FeedIsZeroAddress();
        }
        if (maxAgeSeconds == 0) revert ChainlinkReferenceAdapter__MaxAgeIsZero();
        if (priceNumerator == 0) revert ChainlinkReferenceAdapter__PriceNumeratorIsZero();

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
        PRICED_CURRENCY0 = currency0;
        PRICED_CURRENCY1 = currency1;
    }

    /// @inheritdoc IReferencePriceOracle
    function pricedCurrencies() external view returns (Currency, Currency) {
        return (PRICED_CURRENCY0, PRICED_CURRENCY1);
    }

    /// @inheritdoc IReferencePriceOracle
    /// @dev `roundId`, `startedAt` and `answeredInRound` are deliberately discarded. The
    ///      `answeredInRound >= roundId` idiom applied to legacy aggregators and is no
    ///      longer meaningful for OCR feeds, so checking it would provide false assurance
    ///      rather than protection; `updatedAt` is the field that actually carries staleness.
    ///
    ///      Staleness is a wall-clock question, so `block.timestamp` is the only available
    ///      answer. A proposer can nudge it by a few seconds, which is immaterial against a
    ///      staleness bound measured in minutes or hours, and the worst outcome either way
    ///      is a reading marked unusable rather than a wrong price being trusted.
    // slither-disable-next-line timestamp,unused-return
    function referenceSqrtPriceX96() external view returns (uint160 sqrtPriceX96, bool fresh) {
        // A feed that reverts, returns a non-positive answer, or has stopped updating is a
        // stale reading, not an error. try/catch keeps a misbehaving external contract from
        // propagating a revert into the swap that triggered this read.
        try FEED.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || updatedAt == 0) return (0, false);
            if (block.timestamp > updatedAt && block.timestamp - updatedAt > MAX_AGE_SECONDS) {
                return (0, false);
            }
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
