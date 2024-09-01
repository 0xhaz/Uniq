// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IBrevisProof, Brevis} from "src/interfaces/brevis/IBrevisProof.sol";

contract MockBrevisProof is IBrevisProof {
    mapping(bytes32 => Brevis.ProofData) public mockOutput;
    uint256 private simulatedVolatility;

    function setMockOutput(bytes32 requestId, bytes32 outputCommit, bytes32 vkHash) public {
        mockOutput[requestId] = Brevis.ProofData({
            commitHash: 0,
            length: 0,
            vkHash: 0,
            appCommitHash: outputCommit,
            appVkHash: vkHash,
            smtRoot: 0
        });
    }

    function setSimulatedVolatility(uint256 _volatility) public {
        simulatedVolatility = _volatility;
    }

    function submitProof(uint64 chainId, bytes calldata proofWithPubInputs, bool withAppProof)
        external
        pure
        returns (bytes32 requestId)
    {
        requestId = bytes32(keccak256(abi.encodePacked(chainId, proofWithPubInputs, withAppProof)));
    }

    function hasProof(bytes32 requestId) external view returns (bool) {
        Brevis.ProofData memory data = mockOutput[requestId];
        return data.appVkHash == 0 && data.appCommitHash == 0;
    }

    function validateRequest(bytes32 requestId, uint64 chainId, Brevis.ExtractInfos memory info) external view {}

    function getProofData(bytes32 requestId) external view returns (Brevis.ProofData memory) {
        return mockOutput[requestId];
    }

    // return appCommitHash, appVkHash
    function getProofAppData(bytes32 requestId) external view returns (bytes32, bytes32) {
        Brevis.ProofData memory data = mockOutput[requestId];
        return (data.appCommitHash, data.appVkHash);
    }

    function mustValidateRequest(
        uint64 chainId,
        Brevis.ProofData memory proofData,
        bytes32 merkleRoot,
        bytes32[] memory merkleProof,
        uint8 nodeIndex
    ) external view {}

    function mustSubmitAggProof(uint64 chainId, bytes calldata proofWithPubInputs) external view {}

    function mustValidateRequests(uint64 chainId, Brevis.ProofData[] calldata proofDataArray) external view override {}

    function mustSubmitAggProof(uint64 chainId, bytes32[] calldata requestId, bytes calldata proofWithPubInputs)
        external
        override
    {}
}
