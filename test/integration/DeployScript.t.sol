// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {AssayHook} from "../../src/AssayHook.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {AssayConfig} from "../../src/config/AssayConfig.sol";
import {DeployAssay} from "../../script/DeployAssay.s.sol";

/// @dev Dry-runs the deployment against a PoolManager placed at the canonical address for a
///      real target chain. A deploy script that has never executed is an untested deploy, and
///      the mining step is exactly where a silent failure produces a hook that cannot attach.
contract DeployScriptTest is Test {
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint160 internal constant EXPECTED_FLAGS = 0x30C4;

    function _prepareChain(uint256 chainId) internal returns (address poolManager) {
        vm.chainId(chainId);
        poolManager = AddressConstants.getPoolManagerAddress(chainId);
        vm.etch(poolManager, address(new PoolManager(address(this))).code);
    }

    function _config() internal returns (AssayConfig memory) {
        address feed = address(new MockAggregatorV3(int256(1e8), block.timestamp));
        // Any correctly-ordered pair; this test exercises mining and wiring, not pricing.
        address oracle = address(
            new ChainlinkReferenceAdapter(
                IAggregatorV3(feed), 3600, 1e8, Currency.wrap(address(1)), 0, Currency.wrap(address(2)), 0
            )
        );
        return AssayConfig({
            baseFeePips: 500,
            minFeePips: 100,
            maxFeePips: 10_000,
            captureShareBps: 5000,
            referenceOracle: oracle,
            maxReferenceDeviationTicks: 20_000,
            twapLambdaX32: 4_252_017_623
        });
    }

    function test_Deploy_ProducesCompliantAddressOnBaseSepolia() public {
        address poolManager = _prepareChain(BASE_SEPOLIA);
        AssayHook hook = new DeployAssay().deploy(IPoolManager(poolManager), _config());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS, "flags");
    }

    function test_Deploy_ProducesCompliantAddressOnUnichainSepolia() public {
        address poolManager = _prepareChain(UNICHAIN_SEPOLIA);
        AssayHook hook = new DeployAssay().deploy(IPoolManager(poolManager), _config());
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, EXPECTED_FLAGS, "flags");
    }

    function test_Deploy_CarriesConfiguredFeeBounds() public {
        address poolManager = _prepareChain(BASE_SEPOLIA);
        AssayHook hook = new DeployAssay().deploy(IPoolManager(poolManager), _config());
        (uint24 base, uint24 min, uint24 max) = hook.feeBounds();
        assertEq(base, 500);
        assertEq(min, 100);
        assertEq(max, 10_000);
    }

    /// @dev An unsupported chain must fail loudly rather than deploy against whatever contract
    ///      happens to occupy a hardcoded address on that network.
    function test_RevertWhen_ChainHasNoKnownPoolManager() public {
        vm.chainId(31_337);
        vm.expectRevert(AddressConstants.UnsupportedChainId.selector);
        this.resolvePoolManager(31_337);
    }

    function resolvePoolManager(uint256 chainId) external pure returns (address) {
        return AddressConstants.getPoolManagerAddress(chainId);
    }
}
