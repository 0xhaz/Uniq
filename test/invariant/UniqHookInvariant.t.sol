// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {UniqHookImplementation} from "test/utils/implementation/UniqHookImplementation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IUniqHook} from "src/interfaces/IUniqHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {DeployUniqHook} from "script/DeployUniqHook.s.sol";
import {LongTermOrder} from "src/libraries/LongTermOrder.sol";
import {Struct} from "src/libraries/Struct.sol";
import {UniqHook} from "src/UniqHook.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {MockBrevisProof, IBrevisProof} from "test/mocks/MockBrevisProof.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IBrevisApp} from "src/interfaces/brevis/IBrevisApp.sol";
import {HookMiner} from "test/utils/HookMiner.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolGetters} from "src/libraries/PoolGetters.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {DynamicFees} from "src/libraries/DynamicFees.sol";
import {DynamicFees} from "src/libraries/DynamicFees.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {Constants} from "src/libraries/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Volatility} from "src/libraries/Volatility.sol";

contract UniqHookInvariant is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolGetters for IPoolManager;

    mapping(PoolId => uint256) public lastPrices;
    mapping(PoolId => uint256) lastTimestamp;

    bytes32 private constant VK_HASH = 0x179a48b8a2a08b246cd51cb7b78143db774a83ff75fad0d39cf0445e16773426;

    uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    address priceFeed = 0xc59E3633BAAC79493d908e63626716e204A45EdF;

    MockERC20 tsla;
    MockERC20 usdc;
    MockBrevisProof brevisProofMock;
    UniqHook uniqHook;
    PoolKey poolKey;
    PoolId poolId;
    MockV3Aggregator priceFeedMock;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        tsla = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));
        brevisProofMock = new MockBrevisProof();
        priceFeedMock = new MockV3Aggregator(18, 1e8);

        uniqHook = createUniqHook();

        (poolKey, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, uniqHook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1, ZERO_BYTES
        );

        addLiquidityToPool(-60, 60, 1000 ether);
        addLiquidityToPool(-120, 120, 1000 ether);
        addLiquidityToPoolFullRange();
    }

    // Invariant: Volatility-based fee should decay over time according to smoothing factor
    function testUniqHookInvariant_VolatilityDecaysOverTime() public {
        uint248 initialVolatility = 70e18;
        uint248 newVolatility = 50e18;

        // Set initial volatility
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));

        // Check volatility adjustment after first brevis callback
        uint256 expectedVolatility;
        uint256 initialVolatilityUint = initialVolatility;
        uint256 volatilityChange = abs(int256(initialVolatilityUint) - int256(0)); // Old volatility is 0 at first

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = initialVolatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = initialVolatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        // Assert the expected volatility after the first adjustment
        assertLe(uniqHook.volatility(), expectedVolatility);

        // Warp time by 1 hour to simulate passage of time
        vm.warp(block.timestamp + 2 hours);

        // Set new volatility through brevisProofMock
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(newVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(newVolatility));

        // Calculate the expected smoothed volatility based on the old volatility and new volatility
        uint256 newVolatilityUint = newVolatility;
        uint256 newVolatilityChange = abs(int256(newVolatilityUint) - int256(expectedVolatility));
        uint256 smoothingFactor =
            (newVolatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) ? 5 : Constants.SMOOTHING_FACTOR;

        uint256 smoothedVolatility = (expectedVolatility * (smoothingFactor - 1) + newVolatility) / smoothingFactor;

        // Assert the smoothed volatility after the second adjustment
        assertLt(uniqHook.volatility(), smoothedVolatility);
    }

    function testUniqHookInvariant_FeesAreBounded() public {
        int256 amountSpecified = int256(bound(uint256(10e18), 1e18, 100e18));

        uint24 fee = uniqHook.getFee(
            amountSpecified,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            })
        );

        // Check that fee is within logical bounds
        uint24 maxFee = Constants.MAX_FEE;
        uint24 minFee = Constants.MIN_FEE;
        assertLe(fee, maxFee);
        assertGe(fee, minFee);
    }

    function testUniqHookInvariant_VolatilityDecays_WithMultipleSwaps() public {
        uint248 currentVolatility = 60e18;

        // Set initial volatility through brevisProofMock
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(currentVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(currentVolatility));

        uint256 volatilityUint = currentVolatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = currentVolatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = currentVolatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        // Perform a couple of swaps with dynamic sqrtPrice limits
        swapTokens(true, 10e18, TickMath.getSqrtPriceAtTick(-1000));
        swapTokens(false, 20e18, TickMath.getSqrtPriceAtTick(1000));

        // Check the fee after first swap
        uint24 fee = uniqHook.getFee(
            10e18,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: 10e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-1000)
            })
        );

        // Ensure volatility decayed as expected and fee is within limits
        // expectedVolatility = currentVolatility / uniqHook.SMOOTHING_FACTOR();
        assertGe(uniqHook.volatility(), expectedVolatility);
        assertLe(fee, Constants.MAX_FEE);

        // Warp time forward by 1 hour to simulate volatility decay
        vm.warp(block.timestamp + 1 hours);

        // Perform another swap and check the fee after time delay
        fee = uniqHook.getFee(
            10e18,
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: 10e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(1000)
            })
        );

        // Ensure volatility is decaying correctly and fee remains within bounds
        // expectedVolatility = currentVolatility / uniqHook.SMOOTHING_FACTOR();
        assertGe(uniqHook.volatility(), expectedVolatility);
        assertLe(fee, Constants.MAX_FEE);
    }

    function testUniqHookInvariant_PriceMovementWithVolatility() public {
        uint248 initialVolatility = 70e18;

        // Set initial volatility through brevisProofMock
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));

        uint256 volatilityUint = initialVolatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = initialVolatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = initialVolatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        int256 amountSpecified = int256(bound(uint256(10 ether), 1 ether, 100 ether));

        (, int24 tickBefore,,) = manager.getSlot0(poolKey.toId());

        uint256 prePrice = TickMath.getSqrtPriceAtTick(tickBefore);

        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        (, int24 tickAfter,,) = manager.getSlot0(poolKey.toId());

        uint256 postPrice = TickMath.getSqrtPriceAtTick(tickAfter);

        if (amountSpecified > 0) {
            assertLt(postPrice, prePrice);
        } else {
            assertGt(postPrice, prePrice);
        }
    }

    function testUniqHookInvariant_DirectionalMultiplier_Aggresive(
        uint256 priceMovement,
        uint128 liquidity,
        bool isAggressive
    ) public view {
        // restrict the range of inputs to avoid overflow
        priceMovement = bound(priceMovement, 1e18, 100e18); // Reasonable price movement range
        liquidity = uint128(bound(liquidity, 0, 1e28)); // Safe liquidity bounds

        console.log("Price movement: %d", priceMovement);
        console.log("Liquidity: %d", liquidity);

        uint256[] memory volumes = new uint256[](5);
        volumes[0] = liquidity / 10; // 10% of liquidity
        volumes[1] = liquidity / 2; // 50% of liquidity
        volumes[2] = liquidity; // 100% of liquidity
        volumes[3] = bound(liquidity * 2, 0, type(uint256).max); // 200% of liquidity
        volumes[4] = bound(liquidity * 5, 0, type(uint256).max); // 500% of liquidity

        // Gas tracking: start measurement
        uint256 startGas = gasleft();

        for (uint256 i = 0; i < volumes.length; i++) {
            uint256 volume = volumes[i];
            uint256 expectedMultiplier =
                DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);

            console.log("Expected multiplier (Aggressive): %d", expectedMultiplier);
            console.log("Volume: %d", volume);

            // Gas tracking: end measurement
            uint256 endGas = gasleft();
            console.log("Gas used: %d", startGas - endGas);

            // Multiplier should always be greater than 1 for aggressive trades
            assertGe(expectedMultiplier, 1);

            if (isAggressive) {
                console.log("isAggressive: %d", isAggressive);

                // Multiplier should increase with higher price movement
                if (priceMovement > 10e18) {
                    assertGe(expectedMultiplier, 4); // Highly aggresive multiplier for large price movement
                } else if (priceMovement > 5e18) {
                    assertGe(expectedMultiplier, 3); // Aggresive multiplier for moderate price movement
                } else if (priceMovement > 1e18) {
                    assertGe(expectedMultiplier, 2); // Slightly aggresive multiplier for small price movement
                } else {
                    assertGe(expectedMultiplier, 1); // Default multiplier for small price movement
                }

                // Volume-to-liquidity ratio should also affect the multiplier
                if (liquidity > 0) {
                    uint256 volumeToLiqudityRatio = (volume * 1e18) / liquidity;
                    console.log("Volume-to-liquidity ratio: %d", volumeToLiqudityRatio);

                    // Multiplier should increase with higher volume-to-liquidity ratio
                    if (volumeToLiqudityRatio > 1e18) {
                        assertGe(expectedMultiplier, 3); // Large volume relative to liquidity
                    } else if (volumeToLiqudityRatio > 5e17) {
                        assertGe(expectedMultiplier, 2); // Moderate volume relative to liquidity
                    }
                } else {
                    // No liquidity, multiplier should be at least 3
                    assertGe(expectedMultiplier, 3);
                }
            } else {
                // Multiplier should always be 1 for passive trades
                assertEq(expectedMultiplier, 1);
            }
        }

        // test zero liquidity
        if (liquidity == 0) {
            uint256 zerLiquidityMultiplier =
                DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, 1e18, liquidity);
            console.log("Zero liquidity multiplier: %d", zerLiquidityMultiplier);
            assertGe(zerLiquidityMultiplier, 1);
        }

        // test large price movement and volume
        priceMovement = 1e35;
        liquidity = 1e27;
        uint256 largeVolume = liquidity * 5;

        uint256 largeValueMultiplier =
            DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, largeVolume, liquidity);
        console.log("Large value multiplier: %d", largeValueMultiplier);
        assertGe(largeValueMultiplier, 1);
    }

    function testUniqHookInvariant_DirectionalMultiplier_Passive(uint256 priceMovement, uint128 liquidity)
        public
        pure
    {
        priceMovement = bound(priceMovement, 1e16, 100e18); // Reasonable price movement range
        liquidity = uint128(bound(liquidity, 1, 1e28)); // Safe liquidity bounds
        uint256 volume = liquidity / 2; // 50% of liquidity
        bool isAggressive = false; // Passive trade

        uint256 expectedMultiplier =
            DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);

        console.log("Expected multiplier (Passive): %d", expectedMultiplier);

        // For passive trades, the multiplier should always be 1
        assertEq(expectedMultiplier, 1);
    }

    function testUnitHookVariant_DirectionalMultiplier_LargeValues() public pure {
        uint256 priceMovement = 100e18; // Large price movement
        uint128 liquidity = 1e28; // Large liquidity
        uint256 volume = bound(liquidity * 5, 0, type(uint256).max); // 500% of liquidity
        bool isAggressive = true;

        uint256 expectedMultiplier =
            DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);

        console.log("Expected multiplier (Large values): %d", expectedMultiplier);

        // Expect a large multiplier due to high price movement and volume-to-liquidity ratio
        assertGe(expectedMultiplier, 5);
    }

    function testUniqHookVariant_DirectionalMultiplier_ZeroLiquidity() public pure {
        uint256 priceMovement = 10e18; // Some large price movement
        uint128 liquidity = 0; // Zero liquidity
        uint256 volume = 1e18; // Arbitrary volume
        bool isAggressive = true;

        uint256 expectedMultiplier =
            DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);

        console.log("Expected multiplier (Zero liquidity): %d", expectedMultiplier);

        // Multiplier should increase when liquidity is zero
        assertGe(expectedMultiplier, 3);
    }

    function testUniqHookVariant_CalculateMovement(
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        uint256 volatility,
        uint256 timeElapsed
    ) public {
        // Bounds for volatility and timeElapsed
        volatility = bound(volatility, 0, 1e18);

        // Let's assume you have a base timestamp for testing, for example, simulating a past block
        uint256 mockBlockTime = 1_600_000_000; // Simulate a block timestamp in the past (UNIX timestamp)

        // Now let's bound timeElapsed relative to mockBlockTime
        timeElapsed = bound(timeElapsed, 0, 30 days); // Simulate timeElapsed up to 1 year for more variability

        // Simulate the current block.timestamp based on the mock time
        uint256 currentBlockTime = mockBlockTime + timeElapsed;
        console.log("Simulated current block time: %d", currentBlockTime);

        // Simulate the last timestamp as currentBlockTime - timeElapsed
        lastTimestamp[poolId] = currentBlockTime - timeElapsed;

        // Add bounds to sqrtPriceX96 to prevent overflow when calculating price
        uint160 boundedSqrtPriceX96 = uint160(bound(sqrtPriceX96, 1, 2 ** 40)); // Apply bounds
        uint256 price = (uint256(boundedSqrtPriceX96) * uint256(boundedSqrtPriceX96)) / FixedPoint96.Q96;

        console.log("Bounded sqrtPriceX96: %d", boundedSqrtPriceX96);

        lastPrices[poolId] = price;

        // Gas tracking: start measurement
        uint256 startGas = gasleft();

        // Calculate the price movement
        uint256 priceMovement = DynamicFees.calculateMovement(key, manager, volatility, lastPrices, lastTimestamp);
        console.log("Price movement: %d", priceMovement);

        // Gas tracking: end measurement
        uint256 endGas = gasleft();
        console.log("Gas used: %d", startGas - endGas);

        assertGe(priceMovement, 0); // Ensure movement is non-negative

        // Simulate initial case where lastPrice == 0 to test movement driven by volatility
        if (lastPrices[poolId] == 0) {
            lastPrices[poolId] = 0;
            priceMovement = DynamicFees.calculateMovement(key, manager, volatility, lastPrices, lastTimestamp);
            if (volatility == 0) {
                assertEq(priceMovement, 1e16, "Movement should be minimal when volatility and price change are 0");
            } else {
                assertEq(priceMovement, volatility / 1e10, "Price movement should match volatility-derived value");
            }
        }

        // Ensure decay factor has a dampening effect on price movement when timeElapsed > 0
        if (timeElapsed > 0) {
            uint256 rawMovement = (priceMovement * 1e18) / DynamicFees.calculateTimeDecayFactor(timeElapsed);
            uint256 decayFactor = DynamicFees.calculateTimeDecayFactor(timeElapsed);
            console.log("Raw Movement: %d", rawMovement);
            console.log("Decay Factor: %d", decayFactor);
            assertLe(priceMovement, rawMovement, "Decay factor should reduce price movement");
        }

        // Ensure minimal movement when no price change and no volatility
        if (volatility == 0 && price == lastPrices[poolId]) {
            assertEq(priceMovement, 1e16, "Movement should be minimal when volatility and price change are 0");
        }
    }

    // KIV: This test is not working as expected
    function testUniqHookInvariant_AdjustFeeBasedOnLiquidity(
        uint256 volume,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing
    ) public pure {
        // Apply bounds to prevent overflow and unrealistic values
        volume = bound(volume, 1, 1e12);
        vm.assume(tick > 0 && tick <= 1000);
        liquidity = uint128(bound(liquidity, 1e6, 1e18));
        vm.assume(tickSpacing > 0 && tickSpacing <= 1000);

        // Call the adjustFeeBasedOnLiquidity function
        uint24 fee = DynamicFees.adjustFeeBasedOnLiquidity(volume, sqrtPriceX96, tick, liquidity, tickSpacing);

        // Check if liquidity is zero, fee must be max
        if (liquidity == 0) {
            console.log("Liquidity is zero, asserting MAX_FEE");
            assertEq(fee, Constants.MAX_FEE, "Fee should be MAX_FEE when liquidity is zero");
        } else {
            // Compute TVL and volume-to-liquidity ratio
            uint256 tickTVL = Volatility.computeTickTVLX64(tickSpacing, tick, sqrtPriceX96, liquidity);
            console.log("Tick TVL: %d", tickTVL);
            require(tickTVL > 0, "tickTVL cannot be zero");
            require(tickTVL < 1e40, "tickTVL too large");

            uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e36, tickTVL);
            console.log("Volume-to-Liquidity Ratio: %d", volumeToLiquidityRatio);

            // Assert that the fee is within the expected range based on the ratio
            if (volumeToLiquidityRatio > 1e18) {
                console.log("Volume-to-Liquidity Ratio too high, asserting MAX_FEE");
                assertEq(fee, Constants.MAX_FEE, "Fee should be MAX_FEE for high volume-to-liquidity ratio");
            } else if (volumeToLiquidityRatio < 1e16) {
                console.log("Volume-to-Liquidity Ratio too low, asserting MIN_FEE");
                assertEq(fee, Constants.MIN_FEE, "Fee should be MIN_FEE for low volume-to-liquidity ratio");
            } else {
                // Ensure the fee is scaled correctly between MIN_FEE and MAX_FEE
                uint24 expectedFee = uint24(
                    Math.mulDiv(volumeToLiquidityRatio, Constants.MAX_FEE - Constants.MIN_FEE, 1e18) + Constants.MIN_FEE
                );
                console.log("Expected Fee: %d", expectedFee);
                assertEq(fee, expectedFee, "Fee should be scaled based on volume-to-liquidity ratio");
            }
        }
    }

    function createUniqHook() internal returns (UniqHook) {
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(UniqHook).creationCode,
            abi.encode(manager, 10_000, address(brevisProofMock), address(priceFeedMock))
        );

        UniqHook hook = new UniqHook{salt: salt}(manager, 10_000, address(brevisProofMock), address(priceFeedMock));
        hook.setVkHash(VK_HASH);
        return hook;
    }

    function approveTokens() internal {
        tsla.approve(address(modifyLiquidityRouter), 1000 ether);
        usdc.approve(address(modifyLiquidityRouter), 1000 ether);
        tsla.mint(address(this), 1000 ether);
        usdc.mint(address(this), 1000 ether);
    }

    function addLiquidityToPool(int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function swapTokens(bool zeroForOne, int256 amount, uint160 sqrtPriceLimitX96)
        internal
        returns (BalanceDelta delta)
    {
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amount,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        delta = swapRouter.swap(poolKey, swapParams, settings, ZERO_BYTES);
        return delta;
    }

    function addLiquidityToPoolFullRange() internal {
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
