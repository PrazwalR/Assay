// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IAssayErrors} from "../interfaces/IAssayErrors.sol";
import {Mispricing} from "../libraries/Mispricing.sol";
import {Q32x32} from "../libraries/Q32x32.sol";

/// @notice Construction-time parameters for a hook deployment.
/// @dev Stored individually by the hook, since a struct cannot be `immutable`.
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
    /// @dev Above 100% deters the arbitrage entirely; zero is a hook that does nothing.
    uint24 internal constant MAX_CAPTURE_SHARE_BPS = 10_000;

    /// @notice Reverts unless the config is internally consistent and within protocol limits.
    /// @dev One error per condition, so a bad deploy names the offending field.
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
        // A cap above the mispricing clamp could never trip. Zero means disabled.
        if (
            config.maxReferenceDeviationTicks != 0
                && config.maxReferenceDeviationTicks > uint256(Mispricing.MAX_MISPRICING_TICKS)
        ) {
            revert IAssayErrors.AssayHook__ReferenceDeviationCapTooLarge(
                config.maxReferenceDeviationTicks, uint24(uint256(Mispricing.MAX_MISPRICING_TICKS))
            );
        }
        // Checked even when the cap is disabled: lambda also drives the stored TWAP. Zero
        // would forget all history every block -- a single-block sample.
        if (config.twapLambdaX32 == 0 || config.twapLambdaX32 > Q32x32.ONE) {
            revert IAssayErrors.AssayHook__TwapLambdaOutOfRange(config.twapLambdaX32, Q32x32.ONE);
        }
    }
}
