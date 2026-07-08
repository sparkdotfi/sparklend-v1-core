// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IPool }                   from '../../../interfaces/IPool.sol';
import { IInitializableAToken }    from '../../../interfaces/IInitializableAToken.sol';
import { IInitializableDebtToken } from '../../../interfaces/IInitializableDebtToken.sol';

import {
  InitializableImmutableAdminUpgradeabilityProxy as Proxy
} from '../aave-upgradeability/InitializableImmutableAdminUpgradeabilityProxy.sol';

import { ReserveConfiguration }    from '../configuration/ReserveConfiguration.sol';
import { ReserveConfigurationMap } from '../types/DataTypes.sol';

import {
    InitReserveInput,
    UpdateATokenInput,
    UpdateDebtTokenInput
} from '../types/ConfiguratorInputTypes.sol';

/**
 * @title  ConfiguratorLogic library
 * @author Aave
 * @notice Implements the functions to initialize reserves and update aTokens and debtTokens
 */
library ConfiguratorLogic {

    using ReserveConfiguration for ReserveConfigurationMap;

    // See `IPoolConfigurator` for descriptions
    event ReserveInitialized(
        address indexed asset,
        address indexed aToken,
        address         stableDebtToken,
        address         variableDebtToken,
        address         interestRateStrategy
    );

    event ATokenUpgraded(
        address indexed asset,
        address indexed proxy,
        address indexed implementation
    );

    event StableDebtTokenUpgraded(
        address indexed asset,
        address indexed proxy,
        address indexed implementation
    );

    event VariableDebtTokenUpgraded(
        address indexed asset,
        address indexed proxy,
        address indexed implementation
    );

    /**
     * @notice Initialize a reserve by creating and initializing aToken, stable debt token and
     *         variable deb
     * @dev    Emits the `ReserveInitialized` event
     * @param  pool  The Pool in which the reserve will be initialized
     * @param  input The needed parameters for the initialization
     */
    function executeInitReserve(address pool, InitReserveInput calldata input) public {
        address aTokenProxy = _initTokenWithProxy(
            input.aTokenImplementation,
            abi.encodeWithSelector(
                IInitializableAToken.initialize.selector,
                pool,
                input.treasury,
                input.underlyingAsset,
                input.incentivesController,
                input.underlyingAssetDecimals,
                input.aTokenName,
                input.aTokenSymbol,
                input.params
            )
        );

        address stableDebtTokenProxy = _initTokenWithProxy(
            input.stableDebtTokenImplementation,
            abi.encodeWithSelector(
                IInitializableDebtToken.initialize.selector,
                pool,
                input.underlyingAsset,
                input.incentivesController,
                input.underlyingAssetDecimals,
                input.stableDebtTokenName,
                input.stableDebtTokenSymbol,
                input.params
            )
        );

        address variableDebtTokenProxy = _initTokenWithProxy(
            input.variableDebtTokenImplementation,
            abi.encodeWithSelector(
                IInitializableDebtToken.initialize.selector,
                pool,
                input.underlyingAsset,
                input.incentivesController,
                input.underlyingAssetDecimals,
                input.variableDebtTokenName,
                input.variableDebtTokenSymbol,
                input.params
            )
        );

        IPool(pool).initReserve(
            input.underlyingAsset,
            aTokenProxy,
            stableDebtTokenProxy,
            variableDebtTokenProxy,
            input.interestRateStrategy
        );

        ReserveConfigurationMap memory currentConfig = ReserveConfigurationMap(0);

        currentConfig.setDecimals(input.underlyingAssetDecimals);

        currentConfig.setActive(true);
        currentConfig.setPaused(false);
        currentConfig.setFrozen(false);

        IPool(pool).setConfiguration(input.underlyingAsset, currentConfig);

        emit ReserveInitialized(
            input.underlyingAsset,
            aTokenProxy,
            stableDebtTokenProxy,
            variableDebtTokenProxy,
            input.interestRateStrategy
        );
    }

    /**
     * @notice Updates the aToken implementation and initializes it
     * @dev    Emits the `ATokenUpgraded` event
     * @param  pool  The Pool containing the reserve with the aToken
     * @param  input The parameters needed for the initialize call
     */
    function executeUpdateAToken(address pool, UpdateATokenInput calldata input) public {
        address aToken = IPool(pool).getReserveData(input.asset).aToken;

        ( , , , uint256 decimals, , ) = IPool(pool).getConfiguration(input.asset).getParams();

        bytes memory encodedCall = abi.encodeWithSelector(
            IInitializableAToken.initialize.selector,
            pool,
            input.treasury,
            input.asset,
            input.incentivesController,
            decimals,
            input.name,
            input.symbol,
            input.params
        );

        _upgradeTokenImplementation(aToken, input.implementation, encodedCall);

        emit ATokenUpgraded(input.asset, aToken, input.implementation);
    }

    /**
     * @notice Updates the stable debt token implementation and initializes it
     * @dev    Emits the `StableDebtTokenUpgraded` event
     * @param  pool  The Pool containing the reserve with the stable debt token
     * @param  input The parameters needed for the initialize call
     */
    function executeUpdateStableDebtToken(
        address pool,
        UpdateDebtTokenInput calldata input
    ) public {
        address stableDebtToken = IPool(pool).getReserveData(input.asset).stableDebtToken;

        ( , , , uint256 decimals, , ) = IPool(pool).getConfiguration(input.asset).getParams();

        bytes memory encodedCall = abi.encodeWithSelector(
            IInitializableDebtToken.initialize.selector,
            pool,
            input.asset,
            input.incentivesController,
            decimals,
            input.name,
            input.symbol,
            input.params
        );

        _upgradeTokenImplementation(stableDebtToken, input.implementation, encodedCall);

        emit StableDebtTokenUpgraded(input.asset, stableDebtToken, input.implementation);
    }

    /**
     * @notice Updates the variable debt token implementation and initializes it
     * @dev    Emits the `VariableDebtTokenUpgraded` event
     * @param  pool  The Pool containing the reserve with the variable debt token
     * @param  input The parameters needed for the initialize call
     */
    function executeUpdateVariableDebtToken(
        address pool,
        UpdateDebtTokenInput calldata input
    ) public {
        address variableDebtToken = IPool(pool).getReserveData(input.asset).variableDebtToken;

        ( , , , uint256 decimals, , ) = IPool(pool).getConfiguration(input.asset).getParams();

        bytes memory encodedCall = abi.encodeWithSelector(
            IInitializableDebtToken.initialize.selector,
            pool,
            input.asset,
            input.incentivesController,
            decimals,
            input.name,
            input.symbol,
            input.params
        );

        _upgradeTokenImplementation(variableDebtToken, input.implementation, encodedCall);

        emit VariableDebtTokenUpgraded(input.asset, variableDebtToken, input.implementation);
    }

    /**
     * @notice Creates a new proxy and initializes it
     * @param  implementation The address of the implementation
     * @param  initParams     The parameters that is passed to the implementation to initialize
     * @return proxy          The address of initialized proxy
     */
    function _initTokenWithProxy(
        address        implementation,
        bytes   memory initParams
    ) internal returns (address proxy) {
        Proxy instance = new Proxy(address(this));

        instance.initialize(implementation, initParams);

        return address(instance);
    }

    /**
     * @notice Upgrades the implementation and makes call to the proxy
     * @dev    The call is used to initialize the new implementation.
     * @param  proxy          The address of the proxy
     * @param  implementation The address of the new implementation
     * @param  initParams     The parameters to the call after the upgrade
     */
    function _upgradeTokenImplementation(
        address        proxy,
        address        implementation,
        bytes   memory initParams
    ) internal {
        Proxy(payable(proxy)).upgradeToAndCall(implementation, initParams);
    }

}
