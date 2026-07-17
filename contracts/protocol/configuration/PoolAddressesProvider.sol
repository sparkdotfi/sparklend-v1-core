// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { Ownable } from '../../dependencies/openzeppelin/contracts/Ownable.sol';

import { IPoolAddressesProvider } from '../../interfaces/IPoolAddressesProvider.sol';

import {
    InitializableImmutableAdminUpgradeabilityProxy as Proxy
} from '../libraries/aave-upgradeability/InitializableImmutableAdminUpgradeabilityProxy.sol';

/**
 * @title  PoolAddressesProvider
 * @author Aav
 * @notice Main registry of addresses part of or connected to the protocol, including permissioned roles
 * @dev    Acts as factory of proxies and admin of those, so with right to change its implementations
 * @dev    Owned by the Aave Governance
 */
contract PoolAddressesProvider is IPoolAddressesProvider, Ownable {

    // Identifier of the Aave Market
    string private _marketId;

    // Map of registered addresses (identifier => registeredAddress)
    mapping(bytes32 => address) private _addresses;

    // Main identifiers
    bytes32 private constant POOL                  = 'POOL';
    bytes32 private constant POOL_CONFIGURATOR     = 'POOL_CONFIGURATOR';
    bytes32 private constant PRICE_ORACLE          = 'PRICE_ORACLE';
    bytes32 private constant ACL_MANAGER           = 'ACL_MANAGER';
    bytes32 private constant ACL_ADMIN             = 'ACL_ADMIN';
    bytes32 private constant PRICE_ORACLE_SENTINEL = 'PRICE_ORACLE_SENTINEL';
    bytes32 private constant DATA_PROVIDER         = 'DATA_PROVIDER';

    /**
     * @dev   Constructor.
     * @param marketId The identifier of the market.
     * @param owner    The owner address of this contract.
     */
    constructor(string memory marketId, address owner) {
        _setMarketId(marketId);
        transferOwnership(owner);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getMarketId() external view override returns (string memory) {
        return _marketId;
    }

    /// @inheritdoc IPoolAddressesProvider
    function setMarketId(string memory marketId) external override onlyOwner {
        _setMarketId(marketId);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getAddress(bytes32 id) public view override returns (address) {
        return _addresses[id];
    }

    /// @inheritdoc IPoolAddressesProvider
    function setAddress(bytes32 id, address newAddress) external override onlyOwner {
        address previous = _addresses[id];

        emit AddressSet(id, previous, _addresses[id] = newAddress);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setAddressAsProxy(bytes32 id, address newImplementation) external override onlyOwner {
        address proxy             = _addresses[id];
        address oldImplementation = _getProxyImplementation(id);

        _updateImplementation(id, newImplementation);

        emit AddressSetAsProxy(id, proxy, oldImplementation, newImplementation);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPool() external view override returns (address) {
        return getAddress(POOL);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setPoolImpl(address newImplementation) external override onlyOwner {
        address oldImplementation = _getProxyImplementation(POOL);

        _updateImplementation(POOL, newImplementation);

        emit PoolUpdated(oldImplementation, newImplementation);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPoolConfigurator() external view override returns (address) {
        return getAddress(POOL_CONFIGURATOR);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setPoolConfiguratorImpl(address newImplementation) external override onlyOwner {
        address oldImplementation = _getProxyImplementation(POOL_CONFIGURATOR);

        _updateImplementation(POOL_CONFIGURATOR, newImplementation);

        emit PoolConfiguratorUpdated(oldImplementation, newImplementation);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPriceOracle() external view override returns (address) {
        return getAddress(PRICE_ORACLE);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setPriceOracle(address newOracle) external override onlyOwner {
        address oldOracle = _addresses[PRICE_ORACLE];

        emit PriceOracleUpdated(oldOracle, _addresses[PRICE_ORACLE] = newOracle);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getACLManager() external view override returns (address) {
        return getAddress(ACL_MANAGER);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setACLManager(address newManager) external override onlyOwner {
        address oldManager = _addresses[ACL_MANAGER];

        emit ACLManagerUpdated(oldManager, _addresses[ACL_MANAGER] = newManager);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getACLAdmin() external view override returns (address) {
        return getAddress(ACL_ADMIN);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setACLAdmin(address newAdmin) external override onlyOwner {
        address oldAdmin = _addresses[ACL_ADMIN];

        emit ACLAdminUpdated(oldAdmin, _addresses[ACL_ADMIN] = newAdmin);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPriceOracleSentinel() external view override returns (address) {
        return getAddress(PRICE_ORACLE_SENTINEL);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setPriceOracleSentinel(address newSentinel) external override onlyOwner {
        address oldSentinel = _addresses[PRICE_ORACLE_SENTINEL];

        _addresses[PRICE_ORACLE_SENTINEL] = newSentinel;

        emit PriceOracleSentinelUpdated(oldSentinel, newSentinel);
    }

    /// @inheritdoc IPoolAddressesProvider
    function getPoolDataProvider() external view override returns (address) {
        return getAddress(DATA_PROVIDER);
    }

    /// @inheritdoc IPoolAddressesProvider
    function setPoolDataProvider(address newProvider) external override onlyOwner {
        address oldProvider = _addresses[DATA_PROVIDER];

        emit PoolDataProviderUpdated(oldProvider, _addresses[DATA_PROVIDER] = newProvider);
    }

    /**
     * @notice Internal function to update the implementation of a specific proxied component of the
     *         protocol.
     * @dev    If there is no proxy registered with the given identifier, it creates the proxy
     *         setting `implementation` as implementation and calls the initialize() function on the
     *         proxy
     * @dev    If there is already a proxy registered, it just updates the implementation to
     *         `implementation` and calls the initialize() function via upgradeToAndCall() in the
     *         proxy
     * @param  id             The id of the proxy to be updated
     * @param  implementation The address of the new implementation
     */
    function _updateImplementation(bytes32 id, address implementation) internal {
        address proxy = _addresses[id];

        bytes memory params = abi.encodeWithSignature('initialize(address)', address(this));

        if (proxy != address(0)) {
            return Proxy(payable(proxy)).upgradeToAndCall(implementation, params);
        }

        Proxy instance = new Proxy(address(this));

        instance.initialize(implementation, params);

        emit ProxyCreated(id, _addresses[id] = address(instance), implementation);
    }

    /**
     * @notice Updates the identifier of the Aave market.
     * @param  marketId The new id of the market
     */
    function _setMarketId(string memory marketId) internal {
        string memory oldMarketId = _marketId;

        emit MarketIdSet(oldMarketId, _marketId = marketId);
    }

    /**
     * @notice Returns the the implementation contract of the proxy contract by its identifier.
     * @dev    It returns ZERO if there is no registered address with the given id
     * @dev    It reverts if the registered address with the given id is not `Proxy`
     * @param  id             The id
     * @return implementation The address of the implementation contract
     */
    function _getProxyImplementation(bytes32 id) internal returns (address implementation) {
        address proxy = _addresses[id];

        return proxy == address(0) ? address(0) : Proxy(payable(proxy)).implementation();
    }

}
