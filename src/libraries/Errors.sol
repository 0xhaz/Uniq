// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Struct} from "./Struct.sol";

library Errors {
    /// @notice Thrown when account other than owner attemps to interact with an order
    /// @param owner The owner of the order
    /// @param currentAccount The invalid account attempting to interact with the order
    error MustBeOwner(address owner, address currentAccount);

    /// @notice Thrown when trying to cancel an already completed order
    /// @param orderKey They orderKey
    error CannotModifyCompletedOrder(Struct.OrderKey orderKey);

    /// @notice Thrown when trying to submit an order without initializing TWAMM state first
    error NotInitialized();

    /// @notice Thrown when trying to submit an order with a price deviation that is too high
    error PriceDeviation();

    /// @notice Thrown when trying to submit an order with a price deviation that is too high
    error Oracle__SignificantPriceDeviation(uint internalPrice, uint externalPrice, uint priceDeviation);

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval
    /// @param expiration The expiration timestamp of the order
    error ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past
    /// @param expiration The expiration timestamp of the order
    error ExpirationLessThanBlocktime(uint256 expiration);

    /// @notice Thrown when submitting an order with a sellRate of 0
    error SellRateCannotBeZero();

    /// @notice Thrown when trying to submit an order that's already ongoing
    /// @param orderKey The already existing orderKey
    error OrderAlreadyExists(Struct.OrderKey orderKey);

    /// @notice Thrown when tring to interact with an order that does not exist
    /// @param orderKey the already existing orderKey
    error OrderDoesNotExist(Struct.OrderKey orderKey);

    /// @notice Thrown when trying to subtract more value from a long term order than exists
    /// @param orderKey The orderKey
    /// @param unsoldAmount The amount still unsold
    /// @param amountDelta The amount delta for the order
    error InvalidAmountDelta(Struct.OrderKey orderKey, uint256 unsoldAmount, int256 amountDelta);

    /// @notice Thrown when vkHash is not valid
    error InvalidVkHash();

    /// @notice Thrown when fee is not dynamic
    error MustUseDynamicFee();

    error Oracle__StalePrice();
    error Oracle__CardinalityCannotBeZero();

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error Oracle__TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);

    /// @notice Thrown when trying to interact with an Oracle of a non-initialized pool
    error OracleCardinalityCannotBeZero();

    error OraclePositionMustBeFullRange();

    /// @notice Thrown when trying to observe a price that is older than the oldest recorded price
    /// @param oldestTimestamp Timestamp of the oldest remaining observation
    /// @param targetTimestamp Invalid timestamp targeted to be observed
    error TargetPredatesOldestObservation(uint32 oldestTimestamp, uint32 targetTimestamp);
}
