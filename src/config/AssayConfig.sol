// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IAssayErrors} from "../interfaces/IAssayErrors.sol";
import {Mispricing} from "../libraries/Mispricing.sol";
import {Q32x32} from "../libraries/Q32x32.sol";

/// @notice Construction-time parameters for a hook deployment.
/// @dev Solidity cannot mark a struct `immutable`, so the hook stores these individually.
///      This keeps the constructor signature and its validation in one auditable place.
struct AssayConfig {
    uint24 baseFeePips;
    uint24 minFeePips;
    uint24 maxFeePips;
    uint24 captureShareBps;
    address referenceOracle;
    uint24 maxReferenceDeviationTicks;
    uint64 twapLambdaX32;
}

/// @notice Validation for `AssayConfig`.
library AssayConfigLib {
    /// @dev A capture share above 100% would charge more than the drift being captured,
    ///      which deters the arbitrage entirely and leaves the pool stale. Zero disables the
    ///      response, which is a hook that does nothing.
    uint24 internal constant MAX_CAPTURE_SHARE_BPS = 10_000;

    /// @notice Reverts unless the fee bounds are internally consistent and within protocol limits.
    /// @dev One error per violated condition rather than a single generic failure, so a bad
    ///      deploy names the offending field instead of requiring a debugger.
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
        // A cap larger than the mispricing clamp itself could never trip: no drift the rest
        // of the system computes ever exceeds Mispricing.MAX_MISPRICING_TICKS. Zero is
        // exempted deliberately -- it is the documented "cap disabled" value, not a bound to
        // check against this ceiling.
        if (
            config.maxReferenceDeviationTicks != 0
                && config.maxReferenceDeviationTicks > uint256(Mispricing.MAX_MISPRICING_TICKS)
        ) {
            revert IAssayErrors.AssayHook__ReferenceDeviationCapTooLarge(
                config.maxReferenceDeviationTicks, uint24(uint256(Mispricing.MAX_MISPRICING_TICKS))
            );
        }
        // Required unconditionally, even when the cap above is disabled: this lambda also
        // drives the stored TWAP itself, and a value outside blendSigned's precondition
        // corrupts that average regardless of whether anything currently checks it against a
        // bound. Zero would mean "forget all history every block", which is a single-block
        // sample -- exactly what an attacker can move within one transaction, and exactly
        // what this estimator exists to be resistant to.
        if (config.twapLambdaX32 == 0 || config.twapLambdaX32 > Q32x32.ONE) {
            revert IAssayErrors.AssayHook__TwapLambdaOutOfRange(config.twapLambdaX32, Q32x32.ONE);
        }
    }
}
