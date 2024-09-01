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
// import {TransferHelper} from "src/libraries/TransferHelper.sol";
// import {IUniqHook} from "src/interfaces/IUniqHook.sol";
// import {TwammMath} from "src/libraries/TWAMMMath.sol";
// import {OrderPool} from "src/libraries/OrderPool.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {PoolGetters} from "src/libraries/PoolGetters.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";
// import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
// import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {Constants} from "src/libraries/Constants.sol";
// import {Oracle} from "src/libraries/Oracle.sol";
// import {LongTermOrder} from "src/libraries/LongTermOrder.sol";
// import {Struct} from "src/libraries/Struct.sol";
// import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
// import {BrevisApp, IBrevisProof} from "src/abstracts/brevis/BrevisApp.sol";
// import {Errors} from "src/libraries/Errors.sol";
// import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
// import {console} from "forge-std/Console.sol";

// contract UniqHook is BaseHook, IUniqHook, BrevisApp {
//     using TransferHelper for IERC20Minimal;
//     using CurrencyLibrary for Currency;
//     using CurrencySettler for Currency;
//     using PoolIdLibrary for PoolKey;
//     using TickMath for int24;
//     using TickMath for uint160;
//     using SafeCast for uint256;
//     using PoolGetters for IPoolManager;
//     using TickBitmap for mapping(int16 => uint256);
//     using StateLibrary for IPoolManager;
//     using LPFeeLibrary for uint24;
//     using Oracle for Struct.Observation[65535];

//     enum MarketDirection {
//         Bullish,
//         Bearish,
//         Uncertain
//     }

//     uint256 public immutable expirationInterval;
//     bytes32 public vkHash;
//     uint256 public volatility;
//     bool uncertainIsBullish;
//     uint256 numLongTimePeriods;
//     uint256 numShortTimePeriods;

//     // keeping track of the moving average gas price
//     uint128 movingAverageGasPrice;
//     uint104 movingAverageGasCount;

//     /// @notice The list of observations for a given poolId
//     mapping(PoolId => Struct.Observation[65535]) public observations;
//     /// @notice The current observation array state for the pool
//     mapping(PoolId => Struct.ObservationState) public observationStates;

//     uint24 public constant BASE_FEE = 200; // 2bps
//     uint24 public constant HOOK_COMMISSION = 100; // 1bps paid to the hook to cover Brevis costs

//     /// @notice The state of the long term orders
//     mapping(PoolId => Struct.OrderState) internal orderStates;

//     /// @notice The amount of tokens owed to each user
//     mapping(Currency => mapping(address => uint256)) public tokensOwed;

//     constructor(IPoolManager poolManager, uint256 expirationInterval_, address brevisProof_)
//         BaseHook(poolManager)
//         BrevisApp(IBrevisProof(brevisProof_))
//     {
//         expirationInterval = expirationInterval_;
//     }

//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: true,
//             afterInitialize: true,
//             beforeAddLiquidity: true,
//             beforeRemoveLiquidity: true,
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
//         override
//         onlyByPoolManager
//         returns (bytes4)
//     {
//         int24 maxTickSpacing = type(int16).max;

//         if (!key.fee.isDynamicFee() || key.tickSpacing != maxTickSpacing) {
//             revert Errors.MustUseDynamicFee();
//         }

//         LongTermOrder.initialize(_getTWAMM(key));

//         return this.beforeInitialize.selector;
//     }

//     function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
//         external
//         override
//         onlyByPoolManager
//         returns (bytes4)
//     {
//         PoolId id = key.toId();
//         (observationStates[id].cardinality, observationStates[id].cardinalityNext) =
//             observations[id].initialize(_blockTimestamp());
//         return this.afterInitialize.selector;
//     }

//     function beforeAddLiquidity(
//         address,
//         PoolKey calldata key,
//         IPoolManager.ModifyLiquidityParams calldata params,
//         bytes calldata
//     ) external override onlyByPoolManager returns (bytes4) {
//         int24 maxTickSpacing = type(int16).max;
//         if (
//             params.tickLower != TickMath.minUsableTick(maxTickSpacing)
//                 || params.tickUpper != TickMath.maxUsableTick(maxTickSpacing)
//         ) {
//             revert Errors.OraclePositionMustBeFullRange();
//         }
//         executeTWAMMOrders(key);
//         _updatePool(key);
//         return this.beforeAddLiquidity.selector;
//     }

//     function beforeRemoveLiquidity(
//         address,
//         PoolKey calldata,
//         IPoolManager.ModifyLiquidityParams calldata,
//         bytes calldata
//     ) external view override onlyByPoolManager returns (bytes4) {
//         return this.beforeRemoveLiquidity.selector;
//     }

//     function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
//         external
//         override
//         onlyByPoolManager
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         _updatePool(key);
//         executeTWAMMOrders(key);

//         // calculate dynamic fee based on volatility
//         uint24 dynamicFee = calculateFee(abs(params.amountSpecified));

//         dynamicFee = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

//         return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
//     }

//     ///////////////////////////////////////////////////////////////////////
//     ///                     Public Functions                            ///
//     ///////////////////////////////////////////////////////////////////////
//     /// @inheritdoc IUniqHook
//     function executeTWAMMOrders(PoolKey memory key) public {
//         console.log("////////////////// Execute TWAMM Orders //////////////////");
//         PoolId id = key.toId();
//         (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
//         Struct.OrderState storage state = orderStates[id];

//         (bool zeroForOne, uint160 sqrtPriceLimitX96) = LongTermOrder.executeOrders(
//             state,
//             poolManager,
//             key,
//             Struct.ExecutePool({sqrtPriceX96: sqrtPriceX96, liquidity: poolManager.getLiquidity(id)}),
//             expirationInterval
//         );

//         if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
//             poolManager.unlock(
//                 abi.encode(key, IPoolManager.SwapParams(zeroForOne, type(int256).max, sqrtPriceLimitX96))
//             );
//         }
//     }

//     function getLastVirtualOrder(PoolId key) public view returns (uint256) {
//         return orderStates[key].lastVirtualOrderTime;
//     }

//     ///////////////////////////////////////////////////////////////////////
//     ///                     External Functions                          ///
//     ///////////////////////////////////////////////////////////////////////
//     /// @inheritdoc IUniqHook
//     function submitOrder(PoolKey calldata key, Struct.OrderKey memory orderKey, uint256 amountIn)
//         external
//         returns (bytes32 orderId)
//     {
//         console.log("////////////////// Submit Order //////////////////");
//         PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
//         Struct.OrderState storage state = orderStates[id];
//         executeTWAMMOrders(key);

//         uint256 sellRate;
//         unchecked {
//             uint256 duration = orderKey.expiration - block.timestamp;
//             sellRate = amountIn / duration;
//             orderId = LongTermOrder.submitOrder(state, orderKey, sellRate, expirationInterval);
//             IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
//                 .safeTransferFrom(msg.sender, address(this), sellRate * duration);
//         }

//         emit SubmitOrder(
//             id,
//             orderKey.owner,
//             orderKey.expiration,
//             orderKey.zeroForOne,
//             sellRate,
//             LongTermOrder.getOrder(state, orderKey).rewardsFactorLast
//         );
//     }

//     /// @inheritdoc IUniqHook
//     function updateOrder(PoolKey memory key, Struct.OrderKey memory orderKey, int256 amountDelta)
//         external
//         returns (uint256 tokens0Owed, uint256 token1Owed)
//     {
//         PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
//         Struct.OrderState storage state = orderStates[poolId];

//         executeTWAMMOrders(key);

//         // this call reverts if the caller is not the owner of the order
//         (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 newRewardFactor) =
//             LongTermOrder.updateOrder(state, orderKey, amountDelta);

//         if (orderKey.zeroForOne) {
//             tokens0Owed += sellTokensOwed;
//             token1Owed += buyTokensOwed;
//         } else {
//             tokens0Owed += buyTokensOwed;
//             token1Owed += sellTokensOwed;
//         }

//         tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
//         tokensOwed[key.currency1][orderKey.owner] += token1Owed;

//         if (amountDelta > 0) {
//             IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
//                 .safeTransferFrom(msg.sender, address(this), uint256(amountDelta));
//         }

//         emit UpdateOrder(poolId, orderKey.owner, orderKey.expiration, orderKey.zeroForOne, newSellRate, newRewardFactor);
//     }

//     /// @inheritdoc IUniqHook
//     function claimTokens(Currency token, address to, uint256 amountRequested)
//         external
//         returns (uint256 amountTransferred)
//     {
//         uint256 currentBalance = token.balanceOfSelf();
//         amountTransferred = tokensOwed[token][msg.sender];
//         if (amountRequested != 0 && amountRequested < amountTransferred) amountTransferred = amountRequested;
//         if (currentBalance < amountTransferred) amountTransferred = currentBalance;
//         tokensOwed[token][msg.sender] -= amountTransferred;
//         IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
//     }

//     /// @inheritdoc IUniqHook
//     function getOrder(PoolKey calldata key, Struct.OrderKey calldata orderKey)
//         external
//         view
//         returns (Struct.Order memory)
//     {
//         console.log("////////////////// Get Order //////////////////");
//         return LongTermOrder.getOrder(orderStates[PoolId.wrap(keccak256(abi.encode(key)))], orderKey);
//     }

//     /// @inheritdoc IUniqHook
//     function getOrderPool(PoolKey calldata key, bool zeroForOne)
//         external
//         view
//         returns (uint256 currentSellRate, uint256 currentRewardFactor)
//     {
//         console.log("////////////////// Get Order Pool //////////////////");
//         Struct.OrderState storage state = _getTWAMM(key);
//         return zeroForOne
//             ? (state.orderPool0For1.currentSellRate, state.orderPool0For1.currentRewardFactor)
//             : (state.orderPool1For0.currentSellRate, state.orderPool1For0.currentRewardFactor);
//     }

//     function updateMovingAverage() external returns (uint128) {
//         uint128 gasPrice = uint128(tx.gasprice);

//         // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
//         movingAverageGasPrice =
//             uint128((movingAverageGasPrice * movingAverageGasCount + gasPrice) / (movingAverageGasCount + 1));

//         // Increment the number of transactions tracked
//         movingAverageGasCount++;

//         return movingAverageGasPrice;
//     }

//     ///////////////////////////////////////////////////////////////////////
//     ///                     Internal Functions                          ///
//     ///////////////////////////////////////////////////////////////////////

//     function _getTWAMM(PoolKey memory key) internal view returns (Struct.OrderState storage) {
//         console.log("////////////////// Get TWAMM //////////////////");
//         return orderStates[PoolId.wrap(keccak256(abi.encode(key)))];
//     }

//     function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
//         console.log("////////////////// Unlock Callback //////////////////");
//         (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
//             abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

//         BalanceDelta delta = poolManager.swap(key, swapParams, Constants.ZERO_BYTES);

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

//     function brevisCommission(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams) internal {
//         uint256 tokenAmount =
//             swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

//         uint256 fee = Math.mulDiv(tokenAmount, HOOK_COMMISSION, 10_000);

//         // determine inbound token based on 0 or 1 or 1 or 0 swap
//         Currency inboundToken = swapParams.zeroForOne ? key.currency0 : key.currency1;

//         // take the inbound token from PoolManager, debt is paid by the swapper via swap router
//         // inboud token is added to hook's reserves
//         poolManager.take(inboundToken, address(this), fee);
//     }

//     /// @notice This function takes in parameters necessary to retrieve historical data, calculate moving averages and volatility

//     ///////////////////////////////////////////////////////////////////////
//     ///                     Brevis Override Functions                   ///
//     ///////////////////////////////////////////////////////////////////////
//     function handleProofResult(bytes32, bytes32 vkHash_, bytes calldata circuitOutput_) internal override {
//         if (vkHash != vkHash_) revert Errors.InvalidVkHash();

//         volatility = decodeOutput(circuitOutput_);

//         emit UpdateVolatility(volatility);
//     }

//     function decodeOutput(bytes calldata output) internal pure returns (uint256) {
//         uint248 vol = uint248(bytes31(output[0:31])); // vol is output as uint248 (31 bytes)

//         return uint256(vol);
//     }

//     function setVkHash(bytes32 vkHash_) external {
//         vkHash = vkHash_;
//     }

//     function calculateFee(uint256 vol) private view returns (uint24) {
//         uint256 constant_factor = 1e26; //
//         uint256 variableFee = sqrt(vol) * volatility / constant_factor;
//         // sqrt(vol) * vol / 1e26
//         return uint24(BASE_FEE + variableFee);
//     }

//     function getFee(int256 amount) external view returns (uint24) {
//         return calculateFee(abs(amount));
//     }

//     function abs(int256 x) private pure returns (uint256) {
//         return x >= 0 ? uint256(x) : uint256(-x);
//     }

//     function sqrt(uint256 x) internal pure returns (uint256) {
//         if (x == 0) return 0;

//         uint256 z = (x + 1) / 2;
//         uint256 y = x;

//         while (z < y) {
//             y = z;
//             z = (x / z + z) / 2;
//         }

//         return y;
//     }

//     /// @notice Returns the observation for the given poolId and index
//     function getObservation(PoolKey calldata key, uint256 index)
//         external
//         view
//         returns (Struct.Observation memory observation)
//     {
//         observation = observations[PoolId.wrap(keccak256(abi.encode(key)))][index];
//     }

//     /// @notice Returns the state for the given pool key
//     function getState(PoolKey calldata key) external view returns (Struct.ObservationState memory state) {
//         state = observationStates[PoolId.wrap(keccak256(abi.encode(key)))];
//     }

//     /// @dev For mocking
//     function _blockTimestamp() internal view virtual returns (uint32) {
//         return uint32(block.timestamp);
//     }

//     /// @notice observe the given pool for the timestamps
//     function observe(PoolKey calldata key, uint32[] calldata secondsAgos)
//         external
//         view
//         returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
//     {
//         PoolId id = key.toId();
//         Struct.ObservationState memory state = observationStates[id];
//         (, int24 tick,,) = poolManager.getSlot0(id);

//         uint128 liquidity = poolManager.getLiquidity(id);

//         return observations[id].observe(_blockTimestamp(), secondsAgos, tick, state.index, liquidity, state.cardinality);
//     }

//     /// @dev Called before any action that potentially modifies pool price or liquidity, such as swap or modify positions
//     function _updatePool(PoolKey calldata key) private {
//         PoolId id = key.toId();
//         (, int24 tick,,) = poolManager.getSlot0(id);

//         uint128 liqudity = poolManager.getLiquidity(id);

//         (observationStates[id].index, observationStates[id].cardinality) = observations[id].write(
//             observationStates[id].index,
//             _blockTimestamp(),
//             tick,
//             liqudity,
//             observationStates[id].cardinality,
//             observationStates[id].cardinalityNext
//         );
//     }

//     function calculateMMA(uint256[] memory shortTimePeriods, uint256[] memory longTimePeriods)
//         public
//         pure
//         returns (MarketDirection)
//     {
//         require(shortTimePeriods.length > 0 && longTimePeriods.length > 0, "Invalid time periods");

//         uint256 minS = shortTimePeriods[0];
//         uint256 maxS = shortTimePeriods[0];
//         for (uint256 i = 1; i < shortTimePeriods.length; i++) {
//             if (shortTimePeriods[i] < minS) {
//                 minS = shortTimePeriods[i];
//             }
//             if (shortTimePeriods[i] > maxS) {
//                 maxS = shortTimePeriods[i];
//             }
//         }

//         uint256 minL = longTimePeriods[0];
//         uint256 maxL = longTimePeriods[0];
//         for (uint256 i = 1; i < longTimePeriods.length; i++) {
//             if (longTimePeriods[i] < minL) {
//                 minL = longTimePeriods[i];
//             }
//             if (longTimePeriods[i] > maxL) {
//                 maxL = longTimePeriods[i];
//             }
//         }

//         if (minS > maxL) {
//             return MarketDirection.Bullish;
//         } else if (maxS < minL) {
//             return MarketDirection.Bearish;
//         } else {
//             return MarketDirection.Uncertain;
//         }
//     }

//     function updateVolatility(uint256[] memory S, uint256[] memory L) public returns (uint256) {
//         MarketDirection direction = calculateMMA(S, L);

//         if (direction == MarketDirection.Bullish) {
//             volatility = 5; // 0.5bps
//         } else if (direction == MarketDirection.Bearish) {
//             volatility = 20; // 2bps
//         } else {
//             volatility = 10; // 1bps
//         }

//         return volatility;
//     }
// }
