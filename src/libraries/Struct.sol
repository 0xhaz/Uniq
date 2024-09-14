// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

library Struct {
    /// @notice Information related to a long term order pool
    /// @member currentSalesRate current rate that tokens are being sold (per block)
    /// @member rewardFactor Sum of (salesProceeds_k / salesRate_k) over period k. Stored as a fixed precision floating point number
    /// @member salesRateEndingPerBlock Mapping (timestamp => sellRate) The cumulative sales rate of orders that expire on that block
    /// @member orderExpiry Mapping (timestamp => saleRate) The cumulative sales rate of orders that expire on that block
    /// @member salesRate Mapping(timestamp => saleRate) Mapping of the sales rate at a certain timestamp
    /// @member rewardFactorAtSubmission Mapping (timestamp => rewardFactor) The reward factor accrued at time of submission.
    /// @member rewardFactorAtBlock  Mapping (block => rewardFactor) The reward factor accrued at a certain block
    struct OrderPool {
        uint256 currentSellRate;
        mapping(uint256 => uint256) sellRateEndingAtTime;
        uint256 currentRewardFactor;
        mapping(uint256 => uint256) rewardFactorAtTime;
    }

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

    /// @notice structure contains full state related to the TWAMM
    /// @member orderBlockInterval minimum block interval between order expirations
    /// @member state The state of the long term orders
    /// @notice refTWAMM useful addresses for TWAMM transactions
    /// @notice mapping of poolId to pool that is selling the order
    /// @notice mapping of order id to order
    /// @notice mapping of account address to order id
    /// @notice mapping of order id to its status (true for active, false for inactive)
    struct OrderState {
        uint256 lastVirtualOrderTime;
        OrderPool orderPool0For1;
        OrderPool orderPool1For0;
        mapping(bytes32 => Order) orders;
        Observation[65535] observations;
        ObservationState observationState;
    }

    struct Observation {
        // the block timestamp of the observation
        uint32 blockTimestamp;
        // the tick accumulator, i.e. tick * time elapsed since the pool was first initialized
        int56 tickCumulative;
        // the seconds per liquidity, i.e. seconds elapsed / max(1, liquidity) since the pool was first initialized
        uint160 secondsPerLiquidityCumulativeX128;
        // whether or not the observation is initialized
        bool initialized;
    }

    /// @member index The index of the last written observation for the pool
    /// @member cardinality The cardinality of the observations array for the pool
    /// @member cardinalityNext The cardinality target of the observations array for the pool, which will replace cardinality when enough observations are written
    struct ObservationState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }
}
