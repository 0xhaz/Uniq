// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {UniqWallet, IERC165, IERC1271, IUniqComWallet} from "src/UniqWallet.sol";
import {UniqComNFT} from "src/token/UniqComNFT.sol";
import {ERC6551Registry} from "@tokenbound/ERC6551Registry.sol";
import {DeployTokenBoundRegistry} from "script/DeployTokenBoundRegistry.s.sol";
import {DeployUniqWallet} from "script/DeployUniqWallet.s.sol";
import {DeployUniqComNFT} from "script/DeployUniqComNFT.s.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CallTest} from "test/utils/CallTest.sol";

contract UniqWalletTest is Test, IERC721Receiver {
    event TransactionExecuted(address indexed target, uint256 indexed value, bytes data);

    ERC6551Registry registry;
    UniqWallet uniqWallet;
    UniqComNFT uniqComNFT;
    CallTest callTest = new CallTest();

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address admin = makeAddr("admin");

    function setUp() public {
        DeployTokenBoundRegistry registryDeployer = new DeployTokenBoundRegistry();
        registry = ERC6551Registry(registryDeployer.run());

        DeployUniqWallet walletDeployer = new DeployUniqWallet();
        uniqWallet = UniqWallet(payable(walletDeployer.run()));

        DeployUniqComNFT nftDeployer = new DeployUniqComNFT();
        uniqComNFT = UniqComNFT(nftDeployer.run(admin));
        address current = address(this);
        vm.prank(admin);
        uniqComNFT.addAdmin(current);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function test_IsValidUniqWallet() public view {
        assertEq(uniqWallet.iAmUniqWallet(), true);
    }

    function test_Ownership() public {
        uniqComNFT.safeMint(address(this), 0, "uri-0");
        uniqComNFT.safeMint(user1, 1, "uri-1");
        uniqComNFT.safeMint(user2, 2, "uri-2");

        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);
        address account1 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 1);
        address account2 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 2);

        assertEq(account0, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0));
        assertEq(account1, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 1));
        assertEq(account2, registry.account(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 2));

        assertEq(UniqWallet(payable(account0)).owner(), address(this));
        assertEq(UniqWallet(payable(account1)).owner(), user1);
        assertEq(UniqWallet(payable(account2)).owner(), user2);
    }

    function test_SupportInterface() public view {
        assertEq(uniqWallet.supportsInterface(type(IERC165).interfaceId), true);
        assertEq(uniqWallet.supportsInterface(type(IUniqComWallet).interfaceId), true);
    }

    function test_ExecuteCall() public {
        uniqComNFT.safeMint(admin, 0, "uni-uri");
        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);

        string memory callTestAbi = "callMe(uint256)";
        bytes memory callData = abi.encodeWithSignature(callTestAbi, 10);

        vm.startPrank(admin);
        vm.expectEmit(true, true, false, true);
        emit TransactionExecuted(address(callTest), 0, callData);
        UniqWallet(payable(account0)).executeCall(address(callTest), 0, callData);
        vm.stopPrank();
        assertEq(callTest.lastCaller(), account0);
        assertEq(callTest.lastValue(), 10);
    }

    function test_Token() public {
        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);
        address account1 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 1);

        (uint256 chainId, address tokenContract, uint256 tokenId) = UniqWallet(payable(account0)).token();
        assertEq(chainId, block.chainid);
        assertEq(tokenContract, address(uniqComNFT));
        assertEq(tokenId, 0);
        (chainId, tokenContract, tokenId) = UniqWallet(payable(account1)).token();
        assertEq(chainId, block.chainid);
        assertEq(tokenContract, address(uniqComNFT));
        assertEq(tokenId, 1);
    }

    function test_Nonce() public {
        uniqComNFT.safeMint(admin, 0, "uni-uri");
        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);

        string memory callTestAbi = "callMe(uint256)";
        bytes memory callData = abi.encodeWithSignature(callTestAbi, 10);

        assertEq(UniqWallet(payable(account0)).nonce(), 0);
        vm.startPrank(admin);
        UniqWallet(payable(account0)).executeCall(address(callTest), 0, callData);
        vm.stopPrank();

        assertEq(UniqWallet(payable(account0)).nonce(), 1);

        // Test nonce is not updated on a reverted transaction
        vm.expectRevert();
        UniqWallet(payable(account0)).executeCall(address(callTest), 0, callData);
        assertEq(UniqWallet(payable(account0)).nonce(), 1);

        // Test increment again
        vm.startPrank(admin);
        UniqWallet(payable(account0)).executeCall(address(callTest), 0, callData);
        vm.stopPrank();
        assertEq(UniqWallet(payable(account0)).nonce(), 2);
    }

    function test_IsValidSignature() public {
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        uniqComNFT.safeMint(signer, 0, "uni-uri");
        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);

        string memory clearText = "hello";
        bytes32 digest = keccak256(abi.encodePacked(clearText));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        assertEq(UniqWallet(payable(account0)).isValidSignature(digest, signature), IERC1271.isValidSignature.selector);
    }

    function test_IsNotValidSignature() public {
        (address notSigner, uint256 notSignerPk) = makeAddrAndKey("not-signer");
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        uniqComNFT.safeMint(signer, 0, "uni-uri");
        address account0 = registry.createAccount(address(uniqWallet), 0, block.chainid, address(uniqComNFT), 0);

        string memory clearText = "hello";
        bytes32 digest = keccak256(abi.encodePacked(clearText));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(notSignerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        assertNotEq(
            UniqWallet(payable(account0)).isValidSignature(digest, signature), IERC1271.isValidSignature.selector
        );
    }
}
