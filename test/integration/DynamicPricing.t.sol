// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapFeeEventAsserter} from "hookmate/test/utils/SwapFeeEventAsserter.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";

/// @dev The behaviour the whole project exists to produce, asserted on the fee the
///      PoolManager actually applied rather than on what the hook returned.
contract DynamicPricingTest is AssayTestBase {
    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (uint24) {
        vm.recordLogs();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return SwapFeeEventAsserter.getSwapFeeFromEvent(vm.getRecordedLogs());
    }

    /// @dev Two swaps, same block, same pool, same drift, opposite directions. A fee
    ///      conditioned on volatility charges these identically because volatility is a
    ///      property of the market. Assay does not, because the drift one of them captures
    ///      is the liquidity provider's loss and the other's is not.
    ///
    ///      This is the demo.
    function test_SameBlockOppositeDirectionsAreQuotedDifferently() public {
        // Move the reference 2% above the pool, leaving the pool stale and cheap.
        feed.setAnswer(int256(98e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        uint24 capturingDrift = _swap(false, -0.01 ether);
        uint24 addingToDrift = _swap(true, -0.01 ether);

        emit log_named_uint("quoted, capturing the drift", capturingDrift);
        emit log_named_uint("quoted, adding to the drift", addingToDrift);

        assertGt(
            capturingDrift,
            addingToDrift,
            "the swap picking off the pool must not be quoted the same as the one that is not"
        );
    }

    function test_QuoteScalesWithTheSizeOfTheDrift() public {
        feed.setAnswer(int256(99e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        uint24 smallDrift = _swap(false, -0.001 ether);

        feed.setAnswer(int256(90e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        uint24 largeDrift = _swap(false, -0.001 ether);

        assertGt(largeDrift, smallDrift, "a larger drift must be priced higher");
    }

    /// @dev With no usable reference the hook cannot tell which flow it faces, so it charges
    ///      the ceiling to everyone. Erring upward protects liquidity providers; erring
    ///      downward would underprice whatever arrived while the reference was dark.
    function test_StaleReferenceQuotesTheCeilingToEveryone() public {
        vm.warp(block.timestamp + ORACLE_MAX_AGE + 1);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        assertEq(_swap(true, -0.001 ether), MAX_FEE_PIPS, "zeroForOne under a dark reference");
        assertEq(_swap(false, -0.001 ether), MAX_FEE_PIPS, "oneForZero under a dark reference");
    }

    /// @dev A hook that can be made to revert a swap is a denial of service on every
    ///      liquidity provider in the pool, whatever the state of the world.
    function testFuzz_SwapNeverRevertsWhateverTheReferenceDoes(
        int256 answer,
        bool feedReverts,
        bool zeroForOne,
        uint96 amount
    ) public {
        feed.setAnswer(answer);
        feed.setShouldRevert(feedReverts);
        feed.setUpdatedAt(block.timestamp);

        vm.roll(block.number + 1);
        uint24 charged = _swap(zeroForOne, -int256(uint256(bound(amount, 0.001 ether, 2 ether))));

        assertGe(charged, MIN_FEE_PIPS, "quote below advertised floor");
        assertLe(charged, MAX_FEE_PIPS, "quote above advertised ceiling");
    }
}
