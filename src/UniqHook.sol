// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {TransferHelper} from "src/libraries/TransferHelper.sol";
import {IUniqHook} from "src/interfaces/IUniqHook.sol";
import {TwammMath} from "src/libraries/TWAMMMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolGetters} from "src/libraries/PoolGetters.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Constants} from "src/libraries/Constants.sol";
import {Oracle, AggregatorV3Interface} from "src/libraries/Oracle.sol";
import {LongTermOrder} from "src/libraries/LongTermOrder.sol";
import {Struct} from "src/libraries/Struct.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BrevisApp, IBrevisProof} from "src/abstracts/brevis/BrevisApp.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Volatility} from "src/libraries/Volatility.sol";
import {DynamicFees} from "src/libraries/DynamicFees.sol";
import {console} from "forge-std/Console.sol";

contract UniqHook is BaseHook, IUniqHook, BrevisApp {
    using TransferHelper for IERC20Minimal;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    uint256 public immutable expirationInterval;
    bytes32 public vkHash;
    uint256 public volatility;
    uint256[] public volatilityHistory;
    AggregatorV3Interface public priceFeed;
    Struct.Observation[65535] public observations;
    uint256 public lastOraclePrice;
    uint256 public lastOracleUpdate;
    uint256 lastUpdateTime;

    // Market direction tracking
    mapping(PoolId => uint256) public lastPrices;
    mapping(PoolId => uint256) public lastTimestamp;
    mapping(PoolId => uint24) public lastFee;

    mapping(PoolId => uint256) public highestPrice;
    mapping(PoolId => uint256) public lowestPrice;
    mapping(PoolId => uint256) public largestVolume;

    /// @notice The state of the long term orders
    mapping(PoolId => Struct.OrderState) internal orderStates;

    /// @notice The amount of tokens owed to each user
    mapping(Currency token => mapping(address owner => uint256)) public tokensOwed;

    constructor(IPoolManager poolManager, uint256 expirationInterval_, address brevisProof_, address priceFeed_)
        BaseHook(poolManager)
        BrevisApp(IBrevisProof(brevisProof_))
    {
        expirationInterval = expirationInterval_;
        priceFeed = AggregatorV3Interface(priceFeed_);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) {
            revert Errors.MustUseDynamicFee();
        }

        LongTermOrder.initialize(_getTWAMM(key));

        return this.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyByPoolManager returns (bytes4) {
        executeTWAMMOrders(key);

        return this.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        executeTWAMMOrders(key);

        // calculate dynamic fee based on volatility
        uint256 priceMovement = DynamicFees.calculateMovement(key, poolManager, volatility, lastPrices, lastTimestamp);

        uint24 dynamicFee = _adjustFee(DynamicFees.abs(params.amountSpecified), priceMovement, key, params);

        /// @notice Updates the pools lp fees for the a pool that has enabled dynamic lp fees.
        poolManager.updateDynamicLPFee(key, dynamicFee);

        dynamicFee = dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee);
    }

    /*/////////////////////////////////////////////////////////////////////
                               Public Functions                            
    /////////////////////////////////////////////////////////////////////*/
    /// @inheritdoc IUniqHook
    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId id = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);

        Struct.OrderState storage state = orderStates[id];

        (bool zeroForOne, uint160 sqrtPriceLimitX96) = LongTermOrder.executeOrders(
            state,
            poolManager,
            key,
            Struct.ExecutePool({sqrtPriceX96: sqrtPriceX96, liquidity: poolManager.getLiquidity(id)}),
            expirationInterval
        );

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
            poolManager.unlock(
                abi.encode(key, IPoolManager.SwapParams(zeroForOne, type(int256).max, sqrtPriceLimitX96))
            );
        }
    }

    function getLastVirtualOrder(PoolId key) public view returns (uint256) {
        return orderStates[key].lastVirtualOrderTime;
    }

    /*/////////////////////////////////////////////////////////////////////
                            External Functions                          
    /////////////////////////////////////////////////////////////////////*/
    /// @inheritdoc IUniqHook
    function submitOrder(PoolKey calldata key, Struct.OrderKey memory orderKey, uint256 amountIn)
        external
        returns (bytes32 orderId)
    {
        PoolId id = PoolId.wrap(keccak256(abi.encode(key)));
        Struct.OrderState storage state = orderStates[id];
        executeTWAMMOrders(key);

        uint256 sellRate;
        unchecked {
            uint256 duration = orderKey.expiration - block.timestamp;
            sellRate = amountIn / duration;
            orderId = LongTermOrder.submitOrder(state, orderKey, sellRate, expirationInterval);
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), sellRate * duration);
        }

        emit SubmitOrder(
            id,
            orderKey.owner,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            LongTermOrder.getOrder(state, orderKey).rewardsFactorLast
        );
    }

    /// @inheritdoc IUniqHook
    function updateOrder(PoolKey memory key, Struct.OrderKey memory orderKey, int256 amountDelta)
        external
        returns (uint256 tokens0Owed, uint256 token1Owed)
    {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        Struct.OrderState storage state = orderStates[poolId];

        executeTWAMMOrders(key);

        // this call reverts if the caller is not the owner of the order
        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 newRewardFactor) =
            LongTermOrder.updateOrder(state, orderKey, amountDelta);

        if (orderKey.zeroForOne) {
            tokens0Owed += sellTokensOwed;
            token1Owed += buyTokensOwed;
        } else {
            tokens0Owed += buyTokensOwed;
            token1Owed += sellTokensOwed;
        }

        tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
        tokensOwed[key.currency1][orderKey.owner] += token1Owed;

        if (amountDelta > 0) {
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), uint256(amountDelta));
        }

        emit UpdateOrder(poolId, orderKey.owner, orderKey.expiration, orderKey.zeroForOne, newSellRate, newRewardFactor);
    }

    /// @inheritdoc IUniqHook
    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) {
            amountTransferred = amountRequested;
        }
        if (currentBalance < amountTransferred) {
            amountTransferred = currentBalance;
        }
        tokensOwed[token][msg.sender] -= amountTransferred;
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
    }

    /// @inheritdoc IUniqHook
    function getOrder(PoolKey calldata key, Struct.OrderKey calldata orderKey)
        external
        view
        returns (Struct.Order memory)
    {
        return LongTermOrder.getOrder(orderStates[PoolId.wrap(keccak256(abi.encode(key)))], orderKey);
    }

    /// @inheritdoc IUniqHook
    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 currentSellRate, uint256 currentRewardFactor)
    {
        Struct.OrderState storage state = _getTWAMM(key);
        return zeroForOne
            ? (state.orderPool0For1.currentSellRate, state.orderPool0For1.currentRewardFactor)
            : (state.orderPool1For0.currentSellRate, state.orderPool1For0.currentRewardFactor);
    }

    /// @inheritdoc IUniqHook
    function getVolatilityHistory() external view returns (uint256[] memory) {
        return volatilityHistory;
    }

    /// @inheritdoc IUniqHook
    function getFee(int256 amount, PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (uint24)
    {
        uint256 priceMovement = DynamicFees.calculateMovement(key, poolManager, volatility, lastPrices, lastTimestamp);
        if (priceMovement == 0) {
            return lastFee[key.toId()];
        }

        return _adjustFee(DynamicFees.abs(amount), priceMovement, key, params);
    }

    /*/////////////////////////////////////////////////////////////////////
                            Internal Functions                          
    /////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieves the state of long-term orders for a given pool key.
     * @dev Converts the PoolKey into a PoolId and fetches the associated order state.
     * @param key The PoolKey that uniquely identifies the pool.
     * @return The order state for the given pool.
     */
    function _getTWAMM(PoolKey memory key) internal view returns (Struct.OrderState storage) {
        return orderStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    /**
     * @notice Callback function that is triggered to unlock swap functionality.
     * @dev Decodes the raw data to retrieve the pool key and swap parameters, then executes a swap.
     *      Manages balance deltas and ensures tokens are settled correctly.
     * @param rawData Encoded data containing the PoolKey and SwapParams needed to execute the swap.
     * @return An empty byte array after successful execution.
     */
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        (PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (PoolKey, IPoolManager.SwapParams));

        BalanceDelta delta = poolManager.swap(key, swapParams, Constants.ZERO_BYTES);

        if (swapParams.zeroForOne) {
            if (delta.amount0() < 0) {
                key.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
            }
            if (delta.amount1() > 0) {
                key.currency1.take(poolManager, address(this), uint256(uint128(delta.amount1())), false);
            }
        } else {
            if (delta.amount1() < 0) {
                key.currency1.settle(poolManager, address(this), uint256(uint128(-delta.amount1())), false);
            }
            if (delta.amount0() > 0) {
                key.currency0.take(poolManager, address(this), uint256(uint128(delta.amount0())), false);
            }
        }
        return bytes("");
    }

    /**
     * @notice Charges a commission on the swap by taking a percentage of the token amount.
     * @dev Determines the inbound token from the pool and transfers a portion to the contract.
     * @param key The PoolKey that identifies the pool.
     * @param swapParams Parameters of the swap such as token direction and amount.
     */
    function _brevisCommission(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams) internal {
        uint256 tokenAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

        uint256 fee = Math.mulDiv(tokenAmount, Constants.HOOK_COMMISSION, 10_000);

        // determine inbound token based on 0 or 1 or 1 or 0 swap
        Currency inboundToken = swapParams.zeroForOne ? key.currency0 : key.currency1;

        // take the inbound token from PoolManager, debt is paid by the swapper via swap router
        // inboud token is added to hook's reserves
        poolManager.take(inboundToken, address(this), fee);
    }

    /**
     * @notice Adjusts the fee dynamically based on trade volume, liquidity, and price movement.
     * @dev The fee is adjusted by calculating liquidity-adjusted and volatility-based values, then clamped to a defined range.
     * @param volume The trade volume used for calculating the fee.
     * @param priceMovement The percentage price change since the last trade.
     * @param key The PoolKey for identifying the liquidity pool.
     * @param params The swap parameters containing the direction and amount of the swap.
     * @return The dynamically adjusted fee.
     */
    function _adjustFee(
        uint256 volume,
        uint256 priceMovement,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (uint24) {
        PoolId poolId = key.toId();
        uint24 lastFee_ = lastFee[poolId] == 0 ? Constants.BASE_FEE : lastFee[poolId];

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint160 currentSqrtPrice = sqrtPriceX96;
        int24 currentTick = tick;

        uint256 volatilityFee = DynamicFees.calculateVolatilityFee(priceMovement, volatility);

        // Directional multiplier: higher for aggresive trades, lower for passive trades
        bool isAggressive = (priceMovement > 0 && params.zeroForOne) || (priceMovement < 0 && !params.zeroForOne);
        uint256 directionalMultiplier =
            DynamicFees.calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);
        // console.log("Directional Multiplier: %s", directionalMultiplier);

        // Volume factor and liquidity-based adjustment using new function
        uint24 liquidityAdjustedFee =
            DynamicFees.adjustFeeBasedOnLiquidity(volume, currentSqrtPrice, currentTick, liquidity, key.tickSpacing);

        uint256 dynamicFee = lastFee_ + volatilityFee + liquidityAdjustedFee;

        // directional multiplier at conservative trades
        unchecked {
            dynamicFee = (dynamicFee * directionalMultiplier) / 10;
        }
        // console.log("Dynamic Fee before clamping: %s", dynamicFee);

        // Clamp the fee to the min and max
        if (dynamicFee < Constants.MIN_FEE) {
            dynamicFee = Constants.MIN_FEE;
        } else if (dynamicFee > Constants.MAX_FEE) {
            dynamicFee = Constants.MAX_FEE;
        }

        // console.log("Final Dynamic Fee: %s", dynamicFee);
        // console.log("Current sqrt price after swap: %d", currentSqrtPrice);

        // Store the fee for next time
        if (dynamicFee != lastFee_) {
            lastFee[poolId] = uint24(dynamicFee);
        }

        return uint24(dynamicFee);
    }

    // KIV: To be implemented after the oracle is integrated
    function updateObservation(PoolKey calldata key, int24 tick, uint128 liquidity) internal {
        Struct.OrderState storage state = orderStates[key.toId()];
        Struct.Observation[65535] storage obs = orderStates[key.toId()].observations;
        uint16 index = state.observationState.index;
        uint16 cardinality = state.observationState.cardinality;
        uint16 cardinalityNext = state.observationState.cardinalityNext;

        uint32 timestamp = uint32(block.timestamp);

        if (timestamp - lastOracleUpdate > 60) {
            (, int256 oraclePrice,,,) = Oracle.staleCheckLatestRoundData(priceFeed);

            lastOraclePrice = uint256(oraclePrice);
            lastOracleUpdate = timestamp;
        }

        // Calculate the internal price using tick (assuming tick -> price conversion logic exists)
        uint256 internalPrice = DynamicFees.calculateInternalPriceFromTick(tick);

        // Get price tolerance and dynamically adjust based on volatility
        uint256 tolerance = DynamicFees.getPriceTolerance();

        // adjust tolerance based on market conditions (volatility, time decay, etc)
        tolerance += (volatility / 1e18) * 1e14;
        tolerance = tolerance > 1e16 ? 1e16 : tolerance;

        // Validate internal price agains the oracle price
        if (DynamicFees.abs(int256(internalPrice) - int256(lastOraclePrice)) > tolerance) {
            revert Errors.PriceDeviation();
        }

        Oracle.write(obs, index, timestamp, tick, liquidity, cardinality, cardinalityNext);

        state.observationState.index = (index + 1 == cardinalityNext) ? 0 : index + 1;

        if (cardinalityNext > cardinality && state.observationState.index == 0) {
            state.observationState.cardinality = cardinalityNext;
        }
    }

    // KIV: To be implemented after the oracle is integrated
    function initializeOrderState(PoolId poolId) internal {
        Struct.OrderState storage state = orderStates[poolId];

        state.observationState = Struct.ObservationState({index: 0, cardinality: 1, cardinalityNext: 1});
    }

    /*/////////////////////////////////////////////////////////////////////
                           Brevis Override Functions                   
    /////////////////////////////////////////////////////////////////////*/
    /**
     * @notice Processes the result from a Brevis proof and adjusts volatility accordingly.
     * @dev The proof verifies key performance data such as volatility, and the contract uses this to update its internal volatility value.
     * @param vkHash_ The hash of the verification key for the proof.
     * @param circuitOutput_ The output from the circuit after proof validation.
     */
    function handleProofResult(bytes32, bytes32 vkHash_, bytes calldata circuitOutput_) internal override {
        if (vkHash != vkHash_) revert Errors.InvalidVkHash();

        uint256 newVolatility = decodeOutput(circuitOutput_);
        // console.log("Decoded volatility: %s", newVolatility);
        _adjustVolatility(newVolatility);
    }

    /**
     * @notice Decodes the output of the Brevis proof to retrieve the volatility value.
     * @dev The Brevis proof encodes the volatility as a 248-bit integer within the first 31 bytes of the circuit output.
     * @param output The output of the Brevis proof as bytes.
     * @return The decoded volatility value as a uint256.
     */
    function decodeOutput(bytes calldata output) internal pure returns (uint256) {
        uint248 vol = uint248(bytes31(output[0:31])); // vol is output as uint248 (31 bytes)

        return uint256(vol);
    }

    function setVkHash(bytes32 vkHash_) external {
        vkHash = vkHash_;
    }

    /*/////////////////////////////////////////////////////////////////////
                            Private Functions                          
    /////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Adjusts the internal volatility value based on new data.
     * @dev Uses a decay factor to gradually smooth volatility changes over time and updates the volatility history.
     * @param newVolatility The new volatility value to adjust the internal volatility towards.
     */
    function _adjustVolatility(uint256 newVolatility) private {
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 decayFactor = DynamicFees.calculateTimeDecayFactor(timeElapsed);

        // Adjust the volatility based on the decay factor
        volatility = (volatility * decayFactor) / 1e18;
        lastUpdateTime = block.timestamp;

        uint256 oldVolatility = volatility;

        uint256 volatilityChange =
            (newVolatility > oldVolatility) ? newVolatility - oldVolatility : oldVolatility - newVolatility;
        uint256 dynamicSmoothingFactor =
            volatilityChange > Constants.MAX_VOLATILITY_CHANGE_PCT ? 5 : Constants.SMOOTHING_FACTOR;

        volatility = (volatility * (dynamicSmoothingFactor - 1) + newVolatility) / dynamicSmoothingFactor;
        volatilityHistory.push(volatility);
        // console.log("Volatility after adjustment: %s", volatility);

        emit UpdateVolatility(oldVolatility, volatility);
    }
}
