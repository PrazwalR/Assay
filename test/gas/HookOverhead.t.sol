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
    // One budget was never honest: it described only the cheapest of three reachable paths,
    // and CI measured only that path. Each is now budgeted and measured separately.
    //
    // ORDINARY is the common case -- a swap that is not first in its block and triggers no
    // surcharge. This is what the original 40,000 figure was implicitly about.
    uint256 internal constant ORDINARY_BUDGET = 20_000;

    // BOUNDARY additionally refreshes the reference price. The tests read a mock aggregator;
    // a live Chainlink proxy measured 20,774 gas against the Base Sepolia ETH/USD feed
    // (`cast estimate` on the deployed adapter, less the 21,000 transaction base cost), so
    // production pays roughly REAL_FEED_PREMIUM more than these numbers show. The budget is
    // set against that real cost, not the mock's.
    uint256 internal constant REAL_FEED_PREMIUM = 16_500;
    uint256 internal constant BOUNDARY_BUDGET = 55_000;

    // SURCHARGE additionally calls donate(), a state-changing external call into the
    // PoolManager. It fires only on a dislocation large enough that the capped
    // percentage fee cannot express the drift, which is a tail event, not the common case.
    uint256 internal constant SURCHARGE_BUDGET = 55_000;

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

    /// @dev The block-boundary path: the reference refresh, the variance sample and up to
    ///      two events all live behind `state.lastBlock != block.number`, so a measurement
    ///      taken inside a single block never touches them.
    function test_Gas_BlockBoundaryOverhead() public {
        _measure(baselineKey);
        _measure(poolKey);

        vm.roll(block.number + 1);
        uint256 baseline = _measure(baselineKey);
        vm.roll(block.number + 1);
        uint256 withHook = _measure(poolKey);

        uint256 measured = withHook - baseline;
        uint256 projected = measured + REAL_FEED_PREMIUM;

        emit log_named_uint("boundary, mock feed     ", measured);
        emit log_named_uint("boundary, live feed est ", projected);
        emit log_named_uint("budget                  ", BOUNDARY_BUDGET);
        assertLt(projected, BOUNDARY_BUDGET, "boundary path exceeds the budget with a live feed");
    }

    /// @dev The surcharge path: `donate` plus its accounting only runs when drift exceeds
    ///      what the capped percentage fee can express.
    function test_Gas_SurchargeOverhead() public {
        // Warm both paths first; a cold baseline deflates the difference and would report
        // the surcharge as cheaper than the ordinary swap.
        _measure(baselineKey);
        _measure(poolKey);

        feed.setAnswer(int256(140e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _measure(poolKey);

        // Prove the scenario before measuring it. A surcharge test that never triggers a
        // surcharge measures the ordinary path and reports it as the expensive one.
        (int256 drift, bool fresh) = hook.signedMispricing(poolKey.toId(), true);
        emit log_named_int("drift at measurement", drift);
        emit log_named_string("reference fresh", fresh ? "yes" : "no");
        assertTrue(fresh, "reference must be usable");
        assertGt(drift, 190, "drift must exceed the ceiling threshold or no surcharge fires");

        uint256 baseline = _measure(baselineKey);
        uint256 withHook = _measure(poolKey);

        emit log_named_uint("surcharge overhead", withHook - baseline);
        emit log_named_uint("budget            ", SURCHARGE_BUDGET);
        assertLt(withHook - baseline, SURCHARGE_BUDGET, "surcharge path exceeds the budget");
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
        emit log_named_uint("ordinary overhead ", overhead);
        emit log_named_uint("budget            ", ORDINARY_BUDGET);

        assertLt(overhead, ORDINARY_BUDGET, "ordinary path exceeds the design budget");
    }
}
