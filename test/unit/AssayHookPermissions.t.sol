// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {IAssayErrors} from "../../src/interfaces/IAssayErrors.sol";

contract AssayHookPermissionsTest is AssayTestBase {
    /// @dev Permission bits live in the hook address, so this is the single assertion that
    ///      pins the deployed address shape. A drift here silently changes where the hook
    ///      deploys and breaks every recorded address.
    function test_HookAddress_CarriesExactlyTheDeclaredFlags() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS, "flag mask drifted");
    }

    function test_Permissions_MatchTheFiveRequiredCallbacks() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertTrue(p.beforeInitialize, "beforeInitialize");
        assertTrue(p.afterInitialize, "afterInitialize");
        assertTrue(p.beforeSwap, "beforeSwap");
        assertTrue(p.afterSwap, "afterSwap");
        assertTrue(p.afterSwapReturnDelta, "afterSwapReturnDelta");
    }

    /// @dev An unused permission is an audit finding, not a spare tyre. Every flag Assay does
    ///      not need is asserted false so one cannot be added without a deliberate change here.
    function test_Permissions_ClaimNoUnusedCallbacks() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertFalse(p.beforeAddLiquidity, "beforeAddLiquidity");
        assertFalse(p.afterAddLiquidity, "afterAddLiquidity");
        assertFalse(p.beforeRemoveLiquidity, "beforeRemoveLiquidity");
        assertFalse(p.afterRemoveLiquidity, "afterRemoveLiquidity");
        assertFalse(p.beforeDonate, "beforeDonate");
        assertFalse(p.afterDonate, "afterDonate");
        assertFalse(p.beforeSwapReturnDelta, "beforeSwapReturnDelta");
        assertFalse(p.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta");
        assertFalse(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta");
    }

    /// @dev LPs must never be trapped, so the hook takes no liquidity permissions at all.
    ///      Removal therefore cannot revert through hook logic; this is structural, not a check.
    function test_LiquidityRemoval_HasNoHookPath() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity, "hook intercepts removal");
    }

    function test_FeeBounds_ReportConstructorValues() public view {
        (uint24 base, uint24 min, uint24 max) = hook.feeBounds();
        assertEq(base, BASE_FEE_PIPS);
        assertEq(min, MIN_FEE_PIPS);
        assertEq(max, MAX_FEE_PIPS);
    }

    /// @dev The one safe revert path: it runs at pool creation, before any liquidity exists.
    function test_RevertWhen_PoolIsNotDynamicFee() public {
        PoolKey memory staticFeeKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IAssayErrors.AssayHook__PoolIsNotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticFeeKey, TickMath.getSqrtPriceAtTick(0));
    }
}
