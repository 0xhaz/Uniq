// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {OrderPool} from "src/libraries/OrderPool.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Struct} from "src/libraries/Struct.sol";
import {Errors} from "src/libraries/Errors.sol";

interface IUniqHook {
    /// @notice Emitted when a new long term order is submitted
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the new order
    /// @param expiration The expiration timestamp of the order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The sell rate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    event SubmitOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    /// @notice Emitted when a long term order is updated
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the existing order
    /// @param expiration The expiration timestamp of the order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The updated sellRate of tokens per second being sold in the order
    /// @param earningsFactorLast the current earnings factor of the order pool
    /// (since updated orders will claim existing earnings)
    event UpdateOrder(
        PoolId indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    /// @notice Time interval on which orders are allowed to expire. Conserves processing needed on execute
    // function expirationInterval() external view returns (uint256);

    /// @notice Submits a new long term order into the TWAMM. Also executes TWAMM orders if not up to date
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for the new order
    /// @param amountIn The amount of sell token to add to the order. Some precision on amountIn may be lost up to the
    /// magnitude of (orderKey.expiration - block.timestamp)
    /// @return orderId The bytes32 ID of the order
    function submitOrder(PoolKey calldata key, Struct.OrderKey calldata orderKey, uint256 amountIn)
        external
        returns (bytes32 orderId);

    /// @notice Update an existing long term with current earnings, optionally modify the amount selling
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for which to identify the order
    /// @param amountDelta The delta for the order sell amount. Negative to remove from order, positive to add, or
    /// -1 to remove the full amount from the order
    function updateOrder(PoolKey calldata key, Struct.OrderKey calldata orderKey, int256 amountDelta)
        external
        returns (uint256 tokens0Owed, uint256 tokens1Owed);

    /// @notice Claim tokens owed from TWAMM contract
    /// @param token The token to claim
    /// @param to The recipient of the claim
    /// @param amountRequested The amount of tokens requested to claim. Set to 0 to claim all
    /// @return amountTransferred The total amount to be collected
    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred);

    /// @notice Executes TWAMM orders on the pool, swapping on the pool itself to make up the difference between the
    /// two TWAMM pools swapping against each other
    /// @param key The pool key associated with the TWAMM orders
    function executeTWAMMOrders(PoolKey memory key) external;

    // /// @notice Get the total of tokens owed to an owner
    // /// @param token The token to check
    // /// @param owner The owner to check
    function tokensOwed(Currency token, address owner) external returns (uint256);

    // /// @notice Get the last timestamp in which virtual orders were executed
    // /// @param key The pool key associated with the TWAMM orders
    // /// @return lastVirtualOrderTimestamp The last timestamp in which virtual orders were executed
    function getLastVirtualOrder(PoolId key) external view returns (uint256);

    function getOrder(PoolKey calldata key, Struct.OrderKey calldata orderKey)
        external
        view
        returns (Struct.Order memory);

    function getOrderPool(PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRate, uint256 earningsFactor);
}
