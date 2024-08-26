// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {
    IFunctionsRouter,
    FunctionsResponse
} from "chainlink/contracts/src/v0.8/functions/dev/v1_0_0/interfaces/IFunctionsRouter.sol";
import {IFunctionsClient} from "chainlink/contracts/src/v0.8/functions/dev/v1_0_0/interfaces/IFunctionsClient.sol";

contract MockFunctionsRouter is IFunctionsRouter {
    function handleOracleFulfillment(address who, bytes32 requestId, bytes memory response, bytes memory err)
        external
    {
        IFunctionsClient(who).handleOracleFulfillment(requestId, response, err);
    }

    /// @notice The identifier of the route to retrieve the address of the access control contract
    /// The access control contract controls which accounts can manage subscription
    /// @return id - bytes32 id that can be passed to the "getContractById" of the Router
    function getAllowListId() external pure returns (bytes32) {
        return bytes32(0);
    }

    /// @notice Set the identifier of the route to retrieve the address of the access control contract
    /// The access control contract controls which accounts can manage subscriptions
    function setAllowListId(bytes32 allowListId) external {}

    /// @notice Get the flat fee (in Juels of LINK) that will be paid to the Router owner for operation of the network
    /// @return adminFee
    function getAdminFee() external pure returns (uint72 adminFee) {
        return uint72(0);
    }

    /// @notice Sends a request using the provided subscriptionId
    /// @param subscriptionId - A unique subscription ID allocated by billing system
    /// a client can make requests from different contracts referencing the same subscription
    /// @param data - CBOR encoded Chainlink Functions request data, use FunctionsClient API to encode a request
    /// @param dataVersion - Gas limit for the fulfillment callback
    /// @param callbackGasLimit - Gas limit for the fulfillment callback
    /// @param donId - An identifier used to determine which route to send the request to
    /// @return requestId - A unique identifier for the request
    function sendRequest(
        uint64 subscriptionId,
        bytes calldata data,
        uint16 dataVersion,
        uint32 callbackGasLimit,
        bytes32 donId
    ) external pure returns (bytes32) {
        return bytes32(keccak256(abi.encodePacked(subscriptionId, data, dataVersion, callbackGasLimit, donId)));
    }

    function sendRequestToProposed(
        uint64, // subscriptionId
        bytes calldata, // data
        uint16, // dataVersion
        uint32, // callbackGasLimit
        bytes32 // donId
    ) external pure returns (bytes32) {
        return bytes32(0);
    }

    function fulfill(
        bytes memory, // response
        bytes memory, // error
        uint96, // juelsPerGas
        uint96, // costWithoutFulfillment
        address, // transmitter
        FunctionsResponse.Commitment memory // commitment
    ) external pure returns (FunctionsResponse.FulfillResult, uint96) {
        return (FunctionsResponse.FulfillResult.FULFILLED, uint96(0));
    }

    /// @notice Validate requested gas limit is below the subscription max
    /// @param subscriptionId subscription ID
    /// @param callbackGasLimit desired callback gas limit
    function isValidCallbackGasLimit(uint64 subscriptionId, uint32 callbackGasLimit) external view {}

    /// @notice Get the current contract given an ID
    /// @return contract The current contract address
    function getContractById(bytes32 /*id*/ ) external pure returns (address) {
        return address(0);
    }

    /// @notice Get the proposed next contract given an ID
    /// @return contract The current or proposed contract address
    function getProposedContractById(bytes32 /*id*/ ) external pure returns (address) {
        return address(0);
    }

    /// @notice Return the latest proposal set
    /// @return ids the identifiers of the contracts to update
    /// @return to the addresses of the contracts that will be updated to
    function getProposedContractSet() external pure returns (bytes32[] memory, address[] memory) {
        return (new bytes32[](0), new address[](0));
    }

    /// @notice Proposes one or more updates to the contract routers
    /// @dev Only callable by the owner
    function proposeContractsUpdate(bytes32[] memory proposalSetIds, address[] memory proposalSetAddresses) external {}

    /// @notice Updates the current contract routes to the proposed contracts
    /// @dev Only callable by the owner
    function updateContracts() external {}

    /// @notice Puts the system into an emergency stopped state
    /// @dev Only callable by the owner
    function pause() external {}

    // @notice Takes the system out of an emergency stopped state
    // @dev Only callable by the owner
    function unpause() external {}
}
