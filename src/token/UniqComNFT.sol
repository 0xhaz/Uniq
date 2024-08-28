// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC721Pausable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IUniqComNFT} from "src/interfaces/IUniqComNFT.sol";
import {Constants} from "src/libraries/Constants.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title Membership NFT contract
 * @notice UniCom is an ERC721 NFT
 * The metadata and images are stored in IPFS
 * Minting can be paused
 */
contract UniqComNFT is IUniqComNFT, ERC721Enumerable, EIP712, ERC721URIStorage, ERC721Pausable, AccessControl {
    string private _contractURI;
    uint256 public maxPerWallet = 5;
    uint256 public currentMaxSupply = 1000;
    mapping(uint256 => bool) public isTokenMinted;
    // mapping of owner of existing tokens
    mapping(uint256 => address) public tokenOwners;

    constructor(address _admin) ERC721("UniCom", "UC") EIP712(Constants.SIGNING_DOMAIN, Constants.SIGNATURE_VERSION) {
        _grantRole(Constants.UNIQCOMNFT_ROLE, _admin);
    }

    modifier onlyAdmin() {
        if (!hasRole(Constants.UNIQCOMNFT_ROLE, msg.sender)) {
            revert UniqComNFT__NotAdmin(msg.sender);
        }
        _;
    }

    function addAdmin(address newAdmin) external onlyAdmin {
        console2.log("Adding admin: ", newAdmin);
        console2.log("Sender: ", msg.sender);
        _grantRole(Constants.UNIQCOMNFT_ROLE, newAdmin);
    }

    function revokeAdmin(address oldAdmin) public onlyAdmin {
        require(msg.sender != oldAdmin, "Cannot revoke self");
        _revokeRole(Constants.UNIQCOMNFT_ROLE, oldAdmin);
    }

    function pause() public onlyAdmin {
        _pause();
    }

    function unpause() public onlyAdmin {
        _unpause();
    }

    function updateMaxSupply(uint256 newAmount) public onlyAdmin {
        currentMaxSupply = newAmount;
    }

    function updateMaxPerWalletAmount(uint256 newAmount) public onlyAdmin {
        maxPerWallet = newAmount;
    }

    /// @notice Returns all tokens owned by an address
    /// @param owner The address to query
    function tokensOfOwner(address owner) public view returns (uint256[] memory) {
        uint256 numOfTokens = balanceOf(owner);
        uint256[] memory result = new uint256[](numOfTokens);

        for (uint256 i; i < numOfTokens; ++i) {
            result[i] = tokenOfOwnerByIndex(owner, i);
        }

        return result;
    }

    function setContractURI(string memory newURI) public onlyAdmin {
        _contractURI = newURI;
    }

    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    function tokenOwner(uint256 tokenId) public view returns (address) {
        return ownerOf(tokenId);
    }

    function getTokenOwner(uint256 tokenId) public view returns (address) {
        return tokenOwners[tokenId];
    }

    /// @notice Returns a hash of the given NFTVoucher, prepared using EIP712
    /// typed data hashing rules.abi
    /// @param voucher The NFTVoucher to hash
    function _hash(NFTVoucher calldata voucher) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256("NFTVoucher(uint256 tokenId,string uri,uint256 minPrice)"),
                    voucher.tokenId,
                    keccak256(bytes(voucher.uri)),
                    voucher.minPrice
                )
            )
        );
    }

    /// @notice Verifies that the given signature is valid for the given NFTVoucher, returning the signer
    /// @dev Will revert if the signature is invalid. Does not verify that the signer is authorized to mint.
    /// @param voucher The NFTVoucher to verify
    function _verify(NFTVoucher calldata voucher) internal view returns (address) {
        bytes32 digest = _hash(voucher);
        return ECDSA.recover(digest, voucher.signature);
    }

    /**
     * @dev This is the core minting function
     * The Voucher is a pre signed message containing the tokenId of the NFT to mint as well as the metadata uri location on IPFS
     * The prefixed price is also included and signed so nothing can be tampered with
     *
     * Once minted, the voucher cannot be replayed as the tokenid will be already minted. We manage the tokenIds outside
     * NFTs and their ids outside the contract and provide randomized order vouchers to members
     *
     * @param voucher The NFTVoucher containing tokenId, ipfs metadata uri, price and typed data signature
     */
    function redeem(NFTVoucher calldata voucher) external payable returns (uint256) {
        // make sure signature is valid and get the address of the signer
        address signer = _verify(voucher);
        // make sure that the signer is authorized to mint
        if (!hasRole(Constants.UNIQCOMNFT_ROLE, signer)) {
            revert UniqComNFT__IncorrectSigner();
        }

        if (isTokenMinted[voucher.tokenId]) {
            revert UniqComNFT__AlreadyMinted();
        }

        // make sure that the redeemer is paying enough to cover the price
        if (msg.value < voucher.minPrice) {
            revert UniqComNFT__InsufficientFunds();
        }

        uint256 supply = totalSupply();
        if (supply > currentMaxSupply) {
            revert UniqComNFT__SoldOut();
        }

        uint256 totalOwned = tokensOfOwner(msg.sender).length;
        if (totalOwned >= maxPerWallet) {
            revert UniqComNFT__TooMany();
        }

        //        if (voucher.tokenId == 2) {
        //            _mint(signer, 10001);
        //            _mint(signer, 10002);
        //            _mint(signer, 10003);
        //            _mint(signer, 10004);
        //            _mint(signer, 10005);
        //            _mint(signer, 10006);
        //            _mint(signer, 10007);
        //            _mint(signer, 10008);
        //            _mint(signer, 10009);
        //            _mint(signer, 10010);
        //            _mint(signer, 10011);
        //            _mint(signer, 10012);
        //
        //        }

        isTokenMinted[voucher.tokenId] = true;
        // first assign the token to the signer, to establish provenance on-chain
        _mint(signer, voucher.tokenId);
        _setTokenURI(voucher.tokenId, voucher.uri);

        // transfer the token to the redeemer
        _transfer(signer, msg.sender, voucher.tokenId);

        emit UniqComNFT__Minted(voucher.tokenId, voucher.uri, msg.sender);

        return voucher.tokenId;
    }

    function safeMint(address to, uint256 tokenId, string memory uri) external whenNotPaused onlyAdmin {
        if (isTokenMinted[tokenId]) {
            revert UniqComNFT__AlreadyMinted();
        }
        uint256 supply = totalSupply();
        if (supply > currentMaxSupply) {
            revert UniqComNFT__SoldOut();
        }

        isTokenMinted[tokenId] = true;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        emit UniqComNFT__Minted(tokenId, uri, to);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function _increaseBalance(address account, uint128 value) internal virtual override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    /// @dev This override prevents UniqNFT from being moved to the ERC6551 locker wallet of another UniqNFT
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable, ERC721Pausable)
        returns (address)
    {
        bool isUniqWallet = ERC165Checker.supportsInterface(to, Constants.UNIQWALLET);
        if (isUniqWallet) {
            revert UniqComNFT__CannotMoveToWallet();
        }
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl, ERC721URIStorage)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function withdraw(address payable account) public payable onlyAdmin {
        if (account == address(0)) {
            revert UniqComNFT__NullAddressError();
        }
        (bool success,) = payable(account).call{value: address(this).balance}("");
        require(success, "Transfer failed.");
    }
}
