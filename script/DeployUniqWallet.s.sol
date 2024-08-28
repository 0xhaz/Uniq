// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UniqWallet} from "src/UniqWallet.sol";

contract DeployUniqWallet is Script {
    function run() external returns (address) {
        UniqWallet memberWallet = new UniqWallet();
        console.log("Deployed UniqWallet at address: ", address(memberWallet));
        return address(memberWallet);
    }
}
