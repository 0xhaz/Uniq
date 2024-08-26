// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {ABDKMathQuad} from "./ABDKMathQuad.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @title TWAMM Math - Pure functions for TWAMM calculations
library TwammMath {
    using ABDKMathQuad for bytes16;
    using ABDKMathQuad for uint256;
    using ABDKMathQuad for uint160;
    using ABDKMathQuad for uint128;
    using SafeCast for uint256;

    // ABDKMathQuad FixedPoint96.Q96.fromUInt()
    bytes16 internal constant Q96 = 0x405f0000000000000000000000000000;

    bytes16 internal constant ONE = 0x3fff0000000000000000000000000000;
    //// @dev The minimum value that a pool price can equal, represented in bytes.
    // (TickMath.MIN_SQRT_RATIO + 1).fromUInt()
    bytes16 internal constant MIN_SQRT_RATIO_BYTES = 0x401f000276a400000000000000000000;
    //// @dev The maximum value that a pool price can equal, represented in bytes.
    // (TickMath.MAX_SQRT_RATIO - 1).fromUInt()
    bytes16 internal constant MAX_SQRT_RATIO_BYTES = 0x409efffb12c7dfa3f8d4a0c91092bb2a;

    struct PriceParamsBytes16 {
        bytes16 sqrtSellRatio;
        bytes16 sqrtSellRate;
        bytes16 secondsElapsed;
        bytes16 sqrtPrice;
        bytes16 liquidity;
    }

    struct ExecutionUpdateParams {
        uint256 secondsElapsedX96;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        uint256 sellRateCurrent0;
        uint256 sellRateCurrent1;
    }

    function getNewSqrtPriceX96(ExecutionUpdateParams memory params) internal pure returns (uint160 newSqrtPriceX96) {
        bytes16 sellRateBytes0 = params.sellRateCurrent0.fromUInt();
        bytes16 sellRateBytes1 = params.sellRateCurrent1.fromUInt();
        bytes16 sqrtSellRateBytes = sellRateBytes0.mul(sellRateBytes1).sqrt();
        bytes16 sqrtSellRatioX96Bytes = sellRateBytes1.div(sellRateBytes0).sqrt().mul(Q96);

        PriceParamsBytes16 memory priceParams = PriceParamsBytes16({
            sqrtSellRatio: sqrtSellRatioX96Bytes.div(Q96),
            sqrtSellRate: sqrtSellRateBytes,
            secondsElapsed: params.secondsElapsedX96.fromUInt().div(Q96),
            sqrtPrice: params.sqrtPriceX96.fromUInt().div(Q96),
            liquidity: params.liquidity.fromUInt()
        });

        bytes16 newSqrtPriceBytesX96 = calculateNewSqrtPrice(priceParams).mul(Q96);
        bool isOverflow = newSqrtPriceBytesX96.isInfinity() || newSqrtPriceBytesX96.isNaN();
        bytes16 newSqrtPriceX96Bytes = isOverflow ? sqrtSellRatioX96Bytes : newSqrtPriceBytesX96;

        newSqrtPriceX96 = getSqrtPriceWithinBounds(
            params.sellRateCurrent0 > params.sellRateCurrent1, newSqrtPriceX96Bytes
        ).toUInt().toUint160();
    }

    function getSqrtPriceWithinBounds(bool zeroForOne, bytes16 desiredPriceX96)
        internal
        pure
        returns (bytes16 newSqrtPriceX96)
    {
        if (zeroForOne) {
            newSqrtPriceX96 = MIN_SQRT_RATIO_BYTES.gt(desiredPriceX96) == 1 ? MIN_SQRT_RATIO_BYTES : desiredPriceX96;
        } else {
            newSqrtPriceX96 = desiredPriceX96.gt(MAX_SQRT_RATIO_BYTES) == 1 ? MAX_SQRT_RATIO_BYTES : desiredPriceX96;
        }
    }

    // function calculateEarningsUpdates(ExecutionUpdateParams memory params, uint160 finalSqrtPriceX96)
    //     internal
    //     pure
    //     returns (uint256 earningsFactorPool0, uint256 earningsFactorPool1)
    // {
    //     bytes16 sellRateBytes0 = params.sellRateCurrent0.fromUInt();
    //     bytes16 sellRateBytes1 = params.sellRateCurrent1.fromUInt();

    //     bytes16 sellRatio = sellRateBytes1.div(sellRateBytes0);
    //     bytes16 sqrtSellRate = sellRateBytes0.mul(sellRateBytes1).sqrt();

    //     EarningsFactorParams memory earningsFactorParams = EarningsFactorParams({
    //         secondsElapsed: params.secondsElapsedX96.fromUInt().div(Q96),
    //         sellRatio: sellRatio,
    //         sqrtSellRate: sqrtSellRate,
    //         prevSqrtPrice: params.sqrtPriceX96.fromUInt().div(Q96),
    //         newSqrtPrice: finalSqrtPriceX96.fromUInt().div(Q96),
    //         liquidity: params.liquidity.fromUInt()
    //     });

    //     // Trade the amm orders.
    //     // If liquidity is 0, it trades the twamm orders against each other for the time duration.
    //     earningsFactorPool0 = getEarningsFactorPool0(earningsFactorParams).mul(Q96).toUInt();
    //     earningsFactorPool1 = getEarningsFactorPool1(earningsFactorParams).mul(Q96).toUInt();
    // }

    struct calculateTimeBetweenTicksParams {
        uint256 liquidity;
        uint160 sqrtPriceStartX96;
        uint160 sqrtPriceEndX96;
        uint256 sellRate0;
        uint256 sellRate1;
    }

    /// @notice Used when crossing an initialized tick. Can extract the amount of seconds it took to cross
    ///   the tick, and recalibrate the calculation from there to accommodate liquidity changes
    function calculateTimeBetweenTicks(
        uint256 liquidity,
        uint160 sqrtPriceStartX96,
        uint160 sqrtPriceEndX96,
        uint256 sellRate0,
        uint256 sellRate1
    ) internal pure returns (uint256 secondsBetween) {
        bytes16 sellRate0Bytes = sellRate0.fromUInt();
        bytes16 sellRate1Bytes = sellRate1.fromUInt();
        bytes16 sqrtPriceStartX96Bytes = sqrtPriceStartX96.fromUInt();
        bytes16 sqrtPriceEndX96Bytes = sqrtPriceEndX96.fromUInt();
        bytes16 sqrtSellRatioX96 = sellRate1Bytes.div(sellRate0Bytes).sqrt().mul(Q96);
        bytes16 sqrtSellRate = sellRate0Bytes.mul(sellRate1Bytes).sqrt();

        bytes16 multiple = getTimeBetweenTicksMultiple(sqrtSellRatioX96, sqrtPriceStartX96Bytes, sqrtPriceEndX96Bytes);
        bytes16 numerator = multiple.mul(liquidity.fromUInt());
        bytes16 denominator = uint256(2).fromUInt().mul(sqrtSellRate);
        return numerator.mul(Q96).div(denominator).toUInt();
    }

    function getTimeBetweenTicksMultiple(bytes16 sqrtSellRatioX96, bytes16 sqrtPriceStartX96, bytes16 sqrtPriceEndX96)
        private
        pure
        returns (bytes16 multiple)
    {
        bytes16 multiple1 = sqrtSellRatioX96.add(sqrtPriceEndX96).div(sqrtSellRatioX96.sub(sqrtPriceEndX96));
        bytes16 multiple2 = sqrtSellRatioX96.sub(sqrtPriceStartX96).div(sqrtSellRatioX96.add(sqrtPriceStartX96));
        return multiple1.mul(multiple2).ln();
    }

    struct EarningsFactorParams {
        bytes16 secondsElapsed;
        bytes16 sellRatio;
        bytes16 sqrtSellRate;
        bytes16 prevSqrtPrice;
        bytes16 newSqrtPrice;
        bytes16 liquidity;
    }

    function getEarningsFactorPool0(EarningsFactorParams memory params) private pure returns (bytes16 earningsFactor) {
        bytes16 minuend = params.sellRatio.mul(params.secondsElapsed);
        bytes16 subtrahend = params.liquidity.mul(params.sellRatio.sqrt()).mul(
            params.newSqrtPrice.sub(params.prevSqrtPrice)
        ).div(params.sqrtSellRate);
        return minuend.sub(subtrahend);
    }

    function getEarningsFactorPool1(EarningsFactorParams memory params) private pure returns (bytes16 earningsFactor) {
        bytes16 minuend = params.secondsElapsed.div(params.sellRatio);
        bytes16 subtrahend = params.liquidity.mul(reciprocal(params.sellRatio.sqrt())).mul(
            reciprocal(params.newSqrtPrice).sub(reciprocal(params.prevSqrtPrice))
        ).div(params.sqrtSellRate);
        return minuend.sub(subtrahend);
    }

    function calculateNewSqrtPrice(PriceParamsBytes16 memory params) private pure returns (bytes16 newSqrtPrice) {
        bytes16 pow = uint256(2).fromUInt().mul(params.sqrtSellRate).mul(params.secondsElapsed).div(params.liquidity);
        bytes16 c = params.sqrtSellRatio.sub(params.sqrtPrice).div(params.sqrtSellRatio.add(params.sqrtPrice));
        newSqrtPrice = params.sqrtSellRatio.mul(pow.exp().sub(c)).div(pow.exp().add(c));
    }

    function reciprocal(bytes16 n) private pure returns (bytes16) {
        return ONE.div(n);
    }

    ///////////////////////////////////////////////////////////////////////
    ///           Nezlobin's Directional Fee Functions                  ///
    ///////////////////////////////////////////////////////////////////////

    /// @notice Key Concepts of Nezlobin's Directional Fee:
    /// 1. Directional Component: The fee increases when trades move the price in the less desirable direction.
    ///   (away from equilibrium) and decreases when moving in the favorable direction. (towards equilibrium)
    /// 2. Sensitivity Factor: A coefficient that determines how sensitive the fee adjustment is relative to the price movement
    /// @dev High-Level Plan:
    /// 1. Track Price Movements: Record the current price and the direction of each trade (up or down)
    /// 2. Fee Adjustment Logic: Calculate the fee based on whether the trade moves the price closer to or further from a reference price (moving average)
    /// 3. Update the Fee Dynamically: Apply the new fee when calculating earnings updates or price changes

    // Constants for directional fee 0.3%
    bytes16 internal constant BASE_FEE = 0x3ffd3333333333333333333333333333; // Example: 0.3% (in bytes16)
    bytes16 internal constant SENSITIVITY = 0x3ffc9999999999999999999999999999; // Sensitivity factor (in bytes16)

    struct DirectionalFeeParams {
        bytes16 currentPrice;
        bytes16 previousPrice;
        bytes16 targetPrice;
    }

    function calculateDirectionalFee(DirectionalFeeParams memory params)
        internal
        pure
        returns (bytes16 directionalFee)
    {
        // Calculate the price difference between the current price and the target price
        bytes16 priceDifference = params.currentPrice.sub(params.targetPrice);

        // Determine if the price is moving toward or away from the target price
        bool movingTowardTarget =
            params.currentPrice.sub(params.targetPrice).abs() < params.previousPrice.sub(params.targetPrice).abs();

        // Adjust the fee based on the direction
        if (movingTowardTarget) {
            // Price is moving towards the target price, reduce the fee
            directionalFee = BASE_FEE.sub(SENSITIVITY.mul(priceDifference.abs()));
        } else {
            // Price is moving away from the target price, increase the fee
            directionalFee = BASE_FEE.add(SENSITIVITY.mul(priceDifference.abs()));
        }

        // Ensure the fee stays within reasonable bounds (e.g no negative fees)
        if (directionalFee.isNaN() || directionalFee.isInfinity()) {
            directionalFee = BASE_FEE;
        }
    }

    function calculateEarningsUpdates(ExecutionUpdateParams memory params, uint160 finalSqrtPriceX96)
        internal
        pure
        returns (uint256 earningsFactorPool0, uint256 earningsFactorPool1)
    {
        bytes16 directionalFee = calculateDirectionalFee(
            DirectionalFeeParams({
                currentPrice: params.sqrtPriceX96.fromUInt().div(Q96),
                previousPrice: params.sqrtPriceX96.fromUInt().div(Q96),
                targetPrice: getMovingAverage()
            })
        );

        EarningsFactorParams memory earningsFactorParams = EarningsFactorParams({
            secondsElapsed: params.secondsElapsedX96.fromUInt().div(Q96),
            sellRatio: params.sellRateCurrent1.fromUInt().div(params.sellRateCurrent0.fromUInt()),
            sqrtSellRate: params.sellRateCurrent0.fromUInt().mul(params.sellRateCurrent1.fromUInt()).sqrt(),
            prevSqrtPrice: params.sqrtPriceX96.fromUInt().div(Q96),
            newSqrtPrice: finalSqrtPriceX96.fromUInt().div(Q96),
            liquidity: params.liquidity.fromUInt()
        });

        // Trade the amm orders.
        // If liquidity is 0, it trades the twamm orders against each other for the time duration.
        uint256 baseEarningsFactorPool0 = getEarningsFactorPool0(earningsFactorParams).mul(Q96).toUInt();
        uint256 baseEarningsFactorPool1 = getEarningsFactorPool1(earningsFactorParams).mul(Q96).toUInt();

        // Apply the directional fee to the earnings factors
        earningsFactorPool0 = (baseEarningsFactorPool0 * directionalFee.toUInt()) / (Q96).toUInt();
        earningsFactorPool1 = (baseEarningsFactorPool1 * directionalFee.toUInt()) / (Q96).toUInt();
    }

    function getMovingAverage() internal pure returns (bytes16) {
        // Implement logic to calculate a target price, such as a simple moving average
        return 0x40000000000000000000000000000000; // Example: 2.0 (in bytes16)
    }
}
