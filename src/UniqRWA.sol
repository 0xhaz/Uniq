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

    function addAsset(bytes32 asset, address priceFeed) external onlyOwner {
        if (priceFeed == address(0) || asset == bytes32(0)) {
            revert UniqRWA__AssetNotFound();
        }

        assets.push(RWAAssetData(asset, priceFeed));
        assetPriceFeed[asset] = priceFeed;

        emit AssetAdded(asset, priceFeed);
    }

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
     * @notice Sends an HTTP request for character information
     * @dev If you pass 0, that will act as a way to get an updated portfolio balance
     * @return requestId The ID of the request
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

    function setSecretVersion(uint64 _secretVersion) external override {
        secretVersion = _secretVersion;
    }

    function setSecretSlot(uint8 _secretSlot) external override {
        secretSlot = _secretSlot;
    }

    function withdraw(bytes32 asset) external override whenNotPaused {
        uint256 amountToWithdraw = positions[asset].userToWithdrawAmount[msg.sender];
        positions[asset].userToWithdrawAmount[msg.sender] = 0;

        bool success = ERC20(redemptionToken).transfer(msg.sender, amountToWithdraw);
        if (!success) {
            revert UniqRWA__RedemptionFailed();
        }
    }

    function pause() external override onlyOwner {
        _pause();
    }

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

    function getAssetPrice(bytes32 assetAddress) public view returns (uint256) {
        address assetPriceFeed_ = assetPriceFeed[assetAddress];

        AggregatorV3Interface priceFeed = AggregatorV3Interface(assetPriceFeed_);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * Constants.ADDITIONAL_FEED_PRECISION;
    }

    function getCalculatedNewTotalValue(bytes32 asset, uint256 addedNumberOfAsset)
        public
        view
        override
        returns (uint256)
    {
        return ((totalSupply() + addedNumberOfAsset) * getAssetPrice(asset)) / Constants.PRECISION;
    }

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

    function getPortfolioBalance(bytes32 asset) public view returns (uint256) {
        return positions[asset].portfolioBalance;
    }

    function getUsdcPrice() public view override returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdcPriceFeed);

        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return uint256(price) * Constants.ADDITIONAL_FEED_PRECISION;
    }

    function getUsdValueOfAsset(bytes32 asset, uint256 rwaAmount) public view returns (uint256) {
        return (rwaAmount * getAssetPrice(asset)) / Constants.PRECISION;
    }

    function getUsdcValueofUsd(uint256 usdcValue) public view returns (uint256) {
        return (usdcValue * Constants.PRECISION) / getUsdcPrice();
    }

    // function getTotalUsdValue(bytes32 asset) external view returns (uint256) {}

    function getRequest(bytes32 requestId) external view override returns (RWARequest memory) {
        return requestIdToRequest[requestId];
    }

    function getWithdrawalAmount(bytes32 asset, address user) external view override returns (uint256) {
        return positions[asset].userToWithdrawAmount[user];
    }
}
