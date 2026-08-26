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

    /// @dev A pool sitting exactly at its reference has no drift to price, so it quotes the
    ///      base fee. This is the anchor the surcharge is measured from.
    function test_Swap_AlignedPoolQuotesTheBaseFee() public {
        assertEq(_swap(true, -1 ether), BASE_FEE_PIPS, "an aligned pool must quote the base fee");
    }

    /// @dev The property the whole mechanism exists to provide: with the pool drifted from
    ///      its reference, the direction that captures that drift is quoted more than the
    ///      direction that does not. A volatility-conditioned fee cannot distinguish these.
    function test_Swap_QuotesDirectionsDifferentlyOnceThePoolHasDrifted() public {
        _swap(true, -1 ether);

        uint24 tradingAway = _swap(true, -0.001 ether);
        uint24 tradingBack = _swap(false, -0.001 ether);

        assertGt(tradingBack, tradingAway, "capturing drift must cost more than adding to it");
        assertGe(tradingAway, MIN_FEE_PIPS, "quote fell through the floor");
        assertLe(tradingBack, MAX_FEE_PIPS, "quote broke through the ceiling");
    }

    /// @dev The unspecified currency is the input on an exact-output swap, which is the case
    ///      the surcharge in a later milestone must handle correctly.
    /// @dev The unspecified currency is the input on an exact-output swap, which is the case
    ///      the surcharge in a later milestone must handle correctly.
    function test_Swap_AlignedPoolQuotesTheBaseFeeOnExactOutput() public {
        assertEq(_swap(true, 1 ether), BASE_FEE_PIPS, "exact output on an aligned pool");
    }

    /// @dev Every quote, whatever the drift, stays inside the configured bounds. This is
    ///      the invariant a router relies on when it reads `feeBounds()` before routing.
    function test_Swap_EveryQuoteInABlockStaysWithinBounds() public {
        uint24[3] memory quotes = [_swap(true, -0.5 ether), _swap(true, -0.5 ether), _swap(false, -0.5 ether)];

        for (uint256 i = 0; i < quotes.length; ++i) {
            assertGe(quotes[i], MIN_FEE_PIPS, "quote below floor");
            assertLe(quotes[i], MAX_FEE_PIPS, "quote above ceiling");
        }
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

    /// @dev Whatever the pool state, the quote the manager applies is inside the bounds the
    ///      hook advertises. A quote outside them would mean a router was misled.
    function testFuzz_Swap_QuoteAlwaysWithinAdvertisedBounds(bool zeroForOne, uint128 amount) public {
        amount = uint128(bound(amount, 0.0001 ether, 10 ether));
        uint24 charged = _swap(zeroForOne, -int256(uint256(amount)));

        assertGe(charged, MIN_FEE_PIPS, "quote below advertised floor");
        assertLe(charged, MAX_FEE_PIPS, "quote above advertised ceiling");
    }
}
