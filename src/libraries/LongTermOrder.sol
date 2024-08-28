// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {OrderPool} from "src/libraries/OrderPool.sol";
import {PoolGetters, IPoolManager, StateLibrary, PoolId, PoolIdLibrary, Pool} from "src/libraries/PoolGetters.sol";
import {BinarySearchTree} from "src/libraries/BinarySearchTree.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {TwammMath} from "src/libraries/TWAMMMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";

/// @notice Library that handles the state and execution of long term orders
library LongTermOrder {
    using OrderPool for OrderPool.State;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using PoolGetters for IPoolManager;

    /// @notice Thrown when account other than owner attemps to interact with an order
    /// @param owner The owner of the order
    /// @param currentAccount The invalid account attempting to interact with the order
    error LongTermOrder__MustBeOwner(address owner, address currentAccount);

    /// @notice Thrown when trying to submit an order without initializing TWAMM state first
    error LongTermOrder__NotInitialized();

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval
    /// @param expiration The expiration timestamp of the order
    error LongTermOrder__ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past
    /// @param expiration The expiration timestamp of the order
    error LongTermOrder__ExpirationLessThanBlocktime(uint256 expiration);

    /// @notice Thrown when submitting an order with a sellRate of 0
    error LongTermOrder__SellRateCannotBeZero();

    /// @notice Thrown when trying to submit an order that's already ongoing
    /// @param orderKey The already existing orderKey
    error LongTermOrder__OrderAlreadyExists(OrderKey orderKey);

    /// @notice fee for LP providers, 4 decimal places, i.e 30 = 0.3%
    uint256 public constant LP_FEE = 30;

    /// @notice Information that identifies an order
    /// @member owner The owner of the order
    /// @member expiration The expiration timestamp of the order
    /// @member zeroForOne Bool whether the order is zeroForOne
    struct OrderKey {
        address owner;
        uint160 expiration;
        bool zeroForOne;
    }

    /// @notice information associated with a long term order
    struct Order {
        uint256 sellRate;
        uint256 rewardsFactorLast;
    }

    struct ExecutePool {
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    struct NextParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        ExecutePool pool;
    }

    struct NextSingleParams {
        uint256 expirationInterval;
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        ExecutePool pool;
        bool zeroForOne;
    }

    struct TickCrossingParams {
        int24 initializedTick;
        uint256 nextTimestamp;
        uint256 secondsElapsedX96;
        ExecutePool pool;
    }

    // struct State {
    //     uint256 lastVirtualOrderBlock;
    //     OrderPool.State orderPool0For1;
    //     OrderPool.State orderPool1For0;
    //     mapping(bytes32 => Order) orders;
    // }

    /// @notice structure contains full state related to the TWAMM
    /// @member orderBlockInterval minimum block interval between order expirations
    /// @member state The state of the long term orders
    /// @notice refTWAMM useful addresses for TWAMM transactions
    /// @notice mapping of poolId to pool that is selling the order
    /// @notice mapping of order id to order
    /// @notice mapping of account address to order id
    /// @notice mapping of order id to its status (true for active, false for inactive)
    struct OrderState {
        uint256 lastVirtualOrderBlock;
        uint256 orderBlockInterval;
        OrderPool.State orderPool0For1;
        OrderPool.State orderPool1For0;
        mapping(bytes32 => OrderKey) orderKeys;
        mapping(bytes32 => Order) orders;
        mapping(address => uint256[]) accountOrders;
        mapping(uint256 => bool) orderStatus;
    }

    /// @notice Initialize state
    function initialize(OrderState storage self) public {
        self.lastVirtualOrderBlock = block.timestamp;
    }

    /// @notice Execute all existing long term orders in the pool
    function executeOrders(
        OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        ExecutePool memory pool,
        uint256 expirationInterval
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!hasOutStandingOrders(self)) {
            self.lastVirtualOrderBlock = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderBlock;
        uint256 nextExpirationTime = prevTimestamp + (expirationInterval - (prevTimestamp % expirationInterval));

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

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
                            NextParams({
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
                            NextSingleParams({
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
                        NextParams({
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
                        NextSingleParams({
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
        self.lastVirtualOrderBlock = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }

    function hasOutStandingOrders(OrderState storage self) internal view returns (bool) {
        return self.orderPool0For1.currentSellRate != 0 || self.orderPool1For0.currentSellRate != 0;
    }

    function isCrossingTick(
        ExecutePool memory pool,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) private view returns (bool initializedCrossingTick, int24 nextTick) {
        nextTick = TickMath.getTickAtSqrtPrice(pool.sqrtPriceX96);
        int24 targetTick = TickMath.getTickAtSqrtPrice(nextSqrtPriceX96);
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

    function advanceToNewTime(
        OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        NextParams memory params
    ) internal returns (ExecutePool memory) {
        uint160 finalSqrtPriceX96;
        uint256 elapsedSecondsX96 = params.secondsElapsed * FixedPoint96.Q96;

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

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
                    (params.pool, secondsUntilCrossingX96, elapsedSecondsX96) =
                        handleTickCrossing(self, poolManager, poolKey, params, nextTick, elapsedSecondsX96);
                } else {
                    params.pool = handleNoTickCrossing(
                        self, orderPool0For1, orderPool1For0, params, finalSqrtPriceX96, executionParams
                    );
                    break;
                }
            }
        }
        return params.pool;
    }

    /// @notice Submits a new long term order into the TWAMM.
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The orderKey for the new order
    function submitOrder(
        OrderState storage self,
        OrderKey memory orderKey,
        uint256 sellRate,
        uint256 expirationInterval
    ) internal returns (bytes32 orderId) {
        if (orderKey.owner != msg.sender) revert LongTermOrder__MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderBlock == 0) revert LongTermOrder__NotInitialized();
        if (orderKey.expiration <= block.timestamp) {
            revert LongTermOrder__ExpirationLessThanBlocktime(orderKey.expiration);
        }
        if (sellRate == 0) revert LongTermOrder__SellRateCannotBeZero();
        if (orderKey.expiration % expirationInterval != 0) {
            revert LongTermOrder__ExpirationNotOnInterval(orderKey.expiration);
        }

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert LongTermOrder__OrderAlreadyExists(orderKey);

        OrderPool.State storage pool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            pool.currentSellRate += sellRate;
            pool.sellRateEndingAtTime[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Order({sellRate: sellRate, rewardsFactorLast: pool.currentRewardFactor});
    }

    function advanceTimeThroughTickCrossing(
        OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        TickCrossingParams memory params
    ) private returns (ExecutePool memory, uint256) {
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

    function advanceTimeForSinglePoolSell(
        OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        NextSingleParams memory params
    ) private returns (ExecutePool memory) {
        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
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

    function _orderId(OrderKey memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function handleTickCrossing(
        OrderState storage self,
        IPoolManager poolManager,
        PoolKey memory poolKey,
        NextParams memory params,
        int24, /*nextTick*/
        uint256 elapsedSecondsX96
    ) private returns (ExecutePool memory, uint256, uint256) {
        uint256 secondsUntilCrossingX96;
        (params.pool, secondsUntilCrossingX96) = advanceTimeThroughTickCrossing(
            self,
            poolManager,
            poolKey,
            TickCrossingParams({
                initializedTick: TickMath.getTickAtSqrtPrice(params.pool.sqrtPriceX96),
                nextTimestamp: params.nextTimestamp,
                secondsElapsedX96: elapsedSecondsX96,
                pool: params.pool
            })
        );
        elapsedSecondsX96 -= secondsUntilCrossingX96;

        return (params.pool, secondsUntilCrossingX96, elapsedSecondsX96);
    }

    function handleNoTickCrossing(
        OrderState storage, /*self*/
        OrderPool.State storage orderPool0For1,
        OrderPool.State storage orderPool1For0,
        NextParams memory params,
        uint160 finalSqrtPriceX96,
        TwammMath.ExecutionUpdateParams memory executionParams
    ) private returns (ExecutePool memory) {
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

        return params.pool;
    }
}
