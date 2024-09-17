// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

/**
 * @title Constants
 * @notice Constants used in the Hook contract
 */
library Constants {
    /// @notice The gas limit for minting
    uint32 constant GAS_LIMIT = 300_000;

    /// @notice The minimum redemption price
    uint256 constant MIN_REDEMPTION_PRICE = 100e18;

    /// @notice Additional precision for 6e18 to avoid rounding errors
    uint256 constant ADDITIONAL_FEED_PRECISION = 1e10;

    /// @notice Portfolio precision for 1e18
    uint256 constant PORTFOLIO_PRECISION = 1e18;

    /// @notice The collateral ratio for the UniComNFT contract
    uint256 constant COLLATERAL_RATIO = 200; // 200%

    /// @notice The collateral precision
    uint256 constant COLLATERAL_PRECISION = 100;

    /// @notice The target decimals for the Hook contract
    uint256 constant TARGET_DECIMALS = 18;

    /// @notice The precision for the Hook contract
    uint256 constant PRECISION = 1e18;

    /// @notice Access Role for NFT
    bytes32 constant UNIQCOMNFT_ROLE = keccak256("UNICOMNFT_ROLE");

    /// @notice The signing domain for Wallet
    string constant SIGNING_DOMAIN = "UniComNFT";

    /// @notice The signature version for Wallet
    string constant SIGNATURE_VERSION = "1";

    /// @notice The UniWallet function signature
    bytes4 constant UNIQWALLET = bytes4(keccak256("UniWallet()"));

    /// @notice zero bytes32
    bytes32 constant ZERO_BYTES32 = bytes32("");

    /// @notice zero bytes
    bytes constant ZERO_BYTES = bytes("");

    /// @notice The minimum delta for the Hook contract
    int256 constant MIN_DELTA = -1;

    /// @notice bool for zeroForOne for the Hook contract
    bool constant ZERO_FOR_ONE = true;

    /// @notice bool for oneForZero for the Hook contract
    bool constant ONE_FOR_ZERO = false;

    /// @notice The slot for the Pool
    uint256 constant POOL_SLOT = 10;

    /// @notice Offset for the Pool
    uint256 constant TICKS_OFFSET = 4;

    /// @notice Offset for the Pool Bitmap
    uint256 constant TICK_BITMAP_OFFSET = 5;

    uint256 public constant SMOOTHING_FACTOR = 10;

    uint256 public constant MAX_VOLATILITY_CHANGE_PCT = 20 * 1e16; // 20%

    uint24 public constant BASE_FEE = 200; // 2bps

    uint24 public constant MIN_FEE = 50; // 0.5bps

    uint24 public constant MAX_FEE = 1000; // 10bps

    uint256 public constant VOLATILITY_MULTIPLIER = 10; // 1% increase in fee per 10% increase in volatility

    uint256 public constant VOLATILITY_FACTOR = 1e26;

    uint24 public constant HOOK_COMMISSION = 100; // 1bps paid to the hook to cover Brevis costs

    address constant SEPOLIA_FUNCTION_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
}
