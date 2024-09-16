// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.25;

// import {Test, console} from "forge-std/Test.sol";
// import {Vm} from "forge-std/Vm.sol";
// import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
// import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// import {IHooks} from "v4-core/interfaces/IHooks.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
// import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
// import {PoolDonateTest} from "v4-core/test/PoolDonateTest.sol";
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
// import {IUniqHook} from "src/interfaces/IUniqHook.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {DeployUniqHook} from "script/DeployUniqHook.s.sol";
// import {LongTermOrder} from "src/libraries/LongTermOrder.sol";
// import {Struct} from "src/libraries/Struct.sol";
// import {UniqHook} from "src/UniqHook.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {MockBrevisProof, IBrevisProof} from "test/mocks/MockBrevisProof.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {IBrevisApp} from "src/interfaces/brevis/IBrevisApp.sol";
// import {HookMiner} from "test/utils/HookMiner.sol";

// contract UniqHookTest is Test, Deployers, GasSnapshot {
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;

//     bytes32 private constant VK_HASH = 0x179a48b8a2a08b246cd51cb7b78143db774a83ff75fad0d39cf0445e16773426;

//     // tsla price = 250
//     // sqrt price of tsla = sqrt(250) = 15.8113883
//     // sqrt price X96 = 15.8113883 * 2^96 = 1157920354989271135663335743598
//     uint160 sqrtPriceX96_TSLA_USDC = 1299920354989271135663335743598; // 1 tsla = 250 usdc

//     event SubmitOrder(
//         PoolId indexed poolId,
//         address indexed owner,
//         uint160 expiration,
//         bool zeroForOne,
//         uint256 sellRate,
//         uint256 earningsFactorLast
//     );

//     event UpdateOrder(
//         PoolId indexed poolId,
//         address indexed owner,
//         uint160 expiration,
//         bool zeroForOne,
//         uint256 sellRate,
//         uint256 earningsFactorLast
//     );

//     // UniqHook uniqHook = UniqHook(
//     //     address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG))
//     // );
//     uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

//     MockERC20 tsla;
//     MockERC20 usdc;
//     MockBrevisProof brevisProofMock;
//     UniqHook uniqHook;
//     PoolKey poolKey;
//     PoolId poolId;

//     function setUp() public {
//         deployFreshManagerAndRouters();
//         (currency0, currency1) = deployMintAndApprove2Currencies();

//         // DeployUniqHook uniqHookDeployer = new DeployUniqHook();
//         // uniqHook = UniqHook(uniqHookDeployer.run());

//         tsla = MockERC20(Currency.unwrap(currency0));
//         usdc = MockERC20(Currency.unwrap(currency1));
//         brevisProofMock = new MockBrevisProof();

//         // UniqHookImplementation impl =
//         //     new UniqHookImplementation(manager, 10_000, IBrevisApp(address(brevisProofMock)), uniqHook);
//         (, bytes32 salt) = HookMiner.find(
//             address(this), flags, type(UniqHook).creationCode, abi.encode(manager, 10_000, address(brevisProofMock))
//         );
//         // Tell the VM to start recording all storage reads and writes

//         uniqHook = new UniqHook{salt: salt}(manager, 10_000, address(brevisProofMock));
//         uniqHook.setVkHash(VK_HASH);

//         // (, bytes32[] memory writes) = vm.accesses(address(uniqHook));

//         // Enabling custom precompile for UniqHook
//         // vm.etch(address(uniqHook), address(impl).code);

//         // for each storage key that was written during the hook implementation, copy the value over
//         // unchecked {
//         //     for (uint256 i; i < writes.length; ++i) {
//         //         bytes32 slot = writes[i];
//         //         vm.store(address(uniqHook), slot, vm.load(address(impl), slot));
//         //     }
//         // }

//         // Initialize the pool
//         // tsla price is 1 tsla = 250 usdc
//         // tick calculation

//         (poolKey, poolId) =
//             initPool(currency0, currency1, uniqHook, LPFeeLibrary.DYNAMIC_FEE_FLAG, sqrtPriceX96_TSLA_USDC, ZERO_BYTES);

//         tsla.approve(address(modifyLiquidityRouter), 100 ether);
//         usdc.approve(address(modifyLiquidityRouter), 1000 ether);
//         tsla.mint(address(this), 100 ether);
//         usdc.mint(address(this), 1000 ether);

//         // Add liquidity at short range
//         modifyLiquidityRouter.modifyLiquidity(
//             poolKey,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -60,
//                 tickUpper: 60,
//                 liquidityDelta: 10 ether,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );

//         // Add liquidity at long range
//         modifyLiquidityRouter.modifyLiquidity(
//             poolKey,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -120,
//                 tickUpper: 120,
//                 liquidityDelta: 10 ether,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );

//         // Add liquidity at full range
//         modifyLiquidityRouter.modifyLiquidity(
//             poolKey,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: TickMath.minUsableTick(60),
//                 tickUpper: TickMath.maxUsableTick(60),
//                 liquidityDelta: 10 ether,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );
//     }

//     function testUniqHook_beforeInitialize_setsLastVirtualOrderTimestamp() public {
//         (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(uniqHook);

//         assertEq(uniqHook.getLastVirtualOrder(initId), 0);
//         vm.warp(10_000);

//         manager.initialize(initKey, sqrtPriceX96_TSLA_USDC, ZERO_BYTES);
//         assertEq(uniqHook.getLastVirtualOrder(initId), 10_000);
//     }

//     function testUniqHook_submitOrder_setOrderWithCorrectPoolAndInfo() public {
//         uint160 expiration = 30_000;
//         uint160 submitTimestamp = 10_000;
//         uint160 duration = expiration - submitTimestamp;

//         Struct.OrderKey memory orderKey =
//             Struct.OrderKey({owner: address(this), expiration: expiration, zeroForOne: true});

//         Struct.Order memory nullOrder = uniqHook.getOrder(poolKey, orderKey);
//         assertEq(nullOrder.sellRate, 0);
//         assertEq(nullOrder.rewardsFactorLast, 0);

//         vm.warp(10_000);
//         tsla.approve(address(uniqHook), 100 ether);
//         snapStart("submitOrder");
//         uniqHook.submitOrder(poolKey, orderKey, 1 ether);
//         snapEnd();

//         Struct.Order memory submittedOrder = uniqHook.getOrder(poolKey, orderKey);
//         (uint256 currentSellRate0For1, uint256 currentRewardFactor0For1) = uniqHook.getOrderPool(poolKey, true);
//         (uint256 currentSellRate1For0, uint256 currentRewardFactor1For0) = uniqHook.getOrderPool(poolKey, false);

//         assertEq(submittedOrder.sellRate, 1 ether / duration);
//         assertEq(submittedOrder.rewardsFactorLast, 0);
//         assertEq(currentSellRate0For1, 1 ether / duration);
//         assertEq(currentSellRate1For0, 0);
//         assertEq(currentRewardFactor0For1, 0);
//         assertEq(currentRewardFactor1For0, 0);
//     }

//     function testUniqHook_submitOrder_storeProperSellRatesAndRewardsFactor() public {
//         uint160 expiration1 = 30_000;
//         uint160 expiration2 = 40_000;
//         uint256 submitTimestamp1 = 10_000;
//         uint256 submitTimestamp2 = 30_000;
//         uint256 rewardsFactor0For1;
//         uint256 rewardsFactor1For0;
//         uint256 sellRate0For1;
//         uint256 sellRate1For0;

//         Struct.OrderKey memory orderKey1 =
//             Struct.OrderKey({owner: address(this), expiration: expiration1, zeroForOne: true});
//         Struct.OrderKey memory orderKey2 =
//             Struct.OrderKey({owner: address(this), expiration: expiration2, zeroForOne: true});
//         Struct.OrderKey memory orderKey3 =
//             Struct.OrderKey({owner: address(this), expiration: expiration2, zeroForOne: false});

//         tsla.approve(address(uniqHook), 100 ether);
//         usdc.approve(address(uniqHook), 100 ether);

//         vm.warp(submitTimestamp1);
//         uniqHook.submitOrder(poolKey, orderKey1, 1e18);
//         uniqHook.submitOrder(poolKey, orderKey3, 3e18);

//         (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
//         (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

//         assertEq(sellRate0For1, 1e18 / (expiration1 - submitTimestamp1));
//         assertEq(sellRate1For0, 3e18 / (expiration2 - submitTimestamp1));
//         assertEq(rewardsFactor0For1, 0);
//         assertEq(rewardsFactor1For0, 0);

//         // Warp time and submit 1 TWAMM order. Test that pool information is updated properly as one order expires and
//         // another order is added to the pool
//         vm.warp(submitTimestamp2);
//         uniqHook.submitOrder(poolKey, orderKey2, 2e18);

//         (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
//         (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

//         assertEq(sellRate0For1, 2e18 / (expiration2 - submitTimestamp2));
//         assertEq(sellRate1For0, 3 ether / (expiration2 - submitTimestamp1));
//         assertEq(rewardsFactor0For1, 139015823905313199219668854421439984); //
//         assertEq(rewardsFactor1For0, 23066075991537235709646157881990);
//     }

//     function testUniqHook_submitOrder_EmitsEvent() public {
//         Struct.OrderKey memory orderKey1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});

//         tsla.approve(address(uniqHook), 100 ether);
//         vm.warp(10_000);

//         vm.expectEmit(false, false, false, true);
//         emit SubmitOrder(poolId, address(this), 30_000, true, 1 ether / 20_000, 0);
//         uniqHook.submitOrder(poolKey, orderKey1, 1 ether);
//     }

//     function testUniqHook_updateOrder_EmitsEvent() public {
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         int256 amountDelta = -1;

//         vm.warp(20_000);

//         vm.expectEmit(true, true, false, false);
//         emit UpdateOrder(poolId, address(this), 30_000, true, 0, 10_000 << 96);
//         uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
//     }

//     function testUniqHook_updateOrder_ZeroForOne_DecreasesSellRateAndUpdatesTokensOwed() public {
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();
//         // decrease order amount by 10%
//         int256 amountDelta = -int256(orderAmountTsla) / 10;
//         uint256 feeRate = 200;

//         vm.warp(20_000);

//         (uint256 originalSellRate,) = uniqHook.getOrderPool(poolKey, true);
//         uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
//         (uint256 updatedSellRate,) = uniqHook.getOrderPool(poolKey, true);

//         uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
//         uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

//         uint256 expectedTokens1Owed = (orderAmountUsdc / 2) * (10_000 - feeRate) / 10_000;
//         uint256 tolerance = 10 ether;

//         // takes 10% off the remaining half (so 80% of the original sell rate)
//         assertEq(updatedSellRate, (originalSellRate * 80) / 100);
//         assertEq(tokens0Owed, uint256(-amountDelta));
//         assertApproxEqAbs(tokens1Owed, expectedTokens1Owed, tolerance);
//     }

//     function testUniqHook_updateOrder_OneForZero_DecreasesSellRateAndUpdatesTokensOwed() public {
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         // decrease order amount by 10%
//         int256 amountDelta = -int256(orderAmountUsdc) / 10;
//         console.log("amountDelta: ", amountDelta);

//         vm.warp(20_000);

//         (uint256 originalSellRate,) = uniqHook.getOrderPool(poolKey, false);
//         uniqHook.updateOrder(poolKey, orderKey2, amountDelta);
//         (uint256 updatedSellRate,) = uniqHook.getOrderPool(poolKey, false);

//         uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
//         uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);
//         uint256 tolerance = 0.5 ether;
//         uint256 expectedTokens0Owed = (orderAmountTsla / 2) * 10 / 100; // 10% of the remaining half

//         // takes 10% off the remaining half (so 80% of the original sell rate)
//         assertEq(updatedSellRate, (originalSellRate * 80) / 100);
//         assertEq(tokens1Owed, orderAmountUsdc / 10);
//         assertApproxEqAbs(tokens0Owed, expectedTokens0Owed, tolerance);
//     }

//     function testUniqHook_updatedOrder_ZeroForOne_ClosesOrderIfEliminatingPosition() public {
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         vm.warp(20_000);

//         uniqHook.updateOrder(poolKey, orderKey1, -1);
//         Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey1);
//         uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
//         uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey1.owner);
//         uint256 tolerance = 10 ether;
//         uint256 expectedToken1Owed = orderAmountUsdc / 2;

//         assertEq(deletedOrder.sellRate, 0);
//         assertEq(deletedOrder.rewardsFactorLast, 0);
//         assertEq(token0Owed, orderAmountTsla / 2);
//         assertApproxEqAbs(token1Owed, expectedToken1Owed, tolerance);
//     }

//     function testUniqHook_updatedOrder_OneForZero_ClosesOrderIfEliminatingPosition() public {
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         vm.warp(20_000);

//         uniqHook.updateOrder(poolKey, orderKey2, -1);
//         Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey2);
//         uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey2.owner);
//         uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);
//         uint256 tolerance = 0.5 ether;
//         uint256 expectedToken0Owed = orderAmountTsla / 2;

//         assertEq(deletedOrder.sellRate, 0);
//         assertEq(deletedOrder.rewardsFactorLast, 0);
//         assertApproxEqAbs(token0Owed, expectedToken0Owed, tolerance);
//         assertEq(token1Owed, orderAmountUsdc / 2);
//     }

//     function testUniqHook_updatedOrder_ZeroForOne_IncreaseOrderAmount() public {
//         int256 amountDelta = 1 ether;
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         vm.warp(20_000);
//         uint256 balance0Before = tsla.balanceOf(address(uniqHook));
//         tsla.approve(address(uniqHook), uint256(amountDelta));
//         uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
//         uint256 balance0After = tsla.balanceOf(address(uniqHook));

//         Struct.Order memory updatedOrder = uniqHook.getOrder(poolKey, orderKey1);
//         uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
//         uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey1.owner);

//         // the expected new balance after increasing the order amount
//         uint256 expectedSellRate = (orderAmountTsla + uint256(amountDelta)) / (orderKey1.expiration - 20_000);
//         // allow for a small difference due to rounding errors
//         uint256 tolerance = 10 ether;
//         uint256 expectedTokens1Owed = orderAmountUsdc / 2;

//         assertApproxEqAbs(balance0After - balance0Before, uint256(amountDelta), tolerance);
//         assertApproxEqAbs(updatedOrder.sellRate, expectedSellRate, tolerance);
//         assertEq(tokens0Owed, 0);
//         assertApproxEqAbs(tokens1Owed, expectedTokens1Owed, tolerance);
//     }

//     function testUniqHook_updateOrder_OneForZero_IncreaseOrderAmount() public {
//         int256 amountDelta = 250 ether;
//         Struct.OrderKey memory orderKey1;
//         Struct.OrderKey memory orderKey2;
//         uint256 orderAmountTsla;
//         uint256 orderAmountUsdc;
//         (orderKey1, orderKey2, orderAmountTsla, orderAmountUsdc) = submitOrdersBothDirections();

//         vm.warp(20_000);

//         uint256 balance1Before = usdc.balanceOf(address(uniqHook));
//         usdc.approve(address(uniqHook), uint256(amountDelta));
//         uniqHook.updateOrder(poolKey, orderKey2, amountDelta);
//         uint256 balance1After = usdc.balanceOf(address(uniqHook));

//         Struct.Order memory updatedOrder = uniqHook.getOrder(poolKey, orderKey2);
//         uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey2.owner);
//         uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);
//         uint256 tolerance = 10 ether;
//         uint256 expectedSellRate = (orderAmountUsdc + uint256(amountDelta)) / (orderKey2.expiration - 20_000);
//         uint256 expectedTokens0Owed = orderAmountTsla / 2;

//         assertApproxEqAbs(balance1After - balance1Before, uint256(amountDelta), tolerance);
//         assertApproxEqAbs(updatedOrder.sellRate, expectedSellRate, tolerance);
//         assertApproxEqAbs(tokens0Owed, expectedTokens0Owed, tolerance);
//         assertEq(tokens1Owed, 0);
//     }

//     function testUniqHook_E2ESims_SymmetricalOrderPools() public {
//         uint256 orderAmountTsla = 1 ether;
//         uint256 orderAmountUsdc = 250 ether;
//         Struct.OrderKey memory orderKey1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});
//         Struct.OrderKey memory orderKey2 =
//             Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: false});

//         tsla.approve(address(uniqHook), 100 ether);
//         usdc.approve(address(uniqHook), 250 ether);
//         modifyLiquidityRouter.modifyLiquidity(
//             poolKey,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -2400,
//                 tickUpper: 2400,
//                 liquidityDelta: 10 ether,
//                 salt: bytes32(0)
//             }),
//             ZERO_BYTES
//         );

//         vm.warp(10_000);
//         uniqHook.submitOrder(poolKey, orderKey1, orderAmountTsla);
//         uniqHook.submitOrder(poolKey, orderKey2, orderAmountUsdc);
//         vm.warp(20_000);
//         uniqHook.executeTWAMMOrders(poolKey);
//         uniqHook.updateOrder(poolKey, orderKey1, 0);
//         uniqHook.updateOrder(poolKey, orderKey2, 0);

//         uint256 rewardToken0 = uniqHook.tokensOwed(poolKey.currency0, address(this));
//         uint256 rewardToken1 = uniqHook.tokensOwed(poolKey.currency1, address(this));
//         uint256 tolerance = 10 ether;
//         uint256 expectedRewardToken0 = orderAmountTsla / 2;
//         uint256 expectedRewardToken1 = orderAmountUsdc / 2;

//         assertApproxEqAbs(rewardToken0, expectedRewardToken0, tolerance);
//         assertApproxEqAbs(rewardToken1, expectedRewardToken1, tolerance);

//         uint256 balance0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(uniqHook));
//         uint256 balance1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(uniqHook));
//         uint256 balance0BeforeThis = poolKey.currency0.balanceOfSelf();
//         uint256 balance1BeforeThis = poolKey.currency1.balanceOfSelf();
//         uint256 tolerance2 = 0.1 ether;

//         vm.warp(30_000);
//         uniqHook.executeTWAMMOrders(poolKey);
//         uniqHook.updateOrder(poolKey, orderKey1, 0);
//         uniqHook.updateOrder(poolKey, orderKey2, 0);
//         uniqHook.claimTokens(poolKey.currency0, address(this), 0);
//         uniqHook.claimTokens(poolKey.currency1, address(this), 0);

//         assertEq(uniqHook.tokensOwed(poolKey.currency0, address(this)), 0);
//         assertEq(uniqHook.tokensOwed(poolKey.currency1, address(this)), 0);

//         uint256 balance0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(uniqHook));
//         uint256 balance1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(uniqHook));
//         uint256 balance0AfterThis = poolKey.currency0.balanceOfSelf();
//         uint256 balance1AfterThis = poolKey.currency1.balanceOfSelf();
//         uint256 tolerance3 = 12 ether;

//         assertEq(balance0After, 0);
//         assertEq(balance1After, 0);
//         assertApproxEqAbs(balance0Before - balance0After, orderAmountTsla, tolerance2);
//         assertApproxEqAbs(balance1Before - balance1After, orderAmountUsdc, tolerance);
//         assertApproxEqAbs(balance0AfterThis - balance0BeforeThis, orderAmountTsla, tolerance2);
//         assertApproxEqAbs(balance1AfterThis - balance1BeforeThis, orderAmountUsdc, tolerance3);
//     }

//     function testUniqHook_LowVolatilityImpact_ZeroForOne_OnFeeAdjustment() public {
//         uint256 balance1Before = poolKey.currency1.balanceOfSelf();
//         int256 amountSpecified = 1 ether;
//         uint248 volatility = 20e18; // 20%

//         brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
//         uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

//         assertEq(uniqHook.volatility(), volatility);

//         uint24 fee = uniqHook.getFee(amountSpecified);
//         assertEq(fee, 1200);

//         BalanceDelta swapDelta = swapRouter.swap(
//             poolKey,
//             IPoolManager.SwapParams({
//                 zeroForOne: true,
//                 amountSpecified: amountSpecified,
//                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
//             }),
//             PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
//             ZERO_BYTES
//         );

//         // Check the amount of TSLA swapped
//         console.log("Amount of TSLA swapped (amount0): ", swapDelta.amount0());

//         // Amount of TSLA swapped should be close to -1 ether
//         assertApproxEqAbs(swapDelta.amount0(), -1 ether, 1e12); // Allow tiny tolerance for precision

//         // Check the amount of USDC received
//         uint256 token1Output = poolKey.currency1.balanceOfSelf() - balance1Before;
//         console.log("USDC received: ", token1Output);

//         // The amount of USDC received should be close to 250 USDC
//         assertApproxEqAbs(token1Output, 250 ether, 0.5 ether); // Allow 0.5 USDC tolerance
//     }

//     function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
//         (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
//         PoolKey memory key = PoolKey(_token0, _token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hooks);
//         return (key, key.toId());
//     }

//     function submitOrdersBothDirections()
//         internal
//         returns (Struct.OrderKey memory key1, Struct.OrderKey memory key2, uint256 amountTsla, uint256 amountUsdc)
//     {
//         key1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});
//         key2 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: false});
//         amountTsla = 1 ether;
//         amountUsdc = 250 ether;

//         tsla.approve(address(uniqHook), amountTsla);
//         usdc.approve(address(uniqHook), amountUsdc);

//         vm.warp(10_000);
//         uniqHook.submitOrder(poolKey, key1, amountTsla);
//         uniqHook.submitOrder(poolKey, key2, amountUsdc);
//     }
// }
