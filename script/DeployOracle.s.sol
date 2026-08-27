// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Currency} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../src/oracle/ChainlinkReferenceAdapter.sol";

/// @notice Deploys the reference price source the hook is bound to.
/// @dev Separate from `DeployAssay` because the hook takes the adapter's address as a
///      constructor argument, and that address must exist first. Each script does one thing
///      so a failed hook deploy does not silently redeploy a working oracle.
///
///      Every parameter comes from the environment. The currency pair in particular is not
///      cosmetic: the hook refuses any pool whose currencies do not match what this adapter
///      declares, and the decimal scaling below only describes that one pair.
contract DeployOracle is Script {
    function run() external returns (ChainlinkReferenceAdapter adapter) {
        IAggregatorV3 feed = IAggregatorV3(vm.envAddress("ASSAY_CHAINLINK_FEED"));
        uint256 maxAge = vm.envUint("ASSAY_ORACLE_MAX_AGE_SECONDS");
        uint256 numerator = vm.envUint("ASSAY_ORACLE_PRICE_NUMERATOR");
        Currency currency0 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY0"));
        Currency currency1 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY1"));

        vm.broadcast();
        adapter = new ChainlinkReferenceAdapter(feed, maxAge, numerator, currency0, currency1);

        // Read it back before reporting success. A deployed adapter that cannot produce a
        // usable price is worse than a failed deploy, because the failure surfaces later.
        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        require(fresh, "DeployOracle: feed did not return a usable price");

        console2.log("chain id        ", block.chainid);
        console2.log("oracle adapter  ", address(adapter));
        console2.log("feed            ", address(feed));
        console2.log("reference sqrtP ", sqrtPriceX96);
        console2.log("");
        console2.log("Set ASSAY_REFERENCE_ORACLE to the adapter address above, then run DeployAssay.");
    }
}
