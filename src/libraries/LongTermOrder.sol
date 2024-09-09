// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {OrderPool} from "src/libraries/OrderPool.sol";
import {PoolGetters, IPoolManager, StateLibrary, PoolId, PoolIdLibrary, Pool} from "src/libraries/PoolGetters.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TwammMath} from "src/libraries/TWAMMMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Struct} from "src/libraries/Struct.sol";
import {Errors} from "src/libraries/Errors.sol";
import {console} from "forge-std/Console.sol";
import {Constants} from "src/libraries/Constants.sol";

/// @notice Library that handles the state and execution of long term orders
library LongTermOrder {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PoolGetters for IPoolManager;
    using OrderPool for Struct.OrderPool;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using TickBitmap for mapping(int16 => uint256);

    /// @notice Initialize state
    function initialize(Struct.OrderState storage self) public {
        self.lastVirtualOrderTime = block.timestamp;
    }

    /// @notice Execute all existing long term orders in the pool
    function executeOrders(
        Struct.OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        Struct.ExecutePool memory pool,
        uint256 expirationInterval
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!hasOutStandingOrders(self)) {
            self.lastVirtualOrderTime = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTime;
        uint256 nextExpirationTime = prevTimestamp + (expirationInterval - (prevTimestamp % expirationInterval));

        Struct.OrderPool storage orderPool0For1 = self.orderPool0For1;
        Struct.OrderPool storage orderPool1For0 = self.orderPool1For0;

        unchecked {
            while (nextExpirationTime <= block.timestamp) {
                if (
                    orderPool0For1.sellRateEndingAtTime[nextExpirationTime] > 0
                        || orderPool1For0.sellRateEndingAtTime[nextExpirationTime] > 0
                ) {
                    if (orderPool0For1.currentSellRate != 0 && orderPool1For0.currentSellRate != 0) {
                        pool = advanceToNewTime(
                            self,
                            poolManager,
                            poolKey,
                            Struct.NextParams({
                                expirationInterval: expirationInterval,
                                nextTimestamp: nextExpirationTime,
                                secondsElapsed: nextExpirationTime - prevTimestamp,
                                pool: pool
                            })
                        );
                    } else {
                        pool = advanceTimeForSinglePoolSell(
                            self,
                            poolManager,
                            poolKey,
                            Struct.NextSingleParams({
                                expirationInterval: expirationInterval,
                                nextTimestamp: nextExpirationTime,
                                secondsElapsed: nextExpirationTime - prevTimestamp,
                                pool: pool,
                                zeroForOne: orderPool0For1.currentSellRate != 0
                            })
                        );
                    }
                    prevTimestamp = nextExpirationTime;
                }
                nextExpirationTime += expirationInterval;

                if (!hasOutStandingOrders(self)) break;
            }

            if (prevTimestamp < block.timestamp && hasOutStandingOrders(self)) {
                if (orderPool0For1.currentSellRate != 0 && orderPool1For0.currentSellRate != 0) {
                    pool = advanceToNewTime(
                        self,
                        poolManager,
                        poolKey,
                        Struct.NextParams({
                            expirationInterval: expirationInterval,
                            nextTimestamp: block.timestamp,
                            secondsElapsed: block.timestamp - prevTimestamp,
                            pool: pool
                        })
                    );
                } else {
                    pool = advanceTimeForSinglePoolSell(
                        self,
                        poolManager,
                        poolKey,
                        Struct.NextSingleParams({
                            expirationInterval: expirationInterval,
                            nextTimestamp: block.timestamp,
                            secondsElapsed: block.timestamp - prevTimestamp,
                            pool: pool,
                            zeroForOne: orderPool0For1.currentSellRate != 0
                        })
                    );
                }
            }
        }
        self.lastVirtualOrderTime = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }

    function hasOutStandingOrders(Struct.OrderState storage self) internal view returns (bool) {
        return self.orderPool0For1.currentSellRate != 0 || self.orderPool1For0.currentSellRate != 0;
    }

    function isCrossingTick(
        Struct.ExecutePool memory pool,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) private view returns (bool initializedCrossingTick, int24 nextTick) {
        nextTick = pool.sqrtPriceX96.getTickAtSqrtPrice();
        int24 targetTick = nextSqrtPriceX96.getTickAtSqrtPrice();
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickIsFurtherThanTarget = false;

        // nextTick returns the furthest tick within one word if no tick within that word is initialized
        // need to keep iterating until the tick is further than the target tick
        while (!nextTickIsFurtherThanTarget) {
            unchecked {
                if (searchingLeft) nextTick -= 1;
            }
            (nextTick, initializedCrossingTick) = poolManager.getNextInitializedTickWithinOneWord(
                poolKey.toId(), nextTick, poolKey.tickSpacing, searchingLeft
            );
            nextTickIsFurtherThanTarget = searchingLeft ? nextTick <= targetTick : nextTick > targetTick;
            if (initializedCrossingTick == true) break;
        }
        if (nextTickIsFurtherThanTarget) initializedCrossingTick = false;
    }

    function advanceTimeThroughTickCrossing(
        Struct.OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        Struct.TickCrossingParams memory params
    ) private returns (Struct.ExecutePool memory, uint256) {
        uint160 initializedSqrtPriceX96 = TickMath.getSqrtPriceAtTick(params.initializedTick);

        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPriceX96,
            self.orderPool0For1.currentSellRate,
            self.orderPool1For0.currentSellRate
        );

        (uint256 rewardFactorPool0, uint256 rewardFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams({
                secondsElapsedX96: secondsUntilCrossingX96,
                sqrtPriceX96: params.pool.sqrtPriceX96,
                liquidity: params.pool.liquidity,
                sellRateCurrent0: self.orderPool0For1.currentSellRate,
                sellRateCurrent1: self.orderPool1For0.currentSellRate
            }),
            initializedSqrtPriceX96
        );

        self.orderPool0For1.advanceToCurrentTime(rewardFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(rewardFactorPool1);

        unchecked {
            (, int128 liquidityNet) = poolManager.getTickLiquidity(poolKey.toId(), params.initializedTick);
            if (initializedSqrtPriceX96 < params.pool.sqrtPriceX96) liquidityNet = -liquidityNet;
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPriceX96;
        }
        return (params.pool, secondsUntilCrossingX96);
    }

    function advanceToNewTime(
        Struct.OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        Struct.NextParams memory params
    ) private returns (Struct.ExecutePool memory) {
        uint160 finalSqrtPriceX96;
        uint256 elapsedSecondsX96 = params.secondsElapsed * FixedPoint96.Q96;

        Struct.OrderPool storage orderPool0For1 = self.orderPool0For1;
        Struct.OrderPool storage orderPool1For0 = self.orderPool1For0;

        while (true) {
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams({
                secondsElapsedX96: elapsedSecondsX96,
                sqrtPriceX96: params.pool.sqrtPriceX96,
                liquidity: params.pool.liquidity,
                sellRateCurrent0: orderPool0For1.currentSellRate,
                sellRateCurrent1: orderPool1For0.currentSellRate
            });

            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

            (bool initializedCrossingTick, int24 nextTick) =
                isCrossingTick(params.pool, poolManager, poolKey, finalSqrtPriceX96);

            unchecked {
                if (initializedCrossingTick) {
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = advanceTimeThroughTickCrossing(
                        self,
                        poolManager,
                        poolKey,
                        Struct.TickCrossingParams({
                            initializedTick: nextTick,
                            nextTimestamp: params.nextTimestamp,
                            secondsElapsedX96: elapsedSecondsX96,
                            pool: params.pool
                        })
                    );
                    elapsedSecondsX96 = elapsedSecondsX96 - secondsUntilCrossingX96;
                } else {
                    (uint256 rewardFactorPool0, uint256 rewardFactorPool1) =
                        TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                    if (params.nextTimestamp % params.expirationInterval == 0) {
                        orderPool0For1.advanceToInterval(params.nextTimestamp, rewardFactorPool0);
                        orderPool1For0.advanceToInterval(params.nextTimestamp, rewardFactorPool1);
                    } else {
                        orderPool0For1.advanceToCurrentTime(rewardFactorPool0);
                        orderPool1For0.advanceToCurrentTime(rewardFactorPool1);
                    }
                    params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                    break;
                }
            }
        }
        return params.pool;
    }

    function advanceTimeForSinglePoolSell(
        Struct.OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        Struct.NextSingleParams memory params
    ) private returns (Struct.ExecutePool memory) {
        Struct.OrderPool storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 currentSellRate = orderPool.currentSellRate;
        uint256 amountSelling = currentSellRate * params.secondsElapsed;
        uint256 totalRewards;

        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            (bool crossingInitializedTick, int24 tick) =
                isCrossingTick(params.pool, poolManager, poolKey, finalSqrtPriceX96);

            if (crossingInitializedTick) {
                (, int128 liquidityNetAtTick) = poolManager.getTickLiquidity(poolKey.toId(), tick);
                uint160 initializedSqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);

                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPriceX96, params.pool.liquidity, true
                );

                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPriceX96, params.pool.liquidity, true
                );

                params.pool.liquidity = params.zeroForOne
                    ? params.pool.liquidity - uint128(liquidityNetAtTick)
                    : params.pool.liquidity + uint128(-liquidityNetAtTick);
                params.pool.sqrtPriceX96 = initializedSqrtPriceX96;

                unchecked {
                    totalRewards += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalRewards += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                } else {
                    totalRewards += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                }

                uint256 accruedRewardsFactor = (totalRewards * FixedPoint96.Q96) / currentSellRate;

                if (params.nextTimestamp % params.expirationInterval == 0) {
                    orderPool.advanceToInterval(params.nextTimestamp, accruedRewardsFactor);
                } else {
                    orderPool.advanceToCurrentTime(accruedRewardsFactor);
                }
                params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                break;
            }
        }
        return params.pool;
    }

    /// @notice Submits a new long term order into the TWAMM.
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The orderKey for the new order
    function submitOrder(
        Struct.OrderState storage self,
        Struct.OrderKey memory orderKey,
        uint256 sellRate,
        uint256 expirationInterval
    ) internal returns (bytes32 orderId) {
        if (orderKey.owner != msg.sender) revert Errors.MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderTime == 0) revert Errors.NotInitialized();
        if (orderKey.expiration <= block.timestamp) {
            revert Errors.ExpirationLessThanBlocktime(orderKey.expiration);
        }
        if (sellRate == 0) revert Errors.SellRateCannotBeZero();

        if (orderKey.expiration % expirationInterval != 0) {
            revert Errors.ExpirationNotOnInterval(orderKey.expiration);
        }

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert Errors.OrderAlreadyExists(orderKey);

        // OrderPool.State storage pool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        Struct.OrderPool storage pool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            pool.currentSellRate += sellRate;

            pool.sellRateEndingAtTime[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Struct.Order({sellRate: sellRate, rewardsFactorLast: pool.currentRewardFactor});
    }

    function updateOrder(Struct.OrderState storage self, Struct.OrderKey memory orderKey, int256 amountDelta)
        internal
        returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 rewardFactorLast)
    {
        Struct.Order storage order = getOrder(self, orderKey);
        Struct.OrderPool storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        if (orderKey.owner != msg.sender) revert Errors.MustBeOwner(orderKey.owner, msg.sender);
        if (order.sellRate == 0) revert Errors.OrderDoesNotExist(orderKey);
        if (amountDelta != 0 && orderKey.expiration <= block.timestamp) {
            revert Errors.CannotModifyCompletedOrder(orderKey);
        }

        unchecked {
            uint256 rewardFactor = orderPool.currentRewardFactor - order.rewardsFactorLast;
            buyTokensOwed = (rewardFactor * order.sellRate) >> FixedPoint96.RESOLUTION;

            rewardFactorLast = orderPool.currentRewardFactor;

            order.rewardsFactorLast = rewardFactorLast;

            if (orderKey.expiration <= block.timestamp) {
                delete self.orders[_orderId(orderKey)];
            }

            if (amountDelta != 0) {
                uint256 duration = orderKey.expiration - block.timestamp;
                uint256 unsoldAmount = order.sellRate * duration;
                if (amountDelta == Constants.MIN_DELTA) amountDelta = -(unsoldAmount.toInt256());
                int256 newSellAmount = unsoldAmount.toInt256() + amountDelta;
                if (newSellAmount < 0) revert Errors.InvalidAmountDelta(orderKey, unsoldAmount, amountDelta);

                newSellRate = uint256(newSellAmount) / duration;

                if (amountDelta < 0) {
                    uint256 sellRateDelta = order.sellRate - newSellRate;
                    orderPool.currentSellRate -= sellRateDelta;
                    orderPool.sellRateEndingAtTime[orderKey.expiration] -= sellRateDelta;
                    sellTokensOwed = uint256(-amountDelta);
                } else {
                    uint256 sellRateDelta = newSellRate - order.sellRate;
                    orderPool.currentSellRate += sellRateDelta;
                    orderPool.sellRateEndingAtTime[orderKey.expiration] += sellRateDelta;
                }
                if (newSellRate == 0) {
                    delete self.orders[_orderId(orderKey)];
                } else {
                    order.sellRate = newSellRate;
                }
            }
        }
    }

    function getOrder(Struct.OrderState storage state, Struct.OrderKey memory orderKey)
        internal
        view
        returns (Struct.Order storage)
    {
        return state.orders[keccak256(abi.encode(orderKey))];
    }

    function _orderId(Struct.OrderKey memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}
