// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @title TransferHelper
/// @notice Contains helper functions for interacting with ERC20 tokens that do not consistently return true/false
/// @dev implementation from https://github.com/Rari-Capital/solmate/blob/main/src/utils/SafeTransferLib.sol#L63
library TransferHelper {
    /// @notice Transfers tokens from msg.sender to a recipient
    /// @dev Calls transfer on token contract, errors with TF if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param to The recipient of the transfer
    /// @param value The amount of tokens to transfer
    function safeTransfer(IERC20Minimal token, address to, uint256 value) internal {
        bool success;

        assembly {
            // Get a pointer to some free memory
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000) // transfer(address,uint256)
            mstore(add(freeMemoryPointer, 4), to) // Append the "to" argument
            mstore(add(freeMemoryPointer, 36), value) // Append the "value" argument

            success :=
                and(
                    // Set success to whether the call reverted, if not we check it either
                    // returned exactly 1 (can't just be non-zero data), or hand no return data
                    or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                    // we used 68 because the length of our calldata totals up like so: 4 + 32 * 2
                    // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space
                    // Counterintuitively, this call must positioned second to the or() call in the
                    // surrounding and() call or else returndatasize() will be zero during the computation
                    call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
                )
        }
        require(success, "TRANSFER_FAILED");
    }

    /// @notice Transfers tokens from from to a recipient
    /// @dev Calls transferFrom on token contract, errors with TF if transfer fails
    /// @param token The contract address of the token which will be transferred
    /// @param from The sender of the transfer
    /// @param to The recipient of the transfer
    /// @param value The amount of tokens to transfer
    function safeTransferFrom(IERC20Minimal token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAILED");
    }
}
