// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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

contract UniqHookTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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

    UniqHook uniqHook = UniqHook(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG))
    );

    MockERC20 tsla;
    MockERC20 usdc;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // DeployUniqHook uniqHookDeployer = new DeployUniqHook();
        // uniqHook = UniqHook(uniqHookDeployer.run());

        tsla = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));

        UniqHookImplementation impl = new UniqHookImplementation(manager, 10_000, uniqHook);
        // Tell the VM to start recording all storage reads and writes
        (, bytes32[] memory writes) = vm.accesses(address(uniqHook));
        // Enabling custom precompile for UniqHook
        vm.etch(address(uniqHook), address(impl).code);

        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i; i < writes.length; ++i) {
                bytes32 slot = writes[i];
                vm.store(address(uniqHook), slot, vm.load(address(impl), slot));
            }
        }

        // Initialize the pool
        (poolKey, poolId) = initPool(currency0, currency1, uniqHook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        tsla.approve(address(modifyLiquidityRouter), 100 ether);
        usdc.approve(address(modifyLiquidityRouter), 100 ether);
        tsla.mint(address(this), 100 ether);
        usdc.mint(address(this), 100 ether);

        // Add liquidity at short range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Add liquidity at long range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // Add liquidity at full range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function testUniqHook_beforeInitialize_setsLastVirtualOrderTimestamp() public {
        (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(uniqHook);

        assertEq(uniqHook.getLastVirtualOrder(initId), 0);
        vm.warp(10_000);

        manager.initialize(initKey, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(uniqHook.getLastVirtualOrder(initId), 10_000);
    }

    function testUniqHook_submitOrder_setOrderWithCorrectPoolAndInfo() public {
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

    function testUniqHook_submitOrder_storeProperSellRatesAndRewardsFactor() public {
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
        uniqHook.submitOrder(poolKey, orderKey1, 1e18);
        uniqHook.submitOrder(poolKey, orderKey3, 3e18);

        (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
        (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

        assertEq(sellRate0For1, 1e18 / (expiration1 - submitTimestamp1));
        assertEq(sellRate1For0, 3e18 / (expiration2 - submitTimestamp1));
        assertEq(rewardsFactor0For1, 0);
        assertEq(rewardsFactor1For0, 0);

        // Warp time and submit 1 TWAMM order. Test that pool information is updated properly as one order expires and
        // another order is added to the pool
        vm.warp(submitTimestamp2);
        uniqHook.submitOrder(poolKey, orderKey2, 2e18);

        (sellRate0For1, rewardsFactor0For1) = uniqHook.getOrderPool(poolKey, true);
        (sellRate1For0, rewardsFactor1For0) = uniqHook.getOrderPool(poolKey, false);

        assertEq(sellRate0For1, 2e18 / (expiration2 - submitTimestamp2));
        assertEq(sellRate1For0, 3 ether / (expiration2 - submitTimestamp1));
        assertEq(rewardsFactor0For1, 1712020976636017581269515821040000);
        assertEq(rewardsFactor1For0, 1470157410324350030712806974476955);
    }

    function testUniqHook_submitOrder_EmitsEvent() public {
        Struct.OrderKey memory orderKey1 = Struct.OrderKey({owner: address(this), expiration: 30_000, zeroForOne: true});

        tsla.approve(address(uniqHook), 100 ether);
        vm.warp(10_000);

        vm.expectEmit(false, false, false, true);
        emit SubmitOrder(poolId, address(this), 30_000, true, 1 ether / 20_000, 0);
        uniqHook.submitOrder(poolKey, orderKey1, 1 ether);
    }

    function testUniqHook_updateOrder_EmitsEvent() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        int256 amountDelta = -1;

        vm.warp(20_000);

        vm.expectEmit(true, true, true, true);
        emit UpdateOrder(poolId, address(this), 30_000, true, 0, 10_000 << 96);
        uniqHook.updateOrder(poolKey, orderKey1, amountDelta);
    }

    function testUniqHook_updateOrder_ZeroForOne_DecreasesSellRateAndUpdatesTokensOwed() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();
        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;

        vm.warp(20_000);

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

    function testUniqHook_updateOrder_OneForZero_DecreasesSellRateAndUpdatesTokensOwed() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        // decrease order amount by 10%
        int256 amountDelta = -int256(orderAmount) / 10;

        vm.warp(20_000);

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

    function testUniqHook_updatedOrder_ZeroForOne_ClosesOrderIfEliminatingPosition() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        vm.warp(20_000);

        uniqHook.updateOrder(poolKey, orderKey1, -1);
        Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey1);
        uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey1.owner);
        uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey1.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.rewardsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testUniqHook_updatedOrder_OneForZero_ClosesOrderIfEliminatingPosition() public {
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        vm.warp(20_000);

        uniqHook.updateOrder(poolKey, orderKey2, -1);
        Struct.Order memory deletedOrder = uniqHook.getOrder(poolKey, orderKey2);
        uint256 token0Owed = uniqHook.tokensOwed(poolKey.currency0, orderKey2.owner);
        uint256 token1Owed = uniqHook.tokensOwed(poolKey.currency1, orderKey2.owner);

        assertEq(deletedOrder.sellRate, 0);
        assertEq(deletedOrder.rewardsFactorLast, 0);
        assertEq(token0Owed, orderAmount / 2);
        assertEq(token1Owed, orderAmount / 2);
    }

    function testUniqHook_updatedOrder_ZeroForOne_IncreaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        vm.warp(20_000);
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

    function testUniqHook_updateOrder_OneForZero_IncreaseOrderAmount() public {
        int256 amountDelta = 1 ether;
        Struct.OrderKey memory orderKey1;
        Struct.OrderKey memory orderKey2;
        uint256 orderAmount;
        (orderKey1, orderKey2, orderAmount) = submitOrdersBothDirections();

        vm.warp(20_000);

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

    function testUniqHook_E2ESims_SymmetricalOrderPools() public {
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

        vm.warp(10_000);
        uniqHook.submitOrder(poolKey, orderKey1, orderAmount);
        uniqHook.submitOrder(poolKey, orderKey2, orderAmount);
        vm.warp(20_000);
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

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory key = PoolKey(_token0, _token1, 0, 60, hooks);
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
}
