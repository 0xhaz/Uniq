// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UniqHookImplementation} from "test/utils/implementation/UniqHookImplementation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HelperConfig} from "script/HelperConfig.sol";
import {UniqHook} from "src/UniqHook.sol";

contract DeployUniqHook is Script {
    HelperConfig helperConfig = new HelperConfig();
    IPoolManager poolManager;
    UniqHook uniqHook;

    function run() external returns (address) {
        UniqHookImplementation impl =
            new UniqHookImplementation(poolManager, helperConfig.EXPIRATION_INTERVAL(), uniqHook);
        console.log("UniqHook deployed at: ", address(impl));
        return address(impl);
    }
}
