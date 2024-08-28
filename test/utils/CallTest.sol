// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

contract CallTest {
    address public lastCaller;
    uint256 public lastValue;

    constructor() {}

    function callMe(uint256 value) public {
        lastCaller = msg.sender;
        lastValue = value;
    }
}
