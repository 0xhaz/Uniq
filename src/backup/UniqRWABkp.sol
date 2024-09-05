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

//     uint256 public immutable expirationInterval;
//     bytes32 public vkHash;
//     uint256 public volatility;

//     // Market direction tracking
//     mapping(PoolId => uint256) public lastPrices;
//     mapping(PoolId => uint256) public lastTimestamp;
//     mapping(PoolId => uint24) public lastFee;

//     uint24 public constant BASE_FEE = 200; // 2bps
//     uint24 public constant MAX_FEE = 1000; // 10bps
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
//         override
//         onlyByPoolManager
//         returns (bytes4)
//     {
//         if (!key.fee.isDynamicFee()) {
//             revert Errors.MustUseDynamicFee();
//         }

//         LongTermOrder.initialize(_getTWAMM(key));

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

//     function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
//         external
//         override
//         onlyByPoolManager
//         returns (bytes4, BeforeSwapDelta, uint24)
//     {
//         executeTWAMMOrders(key);

//         // calculate dynamic fee based on volatility
//         uint24 dynamicFee = adjustFee(params.amountSpecified);

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
//         return LongTermOrder.getOrder(orderStates[PoolId.wrap(keccak256(abi.encode(key)))], orderKey);
//     }

//     /// @inheritdoc IUniqHook
//     function getOrderPool(PoolKey calldata key, bool zeroForOne)
//         external
//         view
//         returns (uint256 currentSellRate, uint256 currentRewardFactor)
//     {
//         Struct.OrderState storage state = _getTWAMM(key);
//         return zeroForOne
//             ? (state.orderPool0For1.currentSellRate, state.orderPool0For1.currentRewardFactor)
//             : (state.orderPool1For0.currentSellRate, state.orderPool1For0.currentRewardFactor);
//     }

//     /// @dev For testing purposes only
//     function setVolatility(uint256 vol) external {
//         volatility = vol;
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
//     }

//     function decodeOutput(bytes calldata output) internal pure returns (uint256) {
//         uint248 vol = uint248(bytes31(output[0:31])); // vol is output as uint248 (31 bytes)

//         return uint256(vol);
//     }

//     function setVkHash(bytes32 vkHash_) external {
//         vkHash = vkHash_;
//     }

//     function calculateFee(uint256 vol) private view returns (uint24) {}

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

//     function adjustFee(int256 amountSpecified) internal view returns (uint24) {
//         uint24 adjustedFee = BASE_FEE;
//         int256 priceImpact = int256(uint256(BASE_FEE)) - int256(volatility);

//         if (volatility > 0) {
//             // Buying
//             if (amountSpecified > 0) {
//                 if (priceImpact > 0) {
//                     // Increase the fee more if the trade goes against a falling market
//                     adjustedFee += uint24(Math.min(uint256(priceImpact) + volatility, MAX_FEE));
//                     console.log("Adjusted Fee If Price Impact > 0: ", adjustedFee);
//                 } else {
//                     // Standard increase for buy in rising market
//                     adjustedFee += uint24(Math.min(volatility, MAX_FEE));
//                     console.log("Adjusted Fee W/O Price Impact > 0: ", adjustedFee);
//                 }
//             } else {
//                 // Selling
//                 if (priceImpact < 0) {
//                     // Decrease the fee more if the trade aligns with a falling market
//                     int256 reducedFee = int256(uint256(BASE_FEE)) - int256(volatility) - priceImpact;
//                     console.log("Reduced Fee: ", reducedFee);
//                     if (reducedFee < 0) {
//                         adjustedFee = 0;
//                     } else {
//                         adjustedFee = uint24(uint256(reducedFee));
//                         console.log("Adjusted Fee If Price Impact < 0: ", adjustedFee);
//                     }
//                 } else {
//                     // Standard decrease for sell in rising market
//                     int256 reducedFee = int256(uint256(BASE_FEE)) - int256(volatility);
//                     console.log("Reduced Fee: ", reducedFee);
//                     if (reducedFee < 0) {
//                         adjustedFee = 0;
//                     } else {
//                         adjustedFee = uint24(uint256(reducedFee));
//                         console.log("Adjusted Fee Reduced Fee is > 0: ", adjustedFee);
//                     }
//                 }
//             }
//         }

//         return adjustedFee;
//     }
// }
