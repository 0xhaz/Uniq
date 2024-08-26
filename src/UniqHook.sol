// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

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

contract UniqHook is BaseHook, IUniqHook {
    using TransferHelper for IERC20Minimal;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using OrderPool for OrderPool.State;
    using PoolIdLibrary for PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);
    using StateLibrary for IPoolManager;

    /// @inheritdoc IUniqHook
    uint256 public immutable expirationInterval;
    /// @notice The TWAMM state for each pool
    mapping(PoolId => State) internal uniqAmmStates;
    /// @notice The amount of tokens owed to each user
    mapping(Currency => mapping(address => uint256)) public tokensOwed;

    constructor(IPoolManager poolManager, uint256 expirationInterval_) BaseHook(poolManager) {
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
        _initialize(_getTWAMM(key));
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

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        executeTWAMMOrders(key);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function lastVirtualOrderTimestamp(PoolId key) external view returns (uint256) {
        return uniqAmmStates[key].lastVirtualOrderTimestamp;
    }

    function getOrder(PoolKey calldata key, OrderKey calldata orderKey) external view returns (Order memory) {
        return _getOrder(uniqAmmStates[PoolId.wrap(keccak256(abi.encode(key)))], orderKey);
    }

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        State storage twamm = _getTWAMM(key);
        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }

    /// @inheritdoc IUniqHook
    function executeTWAMMOrders(PoolKey memory key) public {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        State storage twamm = uniqAmmStates[poolId];

        (bool zeroForOne, uint160 sqrtPriceLimitX96) = _executeTWAMMOrders(
            twamm, poolManager, key, PoolParamsOnExecute(sqrtPriceX96, poolManager.getLiquidity(poolId))
        );

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
            poolManager.unlock(
                abi.encode(key, IPoolManager.SwapParams(zeroForOne, type(int256).max, sqrtPriceLimitX96))
            );
        }
    }

    /// @inheritdoc IUniqHook
    function submitOrder(PoolKey calldata key, OrderKey memory orderKey, uint256 amountIn)
        external
        returns (bytes32 orderId)
    {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        State storage twamm = uniqAmmStates[poolId];
        executeTWAMMOrders(key);

        uint256 sellRate;
        unchecked {
            // checks done in TWAMM library
            uint256 duration = orderKey.expiration - block.timestamp;
            sellRate = amountIn / duration;
            orderId = _submitOrder(twamm, orderKey, sellRate);
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), sellRate * duration);
        }

        emit SubmitOrder(
            poolId,
            orderKey.owner,
            orderKey.expiration,
            orderKey.zeroForOne,
            sellRate,
            _getOrder(twamm, orderKey).earningsFactorLast
        );
    }

    /// @inheritdoc IUniqHook
    function updateOrder(PoolKey memory key, OrderKey memory orderKey, int256 amountDelta)
        external
        returns (uint256 tokens0Owed, uint256 tokens1Owed)
    {
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(key)));
        State storage twamm = uniqAmmStates[poolId];

        executeTWAMMOrders(key);

        // This call reverts if the caller is not the owner of the order
        (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 newEarningsFactorLast) =
            _updateOrder(twamm, orderKey, amountDelta);

        if (orderKey.zeroForOne) {
            tokens0Owed += sellTokensOwed;
            tokens1Owed += buyTokensOwed;
        } else {
            tokens0Owed += buyTokensOwed;
            tokens1Owed += sellTokensOwed;
        }

        tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
        tokensOwed[key.currency1][orderKey.owner] += tokens1Owed;

        if (amountDelta > 0) {
            IERC20Minimal(orderKey.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1))
                .safeTransferFrom(msg.sender, address(this), uint256(amountDelta));
        }

        emit UpdateOrder(
            poolId, orderKey.owner, orderKey.expiration, orderKey.zeroForOne, newSellRate, newEarningsFactorLast
        );
    }

    /// @inheritdoc IUniqHook
    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) amountTransferred = amountRequested;
        if (currentBalance < amountTransferred) amountTransferred = currentBalance; // to catch precision errors
        tokensOwed[token][msg.sender] -= amountTransferred;
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
    }

    /*//////////////////////////////////////////////////////////////
                            PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Gets the TWAMM state for a pool
    /// @param key The PoolKey for which to identify the amm pool
    /// @return The TWAMM state for the pool
    function _getTWAMM(PoolKey memory key) private view returns (State storage) {
        return uniqAmmStates[PoolId.wrap(keccak256(abi.encode(key)))];
    }

    function _advanceToNewTimestamp(
        State storage self,
        IPoolManager manager,
        PoolKey memory key,
        AdvanceParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        uint160 finalSqrtPriceX96;
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        while (true) {
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams({
                secondsElapsedX96: secondsElapsedX96,
                sqrtPriceX96: params.pool.sqrtPriceX96,
                liquidity: params.pool.liquidity,
                sellRateCurrent0: orderPool0For1.sellRateCurrent,
                sellRateCurrent1: orderPool1For0.sellRateCurrent
            });

            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, manager, key, finalSqrtPriceX96);

            unchecked {
                if (crossingInitializedTick) {
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
                        self,
                        manager,
                        key,
                        TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool)
                    );
                    secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
                } else {
                    (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
                        TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                    if (params.nextTimestamp % params.expirationInterval == 0) {
                        orderPool0For1.advanceToInterval(params.nextTimestamp, earningsFactorPool0);
                        orderPool1For0.advanceToInterval(params.nextTimestamp, earningsFactorPool1);
                    } else {
                        orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
                        orderPool1For0.advanceToCurrentTime(earningsFactorPool1);
                    }
                    params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                    break;
                }
            }
        }
        return params.pool;
    }

    function _advanceTimeThroughTickCrossing(
        State storage self,
        IPoolManager manager,
        PoolKey memory key,
        TickCrossingParams memory params
    ) private returns (PoolParamsOnExecute memory, uint256) {
        uint160 initializedSqrtPrice = params.initializedTick.getSqrtPriceAtTick();

        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            self.orderPool0For1.sellRateCurrent,
            self.orderPool1For0.sellRateCurrent
        );

        (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams({
                secondsElapsedX96: secondsUntilCrossingX96,
                sqrtPriceX96: params.pool.sqrtPriceX96,
                liquidity: params.pool.liquidity,
                sellRateCurrent0: self.orderPool0For1.sellRateCurrent,
                sellRateCurrent1: self.orderPool1For0.sellRateCurrent
            }),
            initializedSqrtPrice
        );

        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

        unchecked {
            // update pool state
            (, int128 liquidityNet) = manager.getTickLiquidity(key.toId(), params.initializedTick);
            if (initializedSqrtPrice < params.pool.sqrtPriceX96) liquidityNet = -liquidityNet;
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPrice;
        }
        return (params.pool, secondsUntilCrossingX96);
    }

    function _advanceTimestampForSinglePoolSell(
        State storage self,
        IPoolManager manager,
        PoolKey memory key,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        OrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
        uint256 totalEarnings;

        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, manager, key, finalSqrtPriceX96);

            if (crossingInitializedTick) {
                (, int128 liquidityNetAtTick) = manager.getTickLiquidity(key.toId(), tick);
                uint160 initializedSqrtPrice = TickMath.getSqrtPriceAtTick(tick);

                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );

                params.pool.liquidity = params.zeroForOne
                    ? params.pool.liquidity - uint128(liquidityNetAtTick)
                    : params.pool.liquidity + uint128(-liquidityNetAtTick);
                params.pool.sqrtPriceX96 = initializedSqrtPrice;

                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                }

                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;

                if (params.nextTimestamp % params.expirationInterval == 0) {
                    orderPool.advanceToInterval(params.nextTimestamp, accruedEarningsFactor);
                } else {
                    orderPool.advanceToCurrentTime(accruedEarningsFactor);
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

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the TWAMM state for a pool
    /// @param self The TWAMM state to initialize
    function _initialize(State storage self) internal {
        self.lastVirtualOrderTimestamp = block.timestamp;
    }

    /// @notice Executes all existing long term orders in the TWAMM
    /// @param pool The relevant pool for which to execute orders
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager manager,
        PoolKey memory key,
        PoolParamsOnExecute memory pool
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;
        uint256 nextExpirationTimestamp = prevTimestamp + (expirationInterval - (prevTimestamp % expirationInterval));

        OrderPool.State storage orderPool0For1 = self.orderPool0For1;
        OrderPool.State storage orderPool1For0 = self.orderPool1For0;

        unchecked {
            while (nextExpirationTimestamp <= block.timestamp) {
                if (
                    orderPool0For1.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                        || orderPool1For0.sellRateEndingAtInterval[nextExpirationTimestamp] > 0
                ) {
                    if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                        pool = _advanceToNewTimestamp(
                            self,
                            manager,
                            key,
                            AdvanceParams({
                                expirationInterval: expirationInterval,
                                nextTimestamp: nextExpirationTimestamp,
                                secondsElapsed: nextExpirationTimestamp - prevTimestamp,
                                pool: pool
                            })
                        );
                    } else {
                        pool = _advanceTimestampForSinglePoolSell(
                            self,
                            manager,
                            key,
                            AdvanceSingleParams({
                                expirationInterval: expirationInterval,
                                nextTimestamp: nextExpirationTimestamp,
                                secondsElapsed: nextExpirationTimestamp - prevTimestamp,
                                pool: pool,
                                zeroForOne: orderPool0For1.sellRateCurrent != 0
                            })
                        );
                    }
                    prevTimestamp = nextExpirationTimestamp;
                }
                nextExpirationTimestamp += expirationInterval;

                if (!_hasOutstandingOrders(self)) break;
            }
            if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        manager,
                        key,
                        AdvanceParams({
                            expirationInterval: expirationInterval,
                            nextTimestamp: block.timestamp,
                            secondsElapsed: block.timestamp - prevTimestamp,
                            pool: pool
                        })
                    );
                } else {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        manager,
                        key,
                        AdvanceSingleParams({
                            expirationInterval: expirationInterval,
                            nextTimestamp: block.timestamp,
                            secondsElapsed: block.timestamp - prevTimestamp,
                            pool: pool,
                            zeroForOne: orderPool0For1.sellRateCurrent != 0
                        })
                    );
                }
            }
        }
        self.lastVirtualOrderTimestamp = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 < newSqrtPriceX96;
    }

    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        IPoolManager manager,
        PoolKey memory key,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        // use current price as a starting point for nextTickInit
        nextTickInit = pool.sqrtPriceX96.getTickAtSqrtPrice();
        int24 targetTick = nextSqrtPriceX96.getTickAtSqrtPrice();
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickInitFurtherThanTarget = false;

        // NextTickInit returns the furthest tick within one word if no tick within that word is initialized
        // If the target tick is initialized, we can skip this check
        while (!nextTickInitFurtherThanTarget) {
            unchecked {
                if (searchingLeft) nextTickInit--;
            }
            (nextTickInit, crossingInitializedTick) =
                manager.getNextInitializedTickWithinOneWord(key.toId(), nextTickInit, key.tickSpacing, searchingLeft);
            nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
            if (nextTickInitFurtherThanTarget == true) break;
        }
        if (nextTickInitFurtherThanTarget) crossingInitializedTick = false;
    }

    /// @notice Submits a new long term order into the TWAMM.
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The orderKey for the new order
    function _submitOrder(State storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderTimestamp == 0) revert NotInitialized();
        if (orderKey.expiration <= block.timestamp) revert ExpirationLessThanBlocktime(orderKey.expiration);
        if (sellRate == 0) revert SellRateCannotBeZero();
        if (orderKey.expiration % expirationInterval != 0) revert ExpirationNotOnInterval(orderKey.expiration);

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            orderPool.sellRateCurrent += sellRate;
            orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRate;
        }

        self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});
    }

    function _updateOrder(State storage self, OrderKey memory orderKey, int256 amountDelta)
        internal
        returns (uint256 buyTokensOwed, uint256 sellTokensOwed, uint256 newSellRate, uint256 earningsFactorLast)
    {
        Order storage order = _getOrder(self, orderKey);
        OrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (order.sellRate == 0) revert OrderDoesNotExist(orderKey);
        if (amountDelta != 0 && orderKey.expiration <= block.timestamp) revert CannotModifyCompletedOrder(orderKey);

        unchecked {
            uint256 earningsFactor = orderPool.earningsFactorCurrent - order.earningsFactorLast;
            buyTokensOwed = (earningsFactor * order.sellRate) >> FixedPoint96.RESOLUTION;
            earningsFactorLast = orderPool.earningsFactorCurrent;
            order.earningsFactorLast = earningsFactorLast;

            if (orderKey.expiration <= block.timestamp) {
                delete self.orders[_orderId(orderKey)];
            }

            if (amountDelta != 0) {
                uint256 duration = orderKey.expiration - block.timestamp;
                uint256 unsoldAmount = order.sellRate * duration;
                if (amountDelta == Constants.MIN_DELTA) amountDelta = -(unsoldAmount.toInt256());
                int256 newSellAmount = unsoldAmount.toInt256() + amountDelta;
                if (newSellAmount < 0) revert InvalidAmountDelta(orderKey, unsoldAmount, amountDelta);

                if (amountDelta < 0) {
                    uint256 sellRateDelta = order.sellRate - newSellRate;
                    orderPool.sellRateCurrent -= sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] -= sellRateDelta;
                    sellTokensOwed = uint256(-amountDelta);
                } else {
                    uint256 sellRateDelta = newSellRate - order.sellRate;
                    orderPool.sellRateCurrent += sellRateDelta;
                    orderPool.sellRateEndingAtInterval[orderKey.expiration] += sellRateDelta;
                }
                if (newSellRate == 0) {
                    delete self.orders[_orderId(orderKey)];
                } else {
                    order.sellRate = newSellRate;
                }
            }
        }
    }

    function _getOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[_orderId(key)];
    }

    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }
}
