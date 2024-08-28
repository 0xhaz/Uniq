// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

interface IUniqComNFT {
    event UniqComNFT__Minted(uint256 indexed tokenId, string tokenURI, address ownerAddress);

    error UniqComNFT__NotAdmin(address caller);
    error UniqComNFT__IncorrectSigner();
    error UniqComNFT__InsufficientFunds();
    error UniqComNFT__SoldOut();
    error UniqComNFT__TooMany();
    error UniqComNFT__AlreadyMinted();
    error UniqComNFT__NullAddressError();
    error UniqComNFT__CannotMoveToWallet();
    error UniqComNFT__NotMember(address caller);
    error UniqComNFT__NotOwner();

    struct NFTVoucher {
        uint256 tokenId;
        string uri;
        uint256 minPrice;
        bytes signature;
    }

    function addAdmin(address newAdmin) external;

    function revokeAdmin(address oldAdmin) external;

    function pause() external;

    function unpause() external;

    function updateMaxSupply(uint256 newMaxSupply) external;

    function updateMaxPerWalletAmount(uint256 newMaxPerWallet) external;

    /// @notice Returns all tokens owned by an address
    /// @param owner The address to query
    function tokensOfOwner(address owner) external view returns (uint256[] memory);

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
    function redeem(NFTVoucher calldata voucher) external payable returns (uint256);

    function safeMint(address to, uint256 tokenId, string calldata uri) external;

    function withdraw(address payable to) external payable;
}
