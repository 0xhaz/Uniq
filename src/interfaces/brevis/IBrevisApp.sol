// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

interface IBrevisApp {
    function brevisCallback(bytes32 requestId, bytes calldata appCircuitOutput) external;
}
