// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }               from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { IScaledBalanceToken }  from '../../../interfaces/IScaledBalanceToken.sol';
import { IPriceOracleGetter }   from '../../../interfaces/IPriceOracleGetter.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { UserConfiguration }    from '../configuration/UserConfiguration.sol';
import { PercentageMath }       from '../math/PercentageMath.sol';
import { WadRayMath }           from '../math/WadRayMath.sol';

import {
    CalculateUserAccountDataParams,
    EModeCategory,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../types/DataTypes.sol';

import { ReserveLogic } from './ReserveLogic.sol';
import { EModeLogic }  from './EModeLogic.sol';

/**
 * @title  GenericLogic library
 * @author Aave
 * @notice Implements protocol-level logic to calculate and validate the state of a user
 */
library GenericLogic {

    using ReserveLogic         for ReserveData;
    using WadRayMath           for uint256;
    using PercentageMath       for uint256;
    using ReserveConfiguration for ReserveConfigurationMap;
    using UserConfiguration    for UserConfigurationMap;

    struct CalculateUserAccountDataVars {
        uint256 assetPrice;
        uint256 assetUnit;
        uint256 balance; // in base currency
        uint256 decimals;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 i;
        uint256 healthFactor;
        uint256 collateral; // in base currency
        uint256 debt; // in base currency
        uint256 avgLtv;
        uint256 avgLiquidationThreshold;
        uint256 eModeAssetPrice;
        uint256 eModeLtv;
        uint256 eModeLiqThreshold;
        uint256 eModeAssetCategory;
        address currentReserveAddress;
        bool    hasZeroLtvCollateral;
        bool    isInEModeCategory;
    }

    /**
     * @notice Calculates the user data across the reserves.
     * @dev    It includes the total liquidity/collateral/borrow balances in the base currency used
     *         by the price feed, the average Loan To Value, the average Liquidation Ratio, and the Health factor.
     * @param  reservesData            The state of all the reserves
     * @param  reservesList            The addresses of all the active reserves
     * @param  eModeCategories         The configuration of all the efficiency mode categories
     * @param  params                  Additional parameters needed for the calculation
     * @return collateral              The total collateral of the user in the base currency used by the price feed
     * @return debt                    The total debt of the user in the base currency used by the price feed
     * @return avgLtv                  The average ltv of the user
     * @return avgLiquidationThreshold The average liquidation threshold of the user
     * @return healthFactor            The health factor of the user
     * @return hasZeroLtvCollateral    True if the ltv is zero, false otherwise
     */
    function calculateUserAccountData(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        CalculateUserAccountDataParams   memory  params
    ) internal view returns (uint256, uint256, uint256, uint256, uint256, bool) {
        if (params.userConfig.isEmpty()) return ( 0, 0, 0, 0, type(uint256).max, false );

        CalculateUserAccountDataVars memory vars;

        if (params.userEModeCategory != 0) {
            ( vars.eModeLtv, vars.eModeLiqThreshold, vars.eModeAssetPrice ) =
                EModeLogic.getEModeConfiguration(
                    eModeCategories[params.userEModeCategory],
                    params.oracle
                );
        }

        while (vars.i < params.reservesCount) {
            if (!params.userConfig.isUsingAsCollateralOrBorrowing(vars.i)) {
                unchecked {
                    ++vars.i;
                }

                continue;
            }

            vars.currentReserveAddress = reservesList[vars.i];

            if (vars.currentReserveAddress == address(0)) {
                unchecked {
                    ++vars.i;
                }

                continue;
            }

            ReserveData storage currentReserve = reservesData[vars.currentReserveAddress];

            (
                vars.ltv,
                vars.liquidationThreshold,
                ,
                vars.decimals,
                ,
                vars.eModeAssetCategory
            ) = currentReserve.configuration.getParams();

            unchecked {
                vars.assetUnit = 10 ** vars.decimals;
            }

            vars.assetPrice =
                (vars.eModeAssetPrice != 0) && (params.userEModeCategory == vars.eModeAssetCategory)
                    ? vars.eModeAssetPrice
                    : IPriceOracleGetter(params.oracle).getAssetPrice(vars.currentReserveAddress);

            if ((vars.liquidationThreshold != 0) && params.userConfig.isUsingAsCollateral(vars.i)) {
                vars.balance = _getUserBalanceInBaseCurrency(
                    params.user,
                    currentReserve,
                    vars.assetPrice,
                    vars.assetUnit
                );

                vars.collateral += vars.balance;

                vars.isInEModeCategory =
                    EModeLogic.isInEModeCategory(params.userEModeCategory, vars.eModeAssetCategory);

                if (vars.ltv != 0) {
                    vars.avgLtv +=
                        vars.balance * (vars.isInEModeCategory ? vars.eModeLtv : vars.ltv);
                } else {
                    vars.hasZeroLtvCollateral = true;
                }

                vars.avgLiquidationThreshold +=
                    vars.balance *
                    (vars.isInEModeCategory ? vars.eModeLiqThreshold : vars.liquidationThreshold);
            }

            if (params.userConfig.isBorrowing(vars.i)) {
                vars.debt +=
                    _getUserDebtInBaseCurrency(
                        params.user,
                        currentReserve,
                        vars.assetPrice,
                        vars.assetUnit
                    );
            }

            unchecked {
                ++vars.i;
            }
        }

        unchecked {
            vars.avgLtv = vars.collateral != 0 ? vars.avgLtv / vars.collateral : 0;

            vars.avgLiquidationThreshold =
                vars.collateral != 0 ? vars.avgLiquidationThreshold / vars.collateral : 0;
        }

        vars.healthFactor =
            vars.debt == 0
                ? type(uint256).max
                : vars.collateral.percentMul(vars.avgLiquidationThreshold).wadDiv(vars.debt);

        return (
            vars.collateral,
            vars.debt,
            vars.avgLtv,
            vars.avgLiquidationThreshold,
            vars.healthFactor,
            vars.hasZeroLtvCollateral
        );
    }

    /**
     * @notice Calculates the maximum amount that can be borrowed depending on the available
     *         collateral, the total debt and the average Loan To Value
     * @param  totalCollateral  The total collateral in the base currency used by the price feed
     * @param  totalDebt        The total borrow balance in the base currency used by the price feed
     * @param  ltv              The average loan to value
     * @return availableBorrows The amount available to borrow in the base currency of the used by
     8         the price feed
     */
    function calculateAvailableBorrows(
        uint256 totalCollateral,
        uint256 totalDebt,
        uint256 ltv
    ) internal pure returns (uint256 availableBorrows) {
        uint256 availableBorrows = totalCollateral.percentMul(ltv);

        return (availableBorrows < totalDebt) ? 0 : availableBorrows - totalDebt;
    }

    /**
     * @notice Calculates total debt of the user in the based currency used to normalize the values
     *         of the assets
     * @dev    This fetches the `balanceOf` of the stable and variable debt tokens for the user. For
     *         gas reasons, the variable debt balance is calculated by fetching `scaledBalancesOf`
     *         normalized debt, which is cheaper than fetching `balanceOf`
     * @param  user       The address of the user
     * @param  reserve    The data of the reserve for which the total debt of the user is being
     *                    calculated
     * @param  assetPrice The price of the asset for which the total debt of the user is being
     *                    calculated
     * @param  assetUnit  The value representing one full unit of the asset (10^decimals)
     * @return debt       The total debt of the user normalized to the base currency
     */
    function _getUserDebtInBaseCurrency(
        address             user,
        ReserveData storage reserve,
        uint256             assetPrice,
        uint256             assetUnit
    ) private view returns (uint256 debt) {
        // fetching variable debt
        debt = IScaledBalanceToken(reserve.variableDebtToken).scaledBalanceOf(user);

        if (debt != 0) {
            debt = debt.rayMul(reserve.getNormalizedDebt());
        }

        debt += IERC20(reserve.stableDebtToken).balanceOf(user);
        debt *= assetPrice;

        unchecked {
            return debt / assetUnit;
        }
    }

    /**
     * @notice Calculates total aToken balance of the user in the based currency used by the price
     *         oracle
     * @dev    For gas reasons, the aToken balance is calculated by fetching `scaledBalancesOf`
     *         normalized debt, which is cheaper than fetching `balanceOf`
     * @param  user       The address of the user
     * @param  reserve    The data of the reserve for which the total aToken balance of the user is
     *                    being calculated
     * @param  assetPrice The price of the asset for which the total aToken balance of the user is
     *                    being calculated
     * @param  assetUnit  The value representing one full unit of the asset (10^decimals)
     * @return balance    The total aToken balance of the user normalized to the base currency of
     *                    the price oracle
     */
    function _getUserBalanceInBaseCurrency(
        address             user,
        ReserveData storage reserve,
        uint256             assetPrice,
        uint256             assetUnit
    ) private view returns (uint256 balance) {
        uint256 normalizedIncome = reserve.getNormalizedIncome();

        balance =
            IScaledBalanceToken(reserve.aToken).scaledBalanceOf(user).rayMul(normalizedIncome) *
            assetPrice;

        unchecked {
            return balance / assetUnit;
        }
    }

}
