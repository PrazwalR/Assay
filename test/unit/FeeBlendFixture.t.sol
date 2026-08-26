// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeBlend} from "../../src/libraries/FeeBlend.sol";

/// @dev Pins the fee schedule to a fixture the Python calibration reads as well.
///
///      The counterfactual backtest reimplements this formula in Python to evaluate policies
///      over historical flow. Its conclusions are only meaningful if that reimplementation
///      matches the contract exactly, and nothing about the two languages enforces that.
///      Both sides assert against this one file, so a change to either implementation that
///      is not mirrored in the other fails a test rather than silently invalidating a result.
contract FeeBlendFixtureTest is Test {
    struct Case {
        int256 drift;
        uint256 overflow;
        uint256 quote;
        uint256 share;
    }

    function test_ImplementationMatchesTheSharedFixture() public view {
        // Read-only, scoped by `fs_permissions` in foundry.toml to ./test/fixtures. Reading
        // the fixture is the whole point: a hardcoded copy here would drift from the one the
        // Python side reads, which is exactly the divergence this test exists to catch.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory raw = vm.readFile("test/fixtures/fee_blend.json");
        bytes memory decoded = vm.parseJson(raw);
        Case[] memory cases = abi.decode(decoded, (Case[]));

        assertGt(cases.length, 0, "fixture is empty");

        for (uint256 i = 0; i < cases.length; ++i) {
            Case memory c = cases[i];
            assertEq(
                FeeBlend.quote(c.drift, true, 500, 100, 10_000, uint24(c.share)),
                uint24(c.quote),
                "quote diverged from the shared fixture"
            );
            assertEq(
                FeeBlend.ceilingOverflowPips(c.drift, true, 500, 10_000, uint24(c.share)),
                uint24(c.overflow),
                "overflow diverged from the shared fixture"
            );
        }
    }
}
