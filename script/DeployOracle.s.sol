// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../src/oracle/ChainlinkReferenceAdapter.sol";

/// @dev Minimal ERC-20 view, declared locally rather than importing a full interface.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploys the reference price source the hook is bound to.
/// @dev Separate from `DeployAssay` because the hook takes this address as a constructor
///      argument, so a failed hook deploy cannot silently redeploy a working oracle.
///
///      The price-scaling numerator is derived from the feed's and both tokens' own
///      `decimals()`, never accepted as an argument: a hand-typed one assuming the wrong
///      decimals used to deploy without complaint and price against nothing real.
contract DeployOracle is Script {
    /// @notice Reads configuration from the environment and deploys to the current chain.
    /// @return adapter The deployed adapter.
    function run() external returns (ChainlinkReferenceAdapter adapter) {
        return deploy(
            IAggregatorV3(vm.envAddress("ASSAY_CHAINLINK_FEED")),
            vm.envUint("ASSAY_ORACLE_MAX_AGE_SECONDS"),
            Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY0")),
            Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY1"))
        );
    }

    /// @notice Derives the decimal scaling and deploys the adapter.
    /// @dev Split from `run` so tests exercise it without mutating the environment.
    /// @return adapter The deployed adapter, already confirmed to produce a fresh reading.
    function deploy(IAggregatorV3 feed, uint256 maxAge, Currency currency0, Currency currency1)
        public
        returns (ChainlinkReferenceAdapter adapter)
    {
        uint8 decimals0 = _decimalsOf(currency0);
        uint8 decimals1 = _decimalsOf(currency1);
        uint256 numerator = 10 ** (uint256(decimals1) + uint256(feed.decimals()) - uint256(decimals0));

        vm.broadcast();
        adapter = new ChainlinkReferenceAdapter(
            feed, maxAge, numerator, currency0, decimals0, currency1, decimals1
        );

        // A deployed adapter that cannot price is worse than a failed deploy: it surfaces later.
        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        require(fresh, "DeployOracle: feed did not return a usable price");

        console2.log("chain id        ", block.chainid);
        console2.log("oracle adapter  ", address(adapter));
        console2.log("feed            ", address(feed));
        console2.log("feed decimals   ", feed.decimals());
        console2.log("currency0 dec   ", decimals0);
        console2.log("currency1 dec   ", decimals1);
        console2.log("price numerator ", numerator);
        console2.log("reference sqrtP ", sqrtPriceX96);
        console2.log("");
        console2.log("Set ASSAY_REFERENCE_ORACLE to the adapter address above, then run DeployAssay.");
    }

    /// @dev Native ETH has no contract to query and is 18 decimals by convention.
    function _decimalsOf(Currency currency) private view returns (uint8) {
        if (CurrencyLibrary.isAddressZero(currency)) return 18;
        return IERC20Decimals(Currency.unwrap(currency)).decimals();
    }
}
