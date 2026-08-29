// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {ChainlinkReferenceAdapter, IAggregatorV3} from "../src/oracle/ChainlinkReferenceAdapter.sol";

/// @dev Minimal ERC-20 view for reading a token's decimals off chain. Declared locally,
///      matching how the adapter itself declares `IAggregatorV3` rather than importing a
///      full token interface for one field.
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

/// @notice Deploys the reference price source the hook is bound to.
/// @dev Separate from `DeployAssay` because the hook takes the adapter's address as a
///      constructor argument, and that address must exist first. Each script does one thing
///      so a failed hook deploy does not silently redeploy a working oracle.
///
///      Every parameter comes from the environment except the price-scaling numerator, which
///      this script derives from the feed's and both tokens' own `decimals()` rather than
///      accepting one as an argument. A hand-typed numerator that assumed the wrong decimals
///      used to deploy without complaint and price every swap against a reference that was
///      not the price of anything (see `ChainlinkReferenceAdapter`'s constructor, which
///      re-derives and checks the same value independently of this script).
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
    /// @dev Split from `run` so the derivation is exercised by tests without mutating the
    ///      process environment, matching the `run`/`deploy` split in `DeployAssay`.
    /// @param feed The Chainlink aggregator to read.
    /// @param maxAge Staleness bound in seconds.
    /// @param currency0 Lower-sorted currency of the pair this adapter prices.
    /// @param currency1 Higher-sorted currency of that pair.
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

        // Read it back before reporting success. A deployed adapter that cannot produce a
        // usable price is worse than a failed deploy, because the failure surfaces later.
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

    /// @dev Native ETH carries no ERC-20 contract to query and is conventionally 18 decimals
    ///      wherever v4 represents it as the zero currency.
    function _decimalsOf(Currency currency) private view returns (uint8) {
        if (CurrencyLibrary.isAddressZero(currency)) return 18;
        return IERC20Decimals(Currency.unwrap(currency)).decimals();
    }
}
