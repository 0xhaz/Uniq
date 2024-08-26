// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

interface IERC6551AccountProxy {
    function implementation() external view returns (address);
}

interface IUniqComWallet {
    error UniqCom__NotOwner();

    event TransactionExecuted(address indexed target, uint256 indexed value, bytes data);

    function UniqComWallet() external pure returns (bool);

    /**
     * @notice Execute a call to a target contract
     * @param to The target contract address
     * @param value The value to send
     * @param data The data to send
     */
    function executeCall(address to, uint256 value, bytes calldata data) external payable returns (bytes memory);

    /**
     * @notice Get the token information
     * @return chainId The chain ID of the token
     * @return tokenContract The address of the token contract
     * @return tokenId The token ID
     */
    function token() external view returns (uint256 chainId, address tokenContract, uint256 tokenId);

    /**
     * @notice Get the account information
     * @return account The address of the account
     */
    function owner() external view returns (address);

    /**
     * @notice Get the nonce
     */
    function nonce() external view returns (uint256);
}
