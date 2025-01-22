// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import "../Interfaces/VErc20Interface.sol";
import "../Interfaces/OracleInterface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";
import { IPendlePtOracle } from "../Interfaces/IPendlePtOracle.sol";

/**
 * @title PendlePtOracle
 * @author Enclabs
 * @notice This oracle fetches prices of assets from the Chainlink oracle.
 */
contract PendlePtOracle is AccessControlledV8, OracleInterface {
    struct TokenConfig {
     
        address ptToken;
       
        address market;
        
        address underlyingToken;
    }

    /// @notice Set this as asset address for native token on each chain.
    /// This is the underlying address for vBNB on BNB chain or an underlying asset for a native market on any chain.
    address public constant NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
    /// @notice Address of the PT oracle
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IPendlePtOracle public immutable PT_ORACLE;

    /// @notice Address of Resilient Oracle
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    OracleInterface public immutable RESILIENT_ORACLE;

    /// @notice Twap duration for the oracle
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable TWAP_DURATION;

    /// @notice Manually set an override price, useful under extenuating conditions such as price feed failure
    mapping(address => uint256) public prices;

    /// @notice Token config by assets
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Emit when a price is manually set
    event PricePosted(address indexed asset, uint256 previousPriceMantissa, uint256 newPriceMantissa);

    /// @notice Emit when a token config is added
    event TokenConfigAdded(address indexed asset, address feed, address maxStalePeriod);
    /// @notice Thrown if the token address is invalid
    error InvalidTokenAddress();
      /// @notice Thrown if the duration is invalid
    error InvalidDuration();
    modifier notNullAddress(address someone) {
        if (someone == address(0)) revert("can't be zero address");
        _;
    }

    /// @notice Constructor for the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address ptOracle, uint32 twapDuration, address resilientOracle) {
        PT_ORACLE = IPendlePtOracle(ptOracle);
        TWAP_DURATION = twapDuration;
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
    ) public notNullAddress(tokenConfig.ptToken) notNullAddress(tokenConfig.market) notNullAddress(tokenConfig.underlyingToken) {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");

        (bool increaseCardinalityRequired, , bool oldestObservationSatisfied) = PT_ORACLE.getOracleState(
            tokenConfig.market,
            TWAP_DURATION
        );
        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert InvalidDuration();
        }
        
        tokenConfigs[tokenConfig.ptToken] = tokenConfig;
        emit TokenConfigAdded(tokenConfig.ptToken, tokenConfig.market, tokenConfig.underlyingToken);
    }

    /**
     * @notice Fetches the price of the correlated token
     * @param asset Address of the correlated token
     * @return price The price of the correlated token in scaled decimal places
     */
    function getPrice(address asset) public view override returns (uint256) {
        if (address(tokenConfigs[asset].ptToken) == address(0)) revert InvalidTokenAddress();

        // get underlying token amount for 1 correlated token scaled by underlying token decimals
        uint256 underlyingAmount = _getUnderlyingAmount(tokenConfigs[asset].market);

        // oracle returns (36 - asset decimal) scaled price
        uint256 underlyingUSDPrice = RESILIENT_ORACLE.getPrice(tokenConfigs[asset].underlyingToken);

        IERC20Metadata token = IERC20Metadata(asset);
        uint256 decimals = token.decimals();

        // underlyingAmount (for 1 correlated token) * underlyingUSDPrice / decimals(correlated token)
        return (underlyingAmount * underlyingUSDPrice) / (10 ** decimals);
    }

    /**
     * @notice Fetches the amount of underlying token for 1 pendle token
     * @return amount The amount of underlying token for pendle token
     */
    function _getUnderlyingAmount(address market) internal view returns (uint256) {
        return PT_ORACLE.getPtToAssetRate(market, TWAP_DURATION);
    }

    
}
