// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {PoolState} from "../../src/types/PoolState.sol";

contract PoolStateTrackingTest is AssayTestBase {
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

    function test_AfterInitialize_SeedsTickAndBlock() public view {
        PoolState memory state = _state();
        assertEq(state.lastTick, 0, "seeded tick");
        assertEq(state.lastBlock, uint32(block.number), "seeded block");
        assertTrue(state.referenceFresh, "a live feed must seed a usable reference");
    }

    function test_Swap_AdvancesTheLastTick() public {
        _swap(true, -1 ether);
        assertLt(_state().lastTick, 0, "a zeroForOne swap must lower the recorded tick");
    }

    function test_Reference_RefreshesOnlyOncePerBlock() public {
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);

        // Move the feed, then swap again in the SAME block: the cached reference must not move.
        int24 before = _state().referenceTick;
        feed.setAnswer(int256(150e6));
        feed.setUpdatedAt(block.timestamp);
        _swap(true, -0.001 ether);
        assertEq(_state().referenceTick, before, "reference refreshed twice in one block");

        // A new block picks the change up.
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        assertTrue(_state().referenceTick != before, "reference did not refresh across the boundary");
    }

    /// @dev Proves the fields share one storage slot. A field pushed past 256 bits silently
    ///      adds an SLOAD and an SSTORE to the hot path, which the gas budget cannot absorb.
    function test_PoolState_OccupiesOneStorageSlot() public {
        _swap(true, -5 ether);
        vm.roll(block.number + 1);
        _swap(true, -1 ether);

        PoolId poolId = poolKey.toId();
        uint256 word = uint256(vm.load(address(hook), keccak256(abi.encode(poolId, uint256(0)))));

        // Offsets follow declaration order: lastTick 0, referenceTick 24, lastBlock 48,
        // referenceFresh 80 -- 88 bits of the 256 available.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 lastTick = int24(uint24(word));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 referenceTick = int24(uint24(word >> 24));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 lastBlock = uint32(word >> 48);
        bool referenceFresh = ((word >> 80) & 0xFF) != 0;

        PoolState memory state = _state();
        assertEq(lastTick, state.lastTick, "lastTick not in the expected bits");
        assertEq(referenceTick, state.referenceTick, "referenceTick not in the expected bits");
        assertEq(lastBlock, state.lastBlock, "lastBlock not in the expected bits");
        assertEq(referenceFresh, state.referenceFresh, "referenceFresh not in the expected bits");
    }

    function test_FeeBounds_ReportConstructorValues() public view {
        (uint24 base, uint24 min, uint24 max) = hook.feeBounds();
        assertEq(base, BASE_FEE_PIPS);
        assertEq(min, MIN_FEE_PIPS);
        assertEq(max, MAX_FEE_PIPS);
    }

    function testFuzz_State_StaysConsistentAcrossManySwaps(bool startDirection, uint96 amount, uint8 blocks)
        public
    {
        // Direction alternates so the price oscillates rather than walking into the pool's
        // price limit, which would revert in the router before the hook is ever reached.
        amount = uint96(bound(amount, 0.001 ether, 2 ether));
        for (uint256 i = 0; i < 6; ++i) {
            _swap(i % 2 == 0 ? startDirection : !startDirection, -int256(uint256(amount)));
            if (i % 2 == 0) vm.roll(block.number + 1 + (blocks % 3));
        }

        PoolState memory state = _state();
        assertEq(state.lastBlock, uint32(block.number), "block marker must track the latest swap");
    }
}
