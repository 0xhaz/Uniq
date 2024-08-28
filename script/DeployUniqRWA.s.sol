// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {UniqRWA} from "src/UniqRWA.sol";
import {HelperConfig} from "script/HelperConfig.sol";
import {IGetRWAReturnTypes} from "src/interfaces/IGetRWAReturnTypes.sol";

contract DeployUniqRWA is Script {
    string constant alpacaMintSource = "./functions/sources/alpacaBalance.js";
    string constant alpacaRedeemSource = "./functions/sources/alpacaBalance.js";

    function run() public {
        IGetRWAReturnTypes.GetRWAReturnType memory getRWAReturnType = getRWARequirements();

        vm.startBroadcast();
        deployRWA(
            getRWAReturnType.subId,
            getRWAReturnType.assetName,
            getRWAReturnType.mintSource,
            getRWAReturnType.redeemSource,
            getRWAReturnType.functionsRouter,
            getRWAReturnType.donId,
            getRWAReturnType.rwaFeed,
            getRWAReturnType.usdcFeed,
            getRWAReturnType.redemptionCoin,
            getRWAReturnType.secretVersion,
            getRWAReturnType.secretSlot
        );
        vm.stopBroadcast();
    }

    function getRWARequirements() public returns (IGetRWAReturnTypes.GetRWAReturnType memory) {
        HelperConfig helperConfig = new HelperConfig();
        (
            bytes32 assetName,
            address rwaFeed,
            address usdcFeed,
            ,
            address functionsRouter,
            bytes32 donId,
            uint64 subId,
            address redemptionCoin,
            ,
            uint64 secretVersion,
            uint8 secretSlot
        ) = helperConfig.activeNetworkConfig();

        if (
            rwaFeed == address(0) || usdcFeed == address(0) || functionsRouter == address(0) || donId == bytes32(0)
                || subId == 0
        ) {
            revert("Missing network configuration");
        }

        string memory mintSource = vm.readFile(alpacaMintSource);
        string memory redeemSource = vm.readFile(alpacaRedeemSource);

        return IGetRWAReturnTypes.GetRWAReturnType(
            subId,
            assetName,
            mintSource,
            redeemSource,
            functionsRouter,
            donId,
            rwaFeed,
            usdcFeed,
            redemptionCoin,
            secretVersion,
            secretSlot
        );
    }

    function deployRWA(
        uint64 subId,
        bytes32 assetName,
        string memory mintSource,
        string memory redeemSource,
        address functionsRouter,
        bytes32 donId,
        address rwaFeed,
        address usdcFeed,
        address redemptionCoin,
        uint64 secretVersion,
        uint8 secretSlot
    ) public returns (UniqRWA) {
        UniqRWA uniqRWA = new UniqRWA(
            subId,
            assetName,
            mintSource,
            redeemSource,
            functionsRouter,
            donId,
            rwaFeed,
            usdcFeed,
            redemptionCoin,
            secretVersion,
            secretSlot
        );
        console.log("UniqRWA: ", address(uniqRWA));
        return uniqRWA;
    }
}
