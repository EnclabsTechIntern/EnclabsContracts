// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import "../Interfaces/VBep20Interface.sol";
import "../Interfaces/OracleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../Governance/AccessControlledV8.sol";

/**
 * @title OneJumpOracleV2
 * @author Enclabs
 * @notice This oracle fetches prices of assets from the Chainlink oracle.
 */
contract OneJumpOracleV2 is AccessControlledV8, OracleInterface {
    struct TokenConfig {
        /// @notice Underlying token address, which can't be a null address
        /// @notice Used to check if a token is supported
        /// @notice 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB address for native tokens
        ///         (e.g BNB for BNB chain, ETH for Ethereum network)
        address asset;
        /// @notice Chainlink feed address
        address feed;
        /// @notice Underlying asset address
        address underlyingAsset;
        /// @notice Price expiration period of this asset in seconds
        uint256 maxStalePeriod;
    }

    /// @notice Address of Resilient Oracle
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    OracleInterface public immutable RESILIENT_ORACLE;

    /// @notice Set this as asset address for native token on each chain.
    /// This is the underlying address for vBNB on BNB chain or an underlying asset for a native market on any chain.
    address public constant NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    /// @notice Manually set an override price, useful under extenuating conditions such as price feed failure
    mapping(address => uint256) public prices;

    /// @notice Token config by assets
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Emit when a price is manually set
    event PricePosted(address indexed asset, uint256 previousPriceMantissa, uint256 newPriceMantissa);

    /// @notice Emit when a token config is added
    event TokenConfigAdded(address indexed asset, address feed, address underlyingAsset, uint256 maxStalePeriod);
    /// @notice Thrown if the token address is invalid
    error InvalidTokenAddress();
    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    /// @notice Constructor for the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address resilientOracle) {
        RESILIENT_ORACLE = OracleInterface(resilientOracle);
        _disableInitializers();
    }

    /**
     * @notice Initializes the owner of the contract
     * @param accessControlManager_ Address of the access control manager contract
     */
    function initialize(address accessControlManager_) external initializer {
        __AccessControlled_init(accessControlManager_);
    }

    /**
     * @notice Add multiple token configs at the same time
     * @param tokenConfigs_ config array
     * @custom:access Only Governance
     * @custom:error Zero length error thrown, if length of the array in parameter is 0
     */
    function setTokenConfigs(TokenConfig[] memory tokenConfigs_) external {
        if (tokenConfigs_.length == 0) revert("length can't be 0");
        uint256 numTokenConfigs = tokenConfigs_.length;
        for (uint256 i; i < numTokenConfigs; ) {
            setTokenConfig(tokenConfigs_[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Add single token config. asset & feed cannot be null addresses and maxStalePeriod must be positive
     * @param tokenConfig Token config struct
     * @custom:access Only Governance
     * @custom:error NotNullAddress error is thrown if asset address is null
     * @custom:error NotNullAddress error is thrown if token feed address is null
     * @custom:error Range error is thrown if maxStale period of token is not greater than zero
     * @custom:event Emits TokenConfigAdded event on successfully setting of the token config
     */
    function setTokenConfig(
        TokenConfig memory tokenConfig
    ) public notNullAddress(tokenConfig.asset) notNullAddress(tokenConfig.feed) {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");

        
        tokenConfigs[tokenConfig.asset] = tokenConfig;
        emit TokenConfigAdded(tokenConfig.asset, tokenConfig.feed, tokenConfig.underlyingAsset, tokenConfig.maxStalePeriod);
    }

    /**
     * @notice Gets the price of a asset from the chainlink oracle
     * @param asset Address of the asset
     * @return Price in USD from Chainlink or a manually set price for the asset
     */
    function getPrice(address asset) public view virtual returns (uint256) {
         if (address(tokenConfigs[asset].asset) == address(0)) revert InvalidTokenAddress();

        // get underlying token amount for 1 correlated token scaled by underlying token decimals
        uint256 underlyingAmount = _getUnderlyingAmount(tokenConfigs[asset].asset, tokenConfigs[asset].underlyingAsset);

        // oracle returns (36 - asset decimal) scaled price
        uint256 underlyingUSDPrice = RESILIENT_ORACLE.getPrice(tokenConfigs[asset].underlyingAsset);

        IERC20Metadata token = IERC20Metadata(tokenConfigs[asset].asset);
        uint256 decimals = token.decimals();

        // underlyingAmount (for 1 correlated token) * underlyingUSDPrice / decimals(correlated token)
        return (underlyingAmount * underlyingUSDPrice) / (10 ** decimals);
    }

    /**
     * @notice Gets the Chainlink price for a given asset
     * @param asset address of the asset
     * @param decimals decimals of the asset
     * @return price Asset price in USD or a manually set price of the asset
     */
    function _getPriceInternal(address asset, uint256 decimals) internal view returns (uint256 price) {
        uint256 tokenPrice = prices[asset];
        if (tokenPrice != 0) {
            price = tokenPrice;
        } else {
            price = _getChainlinkPrice(asset);
        }

        uint256 decimalDelta = 18 - decimals;
        return price * (10 ** decimalDelta);
    }

    /**
     * @notice Get the Chainlink price for an asset, revert if token config doesn't exist
     * @dev The precision of the price feed is used to ensure the returned price has 18 decimals of precision
     * @param asset Address of the asset
     * @return price Price in USD, with 18 decimals of precision
     * @custom:error NotNullAddress error is thrown if the asset address is null
     * @custom:error Price error is thrown if the Chainlink price of asset is not greater than zero
     * @custom:error Timing error is thrown if current timestamp is less than the last updatedAt timestamp
     * @custom:error Timing error is thrown if time difference between current time and last updated time
     * is greater than maxStalePeriod
     */
    function _getChainlinkPrice(
        address asset
    ) private view notNullAddress(tokenConfigs[asset].asset) returns (uint256) {
        TokenConfig memory tokenConfig = tokenConfigs[asset];
        AggregatorV3Interface feed = AggregatorV3Interface(tokenConfig.feed);

        // note: maxStalePeriod cannot be 0
        uint256 maxStalePeriod = tokenConfig.maxStalePeriod;

        // Chainlink USD-denominated feeds store answers at 8 decimals, mostly
        uint256 decimalDelta = 18 - feed.decimals();

        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        if (answer <= 0) revert("chainlink price must be positive");
        if (block.timestamp < updatedAt) revert("updatedAt exceeds block time");

        uint256 deltaTime;
        unchecked {
            deltaTime = block.timestamp - updatedAt;
        }

        if (deltaTime > maxStalePeriod) revert("chainlink price expired");

        return uint256(answer) * (10 ** decimalDelta);
    }

   /**
     * @notice Fetches the amount of the underlying token for 1 correlated token, using the intermediate oracle
     * @return amount The amount of the underlying token for 1 correlated token scaled by the underlying token decimals
     */
    function _getUnderlyingAmount(address asset, address underlyingAsset) internal view returns (uint256) {
        uint256 underlyingDecimals = IERC20Metadata(underlyingAsset).decimals();
        uint256 correlatedDecimals = IERC20Metadata(asset).decimals();

        //uint256 underlyingAmount = RESILIENT_ORACLE.getPrice(asset);
        uint256 underlyingAmount = _getPriceInternal(asset, correlatedDecimals);

        return (underlyingAmount * (10 ** correlatedDecimals)) / (10 ** (36 - underlyingDecimals));
    }
}
