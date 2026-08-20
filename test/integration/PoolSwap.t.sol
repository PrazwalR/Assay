// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapFeeEventAsserter} from "hookmate/test/utils/SwapFeeEventAsserter.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";

/// @dev Exercises a real swap against a real PoolManager. Assertions are made on the fee the
///      manager actually charged, decoded from its own Swap event, rather than on the value
///      the hook returned. The return value only proves what the hook said; the event proves
///      what the pool did.
contract PoolSwapTest_Integration is AssayTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (uint24 feeCharged) {
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
        Vm.Log[] memory logs = vm.getRecordedLogs();
        return SwapFeeEventAsserter.getSwapFeeFromEvent(logs);
    }

    function test_Swap_ChargesConfiguredBaseFee() public {
        assertEq(_swap(true, -1 ether), BASE_FEE_PIPS, "fee charged is not the configured base fee");
    }

    function test_Swap_ChargesBaseFeeInBothDirections() public {
        assertEq(_swap(true, -1 ether), BASE_FEE_PIPS, "zeroForOne");
        assertEq(_swap(false, -1 ether), BASE_FEE_PIPS, "oneForZero");
    }

    /// @dev The unspecified currency is the input on an exact-output swap, which is the case
    ///      the surcharge in a later milestone must handle correctly.
    function test_Swap_ChargesBaseFeeOnExactOutput() public {
        assertEq(_swap(true, 1 ether), BASE_FEE_PIPS, "exact output");
    }

    function test_Swap_ChargesBaseFeeForEverySwapInABlock() public {
        assertEq(_swap(true, -0.5 ether), BASE_FEE_PIPS, "first of block");
        assertEq(_swap(true, -0.5 ether), BASE_FEE_PIPS, "second of block");
        assertEq(_swap(false, -0.5 ether), BASE_FEE_PIPS, "third of block");
    }

    function test_AfterInitialize_SeedsStoredLpFee() public view {
        (,,, uint24 storedFee) = IPoolManager(address(manager)).getSlot0(poolKey.toId());
        assertEq(storedFee, BASE_FEE_PIPS, "stored lp fee was not seeded");
    }

    /// @dev Assay takes no liquidity permissions, so an LP must always be able to exit. A hook
    ///      that can trap liquidity is unshippable regardless of how good its pricing is.
    function test_LiquidityProvider_CanAlwaysWithdraw() public {
        uint256 balanceBefore = token0.balanceOf(address(this));
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: -50 ether,
                salt: bytes32(0)
            }),
            ""
        );
        assertGt(token0.balanceOf(address(this)), balanceBefore, "withdrawal returned nothing");
    }

    /// @dev A swap only settles if the hook leaves no unsettled delta. Any non-zero delta at
    ///      unlock makes the PoolManager revert, so completion is itself the assertion.
    function test_Swap_LeavesNoUnsettledDelta() public {
        _swap(true, -1 ether);
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "hook left an unsettled delta");
    }

    function testFuzz_Swap_AlwaysChargesBaseFee(bool zeroForOne, uint128 amount) public {
        amount = uint128(bound(amount, 0.0001 ether, 10 ether));
        assertEq(_swap(zeroForOne, -int256(uint256(amount))), BASE_FEE_PIPS);
    }
}
