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

    /// @notice The share of captured drift to charge was zero or above 100%.
    error AssayHook__CaptureShareOutOfRange(uint24 captureShareBps, uint24 upperBound);

    /// @notice The pool's currencies are not the pair the reference source prices, so the
    ///         hook has no usable view of this pool's fair value.
    error AssayHook__PoolDoesNotMatchReference(
        address expectedCurrency0, address expectedCurrency1, address actualCurrency0, address actualCurrency1
    );

    /// @notice No reference price source was configured. The mispricing signal is the
    ///         hook's primary input, so a deployment without one cannot price anything.
    error AssayHook__ReferenceOracleIsZeroAddress();

    /// @notice `maxReferenceDeviationTicks` exceeds the largest drift the rest of the system
    ///         ever computes, so a cap that large could never trip.
    error AssayHook__ReferenceDeviationCapTooLarge(uint24 maxReferenceDeviationTicks, uint24 upperBound);

    /// @notice The TWAP decay factor was zero or above `Q32x32.ONE`. Zero discards all
    ///         history every block, which defeats the manipulation resistance the estimator
    ///         exists for; above `ONE` the blend's own subtraction wraps.
    error AssayHook__TwapLambdaOutOfRange(uint64 twapLambdaX32, uint64 upperBound);
}
