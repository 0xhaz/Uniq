// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {UniqComNFT} from "src/token/UniqComNFT.sol";
import {DeployUniqComNFT} from "script/DeployUniqComNFT.s.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {UniqWallet} from "src/UniqWallet.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IUniqComNFT} from "src/interfaces/IUniqComNFT.sol";
import {Constants} from "src/libraries/Constants.sol";

contract UniqComTest is Test, IERC721Receiver, EIP712 {
    event UniqComNFT__Minted(uint256 indexed tokenId, string tokenURI, address ownerAddress);
    event Transfer(address from, address to, uint256 tokenId);

    UniqComNFT private uniqComNFT;
    address payable private treasury;
    string constant tokenUriToTest = "https://token.uri/";
    string constant tokenUriToTest2 = "https://token.uri2/";
    uint256 constant MAX_SUPPLY = 1000;
    uint256 constant MAX_PER_WALLET = 20;
    address private admin;
    uint256 private adminPk;

    string private constant SIGNING_DOMAIN = "UniComNFT";
    string private constant SIGNATURE_VERSION = "1";
    uint256 private constant MIN_PRICE = 0.0001 ether;
    bytes32 constant EIP712DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    struct VoucherData {
        uint256 tokenId;
        string uri;
        uint256 minPrice;
    }

    constructor() EIP712(SIGNING_DOMAIN, SIGNATURE_VERSION) {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setUp() public {
        (admin, adminPk) = makeAddrAndKey("admin");
        DeployUniqComNFT uniqComDeployer = new DeployUniqComNFT();
        uniqComNFT = UniqComNFT(uniqComDeployer.run(admin));
        address current = address(this);

        vm.prank(admin);
        uniqComNFT.addAdmin(current);

        treasury = payable(makeAddr("treasury"));
    }

    function test_publicVariables() public view {
        assertEq(uniqComNFT.maxPerWallet(), 5);
        assertEq(uniqComNFT.currentMaxSupply(), MAX_SUPPLY);
        assertFalse(uniqComNFT.isTokenMinted(0));
    }

    function testFuzz_publicVariables(uint256 tokenId) public view {
        assertFalse(uniqComNFT.isTokenMinted(tokenId));
    }

    function test_AddAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        address latestAdmin = makeAddr("latestAdmin");
        uniqComNFT.addAdmin(newAdmin);
        assert(uniqComNFT.hasRole(Constants.UNIQCOMNFT_ROLE, newAdmin));
        // test if new admin can add admin
        vm.prank(newAdmin);
        uniqComNFT.addAdmin(latestAdmin);
    }

    function test_RevokeAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        uniqComNFT.addAdmin(newAdmin);
        assert(uniqComNFT.hasRole(Constants.UNIQCOMNFT_ROLE, newAdmin));
        uniqComNFT.revokeAdmin(newAdmin);
        assertFalse(uniqComNFT.hasRole(Constants.UNIQCOMNFT_ROLE, newAdmin));
    }

    function test_Redeem() public {
        bytes32 domainSeparatorHash = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(SIGNING_DOMAIN)),
                keccak256(bytes(SIGNATURE_VERSION)),
                block.chainid,
                address(uniqComNFT)
            )
        );

        bytes32 VOUCHER_TYPEHASH = keccak256("NFTVoucher(uint256 tokenId,string uri,uint256 minPrice)");

        VoucherData memory voucherData = VoucherData(1, "https://token.uri/", 1 ether);
        bytes32 dateEncoded = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucherData.tokenId, keccak256(bytes(voucherData.uri)), voucherData.minPrice)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorHash, dateEncoded));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPk, digest);

        bytes memory voucherSignature = abi.encodePacked(r, s, v);
        UniqComNFT.NFTVoucher memory voucher1 =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, voucherData.minPrice, voucherSignature);

        voucherData = VoucherData(2, "https://token.uri2/", 2 ether);
        dateEncoded = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucherData.tokenId, keccak256(bytes(voucherData.uri)), voucherData.minPrice)
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorHash, dateEncoded));
        (v, r, s) = vm.sign(adminPk, digest);
        voucherSignature = abi.encodePacked(r, s, v);
        UniqComNFT.NFTVoucher memory voucher2 =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, voucherData.minPrice, voucherSignature);

        voucherData = VoucherData(3, "https://token.uri3/", 1 ether);
        dateEncoded = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucherData.tokenId, keccak256(bytes(voucherData.uri)), voucherData.minPrice)
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorHash, dateEncoded));
        (v, r, s) = vm.sign(adminPk, digest);
        voucherSignature = abi.encodePacked(r, s, v);
        UniqComNFT.NFTVoucher memory voucher3 =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, voucherData.minPrice, voucherSignature);

        address user1 = makeAddr("user1");
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        vm.expectEmit(true, true, true, false);
        emit Transfer(address(0), admin, 2);
        emit Transfer(admin, user1, 2);
        emit UniqComNFT__Minted(2, "https://token.uri2/", user1);
        uniqComNFT.redeem{value: 2 ether}(voucher2);
        assertEq(uniqComNFT.ownerOf(voucher2.tokenId), user1);

        address user2 = makeAddr("user2");
        vm.deal(user2, 10 ether);
        vm.prank(user2);
        vm.expectRevert(IUniqComNFT.UniqComNFT__AlreadyMinted.selector);
        uniqComNFT.redeem{value: 2 ether}(voucher2);
        assertEq(uniqComNFT.ownerOf(voucher2.tokenId), user1);

        vm.prank(user2);
        uniqComNFT.redeem{value: 1 ether}(voucher1);
        assertEq(uniqComNFT.ownerOf(voucher1.tokenId), user2);

        uniqComNFT.updateMaxPerWalletAmount(1);
        assertEq(uniqComNFT.tokensOfOwner(user1).length, 1);

        vm.prank(user1);
        vm.expectRevert(IUniqComNFT.UniqComNFT__TooMany.selector);
        uniqComNFT.redeem{value: 1 ether}(voucher3);

        uniqComNFT.updateMaxPerWalletAmount(0);
        vm.prank(user1);
        vm.expectRevert(IUniqComNFT.UniqComNFT__TooMany.selector);
        uniqComNFT.redeem{value: 1 ether}(voucher3);

        uniqComNFT.updateMaxPerWalletAmount(2);
        vm.prank(user1);
        uniqComNFT.redeem{value: 1 ether}(voucher3);
        assertEq(uniqComNFT.ownerOf(voucher3.tokenId), user1);
        assertEq(uniqComNFT.tokensOfOwner(user1).length, 2);
    }

    function test_TransferToDifferentWallets() public {
        uniqComNFT.safeMint(address(this), 1, tokenUriToTest);
        address userB = makeAddr("userB");
        uniqComNFT.transferFrom(address(this), userB, 1);
        assertEq(uniqComNFT.ownerOf(1), userB);
    }

    function test_TransferToUniComWallet() public {
        uniqComNFT.safeMint(address(this), 1, tokenUriToTest);
        UniqWallet uniqWallet = new UniqWallet();
        console.log("UniqWallet is ", uniqWallet.iAmUniqWallet());

        uniqComNFT.transferFrom(address(this), address(uniqWallet), 1);

        assertEq(uniqComNFT.ownerOf(1), address(uniqWallet));
    }

    function testFuzz_RedeemOnTheCheap(uint256 price) public {
        vm.assume(price < 1 ether);

        bytes32 domainSeparatorHash = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(SIGNING_DOMAIN)),
                keccak256(bytes(SIGNATURE_VERSION)),
                block.chainid,
                address(uniqComNFT)
            )
        );

        VoucherData memory voucherData = VoucherData(1, "https://token.uri/", 1 ether);
        bytes32 VOUCHER_TYPEHASH = keccak256("NFTVoucher(uint256 tokenId,string uri,uint256 minPrice)");
        bytes32 dataEncoded = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucherData.tokenId, keccak256(bytes(voucherData.uri)), voucherData.minPrice)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorHash, dataEncoded));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPk, digest);
        bytes memory voucherSignature = abi.encodePacked(r, s, v);
        UniqComNFT.NFTVoucher memory voucher =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, voucherData.minPrice, voucherSignature);

        address user1 = makeAddr("user1");
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        vm.expectRevert(IUniqComNFT.UniqComNFT__InsufficientFunds.selector);
        uniqComNFT.redeem{value: price}(voucher);
    }

    function testFuzz_RedeemTamperWithVoucher(uint256 prices) public {
        vm.assume(prices < 1 ether);

        bytes32 domainSeparatorHash = keccak256(
            abi.encode(
                EIP712DOMAIN_TYPEHASH,
                keccak256(bytes(SIGNING_DOMAIN)),
                keccak256(bytes(SIGNATURE_VERSION)),
                block.chainid,
                address(uniqComNFT)
            )
        );

        VoucherData memory voucherData = VoucherData(1, "https://token.uri/", 1 ether);
        bytes32 VOUCHER_TYPEHASH = keccak256("NFTVoucher(uint256 tokenId,string uri,uint256 minPrice)");
        bytes32 dataEncoded = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucherData.tokenId, keccak256(bytes(voucherData.uri)), voucherData.minPrice)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparatorHash, dataEncoded));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminPk, digest);
        bytes memory voucherSignature = abi.encodePacked(r, s, v);

        UniqComNFT.NFTVoucher memory cleanVoucher =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, voucherData.minPrice, voucherSignature);
        UniqComNFT.NFTVoucher memory tamperedVoucher =
            IUniqComNFT.NFTVoucher(voucherData.tokenId, voucherData.uri, prices, voucherSignature);

        address user1 = makeAddr("user1");
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        vm.expectRevert(IUniqComNFT.UniqComNFT__IncorrectSigner.selector);
        uniqComNFT.redeem{value: prices}(tamperedVoucher);
        uniqComNFT.redeem{value: 1 ether}(cleanVoucher);
        vm.stopPrank();
        assertEq(uniqComNFT.ownerOf(voucherData.tokenId), user1);
    }

    function test_SafeMint() public {
        vm.expectEmit(true, false, false, true, address(uniqComNFT));
        emit UniqComNFT__Minted(0, tokenUriToTest, address(this));
        uniqComNFT.safeMint(address(this), 0, tokenUriToTest);
        assertEq(uniqComNFT.ownerOf(0), address(this));
        assertEq(uniqComNFT.tokenURI(0), tokenUriToTest);

        vm.expectEmit(true, false, false, true, address(uniqComNFT));
        emit UniqComNFT__Minted(10, tokenUriToTest2, address(this));
        uniqComNFT.safeMint(address(this), 10, tokenUriToTest2);
        assertEq(uniqComNFT.ownerOf(10), address(this));
        assertEq(uniqComNFT.tokenURI(10), tokenUriToTest2);

        assertEq(uniqComNFT.balanceOf(address(this)), 2);
    }

    function test_SafeMintWithoutPermission() public {
        vm.prank(makeAddr("nonMember"));
        vm.expectRevert();
        uniqComNFT.safeMint(address(0), 1, tokenUriToTest);
    }

    function test_UpdateMaxSupply() public {
        uniqComNFT.updateMaxSupply(MAX_SUPPLY * 2);
        assertEq(uniqComNFT.currentMaxSupply(), MAX_SUPPLY * 2);
    }

    function test_MaxSupply() public {
        // Set to low value so it will fail when trying to mint new one
        uniqComNFT.updateMaxSupply(1);
        uniqComNFT.safeMint(address(this), 0, "uri-0");
        uniqComNFT.safeMint(address(this), 1, "uri-1");
        vm.expectRevert(IUniqComNFT.UniqComNFT__SoldOut.selector);

        // Increase by 1 and confirm
        uniqComNFT.safeMint(address(this), 2, "uri-2");
        uniqComNFT.updateMaxSupply(2);
        uniqComNFT.safeMint(address(this), 2, "uri-2");
        vm.expectRevert(IUniqComNFT.UniqComNFT__SoldOut.selector);
        uniqComNFT.safeMint(address(this), 3, "uri-3");

        // Increase by lots and confirm all good
        uniqComNFT.updateMaxSupply(10);
        uniqComNFT.safeMint(address(this), 3, "uri-3");
        uniqComNFT.safeMint(address(this), 4, "uri-4");
        uniqComNFT.safeMint(address(this), 5, "uri-5");

        // Set to value lower than current supply and test
        uniqComNFT.updateMaxSupply(1);
        vm.expectRevert(IUniqComNFT.UniqComNFT__SoldOut.selector);
        uniqComNFT.safeMint(address(this), 6, "uri-6");
    }

    function test_UpdateMaxSupplyWithoutPermission() public {
        vm.prank(address(1));
        vm.expectRevert();
        uniqComNFT.updateMaxSupply(MAX_SUPPLY * 2);
    }

    function test_UpdateMaxPerWalletAmount() public {
        uniqComNFT.updateMaxPerWalletAmount(MAX_PER_WALLET + 10);
        assertEq(uniqComNFT.maxPerWallet(), MAX_PER_WALLET + 10);
    }

    function test_UpdateMaxPerWalletAmountWithoutPermission() public {
        vm.prank(address(1));
        vm.expectRevert();
        uniqComNFT.updateMaxPerWalletAmount(MAX_PER_WALLET + 10);
    }

    function test_Withdraw() public {
        // Put 10 eth in UniComNFT and check that the withdraw works and moves the money to treasury
        deal(address(uniqComNFT), 10 ether);
        uniqComNFT.withdraw(treasury);
        uint256 balanceAfter = treasury.balance;
        assertEq(balanceAfter, 10 ether);
    }

    function test_WithdrawWithoutPermission() public {
        uniqComNFT.renounceRole(Constants.UNIQCOMNFT_ROLE, address(this));
        vm.expectRevert();
        uniqComNFT.withdraw(payable(address(this)));
    }

    function test_WithdrawWithNullAddress() public {
        deal(address(uniqComNFT), 10 ether);
        vm.expectRevert(IUniqComNFT.UniqComNFT__NullAddressError.selector);
        uniqComNFT.withdraw(payable(address(0)));
    }

    function test_SetContractURI() public {
        uniqComNFT.setContractURI("http://contract.uri/");
        string memory contractURI = uniqComNFT.contractURI();
        assertEq(contractURI, "http://contract.uri/");

        uniqComNFT.setContractURI("http://contract.uri2/");
        contractURI = uniqComNFT.contractURI();
        assertEq(contractURI, "http://contract.uri2/");
    }

    function test_FailSetContractURI() public {
        vm.prank(address(1));
        vm.expectRevert();
        uniqComNFT.setContractURI("http://contract.uri/");
    }

    function test_TokensOfOwner() public {
        address user1 = makeAddr("user1");
        uint256[] memory tokens = uniqComNFT.tokensOfOwner(user1);
        assertEq(tokens.length, 0);

        uniqComNFT.safeMint(user1, 1, "uri-1");
        uniqComNFT.safeMint(user1, 2, "uri-2");
        tokens = uniqComNFT.tokensOfOwner(user1);
        assertEq(tokens.length, 2);
    }

    function test_Pause() public {
        // creating a signed digest for testing
        uniqComNFT.safeMint(address(this), 0, "uri-0");
        uniqComNFT.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        uniqComNFT.safeMint(address(this), 1, "uri-1");
        uniqComNFT.unpause();
        uniqComNFT.safeMint(address(this), 1, "uri-1");
    }
}
