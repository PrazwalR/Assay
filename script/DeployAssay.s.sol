// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {AssayHook} from "../src/AssayHook.sol";
import {AssayConfig} from "../src/config/AssayConfig.sol";

/// @notice Mines a compliant hook address and deploys AssayHook against the PoolManager for
///         the current chain.
/// @dev Every parameter is read from the environment and validated before use. The
///      PoolManager address is resolved from the chain id via hookmate rather than passed in,
///      so a deploy pointed at the wrong network fails instead of deploying against a
///      contract that happens to exist at a hardcoded address.
contract DeployAssay is Script {
    /// @dev Foundry routes salted deployments through this proxy when broadcasting, so the
    ///      mined address must be computed against it and not against the script address.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice Reads configuration from the environment and deploys to the current chain.
    /// @return hook The deployed hook.
    function run() external returns (AssayHook hook) {
        AssayConfig memory config = AssayConfig({
            baseFeePips: uint24(vm.envUint("ASSAY_BASE_FEE_PIPS")),
            minFeePips: uint24(vm.envUint("ASSAY_MIN_FEE_PIPS")),
            maxFeePips: uint24(vm.envUint("ASSAY_MAX_FEE_PIPS"))
        });
        return deploy(IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid)), config);
    }

    /// @notice Mines a compliant salt and deploys the hook.
    /// @dev Split from `run` so the mining and deployment path is exercised by tests without
    ///      mutating the process environment.
    /// @param poolManager The PoolManager the hook will serve.
    /// @param config Validated fee bounds, checked again inside the constructor.
    /// @return hook The deployed hook, asserted to sit at the mined address.
    function deploy(IPoolManager poolManager, AssayConfig memory config) public returns (AssayHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        bytes memory args = abi.encode(poolManager, config);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(AssayHook).creationCode, args);

        vm.broadcast();
        hook = new AssayHook{salt: salt}(poolManager, config);

        require(address(hook) == expected, "DeployAssay: mined address mismatch");

        console2.log("chain id       ", block.chainid);
        console2.log("pool manager   ", address(poolManager));
        console2.log("assay hook     ", address(hook));
        console2.log("permission mask", uint256(uint160(address(hook)) & Hooks.ALL_HOOK_MASK));
    }
}
