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

            console.log("Raw Price Movement: %s", rawMovement);

            priceMovement = (rawMovement * decayFactor) / 1e18;
        }
        console.log("Price Movement With Decay: %s", priceMovement);

        return priceMovement;
    }

    function adjustFeeBasedOnLiquidity(
        /*PoolKey calldata key*/
        uint256 volume,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        int24 tickSpacing
    ) internal pure returns (uint24) {
        // PoolId poolId = key.toId();

        if (liquidity == 0) {
            return Constants.MAX_FEE;
        }

        // Retrieve liquidity for the current tick
        // (uint128 liquidityGross, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, poolId, tick);

        // console.log("Gross Liquidity in AdjustFeeBasedOnLiquidity: %s", liquidityGross);
        // console.log("Net Liquidity in AdjustFeeBasedOnLiquidity: %s", liquidityNet);
        console.log("Tick in  AdjustFeeBasedOnLiquidity: %s", tick);

        // Compute the TVL at the current tick
        uint256 tickTVL = Volatility.computeTickTVLX64(tickSpacing, tick, sqrtPriceX96, liquidity);
        // console.log("Tick Spacing in AdjustFeeBasedOnLiquidity: %s", tickSpacing);
        // console.log("Sqrt Price in AdjustFeeBasedOnLiquidity: %s", sqrtPriceX96);
        // console.log("Liquidity in AdjustFeeBasedOnLiquidity: %s", liquidity);
        console.log("Tick TVL in AdjustFeeBasedOnLiquidity: %s", tickTVL);

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
        uint256 volumeToLiquidityRatio = Math.mulDiv(volume, 1e36, tickTVL); // safe division
        console.log("Volume * 1e18: %s", volume * 1e18); // Before division
        console.log("Volume-to-Liquidity Ratio: %s", volumeToLiquidityRatio);
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

    function calculateVolatilityFee(uint256 priceMovement, uint256 volatility) internal pure returns (uint256) {
        uint256 movementFactor = priceMovement > 0 ? priceMovement : 1e16;
        return (volatility * Constants.VOLATILITY_MULTIPLIER * movementFactor) / Constants.VOLATILITY_FACTOR;
    }

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

    function calculateInternalPrice(uint160 sqrtPriceX96) private pure returns (uint256) {
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / FixedPoint96.Q96;
    }

    function calculateInternalPriceFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        return (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) / FixedPoint96.Q96;
    }

    function calculatePriceMovement(uint256 internalPrice, uint256 oraclePrice) private pure returns (uint256) {
        if (internalPrice > oraclePrice) {
            return ((internalPrice - oraclePrice) * 1e18) / oraclePrice;
        } else {
            return ((oraclePrice - internalPrice) * 1e18) / internalPrice;
        }
    }

    function calculatePriceDeviation(uint256 internalPrice, uint256 externalPrice) private pure returns (uint256) {
        if (internalPrice > externalPrice) {
            return ((internalPrice - externalPrice) * 1e18) / externalPrice;
        } else {
            return ((externalPrice - internalPrice) * 1e18) / internalPrice;
        }
    }

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

    function getPriceTolerance() internal pure returns (uint256) {
        return 1e16; // 1%
    }

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

    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

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
