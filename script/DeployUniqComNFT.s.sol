// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {UniqComNFT} from "src/token/UniqComNFT.sol";

contract DeployUniqComNFT is Script {
    function run(address admin) external returns (address) {
        UniqComNFT uniqComNFT = new UniqComNFT(admin);
        console.log("UniqComNFT deployed at: ", address(uniqComNFT));
        return address(uniqComNFT);
    }
}
