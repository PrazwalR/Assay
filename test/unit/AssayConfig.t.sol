// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {AssayConfig, AssayConfigLib} from "../../src/config/AssayConfig.sol";
import {IAssayErrors} from "../../src/interfaces/IAssayErrors.sol";
import {Mispricing} from "../../src/libraries/Mispricing.sol";
import {Q32x32} from "../../src/libraries/Q32x32.sol";

contract AssayConfigTest is Test {
    address internal constant ORACLE = address(0xA55A4);
    uint24 internal constant DEVIATION_CAP = 20_000;
    uint64 internal constant TWAP_LAMBDA = 4_252_017_623; // 0.99 in Q32.32

    function _config(uint24 base, uint24 min, uint24 max) internal pure returns (AssayConfig memory) {
        return AssayConfig({
            baseFeePips: base,
            minFeePips: min,
            maxFeePips: max,
            captureShareBps: 5000,
            referenceOracle: ORACLE,
            maxReferenceDeviationTicks: DEVIATION_CAP,
            twapLambdaX32: TWAP_LAMBDA
        });
    }

    function test_Validate_AcceptsOrderedBounds() public pure {
        AssayConfigLib.validate(_config(500, 100, 10_000));
    }

    function test_Validate_AcceptsAllBoundsEqual() public pure {
        AssayConfigLib.validate(_config(500, 500, 500));
    }

    function test_Validate_AcceptsMaxAtProtocolLimit() public pure {
        AssayConfigLib.validate(_config(500, 100, LPFeeLibrary.MAX_LP_FEE));
    }

    function test_RevertWhen_MinFeeIsZero() public {
        vm.expectRevert(IAssayErrors.AssayHook__FeeIsZero.selector);
        this.validateExternal(_config(500, 0, 10_000));
    }

    function test_RevertWhen_BaseFeeIsZero() public {
        vm.expectRevert(IAssayErrors.AssayHook__FeeIsZero.selector);
        this.validateExternal(_config(0, 100, 10_000));
    }

    function test_RevertWhen_MaxFeeIsZero() public {
        vm.expectRevert(IAssayErrors.AssayHook__FeeIsZero.selector);
        this.validateExternal(_config(500, 100, 0));
    }

    function test_RevertWhen_MinFeeExceedsBaseFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__MinFeeAboveBaseFee.selector, uint24(501), uint24(500)
            )
        );
        this.validateExternal(_config(500, 501, 10_000));
    }

    function test_RevertWhen_BaseFeeExceedsMaxFee() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__BaseFeeAboveMaxFee.selector, uint24(500), uint24(499)
            )
        );
        this.validateExternal(_config(500, 100, 499));
    }

    function test_RevertWhen_MaxFeeExceedsProtocolLimit() public {
        uint24 tooLarge = LPFeeLibrary.MAX_LP_FEE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__MaxFeeAboveProtocolLimit.selector, tooLarge, LPFeeLibrary.MAX_LP_FEE
            )
        );
        this.validateExternal(_config(500, 100, tooLarge));
    }

    /// @dev Any triple that survives validation must satisfy the ordering the fee blend
    ///      relies on, across the whole domain rather than the handful of cases above.
    function testFuzz_Validate_AcceptsExactlyTheOrderedDomain(uint24 base, uint24 min, uint24 max) public {
        bool shouldPass =
            min != 0 && base != 0 && max != 0 && min <= base && base <= max && max <= LPFeeLibrary.MAX_LP_FEE;

        if (shouldPass) {
            AssayConfigLib.validate(_config(base, min, max));
        } else {
            vm.expectRevert();
            this.validateExternal(_config(base, min, max));
        }
    }

    function validateExternal(AssayConfig memory config) external pure {
        AssayConfigLib.validate(config);
    }

    function test_RevertWhen_CaptureShareIsZero() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.captureShareBps = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__CaptureShareOutOfRange.selector,
                uint24(0),
                AssayConfigLib.MAX_CAPTURE_SHARE_BPS
            )
        );
        this.validateExternal(c);
    }

    /// @dev A share above 100% charges more than the drift being captured, which deters the
    ///      arbitrage entirely and leaves the pool stale -- the failure mode the mechanism
    ///      exists to avoid.
    function test_RevertWhen_CaptureShareExceedsFullDrift() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.captureShareBps = AssayConfigLib.MAX_CAPTURE_SHARE_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__CaptureShareOutOfRange.selector,
                AssayConfigLib.MAX_CAPTURE_SHARE_BPS + 1,
                AssayConfigLib.MAX_CAPTURE_SHARE_BPS
            )
        );
        this.validateExternal(c);
    }

    function test_Validate_AcceptsCaptureShareAtFullDrift() public view {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.captureShareBps = AssayConfigLib.MAX_CAPTURE_SHARE_BPS;
        this.validateExternal(c);
    }

    /// @dev The mispricing signal is the hook's primary input, so a deployment with no
    ///      reference source cannot price anything and must fail at construction.
    function test_RevertWhen_ReferenceOracleIsUnset() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.referenceOracle = address(0);
        vm.expectRevert(IAssayErrors.AssayHook__ReferenceOracleIsZeroAddress.selector);
        this.validateExternal(c);
    }

    function test_Validate_AcceptsDeviationCapDisabled() public view {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.maxReferenceDeviationTicks = 0;
        this.validateExternal(c);
    }

    function test_Validate_AcceptsDeviationCapAtMispricingBound() public view {
        AssayConfig memory c = _config(500, 100, 10_000);
        // forge-lint: disable-next-line(unsafe-typecast)
        c.maxReferenceDeviationTicks = uint24(uint256(Mispricing.MAX_MISPRICING_TICKS));
        this.validateExternal(c);
    }

    /// @dev A cap larger than the mispricing clamp itself could never trip: no drift the rest
    ///      of the system computes ever exceeds that bound, so a deployer-supplied value past
    ///      it would look configured while silently doing nothing.
    function test_RevertWhen_DeviationCapExceedsMispricingBound() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint24 bound = uint24(uint256(Mispricing.MAX_MISPRICING_TICKS));
        c.maxReferenceDeviationTicks = bound + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__ReferenceDeviationCapTooLarge.selector, bound + 1, bound
            )
        );
        this.validateExternal(c);
    }

    /// @dev Zero discards all history every block, collapsing the average to a single-block
    ///      sample -- exactly what an attacker can move within one transaction, and exactly
    ///      what this estimator exists to resist. Required unconditionally, even when the
    ///      deviation cap itself is disabled: this lambda also drives the stored TWAP.
    function test_RevertWhen_TwapLambdaIsZero() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.twapLambdaX32 = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__TwapLambdaOutOfRange.selector, uint64(0), Q32x32.ONE
            )
        );
        this.validateExternal(c);
    }

    /// @dev Above ONE, blendSigned's own `ONE - lambda` subtraction wraps and every bound it
    ///      documents collapses.
    function test_RevertWhen_TwapLambdaExceedsOne() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.twapLambdaX32 = Q32x32.ONE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__TwapLambdaOutOfRange.selector, Q32x32.ONE + 1, Q32x32.ONE
            )
        );
        this.validateExternal(c);
    }

    function test_Validate_AcceptsTwapLambdaAtOne() public view {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.twapLambdaX32 = Q32x32.ONE;
        this.validateExternal(c);
    }
}
