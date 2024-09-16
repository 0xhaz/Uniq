// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IUniqComWallet} from "src/interfaces/IUniqComWallet.sol";
import {ERC6551AccountLib} from "src/libraries/ERC6551AccountLib.sol";

/**
 * @title UniqWallet
 * @notice A smart contract wallet that interacts with ERC6551 accounts and validates signatures.
 *         It can execute arbitrary calls and verify ownership using the ERC721 standard.
 */
contract UniqWallet is IERC165, IERC1271, IUniqComWallet {
    uint256 public nonce;

    function iAmUniqWallet() external pure returns (bool) {
        return true;
    }

    /**
     * @notice Receives Ether transfers sent to the contract.
     */
    receive() external payable {}

    /**
     * @notice Executes a call to an external contract.
     * @dev Can only be called by the owner of the contract. Increments the nonce with each call to prevent replay attacks.
     *      Reverts if the call fails, returning the error message from the failed contract.
     * @param to The address to call.
     * @param value The amount of Ether to send with the call.
     * @param data The call data to pass along to the contract.
     * @return result The data returned by the external contract.
     */
    function executeCall(address to, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result)
    {
        if (msg.sender != owner()) revert UniqCom__NotOwner();

        ++nonce;

        emit TransactionExecuted(to, value, data);

        bool success;
        (success, result) = to.call{value: value}(data);

        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    /**
     * @notice Retrieves the token associated with this account based on the ERC6551 standard.
     * @return The chain ID, token contract address, and token ID of the associated token.
     */
    function token() external view returns (uint256, address, uint256) {
        return ERC6551AccountLib.token();
    }

    /**
     * @notice Gets the current owner of the wallet based on the associated ERC721 token.
     * @dev The ownership is determined by the token contract and token ID stored in the wallet.
     *      Returns address(0) if the token's chain ID does not match the current chain.
     * @return The address of the wallet owner, or address(0) if the token's chain ID does not match.
     */
    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = this.token();
        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    /**
     * @notice Checks if the contract supports a given interface.
     * @param interfaceId The interface identifier to check.
     * @return True if the contract supports the given interface, false otherwise.
     */
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return (interfaceId == type(IERC165).interfaceId || interfaceId == type(IUniqComWallet).interfaceId);
    }

    /**
     * @notice Validates a signature for a given hash.
     * @dev Uses `SignatureChecker` to validate the signature against the owner's address.
     * @param hash The hash of the data that was signed.
     * @param signature The signature to verify.
     * @return magicValue A selector indicating whether the signature is valid (`0x1626ba7e`) or invalid (`0x`).
     */
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4 magicValue) {
        bool isValid = SignatureChecker.isValidSignatureNow(owner(), hash, signature);

        if (isValid) {
            return IERC1271.isValidSignature.selector;
        }

        return "";
    }

    /// @inheritdoc IUniqComWallet
    function UniqComWallet() external pure returns (bool) {
        return true;
    }
}
