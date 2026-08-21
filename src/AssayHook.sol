// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {AssayConfig, AssayConfigLib} from "./config/AssayConfig.sol";
import {IAssayErrors} from "./interfaces/IAssayErrors.sol";
import {IAssayEvents} from "./interfaces/IAssayEvents.sol";
import {OrderFlowImbalance} from "./libraries/OrderFlowImbalance.sol";
import {VarianceEwma} from "./libraries/VarianceEwma.sol";
import {PoolState} from "./types/PoolState.sol";

/// @title AssayHook
/// @notice A Uniswap v4 hook that prices adverse selection per swap rather than per pool.
/// @dev This contract performs no arithmetic. It reads state, delegates every formula to a
///      pure library, writes state, and returns values. That separation is what makes the
///      math independently fuzzable without a PoolManager.
///
///      At this milestone the hook maintains realised variance and order-flow imbalance per
///      pool and publishes both, but still quotes the configured base fee: the fee curve
///      that consumes them is blocked on parameters that must be estimated from data.
contract AssayHook is BaseHook, IAssayErrors, IAssayEvents {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    uint24 private immutable BASE_FEE_PIPS;
    uint24 private immutable MIN_FEE_PIPS;
    uint24 private immutable MAX_FEE_PIPS;
    uint64 private immutable VARIANCE_LAMBDA_X32;
    uint64 private immutable OFI_LAMBDA_X32;
    int24 private immutable MAX_TICK_DELTA_PER_BLOCK;

    mapping(PoolId poolId => PoolState) private _poolState;

    /// @notice Deploys the hook against a PoolManager with validated parameters.
    /// @dev The address this deploys to must carry exactly the permission bits returned by
    ///      `getHookPermissions`; `BaseHook` enforces that in its constructor, so deployment
    ///      requires a mined CREATE2 salt.
    /// @param poolManager The v4 PoolManager singleton this hook serves.
    /// @param config Fee bounds and estimator parameters, validated before any immutable is set.
    constructor(IPoolManager poolManager, AssayConfig memory config) BaseHook(poolManager) {
        AssayConfigLib.validate(config);
        BASE_FEE_PIPS = config.baseFeePips;
        MIN_FEE_PIPS = config.minFeePips;
        MAX_FEE_PIPS = config.maxFeePips;
        VARIANCE_LAMBDA_X32 = config.varianceLambdaX32;
        OFI_LAMBDA_X32 = config.ofiLambdaX32;
        MAX_TICK_DELTA_PER_BLOCK = config.maxTickDeltaPerBlock;
    }

    /// @notice The permissions this hook requires, and no others.
    /// @dev `afterSwapReturnDelta` is claimed now although the surcharge that uses it lands in
    ///      a later milestone. Permission bits are encoded in the hook address, so adding one
    ///      later would change the address and invalidate every deployment and integration.
    /// @return permissions The v4 permission set, corresponding to address mask 0x30C4.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice The fee bounds this hook was deployed with, in hundredths of a bip.
    /// @dev Exposed because a router or LP needs to know the worst fee a swap can be quoted
    ///      before routing into the pool.
    /// @return baseFeePips The fee quoted when no adverse-selection signal applies.
    /// @return minFeePips The floor of any quoted fee.
    /// @return maxFeePips The ceiling of any quoted fee.
    function feeBounds() external view returns (uint24 baseFeePips, uint24 minFeePips, uint24 maxFeePips) {
        return (BASE_FEE_PIPS, MIN_FEE_PIPS, MAX_FEE_PIPS);
    }

    /// @notice The estimator parameters this hook was deployed with.
    /// @dev Published so an integrator can reproduce the hook's state off chain, and so the
    ///      deployed values can be checked against the calibration artifact that produced them.
    /// @return varianceLambdaX32 Variance EWMA decay, Q32.32.
    /// @return ofiLambdaX32 Order-flow EWMA decay, Q32.32.
    /// @return maxTickDeltaPerBlock The per-block tick move beyond which samples are clamped.
    function estimatorParameters()
        external
        view
        returns (uint64 varianceLambdaX32, uint64 ofiLambdaX32, int24 maxTickDeltaPerBlock)
    {
        return (VARIANCE_LAMBDA_X32, OFI_LAMBDA_X32, MAX_TICK_DELTA_PER_BLOCK);
    }

    /// @notice Current microstructure state for a pool.
    /// @param poolId The pool to read.
    /// @return state Last observed tick and block, realised variance, and order-flow imbalance.
    function poolState(PoolId poolId) external view returns (PoolState memory state) {
        return _poolState[poolId];
    }

    /// @dev Rejects pools that cannot have their fee overridden. This is the only revert path
    ///      in the hook, and it is safe because it runs at pool creation, before any liquidity
    ///      exists. A revert on the swap path would brick the pool for every LP.
    function _beforeInitialize(address, PoolKey calldata key, uint160)
        internal
        pure
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert AssayHook__PoolIsNotDynamicFee();
        return this.beforeInitialize.selector;
    }

    /// @dev Seeds the pool's fee and the tick the first variance sample will measure against.
    ///      Variance and imbalance start at zero, which is the correct prior: no move has been
    ///      observed yet, and any non-zero seed would be an invented measurement.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        _poolState[poolId] = PoolState({
            lastTick: tick, blockOpenTick: tick, lastBlock: uint32(block.number), varEwmaX32: 0, ofiEwmaX32: 0
        });

        emit PoolRegistered(poolId, BASE_FEE_PIPS);
        poolManager.updateDynamicLPFee(key, BASE_FEE_PIPS);
        return this.afterInitialize.selector;
    }

    /// @dev Quotes the fee for this swap. Returns no delta: Assay never takes custody of swap
    ///      principal, which is the highest-severity finding class in v4 hook audits.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            BASE_FEE_PIPS | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /// @dev Folds this swap into the pool's microstructure state.
    ///
    ///      Variance advances only on the first swap of a block. Sampling per swap would let
    ///      an attacker move the price within one block, inflate the estimate, and so choose
    ///      their own fee; sampling at block boundaries means the only observable is the
    ///      block's net move, which costs real money to produce.
    ///
    ///      Order-flow imbalance advances on every swap, because its signal is the persistence
    ///      of direction across individual orders rather than the net move.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolState memory state = _poolState[poolId];

        // Only the price and tick are needed; the protocol and LP fee fields of slot0 are
        // deliberately discarded. One read serves both estimators, which is why slot0 is
        // fetched rather than the tick alone.
        // slither-disable-next-line unused-return
        (uint160 sqrtPriceX96, int24 tickNow,,) = poolManager.getSlot0(poolId);

        // A new block closes the previous observation period. The sample is that period's
        // net move -- where it closed against where it opened -- not the move produced by
        // whichever swap arrived first. Sampling against the first swap's own outcome lets an
        // attacker inject one displacement twice; see the note on PoolState.
        if (state.lastBlock != uint32(block.number)) {
            bool clamped;
            (state.varEwmaX32, clamped) = VarianceEwma.update(
                state.varEwmaX32,
                state.lastTick,
                state.blockOpenTick,
                MAX_TICK_DELTA_PER_BLOCK,
                VARIANCE_LAMBDA_X32
            );
            if (clamped) {
                emit TickDeltaClamped(
                    poolId, int256(state.lastTick) - int256(state.blockOpenTick), MAX_TICK_DELTA_PER_BLOCK
                );
            }
            state.blockOpenTick = state.lastTick;
            state.lastBlock = uint32(block.number);
        }
        state.lastTick = tickNow;

        uint128 liquidity = poolManager.getLiquidity(poolId);
        state.ofiEwmaX32 = OrderFlowImbalance.update(
            state.ofiEwmaX32,
            delta.amount1(),
            OrderFlowImbalance.virtualReserve(liquidity, sqrtPriceX96),
            OFI_LAMBDA_X32
        );

        _poolState[poolId] = state;

        emit SwapAssayed(poolId, sender, BASE_FEE_PIPS, state.varEwmaX32, state.ofiEwmaX32);
        return (this.afterSwap.selector, int128(0));
    }
}
