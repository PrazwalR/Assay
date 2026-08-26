// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {PoolState} from "../../src/types/PoolState.sol";

/// @dev The oracle is now the hook's primary signal, and it is read from the swap path. The
///      binding requirement is therefore not accuracy but totality: no feed condition may
///      revert a swap, because that would brick the pool for every liquidity provider.
contract ReferenceOracleTest is AssayTestBase {
    function _swap(bool zeroForOne, int256 amountSpecified) internal {
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
    }

    function _state() internal view returns (PoolState memory) {
        return hook.poolState(poolKey.toId());
    }

    function test_Initialize_SeedsAFreshReference() public view {
        PoolState memory state = _state();
        assertTrue(state.referenceFresh, "a live feed must seed a fresh reference");
        assertEq(state.referenceTick, 0, "a price of 1.0 between equal decimals is tick 0");
    }

    function test_Reference_TracksTheFeedAcrossBlocks() public {
        // Roughly a 5% move: the reference should follow it, the pool should not.
        feed.setAnswer(int256(105e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        PoolState memory state = _state();
        assertTrue(state.referenceFresh, "feed is live");
        assertLt(state.referenceTick, -400, "reference did not follow the feed");
    }

    function test_Mispricing_IsSignedByDirection() public {
        feed.setAnswer(int256(105e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        (int256 towards, bool freshA) = hook.signedMispricing(poolKey.toId(), true);
        (int256 away, bool freshB) = hook.signedMispricing(poolKey.toId(), false);

        assertTrue(freshA && freshB, "reference should be usable");
        assertGt(towards, 0, "trading toward the reference captures drift");
        assertEq(towards, -away, "the opposite direction must mirror it");
    }

    // --- degradation: none of these may revert a swap ------------------------------------

    function test_StaleFeed_MarksReferenceUnusableWithoutReverting() public {
        vm.warp(block.timestamp + ORACLE_MAX_AGE + 1);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        assertFalse(_state().referenceFresh, "an outdated feed must be marked unusable");
    }

    function test_RevertingFeed_DoesNotRevertTheSwap() public {
        feed.setShouldRevert(true);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        assertFalse(_state().referenceFresh, "a reverting feed must be marked unusable");
    }

    function test_NegativeAnswer_DoesNotRevertTheSwap() public {
        feed.setAnswer(-1);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        assertFalse(_state().referenceFresh, "a negative price must be marked unusable");
    }

    function test_ZeroAnswer_DoesNotRevertTheSwap() public {
        feed.setAnswer(0);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        assertFalse(_state().referenceFresh, "a zero price must be marked unusable");
    }

    /// @dev A reference that has gone stale must keep its last usable value rather than
    ///      resetting to zero, which would read as "the pool is aligned" when in fact the
    ///      hook has no view of the pool at all. The freshness flag is what callers check.
    function test_StaleFeed_RetainsTheLastUsableReading() public {
        feed.setAnswer(int256(105e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        int24 lastGood = _state().referenceTick;

        vm.warp(block.timestamp + ORACLE_MAX_AGE + 1);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        PoolState memory state = _state();
        assertFalse(state.referenceFresh, "should be marked stale");
        assertEq(state.referenceTick, lastGood, "stale must not silently read as aligned");
    }

    function test_FeedRecovery_RestoresFreshness() public {
        feed.setShouldRevert(true);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        assertFalse(_state().referenceFresh, "should be unusable while the feed is down");

        feed.setShouldRevert(false);
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        assertTrue(_state().referenceFresh, "should recover once the feed returns");
    }

    /// @dev The invariant that matters most: whatever the feed does, the swap goes through.
    function testFuzz_Swap_NeverRevertsForAnyFeedCondition(int256 answer, uint32 ageSeconds, bool feedReverts)
        public
    {
        feed.setAnswer(answer);
        feed.setUpdatedAt(bound(uint256(ageSeconds), 0, block.timestamp));
        feed.setShouldRevert(feedReverts);

        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        _swap(false, -0.001 ether);
    }
}
