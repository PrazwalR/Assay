// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {AssayConfig} from "../../src/config/AssayConfig.sol";
import {AssayHook} from "../../src/AssayHook.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {IAssayEvents} from "../../src/interfaces/IAssayEvents.sol";

/// @dev Closes the gap SECURITY.md documented as open: "no deviation cap between the
///      reference price and a pool TWAP." A Chainlink reading that is fresh by every check
///      `ChainlinkReferenceAdapter` itself performs can still be wrong -- a compromised
///      aggregator, or a misconfiguration this hook cannot see from its own side. This is the
///      second, independent check: does the reading agree with where the pool has actually
///      been trading, not just whether it arrived recently.
contract ReferenceDeviationCapTest is AssayTestBase {
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

    function _tripEvents(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IAssayEvents.ReferenceDeviationCapTripped.selector) count++;
        }
    }

    /// @dev Baseline: nothing has happened yet, so the reference must agree with itself
    ///      exactly. A cap that tripped here would mean pools can never come into existence.
    function test_AfterInitialize_ReferenceStartsWithinBound() public view {
        (int24 twapTick, int256 deviationTicks, bool withinBound) = hook.referenceDeviation(poolKey.toId());
        assertEq(twapTick, 0);
        assertEq(deviationTicks, 0);
        assertTrue(withinBound);
    }

    /// @dev A 20% price move (~1,820 ticks) is well inside the 20,000-tick default cap and
    ///      is exactly the kind of ordinary dislocation the hook exists to price, not reject.
    function test_OrdinaryDislocation_IsAdoptedNotRejected() public {
        vm.roll(block.number + 1);
        feed.setAnswer(int256(120e6));
        feed.setUpdatedAt(block.timestamp);

        vm.recordLogs();
        _swap(true, -0.001 ether);

        assertTrue(_state().referenceFresh, "an ordinary dislocation must not be rejected");
        assertEq(_tripEvents(vm.getRecordedLogs()), 0, "the cap must not fire on an ordinary move");
    }

    /// @dev A 10,000x price move is beyond anything a real market produces and squarely in
    ///      the range an order-of-magnitude feed error (the pass-2 M-1 finding's own shape)
    ///      or a compromised aggregator would produce. The oracle itself reports this as
    ///      fresh; the cap is what stops the hook from believing it anyway.
    function test_WildlyWrongButFreshReference_IsRejected() public {
        vm.roll(block.number + 1);
        feed.setAnswer(int256(1e12)); // 10,000x the 1e8 baseline
        feed.setUpdatedAt(block.timestamp);

        vm.recordLogs();
        _swap(true, -0.001 ether);

        assertFalse(
            _state().referenceFresh, "a reference this far from the pool's own history must be rejected"
        );
        assertEq(_tripEvents(vm.getRecordedLogs()), 1, "the cap must fire exactly once");
    }

    /// @dev The rejected value must never be adopted. Mirrors
    ///      `invariant_StaleReferenceRetainsItsLastReading`, but as a directed proof that the
    ///      specific value retained is the *last trusted* one, not merely "some" tick.
    function test_RejectedReference_RetainsTheLastTrustedTick() public {
        vm.roll(block.number + 1);
        feed.setAnswer(int256(101e6)); // small, trusted move
        feed.setUpdatedAt(block.timestamp);
        _swap(true, -0.001 ether);
        int24 lastTrusted = _state().referenceTick;

        vm.roll(block.number + 1);
        feed.setAnswer(int256(1e12));
        feed.setUpdatedAt(block.timestamp);
        _swap(true, -0.001 ether);

        assertEq(
            _state().referenceTick, lastTrusted, "a rejected reference must not overwrite the trusted one"
        );
        assertFalse(_state().referenceFresh);
    }

    /// @dev The mechanical core of the anti-manipulation property: `PoolTwap` only samples
    ///      the tick as of a block's *open*, so nothing a swap does can be reflected in the
    ///      anchor until a later block. This is what makes the cap resistant to an attacker
    ///      walking the pool's own price within the same transaction that needs a bad
    ///      reference to look consistent with it -- the anchor being checked against was
    ///      already fixed before that transaction began.
    function test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor() public {
        // A few blocks of ordinary trading first, so the anchor has moved off its
        // just-initialised seed -- otherwise "unchanged" would hold trivially either way.
        for (uint256 i = 0; i < 3; ++i) {
            vm.roll(block.number + 1);
            _swap(true, -0.001 ether);
        }
        (int24 anchorBefore,,) = hook.referenceDeviation(poolKey.toId());

        // One large swap, still in the same block: walks the pool's own spot tick hard.
        _swap(true, -50 ether);
        int24 spotTickAfter = _state().lastTick;
        assertTrue(
            spotTickAfter < anchorBefore - 1000,
            "the swap must move the spot tick meaningfully or this proves nothing"
        );

        (int24 anchorAfterSameBlockSwap,,) = hook.referenceDeviation(poolKey.toId());
        assertEq(
            anchorAfterSameBlockSwap, anchorBefore, "a same-block swap must not move the TWAP anchor at all"
        );

        // Only a genuine block boundary lets the moved price count. The confirming swap
        // trades the opposite direction: the previous swap left the pool pinned at its price
        // limit, with no room left to move further the same way.
        vm.roll(block.number + 1);
        _swap(false, -0.001 ether);
        (int24 anchorAfterBoundary,,) = hook.referenceDeviation(poolKey.toId());
        assertTrue(anchorAfterBoundary != anchorBefore, "a real block boundary must fold the moved price in");
    }

    /// @dev `maxReferenceDeviationTicks == 0` is documented as "cap disabled". A deployment
    ///      that chooses it must see the pre-existing behaviour exactly: any fresh reading is
    ///      adopted regardless of how far it sits from the pool's own history.
    function test_CapDisabled_AdoptsAnyFreshReading() public {
        AssayConfig memory config = _defaultConfig();
        config.maxReferenceDeviationTicks = 0;
        AssayHook uncapped = _deployHook(config);
        poolKey = _initialisePool(address(uncapped));
        _addLiquidity();

        vm.roll(block.number + 1);
        feed.setAnswer(int256(1e12));
        feed.setUpdatedAt(block.timestamp);

        vm.recordLogs();
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertTrue(
            uncapped.poolState(poolKey.toId()).referenceFresh,
            "an uncapped deployment must adopt any fresh reading"
        );
        assertEq(_tripEvents(vm.getRecordedLogs()), 0, "a disabled cap must never fire");
    }

    /// @dev Total over the reachable input space: whatever the feed reports, and whatever
    ///      the deviation cap decides about it, the swap itself must always settle.
    function testFuzz_Swap_NeverRevertsRegardlessOfDeviation(int256 answer, bool zeroForOne, uint96 amount)
        public
    {
        vm.roll(block.number + 1);
        feed.setAnswer(answer);
        feed.setUpdatedAt(block.timestamp);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(bound(amount, 0.001 ether, 2 ether))),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
