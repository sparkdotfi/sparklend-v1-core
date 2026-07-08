// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/**
 * @title  IPoolAddressesProvider
 * @author Aave
 * @notice Defines the basic interface for a Pool Addresses Provider.
 */
interface IPoolAddressesProvider {

    /**
     * @dev   Emitted when the market identifier is updated.
     * @param oldMarketId The old id of the market
     * @param newMarketId The new id of the market
     */
    event MarketIdSet(string indexed oldMarketId, string indexed newMarketId);

    /**
     * @dev   Emitted when the pool is updated.
     * @param previous The old address of the Pool
     * @param current  The new address of the Pool
     */
    event PoolUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the pool configurator is updated.
     * @param previous The old address of the PoolConfigurator
     * @param current  The new address of the PoolConfigurator
     */
    event PoolConfiguratorUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the price oracle is updated.
     * @param previous The old address of the PriceOracle
     * @param current  The new address of the PriceOracle
     */
    event PriceOracleUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the ACL manager is updated.
     * @param previous The old address of the ACLManager
     * @param current  The new address of the ACLManager
     */
    event ACLManagerUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the ACL admin is updated.
     * @param previous The old address of the ACLAdmin
     * @param current  The new address of the ACLAdmin
     */
    event ACLAdminUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the price oracle sentinel is updated.
     * @param previous The old address of the PriceOracleSentinel
     * @param current  The new address of the PriceOracleSentinel
     */
    event PriceOracleSentinelUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the pool data provider is updated.
     * @param previous The old address of the PoolDataProvider
     * @param current  The new address of the PoolDataProvider
     */
    event PoolDataProviderUpdated(address indexed previous, address indexed current);

    /**
     * @dev   Emitted when a new proxy is created.
     * @param id             The identifier of the proxy
     * @param proxy          The address of the created proxy contract
     * @param implementation The address of the implementation contract
     */
    event ProxyCreated(
        bytes32 indexed id,
        address indexed proxy,
        address indexed implementation
    );

    /**
     * @dev   Emitted when a new non-proxied contract address is registered.
     * @param id       The identifier of the contract
     * @param previous The address of the old contract
     * @param current  The address of the new contract
     */
    event AddressSet(bytes32 indexed id, address indexed previous, address indexed current);

    /**
     * @dev   Emitted when the implementation of the proxy registered with id is updated
     * @param id                The identifier of the contract
     * @param proxy             The address of the proxy contract
     * @param oldImplementation The address of the old implementation contract
     * @param newImplementation The address of the new implementation contract
     */
    event AddressSetAsProxy(
        bytes32 indexed id,
        address indexed proxy,
        address         oldImplementation,
        address indexed newImplementation
    );

    /**
     * @notice Returns the id of the Aave market to which this contract points to.
     * @return id The market id
     */
    function getMarketId() external view returns (string memory id);

    /**
     * @notice Associates an id with a specific PoolAddressesProvider.
     * @dev    This can be used to create an onchain registry of PoolAddressesProviders to identify
     *         and validate multiple Aave markets.
     * @param  id The market id
     */
    function setMarketId(string calldata id) external;

    /**
     * @notice Returns an address by its identifier.
     * @dev    The returned address might be an EOA or a contract, potentially proxied
     * @dev    It returns ZERO if there is no registered address with the given id
     * @param  id    The id
     * @return value The address of the registered for the specified id
     */
    function getAddress(bytes32 id) external view returns (address value);

    /**
     * @notice General function to update the implementation of a proxy registered with certain
     *         `id`. If there is no proxy registered, it will instantiate one and set as
     *         implementation the `implementation`.
     * @dev    IMPORTANT Use this function carefully, only for ids that don't have an explicit
     *         setter function, in order to avoid unexpected consequences
     * @param  id             The id
     * @param  implementation The address of the new implementation
     */
    function setAddressAsProxy(bytes32 id, address implementation) external;

    /**
     * @notice Sets an address for an id replacing the address saved in the addresses map.
     * @dev    IMPORTANT Use this function carefully, as it will do a hard replacement
     * @param  id    The id
     * @param  value The address to set
     */
    function setAddress(bytes32 id, address value) external;

    /**
     * @notice Returns the address of the Pool proxy.
     * @return pool The Pool proxy address
     */
    function getPool() external view returns (address pool);

    /**
     * @notice Updates the implementation of the Pool, or creates a proxy setting the new `pool`
     *         implementation when the function is called for the first time.
     * @param  implementation The new Pool implementation
     */
    function setPoolImpl(address implementation) external;

    /**
     * @notice Returns the address of the PoolConfigurator proxy.
     * @return configurator The PoolConfigurator proxy address
     */
    function getPoolConfigurator() external view returns (address configurator);

    /**
     * @notice Updates the implementation of the PoolConfigurator, or creates a proxy setting the
     *         new `PoolConfigurator` implementation when the function is called for the first time.
     * @param  implementation The new PoolConfigurator implementation
     */
    function setPoolConfiguratorImpl(address implementation) external;

    /**
     * @notice Returns the address of the price oracle.
     * @return oracle The address of the PriceOracle
     */
    function getPriceOracle() external view returns (address oracle);

    /**
     * @notice Updates the address of the price oracle.
     * @param  oracle The address of the new PriceOracle
     */
    function setPriceOracle(address oracle) external;

    /**
     * @notice Returns the address of the ACL manager.
     * @return manager The address of the ACLManager
     */
    function getACLManager() external view returns (address manager);

    /**
     * @notice Updates the address of the ACL manager.
     * @param  manager The address of the new ACLManager
     */
    function setACLManager(address manager) external;

    /**
     * @notice Returns the address of the ACL admin.
     * @return admin The address of the ACL admin
     */
    function getACLAdmin() external view returns (address admin);

    /**
     * @notice Updates the address of the ACL admin.
     * @param  admin The address of the new ACL admin
     */
    function setACLAdmin(address admin) external;

    /**
     * @notice Returns the address of the price oracle sentinel.
     * @return sentinel The address of the PriceOracleSentinel
     */
    function getPriceOracleSentinel() external view returns (address sentinel);

    /**
     * @notice Updates the address of the price oracle sentinel.
     * @param  sentinel The address of the new PriceOracleSentinel
     */
    function setPriceOracleSentinel(address sentinel) external;

    /**
     * @notice Returns the address of the data provider.
     * @return provider The address of the DataProvider
     */
    function getPoolDataProvider() external view returns (address provider);

    /**
     * @notice Updates the address of the data provider.
     * @param  provider The address of the new DataProvider
     */
    function setPoolDataProvider(address provider) external;

}
