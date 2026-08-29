// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolState} from "../../src/types/PoolState.sol";

/// @dev Deploys nothing but two consecutive struct-typed state variables. Solidity starts
///      every struct-typed state variable on a fresh storage slot, so `b` begins exactly one
///      slot after `a` only if `a` fits inside that single slot -- if `PoolState` ever grows
///      past 256 bits, `a` alone would occupy two slots and `b`'s data would land at slot 2
///      instead, leaving slot 1 unused. Kept free of any base contract (including `Test`) so
///      the slot-0 assumption below does not depend on some other contract's own storage
///      layout.
contract PoolStateLayoutProbe {
    PoolState public a;
    PoolState public b;

    function setB(PoolState calldata state) external {
        b = state;
    }
}

contract PoolStateTest is Test {
    /// @dev The doc comment on `PoolState` promises this test by name; a field added past
    ///      the 256-bit budget must fail loudly here rather than silently costing a second
    ///      SLOAD/SSTORE on every swap.
    function test_PoolState_OccupiesExactlyOneSlot() public {
        PoolStateLayoutProbe probe = new PoolStateLayoutProbe();
        probe.setB(
            PoolState({lastTick: 1, referenceTick: 2, lastBlock: 3, referenceFresh: true, twapTickX32: 4})
        );

        assertEq(
            vm.load(address(probe), bytes32(uint256(0))), bytes32(0), "a is unset and must still read zero"
        );
        assertNotEq(
            vm.load(address(probe), bytes32(uint256(1))),
            bytes32(0),
            "b's data must land in slot 1, immediately after a -- PoolState spilled past one slot"
        );
    }
}
