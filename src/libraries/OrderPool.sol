// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {ABDKMathQuad} from "src/libraries/ABDKMathQuad.sol";
import {Struct} from "src/libraries/Struct.sol";

/// @title TWAMM Order Pool - Represents an OrderPool inside of a TWAMM
library OrderPool {
    // Performs all updates on an OrderPool that must happen when hitting an expiration interval with expiring orders
    function advanceToInterval(Struct.State storage self, uint256 expiration, uint256 earningsFactor) internal {
        unchecked {
            self.currentRewardFactor += earningsFactor;
            self.sellRateEndingAtTime[expiration] = self.currentRewardFactor;
            self.currentSellRate -= self.sellRateEndingAtTime[expiration];
        }
    }

    /// Performs all the updates on an OrderPool that must happen when updating to the current time not on an interval
    function advanceToCurrentTime(Struct.State storage self, uint256 earningsFactor) internal {
        unchecked {
            self.currentRewardFactor += earningsFactor;
        }
    }

    /// @notice Distribute payment amount to pool (in the case of TWAMM, proceeds from trades agains amm)
    function distributePayment(Struct.State storage self, uint256 amount) public {
        if (self.currentSellRate != 0) {
            self.currentRewardFactor += amount * (100e18 / self.currentSellRate);
        }
    }

    /// @notice deposit an order into the order pool
    function depositOrder(Struct.State storage self, uint256 orderId, uint256 amountPerBlock, uint256 orderExpiry)
        public
    {
        self.currentSellRate += amountPerBlock;
        self.rewardFactorAtTime[orderExpiry] = self.currentRewardFactor;
        self.sellRateEndingAtTime[orderExpiry] += amountPerBlock;
    }

    /// @notice when orders expire after a given block, need to udpate the state of the pool
    function updateStateFromBlockExpiry(Struct.State storage self, uint256 blockNumber) public {
        uint256 ordersExpiring = self.sellRateEndingAtTime[blockNumber];
        self.currentSellRate -= ordersExpiring;
    }

    /// @notice cancel order and remove from the order pool
    // function cancelOrder(State storage self, uint256 orderId)
    //     public
    //     returns (uint256 unsoldAmount, uint256 purchasedAmount)
    // {
    //     uint256 expiry = self.orderExpiry[orderId];
    //     require(expiry > block.number, "OrderPool: Order already expired");

    //     // calculate amount that wasn't sold and return it
    //     uint256 sellRate = self.sellRate[orderId];
    //     uint256 blocksRemaining = expiry - block.number;
    //     unsoldAmount = (blocksRemaining * sellRate) / 100e18;

    //     // calculate amount of other token that was purchased
    //     uint256 rewardFactorAtSubmission = self.rewardFactorAtSubmission[orderId];
    //     purchasedAmount = (self.currentRewardFactor - rewardFactorAtSubmission) * (sellRate / 100e18);

    //     // update state
    //     self.currentSellRate -= sellRate;
    //     self.sellRate[orderId] = 0;
    //     self.orderExpiry[orderId] = 0;
    //     self.sellRateEndingAtTime[expiry] -= sellRate;
    // }

    /// @notice withdraw proceeds from pool for a given order. This can be done before or after the order expires
    // If the order has expired, we calculate the reward factor at time of expiry. If order has not yet expired,
    // we use current reward factor, and update reward factor at time of staking (effectively creating a new order)
    // function withdrawProceeds(State storage self, uint256 orderId) public returns (uint256 totalReward) {
    //     uint256 stakedAmount = self.sellRate[orderId];
    //     require(stakedAmount > 0, "OrderPool: Order does not exist");
    //     uint256 orderExpiry = self.orderExpiry[orderId];
    //     uint256 rewardFactorAtSubmission = self.rewardFactorAtSubmission[orderId];

    //     unchecked {
    //         // if order has expired, we need to calculate the reward factor at expiry
    //         if (block.number >= orderExpiry) {
    //             uint256 rewardFactorAtExpiry = self.rewardFactorAtBlock[orderExpiry];

    //             totalReward = (rewardFactorAtExpiry - rewardFactorAtSubmission) * (stakedAmount / 100e18);
    //             // remove stake
    //             self.sellRate[orderId] = 0;
    //         } else {
    //             totalReward = (self.currentRewardFactor - rewardFactorAtSubmission) * (stakedAmount / 100e18);
    //             // update reward factor at submission
    //             self.rewardFactorAtSubmission[orderId] = self.currentRewardFactor;
    //         }
    //     }
    // }
}
