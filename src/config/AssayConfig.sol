// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IAssayErrors} from "../interfaces/IAssayErrors.sol";
import {Q32x32} from "../libraries/Q32x32.sol";
import {VarianceEwma} from "../libraries/VarianceEwma.sol";

/// @notice Construction-time parameters for a hook deployment.
/// @dev Solidity cannot mark a struct `immutable`, so the hook stores these as individual
///      immutables. This struct exists to keep the constructor signature and its validation
///      in one auditable place. Fields are added by the milestone that first reads them;
///      a field no code consumes is a stub in another shape.
struct AssayConfig {
    uint24 baseFeePips;
    uint24 minFeePips;
    uint24 maxFeePips;
    uint64 varianceLambdaX32;
    uint64 ofiLambdaX32;
    int24 maxTickDeltaPerBlock;
    uint24 captureShareBps;
    address referenceOracle;
}

/// @notice Validation for `AssayConfig`.
library AssayConfigLib {
    /// @dev Smallest permitted `ONE - lambda`. Corresponds to a half-life of roughly 2,839
    ///      samples, well beyond any lookback this project uses.
    uint64 internal constant MIN_DECAY_GAP = 1 << 20;

    /// @dev A capture share above 100% would charge more than the drift being captured,
    ///      which deters the arbitrage entirely and leaves the pool stale. Zero disables the
    ///      response, which is a hook that does nothing.
    uint24 internal constant MAX_CAPTURE_SHARE_BPS = 10_000;

    /// @notice Reverts unless the fee bounds are internally consistent and within protocol limits.
    /// @dev One error per violated condition rather than a single generic failure, so a bad
    ///      deploy names the offending field instead of requiring a debugger.
    /// @param config The parameters to validate.
    function validate(AssayConfig memory config) internal pure {
        if (config.minFeePips == 0 || config.baseFeePips == 0 || config.maxFeePips == 0) {
            revert IAssayErrors.AssayHook__FeeIsZero();
        }
        if (config.minFeePips > config.baseFeePips) {
            revert IAssayErrors.AssayHook__MinFeeAboveBaseFee(config.minFeePips, config.baseFeePips);
        }
        if (config.baseFeePips > config.maxFeePips) {
            revert IAssayErrors.AssayHook__BaseFeeAboveMaxFee(config.baseFeePips, config.maxFeePips);
        }
        if (config.maxFeePips > LPFeeLibrary.MAX_LP_FEE) {
            revert IAssayErrors.AssayHook__MaxFeeAboveProtocolLimit(
                config.maxFeePips, LPFeeLibrary.MAX_LP_FEE
            );
        }
        if (config.captureShareBps == 0 || config.captureShareBps > MAX_CAPTURE_SHARE_BPS) {
            revert IAssayErrors.AssayHook__CaptureShareOutOfRange(
                config.captureShareBps, MAX_CAPTURE_SHARE_BPS
            );
        }
        if (config.referenceOracle == address(0)) {
            revert IAssayErrors.AssayHook__ReferenceOracleIsZeroAddress();
        }
        _validateDecay(config.varianceLambdaX32);
        _validateDecay(config.ofiLambdaX32);
        if (
            config.maxTickDeltaPerBlock <= 0
                || config.maxTickDeltaPerBlock > VarianceEwma.MAX_TICK_DELTA_CLAMP
        ) {
            revert IAssayErrors.AssayHook__TickDeltaClampOutOfRange(
                config.maxTickDeltaPerBlock, VarianceEwma.MAX_TICK_DELTA_CLAMP
            );
        }
    }

    /// @dev A decay of zero discards all history and a decay of one freezes the estimator.
    ///      The upper bound is tighter than one for a numerical reason: each update advances
    ///      the state by `floor((ONE - lambda) * (sample - state) / ONE)`, which rounds to
    ///      zero once `sample - state < ONE / (ONE - lambda)`. Too close to ONE and the
    ///      estimator stalls short of the sample and never converges -- at `ONE - 1` it
    ///      freezes after a single update, under-reporting by a factor of 4.29e9.
    ///      Requiring `ONE - lambda >= MIN_DECAY_GAP` caps that relative error near 1e-6.
    function _validateDecay(uint64 lambdaX32) private pure {
        if (lambdaX32 == 0 || lambdaX32 > Q32x32.ONE - MIN_DECAY_GAP) {
            revert IAssayErrors.AssayHook__LambdaOutOfRange(lambdaX32);
        }
    }
}
