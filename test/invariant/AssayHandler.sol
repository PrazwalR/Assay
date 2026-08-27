// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SwapFeeEventAsserter} from "hookmate/test/utils/SwapFeeEventAsserter.sol";

import {AssayHook} from "../../src/AssayHook.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice Drives the hook through random but *reachable* sequences for the invariant suite.
/// @dev Every action here is something an ordinary user, liquidity provider, or the outside
///      world can actually do. The point of a handler is to explore orderings a human would
///      not think to write down, so the actions are deliberately unconstrained relative to
///      each other -- but each one individually is bounded to stay reachable, because an
///      invariant that only breaks under an impossible input teaches nothing.
///
///      Ghost variables record what the handler observed so the invariants can assert
///      properties of the *whole run* rather than of a single final state.
contract AssayHandler is CommonBase, StdCheats, StdUtils {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable MANAGER;
    AssayHook public immutable HOOK;
    PoolSwapTest public immutable SWAP_ROUTER;
    PoolModifyLiquidityTest public immutable LIQUIDITY_ROUTER;
    MockAggregatorV3 public immutable FEED;
    PoolKey internal poolKey;
    int24 internal immutable TICK_SPACING;

    // --- ghosts -------------------------------------------------------------------------

    /// @dev Widest fee the PoolManager was ever observed to actually charge.
    uint24 public maxFeeObserved;
    /// @dev Narrowest fee ever charged. Seeded above any legal fee so the first swap lowers it.
    uint24 public minFeeObserved = type(uint24).max;
    uint256 public swapCount;
    uint256 public liquidityOpCount;
    /// @dev Liquidity added minus removed, so a test can assert providers are never trapped.
    int256 public netLiquidityAdded;
    /// @dev One position per add. `PoolModifyLiquidityTest` asserts a deposit never credits
    ///      the caller, but v4 settles a position's accrued fees when you add to it, so
    ///      adding to a position that has earned fees trips that assert. Giving every add a
    ///      fresh salt keeps each deposit clean and lets `fail_on_revert` stay true, which
    ///      is the stronger setting: a genuine hook revert still aborts the run.
    bytes32[] internal positions;
    uint256 internal positionNonce;
    /// @dev Whether the reference was ever usable. A reference that has never been valid may
    ///      legitimately still hold its seeded zero; one that was valid must retain its
    ///      last reading when it goes stale.
    bool public referenceWasEverFresh;

    constructor(
        IPoolManager manager,
        AssayHook hook,
        PoolSwapTest swapRouter,
        PoolModifyLiquidityTest liquidityRouter,
        MockAggregatorV3 feed,
        PoolKey memory poolKey_,
        int24 tickSpacing
    ) {
        MANAGER = manager;
        HOOK = hook;
        SWAP_ROUTER = swapRouter;
        LIQUIDITY_ROUTER = liquidityRouter;
        FEED = feed;
        poolKey = poolKey_;
        TICK_SPACING = tickSpacing;
    }

    function key() external view returns (PoolKey memory) {
        return poolKey;
    }

    /// @dev Bounded so the swap cannot exhaust the pool's liquidity and revert in the router
    ///      before the hook is ever consulted. `fail_on_revert = true` means such a revert
    ///      would abort the run rather than exercise anything.
    function swap(uint96 amount, bool zeroForOne) external {
        uint256 size = bound(amount, 0.0001 ether, 3 ether);

        SWAP_ROUTER.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // `size` is bounded to at most 3 ether, far inside int256.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: -int256(size),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        _recordFee();
        _recordReference();
        swapCount++;
    }

    /// @dev Exact-output swaps take the opposite branch when identifying the unspecified
    ///      currency, which is the branch the surcharge depends on.
    function swapExactOutput(uint96 amount, bool zeroForOne) external {
        uint256 size = bound(amount, 0.0001 ether, 1 ether);

        SWAP_ROUTER.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                // `size` is bounded to at most 1 ether, far inside int256.
                // forge-lint: disable-next-line(unsafe-typecast)
                amountSpecified: int256(size),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        _recordFee();
        _recordReference();
        swapCount++;
    }

    function addLiquidity(uint96 amount) external {
        int256 delta = int256(bound(amount, 1 ether, 50 ether));
        bytes32 salt = bytes32(++positionNonce);
        _modifyLiquidity(delta, salt);
        positions.push(salt);
        netLiquidityAdded += delta;
    }

    /// @dev Closes one whole position rather than part of it: a partial removal can round
    ///      both token deltas to zero, which the same router asserts against.
    function removeLiquidity(uint96 selector) external {
        if (positions.length == 0) return;

        uint256 index = bound(selector, 0, positions.length - 1);
        bytes32 salt = positions[index];
        (uint128 liquidity,,) = MANAGER.getPositionInfo(
            poolKey.toId(), address(LIQUIDITY_ROUTER), -TICK_SPACING * 100, TICK_SPACING * 100, salt
        );
        if (liquidity == 0) return;

        _modifyLiquidity(-int256(uint256(liquidity)), salt);
        positions[index] = positions[positions.length - 1];
        positions.pop();
        netLiquidityAdded -= int256(uint256(liquidity));
    }

    /// @dev Moves the reference price. The hook must survive any value the outside world
    ///      produces, including ones that make the drift enormous.
    function moveReference(uint72 answer) external {
        FEED.setAnswer(int256(uint256(bound(answer, 1, 1e12))));
        FEED.setUpdatedAt(block.timestamp);
    }

    /// @dev Lets the feed go stale without touching it, which is the degradation path.
    function ageReference(uint32 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 30 days));
    }

    function breakReference(bool shouldRevert) external {
        FEED.setShouldRevert(shouldRevert);
    }

    /// @dev Advances blocks so the once-per-block reference refresh is exercised, and so
    ///      sequences span block boundaries rather than all landing in one.
    function advanceBlocks(uint8 blocks) external {
        vm.roll(block.number + bound(blocks, 1, 5));
        vm.warp(block.timestamp + 12);
    }

    function _modifyLiquidity(int256 delta, bytes32 salt) internal {
        LIQUIDITY_ROUTER.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: delta,
                salt: salt
            }),
            ""
        );
        liquidityOpCount++;
    }

    function _recordReference() internal {
        if (HOOK.poolState(poolKey.toId()).referenceFresh) {
            referenceWasEverFresh = true;
        }
    }

    /// @dev Records the fee the PoolManager actually applied, read from its own Swap event.
    ///      The hook's return value would only prove what the hook said.
    function _recordFee() internal {
        uint24 fee = SwapFeeEventAsserter.getSwapFeeFromEvent(vm.getRecordedLogs());
        if (fee > maxFeeObserved) maxFeeObserved = fee;
        if (fee < minFeeObserved) minFeeObserved = fee;
        vm.recordLogs();
    }
}
