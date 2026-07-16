// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }            from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { GPv2SafeERC20 }     from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { IAToken }           from '../../../interfaces/IAToken.sol';
import { Errors }            from '../helpers/Errors.sol';
import { UserConfiguration } from '../configuration/UserConfiguration.sol';

import {
    EModeCategory,
    ExecuteSupplyParams,
    ExecuteWithdrawParams,
    FinalizeTransferParams,
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../types/DataTypes.sol';

import { WadRayMath }           from '../math/WadRayMath.sol';
import { PercentageMath }       from '../math/PercentageMath.sol';
import { ValidationLogic }      from './ValidationLogic.sol';
import { ReserveLogic }         from './ReserveLogic.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';

/**
 * @title  SupplyLogic library
 * @author Aave
 * @notice Implements the base logic for supply/withdraw
 */
library SupplyLogic {

    using ReserveLogic         for ReserveCache;
    using ReserveLogic         for ReserveData;
    using GPv2SafeERC20        for IERC20;
    using UserConfiguration    for UserConfigurationMap;
    using ReserveConfiguration for ReserveConfigurationMap;
    using WadRayMath           for uint256;
    using PercentageMath       for uint256;

    // See `IPool` for descriptions
    event ReserveUsedAsCollateralEnabled(address indexed reserve, address indexed user);

    event ReserveUsedAsCollateralDisabled(address indexed reserve, address indexed user);

    event Withdraw(
        address indexed reserve,
        address indexed user,
        address indexed to,
        uint256         amount
    );

    event Supply(
        address indexed reserve,
        address         user,
        address indexed onBehalfOf,
        uint256         amount,
        uint16  indexed referralCode
    );

    /**
     * @notice Implements the supply feature. Through `supply()`, users supply assets to the Aave
     *         protocol.
     * @dev    Emits the `Supply()` event.
     * @dev    In the first supply action, `ReserveUsedAsCollateralEnabled()` is emitted, if the
     *         asset can be enabled as collateral.
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  userConfig   The user configuration mapping that tracks the supplied/borrowed assets
     * @param  params       The additional parameters needed to execute the supply function
     */
    function executeSupply(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        UserConfigurationMap             storage userConfig,
        ExecuteSupplyParams              memory  params
    ) external {
        ReserveData storage reserveData = reservesData[params.asset];

        ReserveCache memory reserveCache = reserveData.cache();

        reserveData.updateState(reserveCache);
        ValidationLogic.validateSupply(reserveCache, reserveData, params.amount);
        reserveData.updateInterestRates(reserveCache, params.asset, params.amount, 0);

        IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aToken, params.amount);

        bool isFirstSupply =
            IAToken(reserveCache.aToken).mint(
                msg.sender,
                params.onBehalfOf,
                params.amount,
                reserveCache.nextLiquidityIndex
            );

        if (
            isFirstSupply &&
            ValidationLogic.validateAutomaticUseAsCollateral(
                reservesData,
                reservesList,
                userConfig,
                reserveCache.reserveConfiguration,
                reserveCache.aToken
            )
        ) {
            userConfig.setUsingAsCollateral(reserveData.id, true);
            emit ReserveUsedAsCollateralEnabled(params.asset, params.onBehalfOf);
        }

        emit Supply(
            params.asset,
            msg.sender,
            params.onBehalfOf,
            params.amount,
            params.referralCode
        );
    }

    /**
     * @notice Implements the withdraw feature. Through `withdraw()`, users redeem their aTokens for
     *         the underlying asset previously supplied in the Aave protocol.
     * @dev    Emits the `Withdraw()` event.
     * @dev    If the user withdraws everything, `ReserveUsedAsCollateralDisabled()` is emitted.
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  eModeCategories The configuration of all the efficiency mode categories
     * @param  userConfig The user configuration mapping that tracks the supplied/borrowed assets
     * @param  params The additional parameters needed to execute the withdraw function
     * @return withdrawal The actual amount withdrawn
     */
    function executeWithdraw(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        UserConfigurationMap             storage userConfig,
        ExecuteWithdrawParams            memory  params
    ) external returns (uint256 withdrawal) {
        ReserveData storage reserveData = reservesData[params.asset];

        ReserveCache memory reserveCache = reserveData.cache();

        reserveData.updateState(reserveCache);

        uint256 userBalance =
            IAToken(reserveCache.aToken)
                .scaledBalanceOf(msg.sender)
                .rayMul(reserveCache.nextLiquidityIndex);

        withdrawal = params.amount;

        if (params.amount == type(uint256).max) {
            withdrawal = userBalance;
        }

        ValidationLogic.validateWithdraw(reserveCache, withdrawal, userBalance);
        reserveData.updateInterestRates(reserveCache, params.asset, 0, withdrawal);

        bool isCollateral = userConfig.isUsingAsCollateral(reserveData.id);

        if (isCollateral && withdrawal == userBalance) {
            userConfig.setUsingAsCollateral(reserveData.id, false);

            emit ReserveUsedAsCollateralDisabled(params.asset, msg.sender);
        }

        IAToken(reserveCache.aToken).burn(
            msg.sender,
            params.to,
            withdrawal,
            reserveCache.nextLiquidityIndex
        );

        if (isCollateral && userConfig.isBorrowingAny()) {
            ValidationLogic.validateHFAndLtv(
                reservesData,
                reservesList,
                eModeCategories,
                userConfig,
                params.asset,
                msg.sender,
                params.reservesCount,
                params.oracle,
                params.userEModeCategory
            );
        }

        emit Withdraw(params.asset, msg.sender, params.to, withdrawal);
    }

    /**
     * @notice Validates a transfer of aTokens. The sender is subjected to health factor validation
     *         to avoid collateralization constraints violation.
     * @dev    Emits the `ReserveUsedAsCollateralEnabled()` event for the `to` account, if the asset
     *         is being activated as collateral.
     * @dev    In case the `from` user transfers everything, `ReserveUsedAsCollateralDisabled()` is
     *         emitted for `from`.
     * @param  reservesData    The state of all the reserves
     * @param  reservesList    The addresses of all the active reserves
     * @param  eModeCategories The configuration of all the efficiency mode categories
     * @param  usersConfig     The users configuration mapping that track the supplied/borrowed
     *                         assets
     * @param  params          The additional parameters needed to execute the finalizeTransfer
     *                         function
     */
    function executeFinalizeTransfer(
        mapping (address => ReserveData)          storage reservesData,
        mapping (uint256 => address)              storage reservesList,
        mapping (uint8 => EModeCategory)          storage eModeCategories,
        mapping (address => UserConfigurationMap) storage usersConfig,
        FinalizeTransferParams                    memory  params
    ) external {
        ReserveData storage reserveData = reservesData[params.asset];

        ValidationLogic.validateTransfer(reserveData);

        if ((params.from == params.to) || (params.amount == 0)) return;

        uint256 reserveId = reserveData.id;

        UserConfigurationMap storage fromConfig = usersConfig[params.from];

        if (fromConfig.isUsingAsCollateral(reserveId)) {
            if (fromConfig.isBorrowingAny()) {
                ValidationLogic.validateHFAndLtv(
                    reservesData,
                    reservesList,
                    eModeCategories,
                    usersConfig[params.from],
                    params.asset,
                    params.from,
                    params.reservesCount,
                    params.oracle,
                    params.fromEModeCategory
                );
            }

            if (params.balanceFromBefore == params.amount) {
                fromConfig.setUsingAsCollateral(reserveId, false);

                emit ReserveUsedAsCollateralDisabled(params.asset, params.from);
            }
        }

        if (params.balanceToBefore == 0) {
            UserConfigurationMap storage toConfig = usersConfig[params.to];

            if (
                ValidationLogic.validateAutomaticUseAsCollateral(
                    reservesData,
                    reservesList,
                    toConfig,
                    reserveData.configuration,
                    reserveData.aToken
                )
            ) {
                toConfig.setUsingAsCollateral(reserveId, true);

                emit ReserveUsedAsCollateralEnabled(params.asset, params.to);
            }
        }
    }

    /**
     * @notice Executes the 'set as collateral' feature. A user can choose to activate or deactivate
     *         an asset as collateral at any point in time. Deactivating an asset as collateral is
     *         subjected to the usual health factor checks to ensure collateralization.
     * @dev    Emits the `ReserveUsedAsCollateralEnabled()` event if the asset can be activated as
     *         collateral.
     * @dev    In case the asset is being deactivated as collateral,
     *         `ReserveUsedAsCollateralDisabled()` is emitted.
     * @param  reservesData      The state of all the reserves
     * @param  reservesList      The addresses of all the active reserves
     * @param  eModeCategories   The configuration of all the efficiency mode categories
     * @param  userConfig        The users configuration mapping that track the supplied/borrowed
     *                           assets
     * @param  asset             The address of the asset being configured as collateral
     * @param  useAsCollateral   True if the user wants to set the asset as collateral, false
     *                           otherwise
     * @param  reservesCount     The number of initialized reserves
     * @param  priceOracle       The address of the price oracle
     * @param  userEModeCategory The eMode category chosen by the user
     */
    function executeUseReserveAsCollateral(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        UserConfigurationMap             storage userConfig,
        address                          asset,
        bool                             useAsCollateral,
        uint256                          reservesCount,
        address                          priceOracle,
        uint8                            userEModeCategory
    ) external {
        ReserveData storage reserveData = reservesData[asset];

        ReserveCache memory reserveCache = reserveData.cache();

        uint256 userBalance = IERC20(reserveCache.aToken).balanceOf(msg.sender);

        ValidationLogic.validateSetUseReserveAsCollateral(reserveCache, userBalance);

        if (useAsCollateral == userConfig.isUsingAsCollateral(reserveData.id)) return;

        if (useAsCollateral) {
            require(
                ValidationLogic.validateUseAsCollateral(
                reservesData,
                reservesList,
                userConfig,
                reserveCache.reserveConfiguration
                ),
                Errors.USER_IN_ISOLATION_MODE_OR_LTV_ZERO
            );

            userConfig.setUsingAsCollateral(reserveData.id, true);

            emit ReserveUsedAsCollateralEnabled(asset, msg.sender);
        } else {
            userConfig.setUsingAsCollateral(reserveData.id, false);

            ValidationLogic.validateHFAndLtv(
                reservesData,
                reservesList,
                eModeCategories,
                userConfig,
                asset,
                msg.sender,
                reservesCount,
                priceOracle,
                userEModeCategory
            );

            emit ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
    }

}
