// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IBrevisProof, Brevis} from "src/interfaces/brevis/IBrevisProof.sol";
import {console} from "forge-std/Script.sol";

abstract contract BrevisApp {
    IBrevisProof public brevisProof;

    constructor(IBrevisProof _brevisProof) {
        brevisProof = _brevisProof;
    }

    function submitProof(uint64 chainId, bytes calldata proofWithPubInputs, bool withAppProof)
        public
        returns (bytes32)
    {
        return brevisProof.submitProof(chainId, proofWithPubInputs, withAppProof);
    }

    function hasProof(bytes32 requestId) public view returns (bool) {
        return brevisProof.hasProof(requestId);
    }

    function validateRequest(bytes32 requestId, uint64 chainId, Brevis.ExtractInfos memory extractInfos)
        public
        view
        virtual
        returns (bool)
    {
        brevisProof.validateRequest(requestId, chainId, extractInfos);
        return true;
    }

    function brevisCallback(bytes32 requestId, bytes calldata appCircuitOutput) external {
        (bytes32 appCommitHash, bytes32 appVkHash) = IBrevisProof(brevisProof).getProofAppData(requestId);
        require(appCommitHash == keccak256(appCircuitOutput), "BrevisApp: invalid app commit hash");
        handleProofResult(requestId, appVkHash, appCircuitOutput);
    }

    function handleProofResult(bytes32 requestId, bytes32 vkHash, bytes calldata appCircuitOutput) internal virtual;

    function brevisBatchCallback(
        uint64 chainId,
        Brevis.ProofData[] calldata proofDataArray,
        bytes[] calldata appCircuitOutputs
    ) external {
        require(proofDataArray.length == appCircuitOutputs.length, "BrevisApp: invalid array length");
        IBrevisProof(brevisProof).mustValidateRequests(chainId, proofDataArray);
        uint256 len = proofDataArray.length;
        for (uint256 i; i < len; ++i) {
            require(
                proofDataArray[i].appCommitHash == keccak256(appCircuitOutputs[i]), "BrevisApp: invalid app commit hash"
            );
            handleProofResult(proofDataArray[i].commitHash, proofDataArray[i].appVkHash, appCircuitOutputs[i]);
        }
    }

    function singleRun(
        uint64 chainId,
        Brevis.ProofData calldata proofData,
        bytes32 merkleRoot,
        bytes32[] calldata merkleProof,
        uint8 nodeIndex,
        bytes calldata appCircuitOutput
    ) external {
        IBrevisProof(brevisProof).mustValidateRequest(chainId, proofData, merkleRoot, merkleProof, nodeIndex);
        require(proofData.appCommitHash == keccak256(appCircuitOutput), "BrevisApp: invalid app commit hash");
        handleProofResult(proofData.commitHash, proofData.appVkHash, appCircuitOutput);
    }
}
