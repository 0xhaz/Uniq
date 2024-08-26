// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IUniqComWallet} from "src/interfaces/IUniqComWallet.sol";
import {ERC6551AccountLib} from "src/libraries/ERC6551AccountLib.sol";

contract UniqWallet is IERC165, IERC1271, IUniqComWallet {
    uint256 public nonce;

    function iAmUniqWallet() external pure returns (bool) {
        return true;
    }

    receive() external payable {}

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

    function token() external view returns (uint256, address, uint256) {
        return ERC6551AccountLib.token();
    }

    function owner() public view returns (address) {
        (uint256 chainId, address tokenContract, uint256 tokenId) = this.token();
        if (chainId != block.chainid) return address(0);

        return IERC721(tokenContract).ownerOf(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return (interfaceId == type(IERC165).interfaceId || interfaceId == type(IUniqComWallet).interfaceId);
    }

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
