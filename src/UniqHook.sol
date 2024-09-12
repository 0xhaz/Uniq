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
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {TransferHelper} from "src/libraries/TransferHelper.sol";
import {IUniqHook} from "src/interfaces/IUniqHook.sol";
import {TwammMath} from "src/libraries/TWAMMMath.sol";
import {OrderPool} from "src/libraries/OrderPool.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolGetters} from "src/libraries/PoolGetters.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Constants} from "src/libraries/Constants.sol";
import {Oracle} from "src/libraries/Oracle.sol";
import {LongTermOrder} from "src/libraries/LongTermOrder.sol";
import {Struct} from "src/libraries/Struct.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BrevisApp, IBrevisProof} from "src/abstracts/brevis/BrevisApp.sol";
import {Errors} from "src/libraries/Errors.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Volatility} from "src/libraries/Volatility.sol";
import {console} from "forge-std/Console.sol";

contract UniqHook is BaseHook, IUniqHook, BrevisApp {
    using TransferHelper for IERC20Minimal;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    uint256 public immutable expirationInterval;
    bytes32 public vkHash;
    uint256 public volatility;
    uint256[] public volatilityHistory;

    // Market direction tracking
    mapping(PoolId => uint256) public lastPrices;
    mapping(PoolId => uint256) public lastTimestamp;
    mapping(PoolId => uint24) public lastFee;

    mapping(PoolId => uint256) public highestPrice;
    mapping(PoolId => uint256) public lowestPrice;
    mapping(PoolId => uint256) public largestVolume;

    uint24 public constant BASE_FEE = 200; // 2bps
    uint24 public constant MIN_FEE = 50; // 0.5bps
    uint24 public constant MAX_FEE = 1000; // 10bps
    uint24 public constant HOOK_COMMISSION = 100; // 1bps paid to the hook to cover Brevis costs
    uint256 public constant VOLATILITY_MULTIPLIER = 10; // 1% increase in fee per 10% increase in volatility
    uint256 public constant VOLATILITY_FACTOR = 1e26;
    uint256 public constant SMOOTHING_FACTOR = 10;
    uint256 public constant MAX_VOLATILITY_CHANGE_PCT = 20 * 1e16; // 20%

    /// @notice The state of the long term orders
    mapping(PoolId => Struct.OrderState) internal orderStates;

    /// @notice The amount of tokens owed to each user
    mapping(Currency token => mapping(address owner => uint256)) public tokensOwed;

    constructor(IPoolManager poolManager, uint256 expirationInterval_, address brevisProof_)
        BaseHook(poolManager)
        BrevisApp(IBrevisProof(brevisProof_))
    {
        expirationInterval = expirationInterval_;
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
        uint256 priceMovement = calculateMovement(key);
        uint24 dynamicFee = adjustFee(abs(params.amountSpecified), priceMovement, key, params);
        // console.log("Dynamic Fee Applied: %s", dynamicFee);
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
        uint256 priceMovement = calculateMovement(key);
        return adjustFee(abs(amount), priceMovement, key, params);
    }

    /*/////////////////////////////////////////////////////////////////////
                            Internal Functions                          
    /////////////////////////////////////////////////////////////////////*/

    function _getTWAMM(PoolKey memory key) internal view returns (Struct.OrderState storage) {
        return orderStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }

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

    function brevisCommission(PoolKey calldata key, IPoolManager.SwapParams calldata swapParams) internal {
        uint256 tokenAmount =
            swapParams.amountSpecified < 0 ? uint256(-swapParams.amountSpecified) : uint256(swapParams.amountSpecified);

        uint256 fee = Math.mulDiv(tokenAmount, HOOK_COMMISSION, 10_000);

        // determine inbound token based on 0 or 1 or 1 or 0 swap
        Currency inboundToken = swapParams.zeroForOne ? key.currency0 : key.currency1;

        // take the inbound token from PoolManager, debt is paid by the swapper via swap router
        // inboud token is added to hook's reserves
        poolManager.take(inboundToken, address(this), fee);
    }

    // adjust the volatility fee based on the volume of the swap
    function adjustFee(
        uint256 volume,
        uint256 priceMovement,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (uint24) {
        PoolId poolId = key.toId();
        uint24 lastFee_ = lastFee[poolId] == 0 ? BASE_FEE : lastFee[poolId];

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint160 currentSqrtPrice = sqrtPriceX96;
        console.log("Current sqrt price before swap: %d", currentSqrtPrice);
        int24 currentTick = tick;
        console.log("Current tick before swap: %d", currentTick);

        // Directional multiplier: higher for aggresive trades, lower for passive trades
        bool isAggressive = (priceMovement > 0 && params.zeroForOne) || (priceMovement < 0 && !params.zeroForOne);
        uint256 directionalMultiplier = calculateDirectionalMultiplier(isAggressive, priceMovement, volume, liquidity);
        console.log("Directional Multiplier: %s", directionalMultiplier);

        // Volatility fee adjustment
        uint256 volatilityFee = calculateVolatilityFee(priceMovement);
        console.log("Volatility Fee: %s", volatilityFee);

        // Volume factor and liquidity-based adjustment using new function
        uint24 liquidityAdjustedFee =
            adjustFeeBasedOnLiquidity(volume, currentSqrtPrice, currentTick, liquidity, key.tickSpacing);
        console.log("Liquidity Adjusted Fee: %s", liquidityAdjustedFee);
        console.log("Volume: %s, Liquidity: %s", volume, liquidity);
        uint256 dynamicFee = lastFee_ + volatilityFee + liquidityAdjustedFee;

        // directional multiplier at conservative trades
        unchecked {
            dynamicFee = (dynamicFee * directionalMultiplier) / 10;
        }
        console.log("Dynamic Fee before clamping: %s", dynamicFee);

        // Clamp the fee to the min and max
        if (dynamicFee < MIN_FEE) {
            dynamicFee = MIN_FEE;
        } else if (dynamicFee > MAX_FEE) {
            dynamicFee = MAX_FEE;
        }

        console.log("Final Dynamic Fee: %s", dynamicFee);
        console.log("Current sqrt price after swap: %d", currentSqrtPrice);

        // Store the fee for next time
        if (dynamicFee != lastFee_) {
            lastFee[poolId] = uint24(dynamicFee);
        }

        return uint24(dynamicFee);
    }

    /*/////////////////////////////////////////////////////////////////////
                           Brevis Override Functions                   
    /////////////////////////////////////////////////////////////////////*/
    function handleProofResult(bytes32, bytes32 vkHash_, bytes calldata circuitOutput_) internal override {
        if (vkHash != vkHash_) revert Errors.InvalidVkHash();

        uint256 newVolatility = decodeOutput(circuitOutput_);
        console.log("Decoded volatility: %s", newVolatility);
        adjustVolatility(newVolatility);
    }

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

    function calculateMovement(PoolKey calldata key) private returns (uint256 priceMovement) {
        // calculate the price movement from the last block
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Calculate the price from sqrtPriceX96
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / FixedPoint96.Q96;
        uint256 lastPrice = lastPrices[poolId];

        // Store the current price for next time
        uint256 currentTime = block.timestamp;
        uint256 lastTime = lastTimestamp[poolId];

        // Time decay factor based on how much time has passed (e.g, decay per second)
        uint256 timeElapsed = currentTime - lastTime;
        uint256 decayFactor = (timeElapsed > 0) ? Math.min((timeElapsed * 1e18) / 1 days, 1e18) : 1e18; // 1 day decay

        // Store the current time for next time
        lastPrices[poolId] = price;
        lastTimestamp[poolId] = currentTime;

        // Calculate price movement as a percentage difference, with a decay factor
        if (lastPrice == 0) {
            // Initial case, no movement
            priceMovement = (volatility > 0) ? volatility / 1e10 : 1e16;
        } else {
            uint256 rawMovement = (price > lastPrice)
                ? ((price - lastPrice) * 1e18) / lastPrice // price increased
                : ((lastPrice - price) * 1e18) / lastPrice; // price decreased

            priceMovement = (rawMovement * decayFactor) / 1e18;
        }
        console.log("Price Movement With Decay: %s", priceMovement);
        return priceMovement;
    }

    function adjustVolatility(uint256 newVolatility) private {
        console.log("Decoded volatility before adjustment: %s", newVolatility);
        uint256 oldVolatility = volatility;

        volatility = (volatility * (SMOOTHING_FACTOR - 1) + newVolatility) / SMOOTHING_FACTOR;
        volatilityHistory.push(volatility);
        console.log("Volatility after adjustment: %s", volatility);

        emit UpdateVolatility(oldVolatility, volatility);
    }

    function adjustFeeBasedOnLiquidity(
        uint256 volume,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing
    ) private pure returns (uint24) {
        if (liquidity == 0) {
            return MAX_FEE;
        }
        // Compute the TVL at the current tick
        uint256 tickTVL = Volatility.computeTickTVLX64(tickSpacing, tick, sqrtPriceX96, liquidity);

        // A larger TVL indicates deeper liquidity, hence lower fee impact
        if (tickTVL == 0) {
            return MAX_FEE; // if no liquidity, set fee to max
        }

        // volume-to-liquidity ratio to determine fee adjustment
        uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e18, tickTVL);
        console.log("Volume-to-Liquidity Ratio: %s", volumeToLiquidityRatio);

        // Higher ratio = higher fee, lower ratio = lower fee
        if (volumeToLiquidityRatio > 1e18) {
            return MAX_FEE; // if volume is greater than liquidity, set fee to max
        } else if (volumeToLiquidityRatio < 1e16) {
            return MIN_FEE; // if volume is less than 1% of liquidity, set fee to min
        } else {
            // scale fee linearly based on ratio
            return uint24(Math.mulDiv(volumeToLiquidityRatio, MAX_FEE - MIN_FEE, 1e18) + MIN_FEE);
        }
    }

    function calculateVolatilityFee(uint256 priceMovement) private view returns (uint256) {
        uint256 movementFactor = priceMovement > 0 ? priceMovement : 1e16;
        return (volatility * VOLATILITY_MULTIPLIER * movementFactor) / VOLATILITY_FACTOR;
    }

    function calculateDirectionalMultiplier(bool isAggressive, uint256 priceMovement, uint256 volume, uint128 liquidity)
        private
        pure
        returns (uint256)
    {
        // Base directional multiplier for passive trade is 1
        uint256 baseMultiplier = isAggressive ? 1 : 1;

        if (isAggressive) {
            // Scale multiplier based on price movement (larger movement = larger fee multiplier)
            if (priceMovement > 1e18) {
                baseMultiplier = 2; // slightly aggressive
            }
            if (priceMovement > 5e18) {
                baseMultiplier = 3; // moderately aggressive
            }
            if (priceMovement > 10e18) {
                baseMultiplier = 4; // highly aggressive
            }

            if (liquidity > 0) {
                // Adjust multiplier based on trade size relative to liquidity
                uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e18, liquidity); // safe division
                if (volumeToLiquidityRatio > 5e17) {
                    baseMultiplier += 1; // if trade size is greater than 50% of liquidity, increase multiplier
                }
                if (volumeToLiquidityRatio > 1e18) {
                    baseMultiplier += 2; // if trade size is greater than liquidity, increase multiplier
                }
            } else {
                baseMultiplier += 2; // if no liquidity, increase multiplier
            }
        }

        return baseMultiplier;
    }

    function abs(int256 x) private pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function sqrt(uint256 x) private pure returns (uint256 y) {
        assembly {
            // Compute square root of `x` using optimized assembly
            let z := add(div(x, 2), 1)
            y := x
            for {} lt(z, y) {} {
                y := z
                z := div(add(div(x, z), z), 2)
            }
        }
    }
}
