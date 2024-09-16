// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {FunctionsClient} from "chainlink/contracts/src/v0.8/functions/dev/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "chainlink/contracts/src/v0.8/functions/dev/v1_0_0/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Oracle} from "src/libraries/Oracle.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {RWALib, Positions, RWAAssetData, RWARequest, RWAStatus} from "src/libraries/RWALib.sol";
import {Constants} from "src/libraries/Constants.sol";
import {IUniqRWA} from "src/interfaces/IUniqRWA.sol";
import {console2} from "forge-std/console2.sol";
import {AggregatorV3Interface} from "chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title UniqRWA contract
 * @notice This contract is used to make request to the broker API to mint RWA-backed tokens
 */
contract UniqRWA is FunctionsClient, ConfirmedOwner, IUniqRWA, ERC20, Pausable {
    using FunctionsRequest for FunctionsRequest.Request;
    using Oracle for AggregatorV3Interface;
    using Strings for uint256;

    address functionsRouter;
    bytes32 assetName;
    string mintSource;
    string redeemSource;
    uint64 subId;
    bytes32 donID;
    uint64 secretVersion;
    uint8 secretSlot;
    address public rwaPriceFeed;
    address public usdcPriceFeed;
    address public redemptionToken;
    uint256 private immutable redemptionTokenDecimals;

    RWAAssetData[] public assets;

    //    Mapping of the asset positions and the request ID to the request
    mapping(bytes32 => Positions) private positions;
    mapping(bytes32 => address) private assetPriceFeed;
    // Mapping of requestId to RWARequest
    mapping(bytes32 requestId => RWARequest) private requestIdToRequest;

    /**
     * @notice Contract constructor initializes various external dependencies and sets the initial state.
     * @param subId_ The subscription ID for Chainlink Functions.
     * @param assetName_ The name of the RWA asset.
     * @param mintSource_ The JavaScript code for minting tokens.
     * @param redeemSource_ The JavaScript code for redeeming tokens.
     * @param functionsRouter_ The address of the Chainlink Functions router.
     * @param donID_ The DON ID for Chainlink Functions.
     * @param rwaPriceFeed_ The price feed for the RWA asset.
     * @param usdcPriceFeed_ The price feed for USDC.
     * @param redemptionToken_ The address of the token used for redemption.
     * @param secretVersion_ The version of the secret used for Chainlink Functions.
     * @param secretSlot_ The slot number for the secret.
     */
    constructor(
        uint64 subId_,
        bytes32 assetName_,
        string memory mintSource_,
        string memory redeemSource_,
        address functionsRouter_,
        bytes32 donID_,
        address rwaPriceFeed_,
        address usdcPriceFeed_,
        address redemptionToken_,
        uint64 secretVersion_,
        uint8 secretSlot_
    ) FunctionsClient(functionsRouter_) ConfirmedOwner(msg.sender) ERC20("Backed RWA Token", "bRToken") {
        subId = subId_;
        assetName = assetName_;
        mintSource = mintSource_;
        redeemSource = redeemSource_;
        functionsRouter = functionsRouter_;
        donID = donID_;
        rwaPriceFeed = rwaPriceFeed_;
        usdcPriceFeed = usdcPriceFeed_;
        redemptionToken = redemptionToken_;
        redemptionTokenDecimals = ERC20(redemptionToken).decimals();
        secretVersion = secretVersion_;
        secretSlot = secretSlot_;

        assets.push(RWAAssetData(assetName_, rwaPriceFeed_));
        assetPriceFeed[assetName_] = rwaPriceFeed_;
    }

    /**
     * @notice Adds a new asset to the contract with a corresponding price feed.
     * @dev Only the contract owner can add a new asset. Reverts if asset or price feed is zero address.
     * @param asset The asset's unique identifier.
     * @param priceFeed The address of the price feed for the asset.
     */
    function addAsset(bytes32 asset, address priceFeed) external onlyOwner {
        if (priceFeed == address(0) || asset == bytes32(0)) {
            revert UniqRWA__AssetNotFound();
        }

        assets.push(RWAAssetData(asset, priceFeed));
        assetPriceFeed[asset] = priceFeed;

        emit AssetAdded(asset, priceFeed);
    }

    /**
     * @notice Sends a mint request to the Chainlink Functions API to mint RWA tokens.
     * @dev Only the owner can call this function. The request is paused if the contract is paused.
     * @param asset The asset to be minted.
     * @param amountTokensToMint The amount of tokens to mint.
     * @return requestId The unique request ID for tracking the mint request.
     */
    function sendMintRequest(bytes32 asset, uint256 amountTokensToMint)
        external
        onlyOwner
        whenNotPaused
        returns (bytes32 requestId)
    {
        // Check if the portfolio has enough collateral to mint new tokens
        if (_getCollateralRatioAdjustedBalance(asset, amountTokensToMint) > positions[asset].portfolioBalance) {
            revert UniqRWA__NotEnoughCollateral();
        }

        FunctionsRequest.Request memory req;

        req.initializeRequestForInlineJavaScript(mintSource); // Initialize the request with JS code
        req.addDONHostedSecrets(secretSlot, secretVersion);

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subId, Constants.GAS_LIMIT, donID);

        // requestIdToRequestAsset[requestId] = RWARequest(asset, amountTokensToMint, msg.sender, RWAStatus.MINT);

        requestIdToRequest[requestId] = RWARequest(asset, amountTokensToMint, msg.sender, RWAStatus.MINT);

        emit MintRequest(requestId, amountTokensToMint);
        return requestId;
    }

    /**
     * @notice Sends a redeem request to the Chainlink Functions API to redeem RWA tokens for USDC.
     * @dev Pauses the function when the contract is paused. Burns the tokens to be redeemed.
     * @param asset The asset being redeemed.
     * @param amountBRToken The amount of tokens being redeemed.
     * @return requestId The unique request ID for tracking the redeem request.
     */
    function sendRedeemRequest(bytes32 asset, uint256 amountBRToken)
        external
        override
        whenNotPaused
        returns (bytes32 requestId)
    {
        // TODO: Check for potential exploit
        uint256 amountRWAInUSDC = getUsdcValueofUsd(getUsdValueOfAsset(asset, amountBRToken));
        if (amountRWAInUSDC < Constants.MIN_REDEMPTION_PRICE) {
            revert UniqRWA__BelowMinimumRedemption();
        }

        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(redeemSource);
        string[] memory args = new string[](2);
        // The transaction will fail if it's outside of 2% slippage
        // This could be a future improvement to make slippage a parameter
        args[0] = amountBRToken.toString();
        args[1] = amountRWAInUSDC.toString();
        req.setArgs(args);

        // Send the request and store the request ID
        requestId = _sendRequest(req.encodeCBOR(), subId, Constants.GAS_LIMIT, donID);
        requestIdToRequest[requestId] = RWARequest(asset, amountBRToken, msg.sender, RWAStatus.REDEEM);

        _burn(msg.sender, amountBRToken);
    }

    /**
     * @notice Sets the secret version used by Chainlink Functions.
     * @param _secretVersion The new secret version.
     */
    function setSecretVersion(uint64 _secretVersion) external override {
        secretVersion = _secretVersion;
    }

    /**
     * @notice Sets the secret slot used by Chainlink Functions.
     * @param _secretSlot The new secret slot.
     */
    function setSecretSlot(uint8 _secretSlot) external override {
        secretSlot = _secretSlot;
    }

    /**
     * @notice Allows users to withdraw their USDC after a successful redeem request.
     * @param asset The asset being withdrawn.
     */
    function withdraw(bytes32 asset) external override whenNotPaused {
        uint256 amountToWithdraw = positions[asset].userToWithdrawAmount[msg.sender];
        positions[asset].userToWithdrawAmount[msg.sender] = 0;

        bool success = ERC20(redemptionToken).transfer(msg.sender, amountToWithdraw);
        if (!success) {
            revert UniqRWA__RedemptionFailed();
        }
    }

    /**
     * @notice Pauses the contract, halting certain actions.
     * @dev Only the owner can pause the contract.
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, resuming normal functionality.
     * @dev Only the owner can unpause the contract.
     */
    function unpause() external override onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adjusts the total balance of the portfolio to account for the collateral ratio
     * @param amountTokensToMint The amount of tokens to mint
     * @return The amount of tokens to mint
     * @dev This function is used to check if the portfolio has enough collateral to mint new tokens
     */
    function _getCollateralRatioAdjustedBalance(bytes32 asset, uint256 amountTokensToMint)
        internal
        view
        returns (uint256)
    {
        uint256 newValue = getCalculatedNewTotalValue(asset, amountTokensToMint);
        return (newValue * Constants.COLLATERAL_RATIO) / Constants.COLLATERAL_PRECISION;
    }

    /**
     * @notice Callback function for fulfilling Chainlink requests
     * @param requestId The request ID
     * @param response The response of the request
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory /*err*/ )
        internal
        override
        whenNotPaused
    {
        uint256 newPortfolioBalance = abi.decode(response, (uint256));
        // uint256 newPortfolioBalance = abi.decode(response, (uint256));
        // console2.logBytes32(requestId);

        // bytes32 asset = requestIdToRequestAsset[requestId].asset;

        bytes32 asset = requestIdToRequest[requestId].asset;

        positions[asset].portfolioBalance = newPortfolioBalance;

        if (requestIdToRequest[requestId].status == RWAStatus.MINT) {
            _mintFulFillRequest(requestId, newPortfolioBalance);
        } else {
            _redeemFulFillRequest(requestId, response);
        }
    }

    /**
     * @notice Mints tokens for a given request once the Chainlink response is fulfilled.
     * @dev Verifies that the portfolio has enough collateral to mint the requested amount of tokens.
     *      Mints the tokens to the requester if the conditions are met.
     * @param requestId The unique ID of the fulfilled mint request.
     * @param newPortfolioBalance The updated portfolio balance after the Chainlink response.
     */
    function _mintFulFillRequest(bytes32 requestId, uint256 newPortfolioBalance) internal {
        // bytes32 asset = requestIdToRequestAsset[requestId].asset;

        bytes32 asset = requestIdToRequest[requestId].asset;

        uint256 amountOfTokensToMint = requestIdToRequest[requestId].amountOfToken;

        if (_getCollateralRatioAdjustedBalance(asset, amountOfTokensToMint) > newPortfolioBalance) {
            revert UniqRWA__NotEnoughCollateral();
        }

        // address assetToken = assetToToken[asset];

        if (amountOfTokensToMint != 0) {
            _mint(requestIdToRequest[requestId].requester, amountOfTokensToMint);
        }
    }

    /*
     * @notice the callback for the redeem request
     * At this point, USDC should be in this contract, and we need to update the user
     * That they can now withdraw their USDC
     *
     * @param requestId The ID of the request to fulfill
     * @param response The response from the request, it'll be the amount of USDC that was sent
     */
    function _redeemFulFillRequest(bytes32 requestId, bytes memory response) internal {
        bytes32 asset = requestIdToRequest[requestId].asset;

        uint256 amountOfUSDC = abi.decode(response, (uint256));
        uint256 amountOfUSDCWAD;

        if (redemptionTokenDecimals < 18) {
            amountOfUSDCWAD = amountOfUSDC * (10 ** (18 - redemptionTokenDecimals));
        }
        if (amountOfUSDC == 0) {
            uint256 amountOfRWABurned = requestIdToRequest[requestId].amountOfToken;
            _mint(requestIdToRequest[asset].requester, amountOfRWABurned);
            return;
        }

        positions[asset].userToWithdrawAmount[requestIdToRequest[requestId].requester] = amountOfUSDCWAD;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retrieves the current price of an asset using its price feed.
     * @param assetAddress The asset identifier (bytes32) to get the price of.
     * @return The current price of the asset, scaled by the feed's precision.
     */
    function getAssetPrice(bytes32 assetAddress) public view returns (uint256) {
        address assetPriceFeed_ = assetPriceFeed[assetAddress];

        AggregatorV3Interface priceFeed = AggregatorV3Interface(assetPriceFeed_);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * Constants.ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Calculates the total value of the portfolio after adding a specified number of assets.
     * @param asset The asset identifier (bytes32) to calculate the total value for.
     * @param addedNumberOfAsset The number of additional assets to be included in the calculation.
     * @return The calculated total value of the portfolio.
     */
    function getCalculatedNewTotalValue(bytes32 asset, uint256 addedNumberOfAsset)
        public
        view
        override
        returns (uint256)
    {
        return ((totalSupply() + addedNumberOfAsset) * getAssetPrice(asset)) / Constants.PRECISION;
    }

    /**
     * @notice Retrieves data about all assets in the portfolio, including their asset identifiers and price feeds.
     * @return asset An array of asset identifiers (bytes32).
     * @return priceFeed An array of price feed addresses corresponding to each asset.
     */
    function getAssetsData() public view returns (bytes32[] memory, address[] memory) {
        uint256 len = assets.length;
        bytes32[] memory asset = new bytes32[](len);
        address[] memory priceFeed = new address[](len);

        for (uint256 i; i < len;) {
            asset[i] = assets[i].asset;
            priceFeed[i] = assets[i].priceFeed;
            unchecked {
                ++i;
            }
        }

        return (asset, priceFeed);
    }

    /**
     * @notice Retrieves the current portfolio balance of a specified asset.
     * @param asset The asset identifier (bytes32) for which to retrieve the balance.
     * @return The current portfolio balance for the specified asset.
     */
    function getPortfolioBalance(bytes32 asset) public view returns (uint256) {
        return positions[asset].portfolioBalance;
    }

    /**
     * @notice Retrieves the current price of USDC using its price feed.
     * @return The current USDC price, scaled by the feed's precision.
     */
    function getUsdcPrice() public view override returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdcPriceFeed);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * Constants.ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Calculates the USD value of a specified amount of RWA tokens.
     * @param asset The asset identifier (bytes32) for which to calculate the value.
     * @param rwaAmount The amount of RWA tokens to calculate the value for.
     * @return The USD value of the specified amount of RWA tokens.
     */
    function getUsdValueOfAsset(bytes32 asset, uint256 rwaAmount) public view returns (uint256) {
        return (rwaAmount * getAssetPrice(asset)) / Constants.PRECISION;
    }

    /**
     * @notice Converts a USD value into its equivalent value in USDC.
     * @param usdcValue The USD value to convert.
     * @return The equivalent value in USDC.
     */
    function getUsdcValueofUsd(uint256 usdcValue) public view returns (uint256) {
        return (usdcValue * Constants.PRECISION) / getUsdcPrice();
    }

    // function getTotalUsdValue(bytes32 asset) external view returns (uint256) {}

    /**
     * @notice Retrieves the details of a specific request by its ID.
     * @param requestId The unique identifier of the request.
     * @return The RWARequest struct containing details of the request.
     */
    function getRequest(bytes32 requestId) external view override returns (RWARequest memory) {
        return requestIdToRequest[requestId];
    }

    /**
     * @notice Retrieves the amount of USDC available for a user to withdraw after a redeem request.
     * @param asset The asset identifier (bytes32) for which to check the withdrawal amount.
     * @param user The address of the user making the withdrawal.
     * @return The amount of USDC the user is eligible to withdraw.
     */
    function getWithdrawalAmount(bytes32 asset, address user) external view override returns (uint256) {
        return positions[asset].userToWithdrawAmount[user];
    }
}
