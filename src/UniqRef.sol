// // SPDX-License-Identifier: SEE LICENSE IN LICENSE
// pragma solidity ^0.8.25;

// import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
// import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
// import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {SafeCast} from "v4-core/libraries/SafeCast.sol";
// import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {TransferHelper} from "./lib/TransferHelper.sol";
// import {ITWAMM} from "./interfaces/ITWAMM.sol";
// import {TwammMath} from "./lib/TwammMath.sol";
// import {OrderPool} from "./lib/OrderPool.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {PoolGetters} from "./lib/PoolGetters.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
// import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {console} from "forge-std/Console.sol";

// contract TWAMM is BaseHook, ITWAMM {
//     using TransferHelper for IERC20Minimal;
//     using CurrencyLibrary for Currency;
//     using CurrencySettler for Currency;
//     using OrderPool for OrderPool.State;
//     using PoolIdLibrary for PoolKey;
//     using TickMath for int24;
//     using TickMath for uint160;
//     using SafeCast for uint256;
//     using PoolGetters for IPoolManager;
//     using TickBitmap for mapping(int16 => uint256);
//     using StateLibrary for IPoolManager;

//     bytes internal constant ZERO_BYTES = bytes("");
//     int256 internal constant MIN_DELTA = -1;
//     bool internal constant ZERO_FOR_ONE = true;
//     bool internal constant ONE_FOR_ZERO = false;

//     /// @notice Contains full state related to the TWAMM
//     /// @member lastVirtualOrderTimestamp Last timestamp in which virtual orders were executed
//     /// @member orderPool0For1 Order pool trading token0 for token1 of pool
//     /// @member orderPool1For1 Order pool trading token1 for token0 of pool
//     /// @member orders Mapping of orderId to individual orders on pool
//     struct State {
//         uint256 lastVirtualOrderTimestamp;
//         OrderPool.State orderPool0For1;
//         OrderPool.State orderPool1For0;
//         mapping(bytes32 => Order) orders;
//     }

//     /// @inheritdoc ITWAMM
//     uint256 public immutable expirationInterval;

//     // twammStates[poolId] => Twamm.State
//     mapping(PoolId => State) internal twammStates;
//     // tokensOwed[token][owner] => amountOwed
//     mapping(Currency => mapping(address => uint256)) public tokensOwed;

//     constructor(IPoolManager _manager, uint256 _expirationInterval) BaseHook(_manager) {
//         expirationInterval = _expirationInterval;
//     }

//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: true,
//             afterInitialize: false,
//             beforeAddLiquidity: true,
//             beforeRemoveLiquidity: false,
//             afterAddLiquidity: false,
//             afterRemoveLiquidity: false,
//             beforeSwap: true,
//             afterSwap: false,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: false,
//             afterSwapReturnDelta: false,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }

//     function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
//         external
//         virtual
//         override
//         onlyByPoolManager
//         returns (bytes4)
//     {
//         // one-time initialization enforced in PoolManager
//         initialize(_getTWAMM(key));
//         return this.beforeInitialize.selector;
//     }

//     function beforeAddLiquidity(
//         address,
//         PoolKey calldata key,
//         IPoolManager.ModifyLiquidityParams calldata,
//         bytes calldata
//     ) external override onlyByPoolManager returns (bytes4) {
//         executeTWAMMOrders(key);
//         return this.beforeAddLiquidity.selector;
//     }

//     function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
//         external
//         override
//         onlyByPoolManager
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         executeTWAMMOrders(key);
//         return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
//     }

//     function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256) {
//         return twammStates[key].lastVirtualOrderTimestamp;
//     }

//     function getOrder(PoolKey calldata poolKey, OrderKey calldata orderKey) external view returns (Order memory) {
//         return _getOrder(twammStates[PoolId.wrap(keccak256(abi.encode(poolKey)))], orderKey);
//     }

//     function getOrderPool(PoolKey calldata key, bool zeroForOne)
//         external
//         view
//         returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
//     {
//         State storage twamm = _getTWAMM(key);
//         return zeroForOne
//             ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
//             : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
//     }

//     /// @notice Initialize TWAMM state
//     function initialize(State storage self) internal {
//         self.lastVirtualOrderTimestamp = block.timestamp;
//     }

//     /// @inheritdoc ITWAMM
//     function executeTWAMMOrders(PoolKey memory key) public {
//         PoolId poolId = key.toId();
//         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
//         State storage state = twammStates[poolId];

//         (bool zeroForOne, uint160 sqrtPriceLimitX96) = _executeTWAMMOrders(
//             state, poolManager, key, PoolParamsOnExecute(sqrtPriceX96, poolManager.getLiquidity(poolId))
//         );

//         if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
//             poolManager.unlock(
//                 abi.encode(key, IPoolManager.SwapParams(zeroForOne, type(int256).max, sqrtPriceLimitX96))
//             );
//         }
//     }

//     /// @inheritdoc ITWAMM
//     function submitOrder(PoolKey calldata key, OrderKey memory orderKey, uint256 amountIn)
//         external
//         returns (bytes32 orderId)
//     {
//         PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
//         State storage twamm = twammStates[poolId];
//         executeTWAMMOrders(key);

//         uint256 sellRate;
//         unchecked {
//             // checks done in TWAMM library.
//             uint256 duration = orderKey.expiration - block.timestamp;
//             sellRate = amountIn / duration;
//             orderId = _submitOrder(twamm, orderKey, sellRate);
//             IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
//                 .safeTransferFrom(msg.sender, address(this), sellRate * duration);
//         }

//         emit SubmitOrder(
//             poolId,
//             orderKey.owner,
//             orderKey.expiration,
//             orderKey.zeroForOne,
//             sellRate,
//             _getOrder(twamm, orderKey).earningsFactorLast
//         );
//     }

//     /// @notice Submits a new long term order into the TWAMM.
//     /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
//     /// @param orderKey The orderKey for the new order
//     function _submitOrder(State storage self, OrderKey memory orderKey, uint256 sellRate)
//         internal
//         returns (bytes32 orderId)
//     {
//         if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
//         if (self.lastVirtualOrderTimestamp == 0) revert NotInitialized();
//         if (orderKey.expiration <= block.timestamp) revert ExpirationLessThanBlocktime(orderKey.expiration);
//         if (sellRate == 0) revert SellRateCannotBeZero();
//         if (orderKey.expiration % expirationInterval != 0) revert ExpirationNotOnInterval(orderKey.expiration);

//         console.log("////////////////// Internal Submit Order //////////////////");

//         orderId = _orderId(orderKey);
//         if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

//         OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

//         unchecked {
//             orderPool.sellRateCurrent += sellRate;
//             console.log("Pool Current Sale Rate", orderPool.sellRateCurrent);
//             orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;
//             console.log("Pool Sale Rate Ending At Time", orderPool.sellRateEndingAtInterval[orderKey.expiration]);
//         }

//         console.log("Reward Factor Last: ", orderPool.earningsFactorCurrent);
//         console.log("Sell Rate: ", sellRate);

//         self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});

//         console.log("Reward Factor Last: ", orderPool.earningsFactorCurrent);
//         console.log("Sell Rate: ", sellRate);
//     }

//     function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
//         (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
//             abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

//         BalanceDelta delta = poolManager.swap(key, swapParams, ZERO_BYTES);

//         if (swapParams.zeroForOne) {
//             if (delta.amount0() < 0) {
//                 key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
//             }
//             if (delta.amount1() > 0) {
//                 key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
//             }
//         } else {
//             if (delta.amount1() < 0) {
//                 key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
//             }
//             if (delta.amount0() > 0) {
//                 key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
//             }
//         }
//         return bytes("");
//     }

//     /// @notice Executes all existing long term orders in the TWAMM
//     /// @param pool The relevant state of the pool
//     function _executeTWAMMOrders(
//         State storage self,
//         IPoolManager manager,
//         PoolKey memory key,
//         PoolParamsOnExecute memory pool
//     ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
//         if (!_hasOutstandingOrders(self)) {
//             self.lastVirtualOrderTimestamp = block.timestamp;
//             return (false, 0);
//         }

//         console.log("////////////////// Execute Orders //////////////////");

//         uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
//         uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
//         uint256 nextExpirationTimestamp = prevTimestamp + (expirationInterval - (prevTimestamp % expirationInterval));

//         OrderPool.State storage orderPool0For1 = self.orderPool0For1;
//         OrderPool.State storage orderPool1For0 = self.orderPool1For0;

//         unchecked {
//             while (nextExpirationTimestamp <= block.timestamp) {
//                 if (
//                     orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
//                         || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
//                 ) {
//                     if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
//                         console.log("////////////////// Advance To New Time //////////////////");
//                         pool = _advanceToNewTimestamp(
//                             self,
//                             poolManager,
//                             key,
//                             AdvanceParams(
//                                 expirationInterval,
//                                 nextExpirationTimestamp,
//                                 nextExpirationTimestamp - prevTimestamp,
//                                 pool
//                             )
//                         );
//                     } else {
//                         console.log("////////////////// Advance Time for Single Pool //////////////////");
//                         pool = _advanceTimestampForSinglePoolSell(
//                             self,
//                             manager,
//                             key,
//                             AdvanceSingleParams(
//                                 expirationInterval,
//                                 nextExpirationTimestamp,
//                                 nextExpirationTimestamp - prevTimestamp,
//                                 pool,
//                                 orderPool0For1.sellRateCurrent != 0
//                             )
//                         );
//                     }
//                     prevTimestamp = nextExpirationTimestamp;
//                 }
//                 nextExpirationTimestamp += expirationInterval;

//                 if (!_hasOutstandingOrders(self)) break;
//             }

//             if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
//                 if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
//                     console.log("////////////////// Advance To New Time 2 //////////////////");
//                     pool = _advanceToNewTimestamp(
//                         self,
//                         manager,
//                         key,
//                         AdvanceParams(expirationInterval, block.timestamp, block.timestamp - prevTimestamp, pool)
//                     );
//                 } else {
//                     console.log("////////////////// Advance Time for Single Pool 2 //////////////////");
//                     pool = _advanceTimestampForSinglePoolSell(
//                         self,
//                         poolManager,
//                         key,
//                         AdvanceSingleParams(
//                             expirationInterval,
//                             block.timestamp,
//                             block.timestamp - prevTimestamp,
//                             pool,
//                             orderPool0For1.sellRateCurrent != 0
//                         )
//                     );
//                 }
//             }
//         }
//         self.lastVirtualOrderTimestamp = block.timestamp;
//         newSqrtPriceX96 = pool.sqrtPriceX96;
//         zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
//     }

//     struct AdvanceParams {
//         uint256 expirationInterval;
//         uint256 nextTimestamp;
//         uint256 secondsElapsed;
//         PoolParamsOnExecute pool;
//     }

//     function _advanceToNewTimestamp(
//         State storage self,
//         IPoolManager manager,
//         PoolKey memory poolKey,
//         AdvanceParams memory params
//     ) private returns (PoolParamsOnExecute memory) {
//         uint160 finalSqrtPriceX96;
//         uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;

//         console.log("////////////////// Advance To New Time 3 //////////////////");

//         OrderPool.State storage orderPool0For1 = self.orderPool0For1;
//         OrderPool.State storage orderPool1For0 = self.orderPool1For0;

//         while (true) {
//             TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams(
//                 secondsElapsedX96,
//                 params.pool.sqrtPriceX96,
//                 params.pool.liquidity,
//                 orderPool0For1.sellRateCurrent,
//                 orderPool1For0.sellRateCurrent
//             );

//             finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

//             (bool crossingInitializedTick, int24 tick) =
//                 _isCrossingInitializedTick(params.pool, manager, poolKey, finalSqrtPriceX96);
//             unchecked {
//                 if (crossingInitializedTick) {
//                     uint256 secondsUntilCrossingX96;
//                     (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
//                         self,
//                         poolManager,
//                         poolKey,
//                         TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool)
//                     );
//                     secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
//                 } else {
//                     (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
//                         TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

//                     if (params.nextTimestamp % params.expirationInterval == 0) {
//                         orderPool0For1.advanceToInterval(params.nextTimestamp, earningsFactorPool0);
//                         orderPool1For0.advanceToInterval(params.nextTimestamp, earningsFactorPool1);
//                     } else {
//                         orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
//                         orderPool1For0.advanceToCurrentTime(earningsFactorPool1);
//                     }
//                     params.pool.sqrtPriceX96 = finalSqrtPriceX96;
//                     break;
//                 }
//             }
//         }
//         return params.pool;
//     }

//     struct AdvanceSingleParams {
//         uint256 expirationInterval;
//         uint256 nextTimestamp;
//         uint256 secondsElapsed;
//         PoolParamsOnExecute pool;
//         bool zeroForOne;
//     }

//     function _advanceTimestampForSinglePoolSell(
//         State storage self,
//         IPoolManager manager,
//         PoolKey memory poolKey,
//         AdvanceSingleParams memory params
//     ) private returns (PoolParamsOnExecute memory) {
//         OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
//         uint256 sellRateCurrent = orderPool.sellRateCurrent;
//         uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
//         uint256 totalEarnings;

//         console.log("////////////////// Advance Time For Single Pool 3 //////////////////");

//         while (true) {
//             uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
//                 params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
//             );

//             (bool crossingInitializedTick, int24 tick) =
//                 _isCrossingInitializedTick(params.pool, manager, poolKey, finalSqrtPriceX96);

//             if (crossingInitializedTick) {
//                 (, int128 liquidityNetAtTick) = manager.getTickLiquidity(poolKey.toId(), tick);
//                 uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(tick);

//                 uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
//                     params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
//                 );
//                 uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
//                     params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
//                 );

//                 params.pool.liquidity = params.zeroForOne
//                     ? params.pool.liquidity - uint128(liquidityNetAtTick)
//                     : params.pool.liquidity + uint128(-liquidityNetAtTick);
//                 params.pool.sqrtPriceX96 = initializedSqrtPrice;

//                 unchecked {
//                     totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
//                     amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
//                 }
//             } else {
//                 if (params.zeroForOne) {
//                     totalEarnings += SqrtPriceMath.getAmount1Delta(
//                         params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
//                     );
//                 } else {
//                     totalEarnings += SqrtPriceMath.getAmount0Delta(
//                         params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
//                     );
//                 }

//                 uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;

//                 if (params.nextTimestamp % params.expirationInterval == 0) {
//                     orderPool.advanceToInterval(params.nextTimestamp, accruedEarningsFactor);
//                 } else {
//                     orderPool.advanceToCurrentTime(accruedEarningsFactor);
//                 }
//                 params.pool.sqrtPriceX96 = finalSqrtPriceX96;
//                 break;
//             }
//         }
//         return params.pool;
//     }

//     struct TickCrossingParams {
//         int24 initializedTick;
//         uint256 nextTimestamp;
//         uint256 secondsElapsedX96;
//         PoolParamsOnExecute pool;
//     }

//     function _advanceTimeThroughTickCrossing(
//         State storage self,
//         IPoolManager manager,
//         PoolKey memory poolKey,
//         TickCrossingParams memory params
//     ) private returns (PoolParamsOnExecute memory, uint256) {
//         uint160 initializedSqrtPrice = params.initializedTick.getSqrtPriceAtTick();
//         console.log("////////////////// Advance Time Through Tick Crossing //////////////////");

//         uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
//             params.pool.liquidity,
//             params.pool.sqrtPriceX96,
//             initializedSqrtPrice,
//             self.orderPool0For1.sellRateCurrent,
//             self.orderPool1For0.sellRateCurrent
//         );

//         (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
//             TwammMath.ExecutionUpdateParams(
//                 secondsUntilCrossingX96,
//                 params.pool.sqrtPriceX96,
//                 params.pool.liquidity,
//                 self.orderPool0For1.sellRateCurrent,
//                 self.orderPool1For0.sellRateCurrent
//             ),
//             initializedSqrtPrice
//         );

//         self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
//         self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

//         unchecked {
//             // update pool state
//             (, int128 liquidityNet) = manager.getTickLiquidity(poolKey.toId(), params.initializedTick);
//             if (initializedSqrtPrice < params.pool.sqrtPriceX96) liquidityNet = -liquidityNet;
//             params.pool.liquidity = liquidityNet < 0
//                 ? params.pool.liquidity - uint128(-liquidityNet)
//                 : params.pool.liquidity + uint128(liquidityNet);

//             params.pool.sqrtPriceX96 = initializedSqrtPrice;
//         }

//         return (params.pool, secondsUntilCrossingX96);
//     }

//     function _isCrossingInitializedTick(
//         PoolParamsOnExecute memory pool,
//         IPoolManager manager,
//         PoolKey memory poolKey,
//         uint160 nextSqrtPriceX96
//     ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
//         console.log("////////////////// isCrossingTick //////////////////");
//         // use current price as a starting point for nextTickInit
//         nextTickInit = pool.sqrtPriceX96.getTickAtSqrtPrice();
//         int24 targetTick = nextSqrtPriceX96.getTickAtSqrtPrice();
//         bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
//         bool nextTickInitFurtherThanTarget = false; // initialize as false

//         // NextTickInit returns the furthest tick within one word if no tick within that word is initialized
//         // so we must keep iterating if we haven't reached a tick further than our target tick
//         while (!nextTickInitFurtherThanTarget) {
//             console.log("////////////////// !NextTickIsFurtherThanTarget //////////////////");
//             unchecked {
//                 if (searchingLeft) nextTickInit -= 1;
//             }
//             (nextTickInit, crossingInitializedTick) = manager.getNextInitializedTickWithinOneWord(
//                 poolKey.toId(), nextTickInit, poolKey.tickSpacing, searchingLeft
//             );
//             nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
//             if (crossingInitializedTick == true) break;
//         }
//         if (nextTickInitFurtherThanTarget) crossingInitializedTick = false;
//     }

//     function _getTWAMM(PoolKey memory key) private view returns (State storage) {
//         return twammStates[PoolId.wrap(keccak256(abi.encode(key)))];
//     }

//     struct PoolParamsOnExecute {
//         uint160 sqrtPriceX96;
//         uint128 liquidity;
//     }

//     function _getOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
//         return self.orders[_orderId(key)];
//     }

//     function _orderId(OrderKey memory key) private pure returns (bytes32) {
//         return keccak256(abi.encode(key));
//     }

//     function _hasOutstandingOrders(State storage self) internal view returns (bool) {
//         console.log("////////////////// Has Outstanding Orders //////////////////");
//         return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
//     }
// }
