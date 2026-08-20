// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";

/// @dev Measures the hook's marginal cost on the swap path against an identical hookless pool.
///      The budget in the design is 40,000 gas for beforeSwap and afterSwap combined; this is
///      the measurement that holds that number honest as the pricing loop is built out.
contract HookOverheadTest is AssayTestBase {
    uint256 internal constant GAS_BUDGET = 40_000;

    PoolKey internal baselineKey;

    function setUp() public override {
        super.setUp();

        baselineKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: BASE_FEE_PIPS,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(baselineKey, TickMath.getSqrtPriceAtTick(0));
        liquidityRouter.modifyLiquidity(
            baselineKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _measure(PoolKey memory key) internal returns (uint256 gasUsed) {
        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 before = gasleft();
        swapRouter.swap(key, params, settings, "");
        gasUsed = before - gasleft();
    }

    function test_Gas_HookOverheadWithinBudget() public {
        // The first swap against any pool pays cold account and storage access on the router,
        // tokens and manager. Warming both paths first isolates the hook's marginal cost from
        // that one-off, which otherwise swamps the measurement.
        _measure(baselineKey);
        _measure(poolKey);

        uint256 baseline = _measure(baselineKey);
        uint256 withHook = _measure(poolKey);
        assertGt(withHook, baseline, "hooked swap must cost more than a hookless one");
        uint256 overhead = withHook - baseline;

        emit log_named_uint("swap without hook ", baseline);
        emit log_named_uint("swap with hook    ", withHook);
        emit log_named_uint("hook overhead     ", overhead);
        emit log_named_uint("budget            ", GAS_BUDGET);

        assertLt(overhead, GAS_BUDGET, "hook overhead exceeds the design budget");
    }
}
