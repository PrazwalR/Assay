// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {AssayConfig, AssayConfigLib} from "../../src/config/AssayConfig.sol";
import {IAssayErrors} from "../../src/interfaces/IAssayErrors.sol";

contract AssayConfigTest is Test {
    function _config(uint24 base, uint24 min, uint24 max) internal pure returns (AssayConfig memory) {
        return AssayConfig({baseFeePips: base, minFeePips: min, maxFeePips: max});
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
}
