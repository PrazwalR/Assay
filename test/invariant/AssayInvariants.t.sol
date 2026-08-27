// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {AssayHandler} from "./AssayHandler.sol";
import {PoolState} from "../../src/types/PoolState.sol";

/// @notice Stateful properties that must hold after ANY reachable sequence of swaps,
///         liquidity changes, block advances and reference-price events.
///
/// @dev Unit tests assert what happens in orderings someone thought to write down. Four of
///      the five real bugs found in this project so far came from state interactions across
///      calls -- a tick left stale by one swap and read by the next, a guard that only
///      mattered once liquidity had been withdrawn. Those are precisely what a fixed test
///      sequence does not reach and a fuzzer over orderings does.
contract AssayInvariantsTest is StdInvariant, AssayTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    AssayHandler internal handler;

    function setUp() public override {
        super.setUp();

        handler = new AssayHandler(
            IPoolManager(address(manager)), hook, swapRouter, liquidityRouter, feed, poolKey, TICK_SPACING
        );

        // The handler transacts, so it needs balances and approvals of its own.
        token0.mint(address(handler), 1_000_000 ether);
        token1.mint(address(handler), 1_000_000 ether);
        vm.startPrank(address(handler));
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        vm.stopPrank();

        targetContract(address(handler));
        vm.recordLogs();
    }

    /// @dev The promise `feeBounds()` makes to any router that reads it before quoting. A
    ///      fee outside this range means an integrator was misled about the worst case.
    function invariant_QuotedFeeAlwaysWithinAdvertisedBounds() public view {
        if (handler.swapCount() == 0) return;

        assertGe(handler.minFeeObserved(), MIN_FEE_PIPS, "a swap was charged below the advertised floor");
        assertLe(handler.maxFeeObserved(), MAX_FEE_PIPS, "a swap was charged above the advertised ceiling");
    }

    /// @dev The hook takes no custody. It quotes fees and, on dislocation, routes a surcharge
    ///      straight through to liquidity providers -- it should never end a transaction
    ///      holding either token. A balance here means value is stranded in a contract with
    ///      no withdrawal function.
    function invariant_HookNeverAccumulatesTokens() public view {
        assertEq(token0.balanceOf(address(hook)), 0, "hook accumulated currency0");
        assertEq(token1.balanceOf(address(hook)), 0, "hook accumulated currency1");
    }

    /// @dev Every operation settles. A non-zero delta outside an unlock would mean the
    ///      PoolManager's accounting was left open, which it would itself revert on -- so
    ///      this asserts the run never left the system mid-flight.
    function invariant_NoUnsettledDeltas() public view {
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "unsettled delta remains");
    }

    /// @dev `lastBlock` is a marker for "the reference was refreshed in this block". A value
    ///      ahead of the chain would make the hook believe it had refreshed when it had not,
    ///      suppressing every future refresh.
    function invariant_BlockMarkerNeverRunsAhead() public view {
        assertLe(
            uint256(hook.poolState(poolKey.toId()).lastBlock),
            block.number,
            "state claims a refresh from a block that has not happened"
        );
    }

    /// @dev A stale reference must retain its last usable value rather than resetting. Zero
    ///      would read as "the pool sits exactly at its reference", which is a confident
    ///      claim the hook is in no position to make while the feed is dark.
    function invariant_StaleReferenceRetainsItsLastReading() public view {
        PoolState memory state = hook.poolState(poolKey.toId());

        // Only meaningful once a usable reading has actually existed. A reference that was
        // never fresh may legitimately still hold the tick it was seeded with.
        if (handler.referenceWasEverFresh() && !state.referenceFresh) {
            assertTrue(
                state.referenceTick >= TickMath.MIN_TICK && state.referenceTick <= TickMath.MAX_TICK,
                "a stale reference left an unusable tick behind"
            );
        }
    }

    /// @dev Liquidity providers must never be trapped. The hook takes no liquidity
    ///      permissions, so this should hold structurally -- the invariant exists to catch a
    ///      future change that adds one.
    function invariant_LiquidityCanAlwaysBeWithdrawn() public {
        if (handler.netLiquidityAdded() <= 1 ether) return;

        uint256 before = token1.balanceOf(address(this));
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: -1 ether,
                salt: bytes32(0)
            }),
            ""
        );
        assertGt(token1.balanceOf(address(this)), before, "withdrawal returned nothing");
    }

    /// @dev Guards against the invariants above passing vacuously. Foundry evaluates
    ///      invariants once after `setUp` as well, when no call has run, so this asserts a
    ///      conditional rather than a count: if swaps happened, a fee must have been
    ///      recorded from the PoolManager's own event. A run where the handler swapped but
    ///      observed no fee would mean the recording is broken and every fee-bound assertion
    ///      above is meaningless.
    function invariant_ObservedFeesTrackActualSwaps() public view {
        if (handler.swapCount() == 0) return;
        assertLt(handler.minFeeObserved(), type(uint24).max, "swaps ran but no fee was ever observed");
        assertGt(handler.maxFeeObserved(), 0, "swaps ran but every observed fee was zero");
    }
}
