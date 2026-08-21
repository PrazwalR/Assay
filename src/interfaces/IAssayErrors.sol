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

    /// @notice An EWMA decay factor was outside the open interval (0, 1) in Q32.32, which
    ///         would either freeze the estimator or discard all history.
    error AssayHook__LambdaOutOfRange(uint64 lambdaX32);

    /// @notice The per-block tick-delta clamp was zero or above the bound that keeps the
    ///         variance EWMA provably free of overflow.
    error AssayHook__TickDeltaClampOutOfRange(int24 maxTickDelta, int24 upperBound);

    /// @notice A value could not be represented in Q32.32 without truncation.
    error AssayHook__FixedPointOverflow(uint256 value);
}
