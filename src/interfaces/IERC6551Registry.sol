// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

interface IERC6551Registry {
    /// @notice Emitted event when a new account is registered
    event AccountCreated(
        address account, address implementation, uint256 chainId, address tokenContract, uint256 tokenId, uint256 salt
    );

    /**
     * @notice Register a new account
     * @param implementation The address of the implementation contract
     * @param chainId The chain ID of the network
     * @param tokenContract The address of the token contract
     * @param tokenId The token ID
     * @param seed The seed to generate the salt
     * @param initData The data to be used for initialization
     * @return The address of the new account
     */
    function createAccount(
        address implementation,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId,
        uint256 seed,
        bytes calldata initData
    ) external returns (address);

    /**
     * @notice Get the account address
     * @param implementation The address of the implementation contract
     * @param chainId The chain ID of the network
     * @param tokenContract The address of the token contract
     * @param tokenId The token ID
     * @param salt The salt used to generate the account address
     * @return The address of the account
     */
    function account(address implementation, uint256 chainId, address tokenContract, uint256 tokenId, uint256 salt)
        external
        view
        returns (address);
}
