// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolGetters} from "src/libraries/PoolGetters.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {IUniqHook} from "src/interfaces/IUniqHook.sol";
import {Volatility} from "src/libraries/Volatility.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "src/libraries/Constants.sol";
import {console} from "forge-std/Console.sol";

library DynamicFees {
    using PoolIdLibrary for PoolKey;
    using PoolGetters for IPoolManager;
    using StateLibrary for IPoolManager;
    using TickMath for int24;
    using TickMath for uint160;

    /**
     * @notice Calculates the price movement between the current and last price of a given pool.
     * @dev Uses the time decay factor to adjust the price movement and ensures that the first calculation
     *      after deployment returns a default value if no prior prices are available.
     * @param key The PoolKey that uniquely identifies the pool.
     * @param poolManager The pool manager contract that provides pool data such as prices and liquidity.
     * @param volatility The current volatility value.
     * @param lastPrices A mapping of the last prices for each pool ID.
     * @param lastTimestamp A mapping of the last timestamp for each pool ID.
     * @return priceMovement The percentage price change since the last update, adjusted for time decay.
     */
    function calculateMovement(
        PoolKey calldata key,
        IPoolManager poolManager,
        uint256 volatility,
        mapping(PoolId => uint256) storage lastPrices,
        mapping(PoolId => uint256) storage lastTimestamp
    ) internal returns (uint256 priceMovement) {
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
        // uint256 decayFactor = (timeElapsed > 0) ? Math.min((timeElapsed * 1e18) / 1 days, 1e18) : 1e18; // 1 day decay
        uint256 decayFactor = calculateTimeDecayFactor(timeElapsed);

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

            // console.log("Raw Price Movement: %s", rawMovement);

            priceMovement = (rawMovement * decayFactor) / 1e18;
        }
        console.log("Price Movement With Decay: %s", priceMovement);

        return priceMovement;
    }

    /**
     * @notice Adjusts the trading fee based on the liquidity available in the pool and the trade volume.
     * @dev The fee is scaled by comparing the trade volume to the liquidity in the pool and applying a linear adjustment.
     * @param volume The trade volume for the current swap.
     * @param sqrtPriceX96 The current square root of the price.
     * @param tick The current tick value for the pool.
     * @param liquidity The available liquidity in the pool.
     * @param tickSpacing The tick spacing for the pool.
     * @return liquidityAdjustedFee The adjusted fee based on the volume-to-liquidity ratio.
     */
    function adjustFeeBasedOnLiquidity(
        uint256 volume,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing
    ) internal pure returns (uint24) {
        if (liquidity == 0) {
            // console.log("Liquidity is zero, returning MAX_FEE");
            return Constants.MAX_FEE;
        }

        // Retrieve liquidity for the current tick
        // (uint128 liquidityGross, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, poolId, tick);

        // console.log("Gross Liquidity in AdjustFeeBasedOnLiquidity: %s", liquidityGross);
        // console.log("Net Liquidity in AdjustFeeBasedOnLiquidity: %s", liquidityNet);

        // Compute the TVL at the current tick
        uint256 tickTVL = Volatility.computeTickTVLX64(tickSpacing, tick, sqrtPriceX96, liquidity);
        // console.log("Tick TVL in AdjustFeeBasedOnLiquidity: %s", tickTVL);

        require(tickTVL > 0, "tickTVL cannot be zero");
        require(tickTVL < 1e40, "tickTVL too large");

        // A larger TVL indicates deeper liquidity, hence lower fee impact
        if (tickTVL == 0) {
            return Constants.MAX_FEE; // if no liquidity, set fee to max
        }

        // if (liquidityNet < 0) {
        //     // Multiplies volume by 1.1 (or 110/100) with better precision
        //     volume = Math.mulDiv(volume, 110, 100);
        // }

        // volume-to-liquidity ratio to determine fee adjustment
        // console.log("Volume * 1e18: %s", volume * 1e18); // Before division
        uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e36, tickTVL); // safe division
        console.log("Liquidity Adjusted Fee: %s", volumeToLiquidityRatio);
        require(volumeToLiquidityRatio < type(uint256).max, "Overflow in volumeToLiquidityRatio");

        // Higher ratio = higher fee, lower ratio = lower fee
        if (volumeToLiquidityRatio > 1e18) {
            return Constants.MAX_FEE; // if volume is greater than liquidity, set fee to max
        } else if (volumeToLiquidityRatio < 1e16) {
            return Constants.MIN_FEE; // if volume is less than 1% of liquidity, set fee to min
        } else {
            // scale fee linearly based on ratio
            return uint24(
                Math.mulDiv(volumeToLiquidityRatio, Constants.MAX_FEE - Constants.MIN_FEE, 1e18) + Constants.MIN_FEE
            );
        }
    }

    /**
     * @notice Calculates the fee adjustment based on volatility and price movement.
     * @dev A multiplier is applied to the volatility value, scaled by the price movement, to determine the volatility fee.
     * @param priceMovement The percentage change in price.
     * @param volatility The current volatility value.
     * @return The volatility fee as an adjustment to the base fee.
     */
    function calculateVolatilityFee(uint256 priceMovement, uint256 volatility) internal pure returns (uint256) {
        uint256 movementFactor = priceMovement > 0 ? priceMovement : 1e16;
        return (volatility * Constants.VOLATILITY_MULTIPLIER * movementFactor) / Constants.VOLATILITY_FACTOR;
    }

    /**
     * @notice Calculates a directional multiplier to adjust fees based on trade aggression.
     * @dev The multiplier increases for aggressive trades where price movement is high and volume is large relative to liquidity.
     * @param isAggressive Whether the trade is considered aggressive based on direction and price movement.
     * @param priceMovement The percentage change in price.
     * @param volume The trade volume.
     * @param liquidity The available liquidity in the pool.
     * @return The directional multiplier used to adjust the fee.
     */
    function calculateDirectionalMultiplier(bool isAggressive, uint256 priceMovement, uint256 volume, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        // Base directional multiplier for passive trade is 1
        uint256 baseMultiplier = isAggressive ? 1 : 1;

        if (isAggressive) {
            // Scale multiplier based on price movement (larger movement = larger fee multiplier)
            if (priceMovement > 1e18) {
                baseMultiplier = 2; // slightly aggressive
                console.log("Price Movement > 1e18");
            }
            if (priceMovement > 5e18) {
                baseMultiplier = 3; // moderately aggressive
                console.log("Price Movement > 5e18");
            }
            if (priceMovement > 10e18) {
                baseMultiplier = 4; // highly aggressive
                console.log("Price Movement > 10e18");
            }

            if (liquidity > 0) {
                // Adjust multiplier based on trade size relative to liquidity
                uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e18, liquidity); // safe division
                if (volumeToLiquidityRatio > 5e17) {
                    baseMultiplier += 1; // if trade size is greater than 50% of liquidity, increase multiplier
                    console.log("Volume to Liquidity Ratio > 5e17");
                }
                if (volumeToLiquidityRatio > 1e18) {
                    baseMultiplier += 2; // if trade size is greater than liquidity, increase multiplier
                    console.log("Volume to Liquidity Ratio > 1e18");
                }
            } else {
                baseMultiplier += 2; // if no liquidity, increase multiplier
                    // console.log("No Liquidity");
            }
        }
        // console.log("Directional Multiplier: %s", baseMultiplier);
        return baseMultiplier;
    }

    /**
     * @notice Converts a tick value to an internal price.
     * @dev This uses the square root of the price formula to derive the price from the tick.
     * @param tick The tick value representing the current price point in the Uniswap pool.
     * @return The internal price as a uint256.
     */
    function calculateInternalPriceFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / FixedPoint96.Q96;
    }

    // KIV: This function will be use after the integration of the oracle
    function calculatePriceMovement(uint256 internalPrice, uint256 oraclePrice) private pure returns (uint256) {
        if (internalPrice > oraclePrice) {
            return ((internalPrice - oraclePrice) * 1e18) / oraclePrice;
        } else {
            return ((oraclePrice - internalPrice) * 1e18) / internalPrice;
        }
    }

    // KIV: This function will be use after the integration of the oracle
    function calculatePriceDeviation(uint256 internalPrice, uint256 externalPrice) private pure returns (uint256) {
        if (internalPrice > externalPrice) {
            return ((internalPrice - externalPrice) * 1e18) / externalPrice;
        } else {
            return ((externalPrice - internalPrice) * 1e18) / internalPrice;
        }
    }

    /**
     * @notice Calculates the time decay factor to adjust price movements based on the time elapsed since the last trade.
     * @dev Decays the price movement over time, with a 1% decay per day, applied per second.
     * @param timeElapsed The amount of time (in seconds) since the last trade.
     * @return decayFactor The decay factor to apply to price movements.
     */
    function calculateTimeDecayFactor(uint256 timeElapsed) internal pure returns (uint256 decayFactor) {
        // Decay by 1% per day (1e18 / 1 days)
        // (1 - 1% daily decay) ^ (1/86400)
        uint256 decayPerSecond = 999988422222221000; // (1 - 1% daily decay)^(1/86400)
        decayFactor = 1e18;

        assembly {
            for { let i := timeElapsed } gt(i, 0) { i := sub(i, 1) } {
                // decayFactor = (decayFactor * decayPerSecond) / 1e18
                decayFactor := div(mul(decayFactor, decayPerSecond), 1000000000000000000)
            }
        }
    }

    // KIV: This function will be use after the integration of the oracle
    function getPriceTolerance() internal pure returns (uint256) {
        return 1e16; // 1%
    }

    // KIV: This function will be use after the integration of the oracle
    function decayVolatilityImpact(uint256 volatility, uint256 lastOracleUpdate) private view {
        uint256 timeElapsed = block.timestamp - lastOracleUpdate;
        if (timeElapsed > 1 hours) {
            // Decay the impact of volatility over time
            uint256 decayFactor = Math.min((timeElapsed * 1e18) / 1 days, 1e18); // 1 day decay
            volatility = (volatility * (1e18 - decayFactor)) / 1e18;
            console.log("Decayed Volatility: %s", volatility);
        }
    }

    // function getPriceToleranceWithVolatility() private view returns (uint256) {
    //     if (volatility > 1e18) {
    //         return 10e16; // 10% tolerance during high volatility
    //     } else if (volatility > 5e17) {
    //         return 5e16; // 5% tolerance during moderate volatility
    //     } else {
    //         return 3e16; // 3% tolerance during low volatility
    //     }
    // }

    /**
     * @notice Returns the absolute value of a signed integer.
     * @dev Converts a negative signed integer into its positive counterpart.
     * @param x The signed integer input.
     * @return The absolute value of the input as an unsigned integer.
     */
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /**
     * @notice Computes the square root of a given number.
     * @dev Uses an optimized algorithm to calculate the square root of the input number.
     *      The result is truncated towards zero, meaning that it rounds down for non-perfect squares.
     * @param x The number for which to compute the square root.
     * @return y The truncated square root of the input number.
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
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
