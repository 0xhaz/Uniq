// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {UniqWallet} from "src/UniqWallet.sol";
import {UniqComNFT} from "src/token/UniqComNFT.sol";
import {ERC6551Registry} from "@tokenbound/ERC6551Registry.sol";
import {DeployTokenBoundRegistry} from "script/DeployTokenBoundRegistry.s.sol";
import {DeployUniqWallet} from "script/DeployUniqWallet.s.sol";
import {DeployUniqComNFT} from "script/DeployUniqComNFT.s.sol";

contract TokenBoundRegistryTest is Test {
    ERC6551Registry registry;
    address constant UNI_WALLET_0 = 0x8BB538D8162C84Af471553bD7AE228FF4aD25519;
    UniqWallet uniqWallet;
    UniqComNFT uniqComNFT;
    address private admin;

    function setUp() public {
        admin = makeAddr("admin");
        DeployTokenBoundRegistry deployer = new DeployTokenBoundRegistry();
        registry = ERC6551Registry(deployer.run());

        DeployUniqWallet deployerWallet = new DeployUniqWallet();
        uniqWallet = UniqWallet(payable(deployerWallet.run()));

        DeployUniqComNFT deployerNFT = new DeployUniqComNFT();
        uniqComNFT = UniqComNFT(deployerNFT.run(admin));
    }

    function test_register() public view {
        address account = registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);
        assertEq(account, UNI_WALLET_0);
    }

    function test_CreateAccount() public view {
        address account0 = registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);
        address account1 = registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 1);
        address account2 = registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 2);

        assertEq(account0, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0));
        assertEq(account1, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 1));
        assertEq(account2, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 2));
    }
}
