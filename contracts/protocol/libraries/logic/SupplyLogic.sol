// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }        from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';

import { IAToken } from '../../../interfaces/IAToken.sol';
import { IPool }   from '../../../interfaces/IPool.sol';

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
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { ValidationLogic }      from './ValidationLogic.sol';
import { ReserveLogic }         from './ReserveLogic.sol';

/**
 * @title  SupplyLogic library
 * @author Aave
 * @notice Implements the base logic for supply/withdraw
 */
library SupplyLogic {

    using GPv2SafeERC20  for IERC20;
    using WadRayMath     for uint256;
    using PercentageMath for uint256;

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

        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        ReserveLogic.updateState(reserveData, reserveCache);
        ValidationLogic.validateSupply(reserveCache, reserveData, params.amount);
        ReserveLogic.updateInterestRates(reserveData, reserveCache, params.asset, params.amount, 0);

        IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aToken, params.amount);

        bool isFirstSupply =
            IAToken(reserveCache.aToken).mint(
                msg.sender,
                params.onBehalfOf,
                params.amount,
                reserveCache.liquidityIndex
            );

        if (
            isFirstSupply &&
            ValidationLogic.validateAutomaticUseAsCollateral(
                reservesData,
                reservesList,
                userConfig,
                reserveCache.configuration,
                reserveCache.aToken
            )
        ) {
            UserConfiguration.setUsingAsCollateral(userConfig, reserveData.id, true);

            emit IPool.ReserveUsedAsCollateralEnabled(params.asset, params.onBehalfOf);
        }

        emit IPool.Supply(
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

        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        ReserveLogic.updateState(reserveData, reserveCache);

        uint256 userBalance =
            IAToken(reserveCache.aToken)
                .scaledBalanceOf(msg.sender)
                .rayMul(reserveCache.liquidityIndex);

        withdrawal = params.amount;

        // If amount is type(uint256).max, it is a shorthand instruction to withdraw the user's entire collateral balance
        if (params.amount == type(uint256).max) {
            withdrawal = userBalance;
        }

        ValidationLogic.validateWithdraw(reserveCache, withdrawal, userBalance);
        ReserveLogic.updateInterestRates(reserveData, reserveCache, params.asset, 0, withdrawal);

        bool isCollateral = UserConfiguration.isUsingAsCollateral(userConfig, reserveData.id);

        // If the user withdraws their entire collateral balance, automatically disable it as collateral in their config
        if (isCollateral && withdrawal == userBalance) {
            UserConfiguration.setUsingAsCollateral(userConfig, reserveData.id, false);

            emit IPool.ReserveUsedAsCollateralDisabled(params.asset, msg.sender);
        }

        // Burn the user's aTokens and transfer the equivalent underlying asset to their destination address
        IAToken(reserveCache.aToken).burn(
            msg.sender,
            params.to,
            withdrawal,
            reserveCache.liquidityIndex
        );

        // If the asset was used as collateral and the user still has active borrows,
        // validate that their new health factor remains >= 1 after the withdrawal.
        if (isCollateral && UserConfiguration.isBorrowingAny(userConfig)) {
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

        emit IPool.Withdraw(params.asset, msg.sender, params.to, withdrawal);
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

        if (UserConfiguration.isUsingAsCollateral(fromConfig, reserveId)) {
            // If the sender is using this asset as collateral and has active borrows,
            // verify their remaining collateral is sufficient to cover their outstanding debt.
            if (UserConfiguration.isBorrowingAny(fromConfig)) {
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

            // If the sender transferred their entire balance of this collateral,
            // disable the collateral flag in their configuration map.
            if (params.balanceFromBefore == params.amount) {
                UserConfiguration.setUsingAsCollateral(fromConfig, reserveId, false);

                emit IPool.ReserveUsedAsCollateralDisabled(params.asset, params.from);
            }
        }

        // If the receiver did not previously hold this aToken, check if it can be automatically
        // enabled as collateral for them.
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
                UserConfiguration.setUsingAsCollateral(toConfig, reserveId, true);

                emit IPool.ReserveUsedAsCollateralEnabled(params.asset, params.to);
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

        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        uint256 userBalance = IERC20(reserveCache.aToken).balanceOf(msg.sender);

        ValidationLogic.validateSetUseReserveAsCollateral(reserveCache, userBalance);

        if (useAsCollateral == UserConfiguration.isUsingAsCollateral(userConfig, reserveData.id)) {
            return;
        }

        if (useAsCollateral) {
            require(
                ValidationLogic.validateUseAsCollateral(
                    reservesData,
                    reservesList,
                    userConfig,
                    reserveCache.configuration
                ),
                Errors.USER_IN_ISOLATION_MODE_OR_LTV_ZERO
            );

            UserConfiguration.setUsingAsCollateral(userConfig, reserveData.id, true);

            emit IPool.ReserveUsedAsCollateralEnabled(asset, msg.sender);
        } else {
            UserConfiguration.setUsingAsCollateral(userConfig, reserveData.id, false);

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

            emit IPool.ReserveUsedAsCollateralDisabled(asset, msg.sender);
        }
    }

}
