// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {MockReferenceOracle} from "../mocks/MockReferenceOracle.sol";
import {AssayConfig} from "../../src/config/AssayConfig.sol";
import {AssayHook} from "../../src/AssayHook.sol";

/// @dev The oracle is supplied at deployment and may be a third-party contract. The
///      interface forbids reverting, but the hook cannot depend on anyone honouring that,
///      so these exercise the hook's own defences rather than the adapter's.
contract HostileOracleTest is AssayTestBase {
    MockReferenceOracle internal hostile;
    AssayHook internal hostileHook;

    function setUp() public override {
        super.setUp();
        hostile = new MockReferenceOracle(
            TickMath.getSqrtPriceAtTick(0),
            true,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );

        AssayConfig memory config = _defaultConfig();
        config.referenceOracle = address(hostile);
        hostileHook = _deployHook(config);
        poolKey = _initialisePool(address(hostileHook));
        _addLiquidity();
    }

    function _swap() internal {
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
    }

    function test_OracleThatReverts_DoesNotRevertTheSwap() public {
        hostile.setShouldRevert(true);
        vm.roll(block.number + 1);
        _swap();
        assertFalse(hostileHook.poolState(poolKey.toId()).referenceFresh);
    }

    function test_OracleReturningBelowMinSqrtPrice_IsRejected() public {
        hostile.set(TickMath.MIN_SQRT_PRICE - 1, true);
        vm.roll(block.number + 1);
        _swap();
        assertFalse(hostileHook.poolState(poolKey.toId()).referenceFresh);
    }

    function test_OracleReturningAtMaxSqrtPrice_IsRejected() public {
        hostile.set(TickMath.MAX_SQRT_PRICE, true);
        vm.roll(block.number + 1);
        _swap();
        assertFalse(hostileHook.poolState(poolKey.toId()).referenceFresh);
    }

    /// @dev A source reporting its own reading unusable must be believed, even when the
    ///      price it returns alongside would otherwise be perfectly valid.
    function test_OracleReportingNotFresh_IsBelieved() public {
        hostile.set(TickMath.getSqrtPriceAtTick(500), false);
        vm.roll(block.number + 1);
        _swap();
        assertFalse(hostileHook.poolState(poolKey.toId()).referenceFresh);
    }

    function testFuzz_Swap_SurvivesAnyOracleReturn(uint160 sqrtPriceX96, bool fresh, bool reverts) public {
        hostile.set(sqrtPriceX96, fresh);
        hostile.setShouldRevert(reverts);
        vm.roll(block.number + 1);
        _swap();
    }
}
