// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

/**
 * @title RWA Asset Library
 */

/// @notice Enum for the RWA Asset Status
enum RWAStatus {
    ADD,
    MINT,
    REDEEM
}

/// @notice Struct for the RWA Asset
struct RWAAssetData {
    bytes32 asset;
    address priceFeed;
}

/// @notice Struct for the RWA Request
struct RWARequest {
    bytes32 asset;
    uint256 amountOfToken;
    address requester;
    RWAStatus status;
}

/// @notice Struct for representing the RWA Asset Position
struct Positions {
    address owner;
    uint256 portfolioBalance;
    RWAAssetData[] assetData;
    mapping(bytes32 asset => address priceFeed) assetToPriceFeed;
    mapping(address user => uint256 amountAvailableToWithdraw) userToWithdrawAmount;
}

using RWALib for Positions global;

library RWALib {
    error RWALib__NotOwner();

    /**
     * @notice Add a new RWA asset
     * @param asset The asset to add
     * @param priceFeed The price feed of the asset
     */
    function addRWAAsset(Positions storage positions, bytes32 asset, address priceFeed) internal {
        positions.assetData.push(RWAAssetData(asset, priceFeed));
        positions.assetToPriceFeed[asset] = priceFeed;
    }

    /**
     * @notice Get the RWA Asset Data
     * @param position The position to get the RWA Asset Data from
     * @return The RWA asset data
     */
    function getRWAAssetData(Positions storage position) internal view returns (bytes32[] memory, address[] memory) {
        // return (position.assetData.asset, position.assetData.priceFeed);
        RWAAssetData[] storage assetData = position.assetData;
        bytes32[] memory assets = new bytes32[](assetData.length);
        address[] memory priceFeeds = new address[](assetData.length);
        for (uint256 i = 0; i < assetData.length; i++) {
            assets[i] = assetData[i].asset;
            priceFeeds[i] = assetData[i].priceFeed;
        }
        return (assets, priceFeeds);
    }

    function getRWAAssetName(Positions storage position) internal view returns (bytes32[] memory) {
        // return position.assetData.asset;
        RWAAssetData[] memory assetData = position.assetData;
        bytes32[] memory assets = new bytes32[](assetData.length);
        for (uint256 i = 0; i < assetData.length; i++) {
            assets[i] = assetData[i].asset;
        }
        return assets;
    }

    function getRWAPriceFeed(Positions storage position) internal view returns (address[] memory) {
        // return position.assetData.priceFeed;
        RWAAssetData[] memory assetData = position.assetData;
        address[] memory priceFeeds = new address[](assetData.length);
        for (uint256 i = 0; i < assetData.length; i++) {
            priceFeeds[i] = assetData[i].priceFeed;
        }
        return priceFeeds;
    }

    /**
     * @notice Get the RWA Request
     * @param position The position to get the RWA Request from
     * @param owner The owner of the RWA Request
     * @param requestId The request ID of the RWA Request
     * @return The RWA Request
     */
    function getRWARequest(Positions storage position, address owner, bytes32 requestId)
        internal
        view
        returns (RWARequest memory)
    {}

    /**
     * @notice Get the RWA Requester
     * @param position The position to get the RWA Requester from
     * @param requestId The request ID of the RWA Requester
     * @return The RWA Requester
     */
    function getRWARequester(Positions storage position, bytes32 requestId) internal view returns (address) {}

    /**
     * @notice Get the RWA Request Amount
     * @param position The position to get the RWA Request Amount from
     * @param owner The owner of the RWA Request Amount
     * @param requestId The request ID of the RWA Request Amount
     */
    function getRWARequestAmount(Positions storage position, address owner, bytes32 requestId)
        internal
        view
        returns (uint256)
    {}

    /**
     * @notice Get the RWA Request Status
     * @param position The position to get the RWA Request Status from
     * @param owner The owner of the RWA Request Status
     * @param requestId The request ID of the RWA Request Status
     */
    // function getRWARequestStatus(Positions storage position, address owner, bytes32 requestId)
    //     internal
    //     view
    //     returns (RWAStatus)
    // {
    //     if (position.owner != owner) revert RWALib__NotOwner();
    // }

    /**
     * @notice Get the RWA Request Asset
     * @param position The position to get the RWA Request Asset from
     * @param owner The owner of the RWA Request Asset
     * @param requestId The request ID of the RWA Request Asset
     */
    // function getRWARequestAsset(Positions storage position, address owner, bytes32 requestId)
    //     internal
    //     view
    //     returns (bytes32)
    // {
    //     if (position.owner != owner) revert RWALib__NotOwner();
    // }

    /**
     * @notice Get the RWA Request Portfolio Balance
     * @param position The position to get the RWA Request Portfolio Balance from
     * @param owner The owner of the RWA Request Portfolio Balance
     * @return The RWA Request Portfolio Balance
     */
    function getRWARequestPortfolioBalance(Positions storage position, address owner) internal view returns (uint256) {
        if (position.owner != owner) revert RWALib__NotOwner();
        return position.portfolioBalance;
    }

    /**
     * @notice Get the RWA Request Amount Available To Withdraw
     * @param position The position to get the RWA Request Amount Available To Withdraw from
     * @param owner The owner of the RWA Request Amount Available To Withdraw
     * @param user The user of the RWA Request Amount Available To Withdraw
     * @return The RWA Request Amount Available To Withdraw
     */
    function getRWARequestAmountAvailableToWithdraw(Positions storage position, address owner, address user)
        internal
        view
        returns (uint256)
    {
        if (position.owner != owner) revert RWALib__NotOwner();
        return position.userToWithdrawAmount[user];
    }
}
