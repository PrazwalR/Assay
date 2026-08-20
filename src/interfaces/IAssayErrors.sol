// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Every revert reason Assay can produce, declared in one place so the full
///         failure surface is auditable without reading the implementation.
interface IAssayErrors {
    /// @notice The pool was not created with the dynamic-fee flag, so the hook could
    ///         never override its fee.
    error AssayHook__PoolIsNotDynamicFee();

    /// @notice `minFeePips` exceeds `baseFeePips`.
    error AssayHook__MinFeeAboveBaseFee(uint24 minFeePips, uint24 baseFeePips);

    /// @notice `baseFeePips` exceeds `maxFeePips`.
    error AssayHook__BaseFeeAboveMaxFee(uint24 baseFeePips, uint24 maxFeePips);

    /// @notice `maxFeePips` exceeds the protocol ceiling of 100%.
    error AssayHook__MaxFeeAboveProtocolLimit(uint24 maxFeePips, uint24 protocolLimit);

    /// @notice A fee bound was configured as zero, which would quote a free swap.
    error AssayHook__FeeIsZero();
}
