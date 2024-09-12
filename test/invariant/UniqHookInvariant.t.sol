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

contract UniqHookInvariant is StdInvariant, Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using PoolGetters for IPoolManager;

    bytes32 private constant VK_HASH = 0x179a48b8a2a08b246cd51cb7b78143db774a83ff75fad0d39cf0445e16773426;

    uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);

    MockERC20 tsla;
    MockERC20 usdc;
    MockBrevisProof brevisProofMock;
    UniqHook uniqHook;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        tsla = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));
        brevisProofMock = new MockBrevisProof();

        uniqHook = createUniqHook();

        (poolKey, poolId) =
            initPool(currency0, currency1, uniqHook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1, ZERO_BYTES);

        addLiquidityToPool(-60, 60, 100 ether);
        addLiquidityToPool(-120, 120, 100 ether);
        addLiquidityToPoolFullRange();
    }

    // Invariant: Volatility-based fee should decay over time according to smoothing factor
    function testUniqHookInvariant_VolatilityDecaysOverTime() public {
        uint248 initialVolatility = 70e18;
        uint248 newVolatility = 50e18;

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));

        uint256 expectedVolatility = initialVolatility / uniqHook.SMOOTHING_FACTOR();
        assertEq(uniqHook.volatility(), expectedVolatility);

        vm.warp(block.timestamp + 1 hours);

        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(newVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(newVolatility));

        uint256 previousVolatility = expectedVolatility;
        uint256 smoothedVolatility =
            (previousVolatility * (uniqHook.SMOOTHING_FACTOR() - 1) + newVolatility) / uniqHook.SMOOTHING_FACTOR();

        assertEq(uniqHook.volatility(), smoothedVolatility);
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
        uint24 maxFee = uniqHook.MAX_FEE();
        uint24 minFee = uniqHook.MIN_FEE();
        assertLe(fee, maxFee);
        assertGe(fee, minFee);
    }

    function testUniqHookInvariant_VolatilityDecays_WithMultipleSwaps() public {
        uint248 currentVolatility = 60e18;

        // Set initial volatility through brevisProofMock
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(currentVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(currentVolatility));

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
        uint256 expectedVolatility = currentVolatility / uniqHook.SMOOTHING_FACTOR();
        assertGe(uniqHook.volatility(), expectedVolatility);
        assertLe(fee, uniqHook.MAX_FEE());

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
        expectedVolatility = currentVolatility / uniqHook.SMOOTHING_FACTOR();
        assertGe(uniqHook.volatility(), expectedVolatility);
        assertLe(fee, uniqHook.MAX_FEE());
    }

    function testUniqHookInvariant_PriceMovementWithVolatility() public {
        uint248 initialVolatility = 70e18;

        // Set initial volatility through brevisProofMock
        brevisProofMock.setMockOutput(bytes32(0), keccak256(abi.encodePacked(initialVolatility)), VK_HASH);
        uniqHook.brevisCallback(bytes32(0), abi.encodePacked(initialVolatility));

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

        assertLt(postPrice, prePrice);
    }

    function createUniqHook() internal returns (UniqHook) {
        (, bytes32 salt) = HookMiner.find(
            address(this), flags, type(UniqHook).creationCode, abi.encode(manager, 10_000, address(brevisProofMock))
        );

        UniqHook hook = new UniqHook{salt: salt}(manager, 10_000, address(brevisProofMock));
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
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }
}
