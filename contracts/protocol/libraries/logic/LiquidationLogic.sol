// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }        from '../../../dependencies/openzeppelin/contracts//IERC20.sol';
import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';

import { IAToken }              from '../../../interfaces/IAToken.sol';
import { IStableDebtToken }     from '../../../interfaces/IStableDebtToken.sol';
import { IVariableDebtToken }   from '../../../interfaces/IVariableDebtToken.sol';
import { IPriceOracleGetter }   from '../../../interfaces/IPriceOracleGetter.sol';
import { IPool }                from '../../../interfaces/IPool.sol';

import { UserConfiguration }    from '../../libraries/configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../../libraries/configuration/ReserveConfiguration.sol';
import { PercentageMath }       from '../../libraries/math/PercentageMath.sol';
import { WadRayMath }           from '../../libraries/math/WadRayMath.sol';
import { Helpers }              from '../../libraries/helpers/Helpers.sol';

import {
    CalculateUserAccountDataParams,
    EModeCategory,
    ExecuteLiquidationCallParams,
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap,
    ValidateLiquidationCallParams
} from '../../libraries/types/DataTypes.sol';

import { ReserveLogic }         from './ReserveLogic.sol';
import { ValidationLogic }      from './ValidationLogic.sol';
import { GenericLogic }         from './GenericLogic.sol';
import { IsolationModeLogic }   from './IsolationModeLogic.sol';
import { EModeLogic }           from './EModeLogic.sol';

/**
 * @title  LiquidationLogic library
 * @author Aave
 * @notice Implements actions involving management of collateral in the protocol, the main one being the liquidations
 */
library LiquidationLogic {

    using WadRayMath     for uint256;
    using PercentageMath for uint256;
    using GPv2SafeERC20  for IERC20;

    /**
     * @dev Default percentage of borrower's debt to be repaid in a liquidation.
     * @dev Percentage applied when the users health factor is above `CLOSE_FACTOR_HF_THRESHOLD`.
     *      Expressed in bps, a value of 0.5e4 results in 50.00%
     */
    uint256 internal constant DEFAULT_LIQUIDATION_CLOSE_FACTOR = 0.5e4;

    /**
     * @dev Maximum percentage of borrower's debt to be repaid in a liquidation
     * @dev Percentage applied when the users health factor is below `CLOSE_FACTOR_HF_THRESHOLD`.
     *      Expressed in bps, a value of 1e4 results in 100.00%
     */
    uint256 public constant MAX_LIQUIDATION_CLOSE_FACTOR = 1e4;

    /**
     * @dev This constant represents below which health factor value it is possible to liquidate an
     *      amount of debt corresponding to `MAX_LIQUIDATION_CLOSE_FACTOR`. A value of 0.95e18 results
     *      in 0.95
     */
    uint256 public constant CLOSE_FACTOR_HF_THRESHOLD = 0.95e18;

    struct LiquidationCallLocalVars {
        uint256      collateralBalance;
        uint256      variableDebt;
        uint256      totalDebt;
        uint256      actualDebtToLiquidate;
        uint256      actualCollateralToLiquidate;
        uint256      liquidationBonus;
        uint256      healthFactor;
        uint256      liquidationProtocolFee;
        address      collateralPriceSource;
        address      debtPriceSource;
        address      collateralAToken;
        ReserveCache debtReserveCache;
    }

    /**
     * @notice Function to liquidate a position if its Health Factor drops below 1. The caller
     *         (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and
     *         receives a proportional amount of the `collateralAsset` plus a bonus to cover market
     *         risk
     * @dev    Emits the `LiquidationCall()` event
     * @param  reservesData    The state of all the reserves
     * @param  reservesList    The addresses of all the active reserves
     * @param  usersConfig     The users configuration mapping that track the supplied/borrowed
     *                         assets
     * @param  eModeCategories The configuration of all the efficiency mode categories
     * @param  params          The additional parameters needed to execute the liquidation function
     */
    function executeLiquidationCall(
        mapping (address => ReserveData)          storage reservesData,
        mapping (uint256 => address)              storage reservesList,
        mapping (address => UserConfigurationMap) storage usersConfig,
        mapping (uint8 => EModeCategory)          storage eModeCategories,
        ExecuteLiquidationCallParams              memory  params
    ) external {
        LiquidationCallLocalVars memory vars;

        ReserveData          storage collateralReserveData = reservesData[params.collateralAsset];
        ReserveData          storage debtReserveData       = reservesData[params.debtAsset];
        UserConfigurationMap storage userConfig            = usersConfig[params.user];

        vars.debtReserveCache = ReserveLogic.cache(debtReserveData);

        ReserveLogic.updateState(debtReserveData, vars.debtReserveCache);

        ( , , , , vars.healthFactor, ) =
            GenericLogic.calculateUserAccountData(
                reservesData,
                reservesList,
                eModeCategories,
                CalculateUserAccountDataParams({
                    userConfig        : userConfig,
                    reservesCount     : params.reservesCount,
                    user              : params.user,
                    oracle            : params.priceOracle,
                    userEModeCategory : params.userEModeCategory
                })
            );

        ( vars.variableDebt, vars.totalDebt, vars.actualDebtToLiquidate ) =
            _calculateDebt(vars.debtReserveCache, params, vars.healthFactor);

        ValidationLogic.validateLiquidationCall(
            userConfig,
            collateralReserveData,
            ValidateLiquidationCallParams({
                debtReserveCache    : vars.debtReserveCache,
                totalDebt           : vars.totalDebt,
                healthFactor        : vars.healthFactor,
                priceOracleSentinel : params.priceOracleSentinel
            })
        );

        (
        vars.collateralAToken,
        vars.collateralPriceSource,
        vars.debtPriceSource,
        vars.liquidationBonus
        ) = _getConfigurationData(eModeCategories, collateralReserveData, params);

        vars.collateralBalance = IERC20(vars.collateralAToken).balanceOf(params.user);

        (
            vars.actualCollateralToLiquidate,
            vars.actualDebtToLiquidate,
            vars.liquidationProtocolFee
        ) =
            _calculateAvailableCollateralToLiquidate(
                collateralReserveData,
                vars.debtReserveCache,
                vars.collateralPriceSource,
                vars.debtPriceSource,
                vars.actualDebtToLiquidate,
                vars.collateralBalance,
                vars.liquidationBonus,
                params.priceOracle
            );

        // If the liquidator repaid the total debt of the user for this reserve,
        // disable the user's borrowing flag for this reserve in their config bitmap.
        if (vars.totalDebt == vars.actualDebtToLiquidate) {
            UserConfiguration.setBorrowing(userConfig, debtReserveData.id, false);
        }

        // If the user's entire collateral balance (including protocol fee) is seized,
        // disable the collateral flag in the user config bitmap.
        if (
            vars.actualCollateralToLiquidate + vars.liquidationProtocolFee ==
            vars.collateralBalance
        ) {
            UserConfiguration.setUsingAsCollateral(userConfig, collateralReserveData.id, false);

            emit IPool.ReserveUsedAsCollateralDisabled(params.collateralAsset, params.user);
        }

        _burnDebtTokens(params, vars);

        ReserveLogic.updateInterestRates(
            debtReserveData,
            vars.debtReserveCache,
            params.debtAsset,
            vars.actualDebtToLiquidate,
            0
        );

        IsolationModeLogic.updateIsolatedDebtIfIsolated(
            reservesData,
            reservesList,
            userConfig,
            vars.debtReserveCache,
            vars.actualDebtToLiquidate
        );

        if (params.receiveAToken) {
            _liquidateATokens(
                reservesData,
                reservesList,
                usersConfig,
                collateralReserveData,
                params,
                vars
            );
        } else {
            _burnCollateralATokens(collateralReserveData, params, vars);
        }

        // Transfer fee to treasury if it is non-zero
        if (vars.liquidationProtocolFee != 0) {
            uint256 liquidityIndex = ReserveLogic.getNormalizedIncome(collateralReserveData);

            uint256 scaledDownLiquidationProtocolFee =
                vars.liquidationProtocolFee.rayDiv(liquidityIndex);

            uint256 scaledDownUserBalance = IAToken(vars.collateralAToken).scaledBalanceOf(params.user);

            // To avoid trying to send more aTokens than available on balance, due to 1 wei
            // rounding/imprecision when dividing by the liquidity index, cap the fee to the user's actual scaled balance.
            if (scaledDownLiquidationProtocolFee > scaledDownUserBalance) {
                vars.liquidationProtocolFee = scaledDownUserBalance.rayMul(liquidityIndex);
            }

            // Transfer the fee directly from the liquidated user's collateral to the protocol treasury address
            IAToken(vars.collateralAToken).transferOnLiquidation(
                params.user,
                IAToken(vars.collateralAToken).RESERVE_TREASURY_ADDRESS(),
                vars.liquidationProtocolFee
            );
        }

        // Transfers the debt asset being repaid to the aToken, where the liquidity is kept
        IERC20(params.debtAsset).safeTransferFrom(
            msg.sender,
            vars.debtReserveCache.aToken,
            vars.actualDebtToLiquidate
        );

        IAToken(vars.debtReserveCache.aToken).handleRepayment(
            msg.sender,
            params.user,
            vars.actualDebtToLiquidate
        );

        emit IPool.LiquidationCall(
            params.collateralAsset,
            params.debtAsset,
            params.user,
            vars.actualDebtToLiquidate,
            vars.actualCollateralToLiquidate,
            msg.sender,
            params.receiveAToken
        );
    }

    /**
     * @notice Burns the collateral aTokens and transfers the underlying to the liquidator.
     * @dev    The function also updates the state and the interest rate of the collateral reserve.
     * @param  reserveData The data of the collateral reserve
     * @param  params      The additional parameters needed to execute the liquidation function
     * @param  vars        The executeLiquidationCall() function local vars
     */
    function _burnCollateralATokens(
        ReserveData                  storage reserveData,
        ExecuteLiquidationCallParams memory  params,
        LiquidationCallLocalVars     memory  vars
    ) internal {
        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        ReserveLogic.updateState(reserveData, reserveCache);

        ReserveLogic.updateInterestRates(
            reserveData,
            reserveCache,
            params.collateralAsset,
            0,
            vars.actualCollateralToLiquidate
        );

        // Burn the equivalent amount of aToken, sending the underlying to the liquidator
        IAToken(vars.collateralAToken).burn(
            params.user,
            msg.sender,
            vars.actualCollateralToLiquidate,
            reserveCache.liquidityIndex
        );
    }

    /**
     * @notice Liquidates the user aTokens by transferring them to the liquidator.
     * @dev    The function also checks the state of the liquidator and activates the aToken as
     *         collateral as in standard transfers if the isolation mode constraints are respected.
     * @param  reservesData          The state of all the reserves
     * @param  reservesList          The addresses of all the active reserves
     * @param  usersConfig           The users configuration mapping that track the
     *                               supplied/borrowed assets
     * @param  collateralReserveData The data of the collateral reserve
     * @param  params                The additional parameters needed to execute the liquidation
     *                               function
     * @param  vars                  The executeLiquidationCall() function local vars
     */
    function _liquidateATokens(
        mapping (address => ReserveData)          storage reservesData,
        mapping (uint256 => address)              storage reservesList,
        mapping (address => UserConfigurationMap) storage usersConfig,
        ReserveData                               storage collateralReserveData,
        ExecuteLiquidationCallParams              memory  params,
        LiquidationCallLocalVars                  memory  vars
    ) internal {
        uint256 liquidatorPreviousATokenBalance =
            IERC20(vars.collateralAToken).balanceOf(msg.sender);

        IAToken(vars.collateralAToken).transferOnLiquidation(
            params.user,
            msg.sender,
            vars.actualCollateralToLiquidate
        );

        if (liquidatorPreviousATokenBalance != 0) return;

        UserConfigurationMap storage liquidatorConfig = usersConfig[msg.sender];

        if (
            !ValidationLogic.validateAutomaticUseAsCollateral(
                reservesData,
                reservesList,
                liquidatorConfig,
                collateralReserveData.configuration,
                collateralReserveData.aToken
            )
        ) {
            return;
        }

        UserConfiguration.setUsingAsCollateral(liquidatorConfig, collateralReserveData.id, true);

        emit IPool.ReserveUsedAsCollateralEnabled(params.collateralAsset, msg.sender);
    }

    /**
     * @notice Burns the debt tokens of the user up to the amount being repaid by the liquidator.
     * @dev    The function alters the `debtReserveCache` state in `vars` to update the debt related
     *         data.
     * @param  params The additional parameters needed to execute the liquidation function
     * @param  vars   the executeLiquidationCall() function local vars
     */
    function _burnDebtTokens(
        ExecuteLiquidationCallParams memory params,
        LiquidationCallLocalVars     memory vars
    ) internal {
        if (vars.variableDebt >= vars.actualDebtToLiquidate) {
            vars.debtReserveCache.scaledVariableDebt =
                IVariableDebtToken(vars.debtReserveCache.variableDebtToken).burn(
                    params.user,
                    vars.actualDebtToLiquidate,
                    vars.debtReserveCache.variableBorrowIndex
                );

            return;
        }

        // If the user doesn't have variable debt, no need to try to burn variable debt tokens
        if (vars.variableDebt != 0) {
            vars.debtReserveCache.scaledVariableDebt =
                IVariableDebtToken(vars.debtReserveCache.variableDebtToken).burn(
                    params.user,
                    vars.variableDebt,
                    vars.debtReserveCache.variableBorrowIndex
                );
        }

        (
            vars.debtReserveCache.totalStableDebt,
            vars.debtReserveCache.avgStableBorrowRate
        ) =
            IStableDebtToken(vars.debtReserveCache.stableDebtToken).burn(
                params.user,
                vars.actualDebtToLiquidate - vars.variableDebt
            );
    }

    /**
     * @notice Calculates the total debt of the user and the actual amount to liquidate depending on
     *         the health factor and corresponding close factor.
     * @dev    If the Health Factor is below CLOSE_FACTOR_HF_THRESHOLD, the close factor is
     *         increased to MAX_LIQUIDATION_CLOSE_FACTOR
     * @param  debtReserveCache      The reserve cache data object of the debt reserve
     * @param  params                The additional parameters needed to execute the liquidation
     *                               function
     * @param  healthFactor          The health factor of the position
     * @return variableDebt          The variable debt of the user
     * @return totalDebt             The total debt of the user
     * @return actualDebtToLiquidate The actual debt to liquidate as a function of the closeFactor
     */
    function _calculateDebt(
        ReserveCache                 memory debtReserveCache,
        ExecuteLiquidationCallParams memory params,
        uint256                             healthFactor
    )
        internal
        view
        returns (
            uint256 variableDebt,
            uint256 totalDebt,
            uint256 actualDebtToLiquidate
        )
    {
        uint256 stableDebt;

        ( stableDebt, variableDebt ) = Helpers.getUserCurrentDebt(params.user, debtReserveCache);

        totalDebt = stableDebt + variableDebt;

        // If HF is above 0.95, only allow liquidating up to 50% of the debt to avoid unnecessarily large liquidations.
        // If HF is below 0.95 (dangerously close to default), allow liquidating up to 100% of the debt to restore position health quickly.
        uint256 closeFactor =
            healthFactor > CLOSE_FACTOR_HF_THRESHOLD
                ? DEFAULT_LIQUIDATION_CLOSE_FACTOR
                : MAX_LIQUIDATION_CLOSE_FACTOR;

        uint256 maxLiquidatableDebt = totalDebt.percentMul(closeFactor);

        actualDebtToLiquidate =
            params.debtToCover > maxLiquidatableDebt ? maxLiquidatableDebt : params.debtToCover;
    }

    /**
     * @notice Returns the configuration data for the debt and the collateral reserves.
     * @param  eModeCategories       The configuration of all the efficiency mode categories
     * @param  collateralReserveData The data of the collateral reserve
     * @param  params                The additional parameters needed to execute the liquidation
     *                               function
     * @return collateralAToken      The collateral aToken
     * @return collateralPriceSource The address to use as price source for the collateral
     * @return debtPriceSource       The address to use as price source for the debt
     * @return liquidationBonus      The liquidation bonus to apply to the collateral
     */
    function _getConfigurationData(
        mapping (uint8 => EModeCategory) storage eModeCategories,
        ReserveData                      storage collateralReserveData,
        ExecuteLiquidationCallParams     memory  params
    )
        internal
        view
        returns (
            address collateralAToken,
            address collateralPriceSource,
            address debtPriceSource,
            uint256 liquidationBonus
        )
    {
        collateralAToken      = collateralReserveData.aToken;
        collateralPriceSource = params.collateralAsset;
        debtPriceSource       = params.debtAsset;

        liquidationBonus =
            ReserveConfiguration.getLiquidationBonus(collateralReserveData.configuration);

        if (params.userEModeCategory == 0) {
            return ( collateralAToken, collateralPriceSource, debtPriceSource, liquidationBonus );
        }

        address eModePriceSource = eModeCategories[params.userEModeCategory].priceSource;

        if (
            EModeLogic.isInEModeCategory(
                params.userEModeCategory,
                ReserveConfiguration.getEModeCategory(collateralReserveData.configuration)
            )
        ) {
            liquidationBonus = eModeCategories[params.userEModeCategory].liquidationBonus;

            if (eModePriceSource != address(0)) {
                collateralPriceSource = eModePriceSource;
            }
        }

        // when in eMode, debt will always be in the same eMode category, can skip matching
        // category check
        if (eModePriceSource != address(0)) {
            debtPriceSource = eModePriceSource;
        }
    }

    struct AvailableCollateralToLiquidateLocalVars {
        uint256 collateralPrice;
        uint256 debtAssetPrice;
        uint256 maxCollateralToLiquidate;
        uint256 baseCollateral;
        uint256 bonusCollateral;
        uint256 debtAssetDecimals;
        uint256 collateralDecimals;
        uint256 collateralAssetUnit;
        uint256 debtAssetUnit;
        uint256 collateral;
        uint256 debtNeeded;
        uint256 liquidationProtocolFeePercentage;
        uint256 liquidationProtocolFee;
    }

    /**
     * @notice Calculates how much of a specific collateral can be liquidated, given a certain
     *         amount of debt asset.
     * @dev    This function needs to be called after all the checks to validate the liquidation
     *         have been performed, otherwise it might fail.
     * @param  collateralReserveData The data of the collateral reserve
     * @param  debtReserveCache      The cached data of the debt reserve
     * @param  collateralAsset       The address of the underlying asset used as collateral, to
     *                               receive as result of the liquidation
     * @param  debtAsset             The address of the underlying borrowed asset to be repaid with
     *                               the liquidation
     * @param  debtToCover           The debt amount of borrowed `asset` the liquidator wants to
     *                               cover
     * @param  collateralBalance     The collateral balance for the specific `collateralAsset` of
     *                               the user being liquidated
     * @param  liquidationBonus      The collateral bonus percentage to receive as result of the
     *                               liquidation
     * @return maxAmount             The maximum amount that is possible to liquidate given all the
     *                               liquidation constraints (user balance, close factor)
     * @return repayment             The amount to repay with the liquidation
     * @return protocolFee           The fee taken from the liquidation bonus amount to be paid to
     *                               the protocol
     */
    function _calculateAvailableCollateralToLiquidate(
        ReserveData  storage collateralReserveData,
        ReserveCache memory  debtReserveCache,
        address              collateralAsset,
        address              debtAsset,
        uint256              debtToCover,
        uint256              collateralBalance,
        uint256              liquidationBonus,
        address              oracle
    ) internal view returns (uint256, uint256, uint256) {
        AvailableCollateralToLiquidateLocalVars memory vars;

        vars.collateralPrice   = IPriceOracleGetter(oracle).getAssetPrice(collateralAsset);
        vars.debtAssetPrice    = IPriceOracleGetter(oracle).getAssetPrice(debtAsset);
        vars.debtAssetDecimals = ReserveConfiguration.getDecimals(debtReserveCache.configuration);

        vars.collateralDecimals =
            ReserveConfiguration.getDecimals(collateralReserveData.configuration);

        unchecked {
            vars.collateralAssetUnit = 10 ** vars.collateralDecimals;
            vars.debtAssetUnit       = 10 ** vars.debtAssetDecimals;
        }

        vars.liquidationProtocolFeePercentage =
            ReserveConfiguration.getLiquidationProtocolFee(collateralReserveData.configuration);

        // Calculate the base collateral to liquidate (matching the value of the debt being repaid, based on oracle prices)
        vars.baseCollateral =
            (vars.debtAssetPrice * debtToCover * vars.collateralAssetUnit) /
            (vars.collateralPrice * vars.debtAssetUnit);

        // Max collateral includes the liquidation bonus (e.g., base collateral * 1.10)
        vars.maxCollateralToLiquidate = vars.baseCollateral.percentMul(liquidationBonus);

        // If the liquidator wants to claim more collateral than the user actually has,
        // scale down the liquidation: take all of the user's collateral, and solve for the required debt repayment.
        if (vars.maxCollateralToLiquidate > collateralBalance) {
            vars.collateral = collateralBalance;

            vars.debtNeeded =
                (
                    (vars.collateralPrice * vars.collateral * vars.debtAssetUnit) /
                    (vars.debtAssetPrice * vars.collateralAssetUnit)
                ).percentDiv(liquidationBonus);
        } else {
            vars.collateral = vars.maxCollateralToLiquidate;
            vars.debtNeeded = debtToCover;
        }

        if (vars.liquidationProtocolFeePercentage == 0) {
            return ( vars.collateral, vars.debtNeeded, 0 );
        }

        // Calculate the bonus portion of the collateral (total collateral minus the base collateral equivalent)
        vars.bonusCollateral = vars.collateral - vars.collateral.percentDiv(liquidationBonus);

        // Calculate the protocol fee, which is taken only from the bonus portion, not the base collateral.
        vars.liquidationProtocolFee =
            vars.bonusCollateral.percentMul(vars.liquidationProtocolFeePercentage);

        // Deduct the protocol fee from the liquidator's collateral payout
        return (
            vars.collateral - vars.liquidationProtocolFee,
            vars.debtNeeded,
            vars.liquidationProtocolFee
        );
    }

}
