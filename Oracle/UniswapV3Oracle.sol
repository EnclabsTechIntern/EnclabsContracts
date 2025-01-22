// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import "../Interfaces/VErc20Interface.sol";
import "../Interfaces/OracleInterface.sol";
import "../Governance/AccessControlledV8.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {BaseAdapter, Errors} from "./BaseAdapter.sol";

/// @title UniswapV3Oracle
/// @author Enclabs
/// @notice Adapter for Uniswap V3's TWAP oracle.
/// WARNING: READ THIS BEFORE DEPLOYING
/// Do not use Uniswap V3 as an oracle unless you understand its security implications.
/// Instead, consider using another provider as a primary price source.
/// Under PoS a validator may be chosen to propose consecutive blocks, allowing risk-free multi-block manipulation.
/// The cardinality of the observation buffer must be grown sufficiently to accommodate for the chosen TWAP window.
/// The observation buffer must contain enough observations to accommodate for the chosen TWAP window.
/// The chosen pool must have enough total liquidity and some full-range liquidity to resist manipulation.
/// The chosen pool must have had sufficient liquidity when past observations were recorded in the buffer.
/// Networks with short block times are highly susceptible to TWAP manipulation due to the reduced attack cost.
contract UniswapV3Oracle is BaseAdapter, AccessControlledV8, OracleInterface {
    struct TokenConfig {
    /// @notice The first token in the pool. 
    address  tokenA;
    /// @notice The other token in the pool.
    address  tokenB;
    /// @notice The fee tier of the pool.
    uint24  fee;
    /// @notice The desired length of the twap window.
    uint32  twapWindow;
    /// @notice The token that is being priced. Either `tokenA` or `tokenB`.
    address baseToken;
    /// @notice The token that is the unit of account. Either `tokenB` or `tokenA`.
    address quoteToken;
    /// @notice The pool address
    address pool;
    }

    /// @notice Address of Resilient Oracle
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    OracleInterface public immutable RESILIENT_ORACLE;

    /// @dev The minimum length of the TWAP window.
    uint32 internal constant MIN_TWAP_WINDOW = 5 minutes;

    /// @notice Set this as asset address for native token on each chain.
    /// This is the underlying address for vETH on ETH chain or an underlying asset for a native market on any chain.
    address public constant NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;

    /// @notice Address of Uniswap V3 Factory
    address public immutable uniswapV3Factory;
    
    /// @notice Manually set an override price, useful under extenuating conditions such as price feed failure
    mapping(address => uint256) public prices;

    /// @notice Token config by assets
    mapping(address => TokenConfig) public tokenConfigs;

    /// @notice Emit when a price is manually set
    event PricePosted(address indexed asset, uint256 previousPriceMantissa, uint256 newPriceMantissa);

    /// @notice Emit when a token config is added
    event TokenConfigAdded( address baseToken, address quoteToken, address tokenA, address tokenB, uint24 fee, uint32 twapWindow, address pool);
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
    constructor(address _uniswapV3Factory, address resilientOracle) {
        uniswapV3Factory = _uniswapV3Factory;
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
     * @custom:error NotNullAddress error is thrown if tokenA address is null
     * @custom:error NotNullAddress error is thrown if tokenB address is null
     * @custom:error Range error is thrown if maxStale period of token is not greater than zero
     * @custom:event Emits TokenConfigAdded event on successfully setting of the token config
     */
    function setTokenConfig(
        TokenConfig memory tokenConfig
    ) public notNullAddress(tokenConfig.tokenA) notNullAddress(tokenConfig.tokenB) notNullAddress(tokenConfig.baseToken) notNullAddress(tokenConfig.quoteToken) {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");
        if (tokenConfig.fee > 10000 || tokenConfig.fee < 0) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }

        if (tokenConfig.twapWindow < MIN_TWAP_WINDOW || tokenConfig.twapWindow > uint32(type(int32).max)) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }
        
        tokenConfig.pool = IUniswapV3Factory(uniswapV3Factory).getPool(tokenConfig.tokenA, tokenConfig.tokenB, tokenConfig.fee);
        if (tokenConfig.pool == address(0)) revert Errors.PriceOracle_InvalidConfiguration();

        tokenConfigs[tokenConfig.baseToken] = tokenConfig;
        emit TokenConfigAdded(tokenConfig.baseToken,tokenConfig.quoteToken,tokenConfig.tokenA,tokenConfig.tokenB,tokenConfig.fee,tokenConfig.twapWindow,tokenConfig.pool);
    }

    /**
     * @notice Fetches the price of the correlated token
     * @param asset Address of the correlated token
     * @return price The price of the correlated token in scaled decimal places
     */
    function getPrice(address asset) public view override returns (uint256) {
        if (address(tokenConfigs[asset].baseToken) == address(0)) revert InvalidTokenAddress();

        IERC20Metadata token = IERC20Metadata(tokenConfigs[asset].baseToken);
        uint256 decimals = token.decimals();

        // get underlying token amount for 1 correlated token scaled by underlying token decimals
        uint256 underlyingAmount = _getQuote(10 ** decimals, tokenConfigs[asset].baseToken, tokenConfigs[asset].quoteToken, tokenConfigs[asset].twapWindow);

        // oracle returns (36 - asset decimal) scaled price
        uint256 underlyingUSDPrice = RESILIENT_ORACLE.getPrice(tokenConfigs[asset].quoteToken);

        // underlyingAmount (for 1 correlated token) * underlyingUSDPrice / decimals(correlated token)
        return (underlyingAmount * underlyingUSDPrice) / (10 ** decimals);
    }

     /// @notice Get a quote by calling the pool's TWAP oracle.
    /// @param inAmount The amount of `base` to convert.
    /// @param base The token that is being priced. Either `tokenA` or `tokenB`.
    /// @param quote The token that is the unit of account. Either `tokenB` or `tokenA`.
    /// @return The converted amount.
    function _getQuote(uint256 inAmount, address base, address quote, uint32 twapWindow) internal view returns (uint256) {
        // Size limitation enforced by the pool.
        if (inAmount > type(uint128).max) revert Errors.PriceOracle_Overflow();

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;

        // Calculate the mean tick over the twap window.
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(tokenConfigs[base].pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 tick = int24(tickCumulativesDelta / int56(uint56(twapWindow)));
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(twapWindow)) != 0)) tick--;
        return OracleLibrary.getQuoteAtTick(tick, uint128(inAmount), base, quote);
    }
}