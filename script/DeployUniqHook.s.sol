// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UniqHook} from "src/UniqHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HelperConfig} from "script/HelperConfig.sol";

contract DeployUniqHook is Script {
    HelperConfig helperConfig = new HelperConfig();
    IPoolManager poolManager;

    function run() external returns (address) {
        UniqHook uniqHook = new UniqHook(poolManager, helperConfig.EXPIRATION_INTERVAL());
        console.log("UniqHook deployed at: ", address(uniqHook));
        return address(uniqHook);
    }
}
