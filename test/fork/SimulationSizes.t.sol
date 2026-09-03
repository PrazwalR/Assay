// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Reproduces the Simulation page's two-leg arbitrage against the real deployment, at the
///         dislocation sizes the UI offers.
/// @dev Written to explain a reported failure: 0.5 and 1 USDC error, 2 USDC succeeds. The
///      TypeScript engine quotes all three without complaint, so if a size fails it fails on
///      chain, and this is the only place that distinction can be settled.
contract SimulationSizesForkTest is Test {
    address internal constant HOOK = 0xc825ad661BA0398eF9Cf809E6635528C9aa370c4;
    address internal constant SWAP_ROUTER = 0x0DFA8a0e1CaC977015cc7D214380AeB24FE766d5;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    int24 internal constant TICK_SPACING = 60;

    PoolSwapTest internal swapRouter;
    PoolKey internal poolKey;

    function setUp() public {
        vm.createSelectFork("base_sepolia");
        swapRouter = PoolSwapTest(SWAP_ROUTER);
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    /// @dev Mirrors `useSimulation.run()`: leg one sells USDC to open the gap, leg two sells back
    ///      exactly the WETH leg one produced. Both legs unbounded on price, as the UI sends them.
    function _runBothLegs(uint256 usdcIn) internal returns (uint256 wethOut, uint256 usdcBack) {
        address trader = makeAddr(string(abi.encodePacked("sim-", vm.toString(usdcIn))));
        deal(USDC, trader, usdcIn);

        vm.startPrank(trader);
        IERC20Like(USDC).approve(SWAP_ROUTER, type(uint256).max);
        IERC20Like(WETH).approve(SWAP_ROUTER, type(uint256).max);

        uint256 wethBefore = IERC20Like(WETH).balanceOf(trader);
        swapRouter.swap(
            poolKey,
            // `usdcIn` is a small literal from the test table, far inside int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(usdcIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        wethOut = IERC20Like(WETH).balanceOf(trader) - wethBefore;

        uint256 usdcBefore = IERC20Like(USDC).balanceOf(trader);
        swapRouter.swap(
            poolKey,
            // `wethOut` is the measured output of the leg above, far inside int256.
            // forge-lint: disable-next-line(unsafe-typecast)
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(wethOut),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        usdcBack = IERC20Like(USDC).balanceOf(trader) - usdcBefore;
        vm.stopPrank();
    }

    function test_Simulation_HalfUsdc() public {
        (uint256 wethOut, uint256 usdcBack) = _runBothLegs(500_000);
        console2.log("0.5 USDC: weth out", wethOut);
        console2.log("0.5 USDC: usdc back", usdcBack);
        assertGt(wethOut, 0, "leg one produced no WETH");
    }

    function test_Simulation_OneUsdc() public {
        (uint256 wethOut, uint256 usdcBack) = _runBothLegs(1_000_000);
        console2.log("1 USDC: weth out", wethOut);
        console2.log("1 USDC: usdc back", usdcBack);
        assertGt(wethOut, 0, "leg one produced no WETH");
    }

    function test_Simulation_TwoUsdc() public {
        (uint256 wethOut, uint256 usdcBack) = _runBothLegs(2_000_000);
        console2.log("2 USDC: weth out", wethOut);
        console2.log("2 USDC: usdc back", usdcBack);
        assertGt(wethOut, 0, "leg one produced no WETH");
    }
}
