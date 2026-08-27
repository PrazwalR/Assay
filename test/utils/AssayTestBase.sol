// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {AssayHook} from "../../src/AssayHook.sol";
import {AssayConfig} from "../../src/config/AssayConfig.sol";
import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @dev Shared harness that stands up a real PoolManager, a mined hook, and a funded
///      dynamic-fee pool. A genuine PoolManager is deployed rather than a stand-in so the
///      dynamic-fee handshake and delta accounting are exercised as they run on chain.
abstract contract AssayTestBase is Test {
    /// @dev The exact permission set Assay claims: BEFORE_INITIALIZE | AFTER_INITIALIZE |
    ///      BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA.
    uint160 internal constant EXPECTED_FLAGS = 0x30C4;

    uint24 internal constant BASE_FEE_PIPS = 500;
    uint24 internal constant MIN_FEE_PIPS = 100;
    uint24 internal constant MAX_FEE_PIPS = 10_000;

    int24 internal constant TICK_SPACING = 60;

    /// @dev Both test tokens use 18 decimals and the mock feed uses 8, so the decimal
    ///      scaling is 10 ** (18 - 18 + 8). See ChainlinkReferenceAdapter.PRICE_NUMERATOR.
    uint256 internal constant PRICE_NUMERATOR = 1e8;
    uint256 internal constant ORACLE_MAX_AGE = 3600;

    /// @dev Matches the calibrated value shipped in .env.example, so the suite exercises the
    ///      configuration that actually deploys. `test_Quote_AtAHigherCaptureShare` covers a
    ///      second point so the mechanism is not only tested at one setting.
    uint24 internal constant CAPTURE_SHARE_BPS = 1000;

    PoolManager internal manager;
    AssayHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    MockERC20 internal token0;
    MockERC20 internal token1;
    PoolKey internal poolKey;
    MockAggregatorV3 internal feed;
    ChainlinkReferenceAdapter internal oracle;

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        liquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));

        (token0, token1) = _deploySortedTokens();

        // A price of 1.0 between two 18-decimal tokens puts the reference at tick 0, which is
        // where the pool is initialised, so the pool starts perfectly aligned.
        feed = new MockAggregatorV3(int256(1e8), block.timestamp);
        oracle = new ChainlinkReferenceAdapter(
            IAggregatorV3(address(feed)),
            ORACLE_MAX_AGE,
            PRICE_NUMERATOR,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );
        hook = _deployHook(_defaultConfig());
        poolKey = _initialisePool(address(hook));
        _addLiquidity();
    }

    function _defaultConfig() internal view returns (AssayConfig memory) {
        return AssayConfig({
            baseFeePips: BASE_FEE_PIPS,
            minFeePips: MIN_FEE_PIPS,
            maxFeePips: MAX_FEE_PIPS,
            captureShareBps: CAPTURE_SHARE_BPS,
            referenceOracle: address(oracle)
        });
    }

    /// @dev Mines a salt so the deployed address carries exactly `EXPECTED_FLAGS`. Deploying
    ///      to an unmined address reverts inside BaseHook, so a passing test is itself proof
    ///      the permission bits are correct.
    function _deployHook(AssayConfig memory config) internal returns (AssayHook deployed) {
        bytes memory args = abi.encode(IPoolManager(address(manager)), config);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), EXPECTED_FLAGS, type(AssayHook).creationCode, args);
        deployed = new AssayHook{salt: salt}(IPoolManager(address(manager)), config);
        require(address(deployed) == expected, "hook address mismatch");
    }

    function _deploySortedTokens() internal returns (MockERC20 lower, MockERC20 upper) {
        MockERC20 a = new MockERC20("Token A", "TKA", 18);
        MockERC20 b = new MockERC20("Token B", "TKB", 18);
        (lower, upper) = address(a) < address(b) ? (a, b) : (b, a);

        lower.mint(address(this), 1_000_000 ether);
        upper.mint(address(this), 1_000_000 ether);
        lower.approve(address(swapRouter), type(uint256).max);
        upper.approve(address(swapRouter), type(uint256).max);
        lower.approve(address(liquidityRouter), type(uint256).max);
        upper.approve(address(liquidityRouter), type(uint256).max);
    }

    function _initialisePool(address hookAddress) internal returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function _addLiquidity() internal {
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: -TICK_SPACING * 100,
                tickUpper: TICK_SPACING * 100,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }
}
