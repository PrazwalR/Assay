// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {AssayConfig, AssayConfigLib} from "../../src/config/AssayConfig.sol";
import {IAssayErrors} from "../../src/interfaces/IAssayErrors.sol";
import {Q32x32} from "../../src/libraries/Q32x32.sol";
import {VarianceEwma} from "../../src/libraries/VarianceEwma.sol";

contract AssayConfigTest is Test {
    uint64 internal constant VALID_LAMBDA = 4_037_269_258;
    address internal constant ORACLE = address(0xA55A4);

    function _config(uint24 base, uint24 min, uint24 max) internal pure returns (AssayConfig memory) {
        return AssayConfig({
            baseFeePips: base,
            minFeePips: min,
            maxFeePips: max,
            varianceLambdaX32: VALID_LAMBDA,
            ofiLambdaX32: VALID_LAMBDA,
            maxTickDeltaPerBlock: 1000,
            captureShareBps: 5000,
            referenceOracle: ORACLE
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

    function _withDecay(uint64 varianceLambda, uint64 ofiLambda)
        internal
        pure
        returns (AssayConfig memory c)
    {
        c = _config(500, 100, 10_000);
        c.varianceLambdaX32 = varianceLambda;
        c.ofiLambdaX32 = ofiLambda;
    }

    function test_RevertWhen_VarianceDecayIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IAssayErrors.AssayHook__LambdaOutOfRange.selector, uint64(0)));
        this.validateExternal(_withDecay(0, VALID_LAMBDA));
    }

    function test_RevertWhen_VarianceDecayIsOne() public {
        vm.expectRevert(abi.encodeWithSelector(IAssayErrors.AssayHook__LambdaOutOfRange.selector, Q32x32.ONE));
        this.validateExternal(_withDecay(Q32x32.ONE, VALID_LAMBDA));
    }

    /// @dev Regression: a decay this close to ONE makes each update round to zero, so the
    ///      estimator freezes after one sample. Validation now rejects the stalling region
    ///      rather than only the exact endpoint.
    function test_RevertWhen_DecayIsCloseEnoughToOneToStall() public {
        uint64 stalling = Q32x32.ONE - 1;
        vm.expectRevert(abi.encodeWithSelector(IAssayErrors.AssayHook__LambdaOutOfRange.selector, stalling));
        this.validateExternal(_withDecay(stalling, VALID_LAMBDA));
    }

    function test_Validate_AcceptsDecayAtTheStallBoundary() public view {
        this.validateExternal(_withDecay(Q32x32.ONE - AssayConfigLib.MIN_DECAY_GAP, VALID_LAMBDA));
    }

    /// @dev The mispricing signal is the hook's primary input, so a deployment with no
    ///      reference source cannot price anything and must fail at construction.
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

    function test_RevertWhen_ReferenceOracleIsUnset() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.referenceOracle = address(0);
        vm.expectRevert(IAssayErrors.AssayHook__ReferenceOracleIsZeroAddress.selector);
        this.validateExternal(c);
    }

    function test_RevertWhen_OrderFlowDecayIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IAssayErrors.AssayHook__LambdaOutOfRange.selector, uint64(0)));
        this.validateExternal(_withDecay(VALID_LAMBDA, 0));
    }

    function test_RevertWhen_TickDeltaClampIsZero() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.maxTickDeltaPerBlock = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__TickDeltaClampOutOfRange.selector,
                int24(0),
                VarianceEwma.MAX_TICK_DELTA_CLAMP
            )
        );
        this.validateExternal(c);
    }

    /// @dev Above this bound the variance EWMA could overflow uint64, so the ceiling is a
    ///      correctness boundary rather than a policy preference.
    function test_RevertWhen_TickDeltaClampExceedsOverflowBound() public {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.maxTickDeltaPerBlock = VarianceEwma.MAX_TICK_DELTA_CLAMP + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssayErrors.AssayHook__TickDeltaClampOutOfRange.selector,
                VarianceEwma.MAX_TICK_DELTA_CLAMP + 1,
                VarianceEwma.MAX_TICK_DELTA_CLAMP
            )
        );
        this.validateExternal(c);
    }

    function test_Validate_AcceptsClampAtTheOverflowBound() public view {
        AssayConfig memory c = _config(500, 100, 10_000);
        c.maxTickDeltaPerBlock = VarianceEwma.MAX_TICK_DELTA_CLAMP;
        this.validateExternal(c);
    }
}
