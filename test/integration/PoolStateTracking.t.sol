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

    function test_AfterInitialize_SeedsTickAndBlockWithZeroedEstimates() public view {
        PoolState memory state = _state();
        assertEq(state.lastTick, 0, "seeded tick");
        assertEq(state.lastBlock, uint32(block.number), "seeded block");
        assertEq(state.varEwmaX32, 0, "variance must start unmeasured, not invented");
        assertEq(state.ofiEwmaX32, 0, "imbalance must start unmeasured");
    }

    function test_Swap_MovesImbalanceInTheDirectionOfFlow() public {
        _swap(true, -1 ether);
        int64 afterBuy = _state().ofiEwmaX32;
        assertTrue(afterBuy != 0, "imbalance did not respond to flow");

        _swap(false, -1 ether);
        assertLt(_state().ofiEwmaX32, afterBuy, "opposing flow did not reduce imbalance");
    }

    function test_Variance_StaysUnmeasuredWithinTheOpeningBlock() public {
        _swap(true, -1 ether);
        _swap(true, -1 ether);
        assertEq(_state().varEwmaX32, 0, "variance advanced without a block boundary");
    }

    function test_Variance_AdvancesOnTheFirstSwapOfANewBlock() public {
        _swap(true, -10 ether);
        vm.roll(block.number + 1);
        _swap(true, -0.01 ether);

        PoolState memory state = _state();
        assertGt(state.varEwmaX32, 0, "variance did not advance across the block boundary");
        assertEq(state.lastBlock, uint32(block.number), "block marker not advanced");
    }

    function test_Variance_AdvancesOnlyOncePerBlock() public {
        _swap(true, -10 ether);
        vm.roll(block.number + 1);

        _swap(true, -0.01 ether);
        uint64 afterFirst = _state().varEwmaX32;

        _swap(true, -10 ether);
        _swap(false, -10 ether);
        assertEq(_state().varEwmaX32, afterFirst, "a later swap in the same block moved variance");
    }

    /// @dev The security property the per-block design exists to provide.
    ///
    ///      An attacker who can move variance can choose their own fee. Sampling per swap
    ///      would let them push the price hard in both directions inside one block and
    ///      inflate the estimate for free, since the round trip nets out. Sampling at block
    ///      boundaries means only the net move is observable, and a net move has to be paid
    ///      for and left standing.
    function test_Exploit_IntraBlockRoundTripCannotInflateVariance() public {
        // Sizes are chosen to stay inside the tick-delta clamp. At the clamp both arms would
        // truncate to the same sample and the comparison would prove nothing: a 3 ether swap
        // moves roughly 580 ticks here, against a 1,000 tick bound.
        _swap(true, -3 ether);
        _swap(false, -3 ether);
        _swap(true, -3 ether);
        _swap(false, -3 ether);

        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        uint64 afterManipulation = _state().varEwmaX32;

        // The same gross volume, but left standing across the boundary instead of unwound.
        setUp();
        _swap(true, -3 ether);
        vm.roll(block.number + 1);
        _swap(true, -0.001 ether);
        uint64 afterHonestMove = _state().varEwmaX32;

        assertLt(
            afterManipulation,
            afterHonestMove / 100,
            "an intra-block round trip moved variance comparably to a real move"
        );
    }

    /// @dev Proves the four fields share one storage slot. If a later field pushes the struct
    ///      past 256 bits the hot path silently gains a second SLOAD and SSTORE, which the gas
    ///      budget cannot absorb.
    function test_PoolState_OccupiesOneStorageSlot() public {
        _swap(true, -5 ether);
        vm.roll(block.number + 1);
        _swap(true, -1 ether);

        PoolId poolId = poolKey.toId();
        bytes32 raw = vm.load(address(hook), keccak256(abi.encode(poolId, uint256(0))));
        uint256 word = uint256(raw);

        // Truncation is the operation here: each cast slices the bit range the compiler
        // packed that field into, and a wrong width is exactly what this test exists to catch.
        // Offsets follow declaration order: lastTick 0, blockOpenTick 24, referenceTick 48,
        // lastBlock 72, varEwmaX32 104, ofiEwmaX32 168, referenceFresh 232 -- 240 bits of
        // the 256 available.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 lastTick = int24(uint24(word));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 blockOpenTick = int24(uint24(word >> 24));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 referenceTick = int24(uint24(word >> 48));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 lastBlock = uint32(word >> 72);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 varEwmaX32 = uint64(word >> 104);
        // forge-lint: disable-next-line(unsafe-typecast)
        int64 ofiEwmaX32 = int64(uint64(word >> 168));
        bool referenceFresh = ((word >> 232) & 0xFF) != 0;

        PoolState memory state = _state();
        assertEq(lastTick, state.lastTick, "lastTick not in the expected bits");
        assertEq(blockOpenTick, state.blockOpenTick, "blockOpenTick not in the expected bits");
        assertEq(referenceTick, state.referenceTick, "referenceTick not in the expected bits");
        assertEq(referenceFresh, state.referenceFresh, "referenceFresh not in the expected bits");
        assertEq(lastBlock, state.lastBlock, "lastBlock not in the expected bits");
        assertEq(varEwmaX32, state.varEwmaX32, "variance not in the expected bits");
        assertEq(ofiEwmaX32, state.ofiEwmaX32, "imbalance not in the expected bits");
    }

    function test_EstimatorParameters_ReportConstructorValues() public view {
        (uint64 varianceLambda, uint64 ofiLambda, int24 maxDelta) = hook.estimatorParameters();
        assertEq(varianceLambda, VARIANCE_LAMBDA_X32);
        assertEq(ofiLambda, OFI_LAMBDA_X32);
        assertEq(maxDelta, MAX_TICK_DELTA);
    }

    function testFuzz_State_NeverEscapesItsDeclaredBounds(bool startDirection, uint96 amount, uint8 blocks)
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
        assertLe(state.varEwmaX32, uint64(1) << 62, "variance escaped its ceiling");
        assertLe(state.ofiEwmaX32, int64(uint64(1) << 32), "imbalance exceeded +1");
        assertGe(state.ofiEwmaX32, -int64(uint64(1) << 32), "imbalance fell below -1");
    }
}
