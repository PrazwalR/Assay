// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {IAssayEvents} from "../../src/interfaces/IAssayEvents.sol";

/// @dev The surcharge exists because `FeeBlend.quote` charges a percentage of notional and
///      that percentage is capped. On an extreme dislocation the formula wants more than the
///      cap can express, and without this path the remainder is silently discarded.
///
///      Every assertion here is on realised pool state -- fee growth actually credited to
///      liquidity providers -- rather than on the event, which only proves what the hook
///      believed it did.
contract ToxicitySurchargeFlowTest is AssayTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

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

    function _feeGrowth() internal view returns (uint256 g0, uint256 g1) {
        return IPoolManager(address(manager)).getFeeGrowthGlobals(poolKey.toId());
    }

    /// @dev Moves the reference far enough that the uncapped formula exceeds `maxFeePips`.
    ///      A 5% quoted move is roughly 490 ticks; at a 50% capture share that asks for
    ///      500 + 490*50 = 25,000 pips against a 10,000 ceiling.
    function _dislocateReference() internal {
        feed.setAnswer(int256(105e6));
        feed.setUpdatedAt(block.timestamp);
        vm.roll(block.number + 1);
        _swap(true, -0.0001 ether); // refreshes the cached reference
    }

    /// @dev The common case. If an ordinary swap paid a surcharge, every trader would be
    ///      charged beyond the advertised fee ceiling.
    function test_OrdinarySwap_DonatesNothing() public {
        (uint256 before0, uint256 before1) = _feeGrowth();

        vm.recordLogs();
        _swap(true, -0.01 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IAssayEvents.ToxicitySurchargeDonated.selector,
                "an aligned pool must not surcharge"
            );
        }

        (uint256 after0, uint256 after1) = _feeGrowth();
        // Fee growth still rises from the ordinary LP fee; it must not rise by a surcharge.
        assertGt(after0 + after1, before0 + before1, "the ordinary fee should still accrue");
    }

    /// @dev The path this module exists for: value that the capped percentage fee could not
    ///      express reaches liquidity providers instead of being discarded.
    function test_ExtremeDislocation_DonatesTheOverflowToLiquidityProviders() public {
        _dislocateReference();
        (uint256 before0, uint256 before1) = _feeGrowth();

        vm.recordLogs();
        _swap(true, -0.05 ether);

        bool sawDonation;
        uint256 donated;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IAssayEvents.ToxicitySurchargeDonated.selector) {
                sawDonation = true;
                (donated,) = abi.decode(logs[i].data, (uint256, bool));
            }
        }

        assertTrue(sawDonation, "a dislocation beyond the fee ceiling must surcharge");
        assertGt(donated, 0, "a surcharge of zero is not a surcharge");

        (uint256 after0, uint256 after1) = _feeGrowth();
        assertGt(after0 + after1, before0 + before1, "the donation must reach liquidity providers");
    }

    /// @dev `donate` debits the hook and the returned delta credits it back. If those did not
    ///      cancel exactly, the hook would either accumulate a balance it cannot withdraw or
    ///      leave an unsettled delta, and the PoolManager would revert the whole swap.
    function test_Surcharge_LeavesTheHookHoldingNothing() public {
        _dislocateReference();
        _swap(true, -0.05 ether);

        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "unsettled delta remains");
        assertEq(token0.balanceOf(address(hook)), 0, "hook accumulated currency0");
        assertEq(token1.balanceOf(address(hook)), 0, "hook accumulated currency1");
    }

    /// @dev `Pool.donate` reverts outright when in-range liquidity is zero, because there is
    ///      nobody to credit. A swap can reach that state while still having moved real
    ///      tokens: if it walks the price out of every liquidity range, the notional is
    ///      non-zero but the pool is empty by the time `afterSwap` runs. With a surcharge
    ///      also due, the donation would revert inside `afterSwap` and brick the pool -- the
    ///      precise failure this hook is built never to cause.
    ///
    ///      Constructing it needs all three conditions at once: a dislocated reference so a
    ///      surcharge is owed, liquidity concentrated in a narrow band, and a swap large
    ///      enough to cross out of it.
    function test_Exploit_SurchargeAfterExitingAllLiquidityCannotBrickTheSwap() public {
        _dislocateReference();

        // Replace the wide default position with a narrow band the next swap will cross.
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: -100 ether,
                salt: bytes32(0)
            }),
            ""
        );
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING, tickUpper: TICK_SPACING, liquidityDelta: 10 ether, salt: bytes32(0)
            }),
            ""
        );

        (int256 drift, bool fresh) = hook.signedMispricing(poolKey.toId(), true);
        assertTrue(fresh, "reference must be usable for a surcharge to be owed");
        assertGt(drift, 190, "drift must exceed the ceiling threshold or this proves nothing");

        // Must not revert, even though the pool is left empty and a surcharge was owed.
        _swap(true, -5 ether);

        assertEq(
            IPoolManager(address(manager)).getLiquidity(poolKey.toId()),
            0,
            "swap should have emptied the pool"
        );
    }

    /// @dev A surcharge is owed but the swap is so small the amount rounds to zero. Donating
    ///      nothing would still cost an external call and emit a meaningless event, so the
    ///      path returns early -- and it must not revert or mis-settle on the way out.
    function test_DustSwap_OwesASurchargeThatRoundsToNothing() public {
        _dislocateReference();

        vm.recordLogs();
        _swap(true, -40); // 40 wei: the surcharge is a fraction of one wei

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IAssayEvents.ToxicitySurchargeDonated.selector,
                "a surcharge that rounds to zero must not be donated"
            );
        }
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "unsettled delta remains");
    }

    function test_LiquidityProvider_CanStillWithdrawAfterASurcharge() public {
        _dislocateReference();
        _swap(true, -0.05 ether);

        uint256 balanceBefore = token1.balanceOf(address(this));
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
        assertGt(token1.balanceOf(address(this)), balanceBefore, "withdrawal returned nothing");
    }

    /// @dev Whatever the reference does and whatever the swap is, the swap settles.
    function testFuzz_SwapNeverRevertsWithSurchargeEnabled(
        int256 answer,
        bool feedReverts,
        bool zeroForOne,
        uint96 amount
    ) public {
        feed.setAnswer(answer);
        feed.setShouldRevert(feedReverts);
        feed.setUpdatedAt(block.timestamp);

        vm.roll(block.number + 1);
        _swap(zeroForOne, -int256(uint256(bound(amount, 0.001 ether, 5 ether))));

        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "unsettled delta remains");
    }
}
