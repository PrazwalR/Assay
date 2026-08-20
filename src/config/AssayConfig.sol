// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {IAssayErrors} from "../interfaces/IAssayErrors.sol";

/// @notice Construction-time parameters for a hook deployment.
/// @dev Solidity cannot mark a struct `immutable`, so the hook stores these as individual
///      immutables. This struct exists to keep the constructor signature and its validation
///      in one auditable place. Fields are added by the milestone that first reads them;
///      a field no code consumes is a stub in another shape.
struct AssayConfig {
    uint24 baseFeePips;
    uint24 minFeePips;
    uint24 maxFeePips;
}

/// @notice Validation for `AssayConfig`.
library AssayConfigLib {
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
    }
}
