// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {UniqHook} from "src/UniqHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

contract UniqHookImplementation is UniqHook {
    constructor(IPoolManager _manager, uint256 interval, UniqHook addressToEtch) UniqHook(_manager, interval) {
        Hooks.validateHookPermissions(addressToEtch, getHookPermissions());
    }

    // make this a no-op testing
    function validateHookAddress(BaseHook _this) internal pure override {
        // do nothing
    }
}
