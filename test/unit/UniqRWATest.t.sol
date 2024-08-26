// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployUniqRWA, UniqRWA} from "script/DeployUniqRWA.s.sol";
import {MockFunctionsRouter} from "test/mocks/MockFunctionsRouter.sol";
import {IGetRWAReturnTypes} from "src/interfaces/IGetRWAReturnTypes.sol";
import {IUniqRWA} from "src/interfaces/IUniqRWA.sol";
import {UniqWallet, IERC165, IERC1271, IUniqComWallet} from "src/UniqWallet.sol";
// import {RWAAssetData} from "src/UniqRWA.sol";

contract UniqRWATest is Test {
    DeployUniqRWA deployUniqRWA;

    address public nonOwner = makeAddr("nonOwner");
    uint256 public constant STARTING_PORTFOLIO_BALANCE = 100_000e18;

    UniqRWA public uniqRWA;
    MockFunctionsRouter public mockFunctionsRouter;

    event AssetAdded(bytes32 indexed asset, address indexed priceFeed);
    event MintRequest(bytes32 indexed requestId, uint256 amountTokensToMint);
    event RequestSent(bytes32 indexed requestId);

    function setUp() public {
        deployUniqRWA = new DeployUniqRWA();

        IGetRWAReturnTypes.GetRWAReturnType memory rwaReturnValues = deployUniqRWA.getRWARequirements();
        mockFunctionsRouter = MockFunctionsRouter(rwaReturnValues.functionsRouter);

        uniqRWA = deployUniqRWA.deployRWA(
            rwaReturnValues.subId,
            rwaReturnValues.assetName,
            rwaReturnValues.mintSource,
            rwaReturnValues.redeemSource,
            rwaReturnValues.functionsRouter,
            rwaReturnValues.donId,
            rwaReturnValues.rwaFeed,
            rwaReturnValues.usdcFeed,
            rwaReturnValues.redemptionCoin,
            rwaReturnValues.secretVersion,
            rwaReturnValues.secretSlot
        );
    }

    modifier balanceInitialized() {
        uint256 amountToRequest = 0;
        bytes32 asset = "TSLA";

        vm.prank(uniqRWA.owner());
        bytes32 requestId = uniqRWA.sendMintRequest(asset, amountToRequest);

        mockFunctionsRouter.handleOracleFulfillment(
            address(uniqRWA), requestId, abi.encodePacked(STARTING_PORTFOLIO_BALANCE), hex""
        );
        _;
    }

    function test_assetName_andPriceFeed() public view {
        (bytes32[] memory asset, address[] memory priceFeed) = uniqRWA.getAssetsData();

        assertEq(asset[0], bytes32("TSLA"));
        assertEq(priceFeed[0], 0x0401911641c4781D93c41f9aa8094B171368E6a9);
        // console2.log("Price Feed: ", priceFeed[0]);
    }

    function test_addAsset() public {
        bytes32 newAsset = "AAPL";
        // console2.log(vm.toString(newAsset));
        address newPriceFeed = 0x0715A7794a1dc8e42615F059dD6e406A6594651A;
        // console2.log(vm.toString(newPriceFeed));

        vm.prank(uniqRWA.owner());
        uniqRWA.addAsset(newAsset, newPriceFeed);

        (bytes32[] memory asset, address[] memory priceFeed) = uniqRWA.getAssetsData();

        assertEq(asset[1], newAsset);
        assertEq(priceFeed[1], newPriceFeed);
    }

    function test_EmitEvent_AddAsset() public {
        bytes32 newAsset = "AAPL";
        // console2.log(vm.toString(newAsset));
        address newPriceFeed = 0x0715A7794a1dc8e42615F059dD6e406A6594651A;
        // console2.log(vm.toString(newPriceFeed));

        vm.prank(uniqRWA.owner());
        vm.expectEmit(true, true, false, false);
        emit AssetAdded(newAsset, newPriceFeed);

        uniqRWA.addAsset(newAsset, newPriceFeed);

        (bytes32[] memory asset, address[] memory priceFeed) = uniqRWA.getAssetsData();
        assertEq(asset[1], newAsset);
        assertEq(priceFeed[1], newPriceFeed);

        // console2.log(vm.toString(newPriceFeed[1]));
    }

    function test_ExpectRevert_AddAsset() public {
        vm.prank(nonOwner);
        vm.expectRevert();

        uniqRWA.addAsset(bytes32("AAPL"), 0x0715A7794a1dc8e42615F059dD6e406A6594651A);
    }

    function test_canSendMintRequest_WithRWABalance() public {
        uint256 amountToRequest = 0;
        bytes32 asset = "TSLA";

        vm.prank(uniqRWA.owner());
        bytes32 requestId = uniqRWA.sendMintRequest(asset, amountToRequest);
        assert(requestId != 0);
    }

    function test_RevertNonOwner_sendMintRequest() public {
        uint256 amountToRequest = 0;
        bytes32 asset = "TSLA";

        vm.prank(nonOwner);
        vm.expectRevert();

        uniqRWA.sendMintRequest(asset, amountToRequest);
    }

    function test_mintFails_WithoutInitialBalance() public {
        uint256 amountToRequest = 1e18;
        bytes32 asset = "TSLA";

        vm.prank(uniqRWA.owner());
        vm.expectRevert(IUniqRWA.UniqRWA__NotEnoughCollateral.selector);
        uniqRWA.sendMintRequest(asset, amountToRequest);
    }

    function test_oracleCanUpdate_Portfolio() public {
        uint256 amountToRequest = 0;
        bytes32 asset = "TSLA";

        vm.prank(uniqRWA.owner());
        bytes32 requestId = uniqRWA.sendMintRequest(asset, amountToRequest);

        mockFunctionsRouter.handleOracleFulfillment(
            address(uniqRWA), requestId, abi.encodePacked(STARTING_PORTFOLIO_BALANCE), hex""
        );

        assert(uniqRWA.getPortfolioBalance(asset) == STARTING_PORTFOLIO_BALANCE);
    }

    function test_canMintAfter_PortfolioBalanceIsSet() public balanceInitialized {
        uint256 amountToRequest = 1e18;
        bytes32 asset = "TSLA";

        vm.prank(uniqRWA.owner());
        bytes32 requestId = uniqRWA.sendMintRequest(asset, amountToRequest);

        mockFunctionsRouter.handleOracleFulfillment(
            address(uniqRWA), requestId, abi.encodePacked(STARTING_PORTFOLIO_BALANCE), hex""
        );

        uint256 totalSupply = uniqRWA.totalSupply();
        console2.log("Total Supply: ", totalSupply);

        assert(uniqRWA.totalSupply() == amountToRequest);
    }
}
