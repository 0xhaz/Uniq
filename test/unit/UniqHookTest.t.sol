// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
import {UniqHook} from "src/UniqHook.sol";
import {IUniqHook} from "src/interfaces/IUniqHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {DeployUniqHook} from "script/DeployUniqHook.s.sol";

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

        DeployUniqHook uniqHookDeployer = new DeployUniqHook();
        uniqHook = UniqHook(uniqHookDeployer.run());

        tsla = MockERC20(Currency.unwrap(currency0));
        usdc = MockERC20(Currency.unwrap(currency1));

        UniqHookImplementation impl = new UniqHookImplementation(manager, 10_000, uniqHook);
        // Tell the VM to start recording all storage reads and writes
        (, bytes32[] memory writes) = vm.accesses(address(impl));
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

    function TestUniqHook_beforeInitialize_setsLastVirtualOrderTimestamp() public {
        (PoolKey memory initKey, PoolId initId) = newPoolKeyWithTWAMM(uniqHook);
        assertEq(uniqHook.lastVirtualOrderTimestamp(initId), 0);
        vm.warp(10_000);

        manager.initialize(initKey, SQRT_PRICE_1_1, ZERO_BYTES);
        assertEq(uniqHook.lastVirtualOrderTimestamp(initId), 10_000);
    }

    function newPoolKeyWithTWAMM(IHooks hooks) public returns (PoolKey memory, PoolId) {
        (Currency _token0, Currency _token1) = deployMintAndApprove2Currencies();
        PoolKey memory key = PoolKey(_token0, _token1, 0, 60, hooks);
        return (key, key.toId());
    }
}
