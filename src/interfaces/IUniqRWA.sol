// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {RWALib, RWAAssetData, RWARequest, Positions} from "src/libraries/RWALib.sol";

/**
 * @title UniqRWA Interface
 * @notice Interface for the UniqRWA contract
 */
interface IUniqRWA {
    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error UniqRWA__NotEnoughCollateral();
    error UniqRWA__BelowMinimumRedemption();
    error UniqRWA__RedemptionFailed();
    error UniqRWA__AssetNotFound();
    error UniqRWA__NotOwner();
    error UniqRWA__NotAdmin(address admin);

    error UnexpectedRequestID(bytes32 requestId);

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a request is made
    /// @param requestId The request ID
    /// @param character The character of the request
    /// @param response The response of the request
    /// @param err The error of the request
    event Response(bytes32 indexed requestId, uint256 character, bytes response, bytes err);

    /// @notice Emitted when a new asset is added
    /// @param asset The asset added
    /// @param priceFeed The price feed of the asset
    event AssetAdded(bytes32 indexed asset, address indexed priceFeed);

    /// @notice Emitted when a mint request is made
    /// @param requestId The request ID
    /// @param amountTokensToMint The amount of tokens to mint
    event MintRequest(bytes32 indexed requestId, uint256 amountTokensToMint);

    event AssetApiBackedStatusUpdated(bytes32 indexed asset, bool status);

    /*//////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set Secret Version of Chailink Function
    /// @param _secretVersion The secret version
    function setSecretVersion(uint64 _secretVersion) external;

    /// @notice Set Secret Slot of Chailink Function
    /// @param _secretSlot The secret slot
    function setSecretSlot(uint8 _secretSlot) external;

    // function setApiBackedAsset(bytes32 asset, bool isBackedByApi) external;

    // function isApiBackedAsset(bytes32 asset) external view returns (bool);

    /// @notice Add a new RWA asset
    /// @param _asset The asset to add
    /// @param _priceFeed The price feed of the asset
    function addAsset(bytes32 _asset, address _priceFeed) external;

    /// @notice Sends an HTTP request for character information
    /// @param amountTokensToMint The amount of tokens to mint
    /// @return requestId The request ID
    /// @dev If you pass 0, that will act as a way to get an updarted portfolio balance
    // function sendMintRequest(bytes32 asset, uint256 amountTokensToMint) external returns (bytes32 requestId);

    /// @notice User sends a Chainlink Function request to sell RWA assets for redemption token
    /// @notice This will put the redemption token in a withdrawal state that the user can call to redeem
    /// @dev This will burn RWA tokens, sell the assets on brokerage, buy stablecoin and send it to the user to withdraw
    /// @param amountBRToken The amount of dAsset to redeem
    function sendRedeemRequest(bytes32 asset, uint256 amountBRToken) external returns (bytes32 requestId);

    /**
     * @notice Withdraw the redemption token
     *
     */
    function withdraw(bytes32 asset) external;

    /**
     * @notice Pause the contract
     */
    function pause() external;

    /**
     * @notice Unpause the contract
     */
    function unpause() external;

    /*//////////////////////////////////////////////////////////////
                         VIEW AND PURE 
    //////////////////////////////////////////////////////////////*/

    function getAssetPrice(bytes32 asset) external view returns (uint256);

    function getUsdcPrice() external view returns (uint256);

    function getUsdValueOfAsset(bytes32 asset, uint256 _amount) external view returns (uint256);

    function getUsdcValueofUsd(uint256 _amount) external view returns (uint256);

    // function getTotalUsdValue() external view returns (uint256);

    function getCalculatedNewTotalValue(bytes32 asset, uint256 addedNumberOfAsset) external view returns (uint256);

    function getRequest(bytes32 requestId) external view returns (RWARequest memory);

    function getWithdrawalAmount(bytes32 asset, address user) external view returns (uint256);

    function getPortfolioBalance(bytes32 asset) external view returns (uint256);
}
