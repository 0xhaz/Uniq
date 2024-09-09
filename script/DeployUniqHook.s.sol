// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UniqHookImplementation} from "test/utils/implementation/UniqHookImplementation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {HelperConfig} from "script/HelperConfig.sol";
import {UniqHook} from "src/UniqHook.sol";
import {IBrevisApp} from "src/interfaces/brevis/IBrevisApp.sol";

contract DeployUniqHook is Script {
    HelperConfig helperConfig = new HelperConfig();
    IPoolManager poolManager;
    UniqHook uniqHook;
    address brevisProof;

    function run() external returns (address) {
        UniqHookImplementation impl = new UniqHookImplementation(
            poolManager, helperConfig.EXPIRATION_INTERVAL(), IBrevisApp(brevisProof), uniqHook
        );
        console.log("UniqHook deployed at: ", address(impl));
        return address(impl);
    }
}
