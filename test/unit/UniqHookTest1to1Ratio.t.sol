// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
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
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Constants} from "src/libraries/Constants.sol";

contract UniqHookTest1to1Ratio is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    bytes32 private constant VK_HASH = 0x179a48b8a2a08b246cd51cb7b78143db774a83ff75fad0d39cf0445e16773426;

    event SubmitOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    event UpdateOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    // use LINK/USD for TSLA/USDC
    address priceFeed = 0xc59E3633BAAC79493d908e63626716e204A45EdF;

    MockERC20 tsla;
    MockERC20 usdc;
    MockBrevisProof brevisProofMock;
    UniqHook uniqHook;
    PoolKey poolKey;
    PoolId poolId;
    MockV3Aggregator tslaPriceOracle;
    MockV3Aggregator priceOracle;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // DeployUniqHook uniqHookDeployer = new DeployUniqHook();
        // uniqHook = UniqHook(uniqHookDeployer.run());

        tsla = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));
        brevisProofMock = new MockBrevisProof();
        tslaPriceOracle = new MockV3Aggregator(18, 250e18);
        priceOracle = new MockV3Aggregator(18, 1e8);

        // UniqHookImplementation impl =
        //     new UniqHookImplementation(manager, 10_000, IBrevisApp(address(brevisProofMock)), uniqHook);
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(UniqHook).creationCode,
            abi.encode(manager, 10_000, address(brevisProofMock), address(priceOracle))
        );
        // Tell the VM to start recording all storage reads and writes
        // (, bytes32[] memory writes) = vm.accesses(address(uniqHook));

        // Enabling custom precompile for UniqHook
        // vm.etch(address(uniqHook), address(impl).code);
        uniqHook = new UniqHook{salt: salt}(manager, 10_000, address(brevisProofMock), address(priceOracle));
        uniqHook.setVkHash(VK_HASH);

        // for each storage key that was written during the hook implementation, copy the value over
        // unchecked {
        //     for (uint256 i; i < writes.length; ++i) {
        //         bytes32 slot = writes[i];
        //         vm.store(address(uniqHook), slot, vm.load(address(impl), slot));
        //     }
        // }

        // Initialize the pool
        (poolKey, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, uniqHook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1, ZERO_BYTES
        );

        tsla.approve(address(modifyLiquidityRouter), 10000 ether);
        usdc.approve(address(modifyLiquidityRouter), 10000 ether);
        tsla.mint(address(this), 10000 ether);
        usdc.mint(address(this), 10000 ether);

        // Add liquidity at short range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // seedMoreLiquidity(poolKey, 10 ether, 10 ether);

        // Add liquidity at long range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // seedMoreLiquidity(poolKey, 10 ether, 10 ether);

        // Add liquidity at full range
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

        // seedMoreLiquidity(poolKey, 10 ether, 10 ether);
    }

    function testUniqHook1to1_beforeInitialize_setsLastVirtualOrderTimestamp() public {
        (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(uniqHook);

        assertEq(uniqHook.getLastVirtualOrder(initId), 0);
        vm.warp(10_000);

        manager.initialize(initKey, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(uniqHook.getLastVirtualOrder(initId), 10_000);
    }

    function testUniqHook1to1_submitOrder_setOrderWithCorrectPoolAndInfo() public {
        uint160 expiration = 30_000;
        uint160 submitTimestamp = 10_000;
        uint160 duration = expiration - submitTimestamp;

        Struct.OrderKey memory orderKey =
            Struct.OrderKey({owner: address(this), expiration: expiration, zeroForOne: true});

        Struct.Order memory nullOrder = uniqHook.getOrder(poolKey, orderKey);
        assertEq(nullOrder.sellRate, 0);
        assertEq(nullOrder.rewardsFactorLast, 0);

        vm.warp(10_000);
        tsla.approve(address(uniqHook), 100 ether);
        snapStart("submitOrder");
        uniqHook.submitOrder(poolKey, orderKey, 1 ether);
        snapEnd();

        Struct.Order memory submittedOrder = uniqHook.getOrder(poolKey, orderKey);
        (uint256 currentSellRate0For1, uint256 currentRewardFactor0For1) = uniqHook.getOrderPool(poolKey, true);
        (uint256 currentSellRate1For0, uint256 currentRewardFactor1For0) = uniqHook.getOrderPool(poolKey, false);

        assertEq(submittedOrder.sellRate, 1 ether / duration);
        assertEq(submittedOrder.rewardsFactorLast, 0);
        assertEq(currentSellRate0For1, 1 ether / duration);
        assertEq(currentSellRate1For0, 0);
        assertEq(currentRewardFactor0For1, 0);
        assertEq(currentRewardFactor1For0, 0);
    }

    function testUniqHook1to1_submitOrder_storeProperSellRatesAndRewardsFactor() public {
        uint160 expiration1 = 30_000;
        uint160 expiration2 = 40_000;
        uint256 submitTimestamp1 = 10_000;
        uint256 submitTimestamp2 = 30_000;
        uint256 rewardsFactor0For1;
        uint256 rewardsFactor1For0;
        uint256 sellRate0For1;
        uint256 sellRate1For0;

        Struct.OrderKey memory orderKey1 =
            Struct.OrderKey({owner: address(this), expiration: expiration1, zeroForOne: true});
        Struct.OrderKey memory orderKey2 =
            Struct.OrderKey({owner: address(this), expiration: expiration2, zeroForOne: true});
        Struct.OrderKey memory orderKey3 =
            Struct.OrderKey({owner: address(this), expiration: expiration2, zeroForOne: false});

        tsla.approve(address(uniqHook), 100 ether);
        usdc.approve(address(uniqHook), 100 ether);

        vm.warp(submitTimestamp1);
        priceOracle.updateAnswer(100e18);
        uniqHook.submitOrder(poolKey, orderKey1, 1e18);
        uniqHook.submitOrder(poolKey, orderKey3, 3e18);

        (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
        (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

        assertEq(sellRate0For1, 1e18 / (expiration1 - submitTimestamp1));
        assertEq(sellRate1For0, 3e18 / (expiration2 - submitTimestamp1));
        assertEq(rewardsFactor0For1, 0);
        assertEq(rewardsFactor1For0, 0);

        vm.warp(submitTimestamp2);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        // Warp time and submit 1 TWAMM order. Test that pool information is updated properly as one order expires and
        // another order is added to the pool

        uniqHook.submitOrder(poolKey, orderKey2, 2e18);

        (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
        (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

        assertEq(sellRate0For1, 2e18 / (expiration2 - submitTimestamp2));
        assertEq(sellRate1For0, 3 ether / (expiration2 - submitTimestamp1));
        assertEq(rewardsFactor0For1, 1585091203363510286791812995220000);
        assertEq(rewardsFactor1For0, 1584035531624958300378123585590279);
    }

    function testUniqHook1to1_submitOrder_EmitsEvent() public {
        Struct.OrderKey memory orderKey1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});

        tsla.approve(address(uniqHook), 100 ether);
        vm.warp(10_000);

        vm.expectEmit(false, false, false, true);
        emit SubmitOrder(poolId, address(this), 30_000, true, 1 ether / 20_000, 0);
        uniqHook.submitOrder(poolKey, orderKey1, 1 ether);
    }

    function testUniqHook1to1_updateOrder_EmitsEvent() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        int256 amountDelta = -1;
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        vm.expectEmit(true, true, true, true);
        emit UpdateOrder(poolId, address(this), 30_000, true, 0, 10_000 << 96);
        uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
    }

    function testUniqHook1to1_updateOrder_ZeroForOne_DecreasesSellRateAndUpdatesTokensOwed() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        (uint256 originalSellRate,) = uniqHook.getOrderPool(poolKey, true);
        uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
        (uint256 updatedSellRate,) = uniqHook.getOrderPool(poolKey, true);

        uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

        // takes 10% off the remaining half (so 80% of the original sell rate)
        assertEq(updatedSellRate, (originalSellRate * 80) / 100);
        assertEq(tokens0Owed, uint256(-amountDelta));
        assertEq(tokens1Owed, orderAmount / 2);
    }

    function testUniqHook1to1_updateOrder_OneForZero_DecreasesSellRateAndUpdatesTokensOwed() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        (uint256 originalSellRate,) = uniqHook.getOrderPool(poolKey, false);
        uniqHook.updateOrder(poolKey, orderKey2, amountDelta);
        (uint256 updatedSellRate,) = uniqHook.getOrderPool(poolKey, false);

        uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

        // takes 10% off the remaining half (so 80% of the original sell rate)
        assertEq(updatedSellRate, (originalSellRate * 80) / 100);
        assertEq(tokens0Owed, orderAmount / 2);
        assertEq(tokens1Owed, uint256(-amountDelta));
    }

    function testUniqHook1to1_updatedOrder_ZeroForOne_ClosesOrderIfEliminatingPosition() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        uniqHook.updateOrder(poolKey, orderKey1, -1);
        Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey1);
        uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey1.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.rewardsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testUniqHook1to1_updatedOrder_OneForZero_ClosesOrderIfEliminatingPosition() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        uniqHook.updateOrder(poolKey, orderKey2, -1);
        Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey2);
        uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.rewardsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testUniqHook1to1_updatedOrder_ZeroForOne_IncreaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        uint256 balance0Before = tsla.balanceOf(address(uniqHook));
        tsla.approve(address(uniqHook), uint256(amountDelta));
        uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
        uint256 balance0After = tsla.balanceOf(address(uniqHook));

        Struct.Order memory updatedOrder = uniqHook.getOrder(poolKey, orderKey1);
        uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey1.owner);

        assertEq(balance0After - balance0Before, uint256(amountDelta));
        assertEq(updatedOrder.sellRate, 150000000000000);
        assertEq(tokens0Owed, 0);
        assertEq(tokens1Owed, orderAmount / 2);
    }

    function testUniqHook1to1_updateOrder_OneForZero_IncreaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        priceOracle.updateAnswer(100e18);

        vm.warp(20_000);

        uint80 roundId = 2;
        int256 answer = 100e18;
        uint256 startedAt = block.timestamp - 100;
        uint256 updatedAt = block.timestamp - 1;
        priceOracle.updateRoundData(roundId, answer, updatedAt, startedAt);

        uint256 balance1Before = usdc.balanceOf(address(uniqHook));
        usdc.approve(address(uniqHook), uint256(amountDelta));
        uniqHook.updateOrder(poolKey, orderKey2, amountDelta);
        uint256 balance1After = usdc.balanceOf(address(uniqHook));

        Struct.Order memory updatedOrder = uniqHook.getOrder(poolKey, orderKey2);
        uint256 tokens0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 tokens1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(balance1After - balance1Before, uint256(amountDelta));
        assertEq(updatedOrder.sellRate, 150000000000000);
        assertEq(tokens0Owed, orderAmount / 2);
        assertEq(tokens1Owed, 0);
    }

    function testUniqHook1to1_E2ESims_SymmetricalOrderPools() public {
        uint256 orderAmount = 1 ether;
        Struct.OrderKey memory orderKey1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});
        Struct.OrderKey memory orderKey2 =
            Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: false});

        tsla.approve(address(uniqHook), 100 ether);
        usdc.approve(address(uniqHook), 100 ether);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -2400,
                tickUpper: 2400,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        priceOracle.updateAnswer(100e18);

        vm.warp(10_000);

        priceOracle.updateRoundData(2, 100e18, 9500, 9900);

        // debugging
        (uint80 _roundId, int256 _price, uint256 _startedAt, uint256 _updatedAt, uint80 _answeredInRound) =
            priceOracle.latestRoundData();
        emit log_named_uint("Oracle roundId", _roundId);
        emit log_named_uint("Oracle startedAt", _startedAt);
        emit log_named_uint("Oracle updatedAt", _updatedAt);

        uniqHook.submitOrder(poolKey, orderKey1, orderAmount);
        uniqHook.submitOrder(poolKey, orderKey2, orderAmount);

        vm.warp(20_000);

        priceOracle.updateRoundData(3, 100e18, 19500, 19900);

        // debugging
        (_roundId, _price, _startedAt, _updatedAt, _answeredInRound) = priceOracle.latestRoundData();
        emit log_named_uint("Oracle roundId (after warp 20_000)", _roundId);
        emit log_named_uint("Oracle startedAt (after warp 20_000)", _startedAt);
        emit log_named_uint("Oracle updatedAt (after warp 20_000)", _updatedAt);

        uniqHook.executeTWAMMOrders(poolKey);
        uniqHook.updateOrder(poolKey, orderKey1, 0);
        uniqHook.updateOrder(poolKey, orderKey2, 0);

        uint256 rewardToken0 = uniqHook.tokensOwed(poolKey.currency0, address(this));
        uint256 rewardToken1 = uniqHook.tokensOwed(poolKey.currency1, address(this));

        assertEq(rewardToken0, orderAmount / 2);
        assertEq(rewardToken1, orderAmount / 2);

        uint256 balance0Before = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(uniqHook));
        uint256 balance1Before = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(uniqHook));
        uint256 balance0BeforeThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1BeforeThis = poolKey.currency1.balanceOfSelf();

        vm.warp(30_000);

        priceOracle.updateRoundData(4, 100e18, 29500, 29900);

        // debugging
        (_roundId, _price, _startedAt, _updatedAt, _answeredInRound) = priceOracle.latestRoundData();
        emit log_named_uint("Oracle roundId (after warp 30_000)", _roundId);
        emit log_named_uint("Oracle startedAt (after warp 30_000)", _startedAt);
        emit log_named_uint("Oracle updatedAt (after warp 30_000)", _updatedAt);

        uniqHook.executeTWAMMOrders(poolKey);
        uniqHook.updateOrder(poolKey, orderKey1, 0);
        uniqHook.updateOrder(poolKey, orderKey2, 0);
        uniqHook.claimTokens(poolKey.currency0, address(this), 0);
        uniqHook.claimTokens(poolKey.currency1, address(this), 0);

        assertEq(uniqHook.tokensOwed(poolKey.currency0, address(this)), 0);
        assertEq(uniqHook.tokensOwed(poolKey.currency1, address(this)), 0);

        uint256 balance0After = MockERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(uniqHook));
        uint256 balance1After = MockERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(uniqHook));
        uint256 balance0AfterThis = poolKey.currency0.balanceOfSelf();
        uint256 balance1AfterThis = poolKey.currency1.balanceOfSelf();

        assertEq(balance0After, 0);
        assertEq(balance1After, 0);
        assertEq(balance0Before - balance0After, orderAmount);
        assertEq(balance1Before - balance1After, orderAmount);
        assertEq(balance0AfterThis - balance0BeforeThis, orderAmount);
        assertEq(balance1AfterThis - balance1BeforeThis, orderAmount);
    }

    function testUniqHook1to1_LowVolatilityImpact_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 1 ether;
        uint248 volatility = 20e18;

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        // Check the expected volatility change based on dynamic smoothing
        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        uint128 liquidityAfterModification = manager.getLiquidity(poolKey.toId());
        console.log("Liquidity after modification: %d", liquidityAfterModification);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        console.log("Liquidity before swap: %s", manager.getLiquidity(poolKey.toId()));
        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        console.log("Liquidity after swap: %s", manager.getLiquidity(poolKey.toId()));

        (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) = manager.getFeeGrowthGlobals(key.toId());
        console.log("Fee Growth Global 0: %s, Fee Growth Global 1: %s", feeGrowthGlobal0, feeGrowthGlobal1);

        // Assert that the fee growth is non-zero
        // assertGt(feeGrowthGlobal0, 0, "Fee Growth Global 0 should be greater than zero");
        // assertGt(feeGrowthGlobal1, 0, "Fee Growth Global 1 should be greater than zero");

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("Low volatility fee: %d", fee);

        assertEq(fee, 408);
        assertEq(swapDelta.amount0(), -1000383352500958382);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_LowVolatilityWithLiquidity_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 10 ether;
        uint248 volatility = 20e18;

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        tsla.approve(address(modifyLiquidityRouter), 1000 ether);
        usdc.approve(address(modifyLiquidityRouter), 1000 ether);

        // IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
        //     tickLower: -60,
        //     tickUpper: 60,
        //     liquidityDelta: 100_000 ether,
        //     salt: bytes32(0)
        // });

        // modifyLiquidityRouter.modifyLiquidity(poolKey, modifyParams, ZERO_BYTES);

        uint128 liquidityAfterModification = manager.getLiquidity(poolKey.toId());
        console.log("Liquidity after modification: %d", liquidityAfterModification);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        console.log("Liquidity before swap: %s", manager.getLiquidity(poolKey.toId()));
        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        console.log("Liquidity after swap: %s", manager.getLiquidity(poolKey.toId()));

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);

        assertEq(fee, 408);
        assertEq(swapDelta.amount0(), -10034107214644990274);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_LowVolatilityHighVolume_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 100 ether;
        uint248 volatility = 30e18; // 20%

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        uint128 liquidityAfterModification = manager.getLiquidity(poolKey.toId());
        console.log("Liquidity after modification: %d", liquidityAfterModification);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        console.log("Liquidity before swap: %s", manager.getLiquidity(poolKey.toId()));
        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);
        console.log("Liquidity after swap: %s", manager.getLiquidity(poolKey.toId()));

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("Low volatility fee: %d", fee);

        assertEq(fee, 468);
        assertEq(swapDelta.amount0(), -109171483690460650278);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_MidVolatilityImpact_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 1 ether;
        uint248 volatility = 60e18; // 60%

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("Medium volatility fee: %d", fee);

        assertEq(fee, 792);
        assertEq(swapDelta.amount0(), -1000502418242016235);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_MidVolatilityHighVolume_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 100 ether;
        uint248 volatility = 60e18; // 60%

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("Medium volatility fee: %d", fee);

        assertEq(fee, 792);
        assertEq(swapDelta.amount0(), -109183276875959142688);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_HighVolatilityImpact_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 1 ether;
        uint248 volatility = 100e18; // 100%

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        assertEq(uniqHook.volatility(), expectedVolatility);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("High volatility fee: %d", fee);

        assertEq(fee, 1000);
        assertEq(swapDelta.amount0(), -1000758655762032198);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_HighVolatilityHighVolume_OnFeeAdjustment() public {
        uint256 balance1Before = poolKey.currency1.balanceOfSelf();
        int256 amountSpecified = 100 ether;
        uint248 volatility = 100e18; // 100%

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(volatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(volatility));

        uint256 volatilityUint = volatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = volatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = volatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false});

        BalanceDelta swapDelta = swapRouter.swap(poolKey, params, settings, ZERO_BYTES);

        uint24 fee = uniqHook.getFee(amountSpecified, key, params);
        console.log("High volatility fee: %d", fee);

        assertEq(fee, 1000);
        assertEq(swapDelta.amount0(), -109211241273679089242);
        uint256 token1Output = currency1.balanceOfSelf() - balance1Before;
        assertEq(int256(swapDelta.amount1()), int256(token1Output));
        assertEq(int256(token1Output), amountSpecified);
    }

    function testUniqHook1to1_FluctuateVolatility_PriceMovementOverTime() public {
        int256 amountSpecified = 10 ether; // Swap amount
        uint248 initialVolatility = 75e18; // Initial volatility (70%)

        // Simulate an initial high volatility environment
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));

        uint256 volatilityUint = initialVolatility;
        uint256 volatilityChange = abs(int256(volatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = initialVolatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = initialVolatility / Constants.MAX_VOLATILITY_CHANGE_PCT; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Perform an initial swap to set a price change
        uint24 initialFee = uniqHook.getFee(amountSpecified, poolKey, params);
        console.log("Initial fee before 1-hour wait: %d", initialFee);

        BalanceDelta swapDelta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        assertEq(initialFee, 255); // Expected high initial fee due to volatility and movement
        assertEq(swapDelta.amount0(), -10043649158442700725);

        vm.warp(block.timestamp + 1 hours); // Wait 1 hour
        uint248 decayedVolatility = 60e18;
        int256 amountSpecified2 = 20 ether;

        // Simulate a lower volatility environment after 1 hour
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(decayedVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(decayedVolatility));

        uint256 volatilityUint2 = decayedVolatility;
        volatilityChange = abs(int256(volatilityUint2) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility2;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility2 = decayedVolatility / 5;
        } else {
            expectedVolatility2 = decayedVolatility / Constants.MAX_VOLATILITY_CHANGE_PCT; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params2 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified2,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 newFee = uniqHook.getFee(amountSpecified, poolKey, params2);
        console.log("New fee after 1-hour wait: %d", newFee);

        swapDelta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified2,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        assertEq(newFee, 1000);
        assertEq(swapDelta.amount0(), -20483103072751030820);

        vm.warp(block.timestamp + 6 hours); // Wait 6 hours
        uint248 decayedVolatility2 = 50e18;
        int256 amountSpecified3 = 30 ether;

        // Simulate a lower volatility environment after 6 hours
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(decayedVolatility2)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(decayedVolatility2));

        uint256 volatilityUint3 = decayedVolatility2;
        volatilityChange = abs(int256(volatilityUint3) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility3;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility3 = decayedVolatility2 / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility3 = decayedVolatility2 / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params3 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified3,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 newFee2 = uniqHook.getFee(amountSpecified, poolKey, params3);
        console.log("New fee after 6-hour wait: %d", newFee2);

        swapDelta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified3,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        assertEq(newFee2, 1000); // Expected lower fee due to decayed volatility
        assertEq(swapDelta.amount0(), -32323778080381082990);

        vm.warp(block.timestamp + 12 hours); // Wait 12 hours
        uint248 decayedVolatility3 = 40e18;
        int256 amountSpecified4 = 30 ether;

        // Simulate a lower volatility environment after 12 hours
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(decayedVolatility3)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(decayedVolatility3));

        uint256 volatilityUint4 = decayedVolatility3;
        volatilityChange = abs(int256(volatilityUint4) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility4;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility4 = decayedVolatility3 / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility4 = decayedVolatility3 / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params4 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified4,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 newFee3 = uniqHook.getFee(amountSpecified, poolKey, params4);
        console.log("New fee after 12-hour wait: %d", newFee3);

        swapDelta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified4,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        assertEq(newFee3, 1000);
        assertEq(swapDelta.amount0(), -34434183308436849251);

        vm.warp(block.timestamp + 24 hours); // Wait 24 hours
        uint248 decayedVolatility4 = 30e18;
        int256 amountSpecified5 = 40 ether;

        // Simulate a lower volatility environment after 24 hours
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(decayedVolatility4)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(decayedVolatility4));

        uint256 volatilityUint5 = decayedVolatility4;
        volatilityChange = abs(int256(volatilityUint5) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility5;

        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility5 = decayedVolatility4 / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility5 = decayedVolatility4 / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }

        IPoolManager.SwapParams memory params5 = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified5,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        uint24 newFee4 = uniqHook.getFee(amountSpecified, poolKey, params5);
        console.log("New fee after 24-hour wait: %d", newFee4);

        swapDelta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: amountSpecified5,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({settleUsingBurn: false, takeClaims: false}),
            ZERO_BYTES
        );

        assertEq(newFee4, 1000); // Expected lower fee due to decayed volatility
        assertEq(swapDelta.amount0(), -49568580013368816921);
    }

    function testTrackVolatilityChanges() public {
        uint248 initialVolatility = 50e18; // Initial 50%
        uint248 newVolatility = 40e18; // New 40%
        uint248 newVolatility2 = 30e18; // New 30%

        // Set initial volatility
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));
        uint256 firstVolatility = uniqHook.volatility();

        // Calculate the expected volatility after the first update
        uint256 initialVolatilityUint = initialVolatility;
        uint256 volatilityChange = abs(int256(initialVolatilityUint) - int256(0)); // Old volatility is 0 at first
        uint256 expectedVolatility;
        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = initialVolatility / 5; // Dynamic smoothing factor = 5
        } else {
            expectedVolatility = initialVolatility / Constants.SMOOTHING_FACTOR; // Regular smoothing factor
        }
        assertEq(uniqHook.volatility(), expectedVolatility);

        // Update volatility with a new value (decayed)
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(newVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(newVolatility));
        uint256 secondVolatility = uniqHook.volatility();

        // Recalculate expected volatility for the second update
        uint256 newVolatilityUint = newVolatility;
        volatilityChange = abs(int256(newVolatilityUint) - int256(firstVolatility));
        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = (firstVolatility * 4 + newVolatility) / 5; // Apply dynamic smoothing factor
        } else {
            expectedVolatility =
                (firstVolatility * (Constants.SMOOTHING_FACTOR - 1) + newVolatility) / Constants.SMOOTHING_FACTOR;
        }
        assertEq(uniqHook.volatility(), expectedVolatility);

        // Update volatility again
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(newVolatility2)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(newVolatility2));

        // Recalculate expected volatility for the third update
        uint256 newVolatilityUint2 = newVolatility2;
        volatilityChange = abs(int256(newVolatilityUint2) - int256(secondVolatility));
        if (volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT) {
            expectedVolatility = (secondVolatility * 4 + newVolatility2) / 5; // Dynamic smoothing factor
        } else {
            expectedVolatility =
                (secondVolatility * (Constants.SMOOTHING_FACTOR - 1) + newVolatility2) / Constants.SMOOTHING_FACTOR;
        }
        assertEq(uniqHook.volatility(), expectedVolatility);
    }

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory key = PoolKey(_token0, _token1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, hooks);
        return (key, key.toId());
    }

    function submitOrdersBothDirections()
        internal
        returns (Struct.OrderKey memory key1, Struct.OrderKey memory key2, uint256 amount)
    {
        key1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});
        key2 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: false});
        amount = 1 ether;

        tsla.approve(address(uniqHook), amount);
        usdc.approve(address(uniqHook), amount);

        vm.warp(10_000);
        uniqHook.submitOrder(poolKey, key1, amount);
        uniqHook.submitOrder(poolKey, key2, amount);
    }

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
