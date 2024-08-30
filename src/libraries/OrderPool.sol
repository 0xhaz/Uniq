// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {ABDKMathQuad} from "src/libraries/ABDKMathQuad.sol";
import {Struct} from "src/libraries/Struct.sol";

/// @title TWAMM Order Pool - Represents an OrderPool inside of a TWAMM
library OrderPool {
    // Performs all updates on an OrderPool that must happen when hitting an expiration interval with expiring orders
    function advanceToInterval(Struct.OrderPool storage self, uint256 expiration, uint256 earningsFactor) internal {
        unchecked {
            self.currentRewardFactor += earningsFactor;
            self.rewardFactorAtTime[expiration] = self.currentRewardFactor;
            self.currentSellRate -= self.sellRateEndingAtTime[expiration];
        }
    }

    /// Performs all the updates on an OrderPool that must happen when updating to the current time not on an interval
    function advanceToCurrentTime(Struct.OrderPool storage self, uint256 earningsFactor) internal {
        unchecked {
            self.currentRewardFactor += earningsFactor;
        }
    }
}
