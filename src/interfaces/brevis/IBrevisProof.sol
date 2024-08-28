// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Brevis} from "src/libraries/Brevis.sol";

interface IBrevisProof {
    /**
     * @notice Submit a proof to the Brevis network
     * @param chainId  The chain ID of the proof
     * @param proofWithPubInputs  The proof with public inputs
     * @param withAppProof  Whether the proof is for an application
     */
    function submitProof(uint64 chainId, bytes calldata proofWithPubInputs, bool withAppProof)
        external
        returns (bytes32 requestId);

    /**
     * @notice Check if a proof exists
     * @param requestId The request ID
     * @return True if the proof exists
     */
    function hasProof(bytes32 requestId) external view returns (bool);

    /**
     * @notice Validate a request
     * @param requestId The request ID
     * @param chainId The chain ID
     * @param info The extract infos
     */
    function validateRequest(bytes32 requestId, uint64 chainId, Brevis.ExtractInfos memory info) external view;

    /**
     * @notice Get the proof data
     * @param requestId The request ID
     * @return The proof data
     */
    function getProofData(bytes32 requestId) external view returns (Brevis.ProofData memory);

    /**
     * @notice Get the proof app data
     * @param requestId The request ID
     * @return The app commit hash and app vk hash
     */
    function getProofAppData(bytes32 requestId) external view returns (bytes32, bytes32);

    /**
     * @notice Validate a proof request
     * @param chainId The chain ID
     * @param proofData The proof data
     * @param merkleRoot The merkle root
     * @param merkleProof The merkle proof
     * @param nodeIndex The node index
     */
    function mustValidateRequest(
        uint64 chainId,
        Brevis.ProofData memory proofData,
        bytes32 merkleRoot,
        bytes32[] memory merkleProof,
        uint8 nodeIndex
    ) external view;

    /**
     * @notice Validate multiple requests
     * @param chainId  The chain ID
     * @param proofDataArray The proof data array
     */
    function mustValidateRequests(uint64 chainId, Brevis.ProofData[] calldata proofDataArray) external view;

    /**
     * @notice Submit an aggregated proof
     * @param chainId  The chain ID
     * @param requestId  The request ID
     * @param proofWithPubInputs  The proof with public inputs
     */
    function mustSubmitAggProof(uint64 chainId, bytes32[] calldata requestId, bytes calldata proofWithPubInputs)
        external;
}
