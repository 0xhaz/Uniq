// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

interface IGetRWAReturnTypes {
    struct GetRWAReturnType {
        uint64 subId;
        bytes32 assetName;
        string mintSource;
        string redeemSource;
        address functionsRouter;
        bytes32 donId;
        address rwaFeed;
        address usdcFeed;
        address redemptionCoin;
        uint64 secretVersion;
        uint8 secretSlot;
    }
}
