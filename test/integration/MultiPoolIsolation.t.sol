// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {PoolState} from "../../src/types/PoolState.sol";

/// @dev One hook serves many pools, and all of their state lives in a single mapping keyed
///      by PoolId. Nothing about that keying is enforced by the type system: a function that
///      derived the key wrongly, or cached a PoolId across calls, would let one pool's swaps
///      corrupt another's fee. These are the tests that would fail if that ever happened.
contract MultiPoolIsolationTest is AssayTestBase {
    using StateLibrary for IPoolManager;

    PoolKey internal secondKey;

    function setUp() public override {
        super.setUp();

        // A second pool over the same currency pair, distinguished only by tick spacing, so
        // it is a different PoolId while remaining attachable to the same oracle binding.
        secondKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING * 2,
            hooks: IHooks(address(hook))
        });
        manager.initialize(secondKey, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(
            secondKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 200,
                tickUpper: TICK_SPACING * 200,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_TwoPoolsHaveDistinctIds() public view {
        assertTrue(
            PoolId.unwrap(poolKey.toId()) != PoolId.unwrap(secondKey.toId()),
            "the two pools must be distinct or this suite proves nothing"
        );
    }

    /// @dev The core isolation property: swapping one pool must not move the other's state.
    function test_SwappingOnePoolLeavesTheOthersStateUntouched() public {
        PoolState memory before = hook.poolState(secondKey.toId());

        _swap(poolKey, true, -5 ether);
        _swap(poolKey, false, -2 ether);

        PoolState memory unchangedState = hook.poolState(secondKey.toId());
        assertEq(unchangedState.lastTick, before.lastTick, "lastTick leaked across pools");
        assertEq(unchangedState.referenceTick, before.referenceTick, "referenceTick leaked");
        assertEq(unchangedState.lastBlock, before.lastBlock, "lastBlock leaked");
    }

    /// @dev Two pools drifted in opposite directions must be quoted independently. If the
    ///      mapping key were wrong, the second pool would inherit the first pool's drift and
    ///      both would quote the same fee.
    function test_PoolsDriftedOppositelyAreQuotedIndependently() public {
        // Push one pool down and the other up, within the same block.
        _swap(poolKey, true, -5 ether);
        _swap(secondKey, false, -5 ether);

        (int256 firstDrift,) = hook.signedMispricing(poolKey.toId(), true);
        (int256 secondDrift,) = hook.signedMispricing(secondKey.toId(), true);

        assertTrue(firstDrift != secondDrift, "pools drifted oppositely must not share a drift");

        // The first pool was pushed BELOW the reference, so a further zeroForOne swap moves
        // it further away and captures nothing: negative drift. The second was pushed ABOVE,
        // so a zeroForOne swap moves it back toward the reference and does capture: positive.
        // The signs being opposite is the isolation being proven; a shared mapping key would
        // give both the same value.
        assertLt(firstDrift, 0, "a swap moving further from the reference captures nothing");
        assertGt(secondDrift, 0, "a swap moving back toward the reference captures drift");
    }

    /// @dev Each pool's reference refresh is tracked separately. A shared block marker would
    ///      let a swap on one pool suppress the other's refresh for that block.
    function test_EachPoolRefreshesItsOwnReference() public {
        vm.roll(block.number + 1);
        _swap(poolKey, true, -0.001 ether);

        // The first pool has now refreshed in this block; the second has not.
        assertEq(hook.poolState(poolKey.toId()).lastBlock, uint32(block.number), "first refreshed");
        assertTrue(
            hook.poolState(secondKey.toId()).lastBlock != uint32(block.number),
            "the second pool must not be marked refreshed by the first pool's swap"
        );

        feed.setAnswer(int256(130e6));
        feed.setUpdatedAt(block.timestamp);
        _swap(secondKey, true, -0.001 ether);

        // The second pool picks up the new price even though the first already refreshed.
        assertTrue(
            hook.poolState(secondKey.toId()).referenceTick != hook.poolState(poolKey.toId()).referenceTick,
            "the second pool did not refresh independently"
        );
    }

    function testFuzz_InterleavedSwapsKeepPoolStatesDistinct(uint96 amount, uint8 rounds) public {
        amount = uint96(bound(amount, 0.001 ether, 1 ether));
        uint256 n = bound(rounds, 1, 5);

        for (uint256 i = 0; i < n; ++i) {
            _swap(poolKey, true, -int256(uint256(amount)));
            _swap(secondKey, false, -int256(uint256(amount)));
            vm.roll(block.number + 1);
        }

        // Driven in opposite directions throughout, so their ticks must not have converged.
        assertTrue(
            hook.poolState(poolKey.toId()).lastTick != hook.poolState(secondKey.toId()).lastTick,
            "pools driven oppositely converged, which means state is shared"
        );
    }
}
