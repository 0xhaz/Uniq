// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC6551Registry} from "@tokenbound/ERC6551Registry.sol";

contract DeployTokenBoundRegistry is Script {
    function run() external returns (address) {
        ERC6551Registry registry = new ERC6551Registry();
        console.log("Registry deployed at: ", address(registry));
        return address(registry);
    }
}
