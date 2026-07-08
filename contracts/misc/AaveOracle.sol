// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { AggregatorInterface }    from '../dependencies/chainlink/AggregatorInterface.sol';
import { Errors }                 from '../protocol/libraries/helpers/Errors.sol';
import { IACLManager }            from '../interfaces/IACLManager.sol';
import { IPoolAddressesProvider } from '../interfaces/IPoolAddressesProvider.sol';
import { IPriceOracleGetter }     from '../interfaces/IPriceOracleGetter.sol';
import { IAaveOracle }            from '../interfaces/IAaveOracle.sol';

/**
 * @title  AaveOracle
 * @author Aave
 * @notice Contract to get asset prices, manage price sources and update the fallback oracle
 *           - Use of Chainlink Aggregators as first source of price
 *           - If the returned price by a Chainlink aggregator is <= 0, the call is forwarded to a
 *             fallback oracle
 *           - Owned by the Aave governance
 */
contract AaveOracle is IAaveOracle {

    address public immutable ADDRESSES_PROVIDER;

    // Map of asset price sources (asset => priceSource)
    mapping(address => AggregatorInterface) private assetsSources;

    address private _fallbackOracle;

    address public immutable override BASE_CURRENCY;

    uint256 public immutable override BASE_CURRENCY_UNIT;

    /**
     * @dev Only asset listing or pool admin can call functions marked by this modifier.
     */
    modifier onlyAssetListingOrPoolAdmins() {
        _onlyAssetListingOrPoolAdmins();
        _;
    }

    /**
     * @notice Constructor
     * @param  provider         The address of the new PoolAddressesProvider
     * @param  assets           The addresses of the assets
     * @param  sources          The address of the source of each asset
     * @param  fallbackOracle   The address of the fallback oracle to use if the data of an
     *                          aggregator is not consistent
     * @param  baseCurrency     The base currency used for the price quotes. If USD is used, base
     *                          currency is 0x0
     * @param  baseCurrencyUnit The unit of the base currency
     */
    constructor(
        address          provider,
        address[] memory assets,
        address[] memory sources,
        address          fallbackOracle,
        address          baseCurrency,
        uint256          baseCurrencyUnit
    ) {
        ADDRESSES_PROVIDER = provider;

        _setFallbackOracle(fallbackOracle);
        _setAssetsSources(assets, sources);

        BASE_CURRENCY      = baseCurrency;
        BASE_CURRENCY_UNIT = baseCurrencyUnit;

        emit BaseCurrencySet(baseCurrency, baseCurrencyUnit);
    }

    /// @inheritdoc IAaveOracle
    function setAssetSources(
        address[] calldata assets,
        address[] calldata sources
    ) external override onlyAssetListingOrPoolAdmins {
        _setAssetsSources(assets, sources);
    }

    /// @inheritdoc IAaveOracle
    function setFallbackOracle(
        address fallbackOracle
    ) external override onlyAssetListingOrPoolAdmins {
        _setFallbackOracle(fallbackOracle);
    }

    /**
     * @notice Internal function to set the sources for each asset
     * @param  assets  The addresses of the assets
     * @param  sources The address of the source of each asset
     */
    function _setAssetsSources(address[] memory assets, address[] memory sources) internal {
        require(assets.length == sources.length, Errors.INCONSISTENT_PARAMS_LENGTH);

        for (uint256 i = 0; i < assets.length; i++) {
            assetsSources[assets[i]] = AggregatorInterface(sources[i]);

            emit AssetSourceUpdated(assets[i], sources[i]);
        }
    }

    /**
     * @notice Internal function to set the fallback oracle
     * @param  fallbackOracle The address of the fallback oracle
     */
    function _setFallbackOracle(address fallbackOracle) internal {
        _fallbackOracle = fallbackOracle;

        emit FallbackOracleUpdated(fallbackOracle);
    }

    /// @inheritdoc IPriceOracleGetter
    function getAssetPrice(address asset) public view override returns (uint256) {
        AggregatorInterface source = assetsSources[asset];

        if (asset == BASE_CURRENCY) return BASE_CURRENCY_UNIT;

        if (address(source) == address(0)) {
            return IPriceOracleGetter(_fallbackOracle).getAssetPrice(asset);
        }

        int256 price = source.latestAnswer();

        return
            price > 0 ? uint256(price) : IPriceOracleGetter(_fallbackOracle).getAssetPrice(asset);
    }

    /// @inheritdoc IAaveOracle
    function getAssetsPrices(
        address[] calldata assets
    ) external view override returns (uint256[] memory prices) {
        prices = new uint256[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = getAssetPrice(assets[i]);
        }
    }

    /// @inheritdoc IAaveOracle
    function getSourceOfAsset(address asset) external view override returns (address) {
        return address(assetsSources[asset]);
    }

    /// @inheritdoc IAaveOracle
    function getFallbackOracle() external view returns (address) {
        return address(_fallbackOracle);
    }

    function _onlyAssetListingOrPoolAdmins() internal view {
        IACLManager aclManager =
            IACLManager(IPoolAddressesProvider(ADDRESSES_PROVIDER).getACLManager());

        require(
            aclManager.isAssetListingAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_ASSET_LISTING_OR_POOL_ADMIN
        );
    }

}
