// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { GPv2SafeERC20 }        from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { SafeCast }             from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import { IERC20 }               from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { IStableDebtToken }     from '../../../interfaces/IStableDebtToken.sol';
import { IVariableDebtToken }   from '../../../interfaces/IVariableDebtToken.sol';
import { IAToken }              from '../../../interfaces/IAToken.sol';
import { UserConfiguration }    from '../configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { Helpers }              from '../helpers/Helpers.sol';

import {
    EModeCategory,
    ExecuteBorrowParams,
    ExecuteRepayParams,
    InterestRateMode,
    ReserveConfigurationMap,
    ReserveCache,
    ReserveData,
    UserConfigurationMap,
    ValidateBorrowParams
} from '../types/DataTypes.sol';

import { ValidationLogic }    from './ValidationLogic.sol';
import { ReserveLogic }       from './ReserveLogic.sol';
import { IsolationModeLogic } from './IsolationModeLogic.sol';

/**
 * @title BorrowLogic library
 * @author Aave
 * @notice Implements the base logic for all the actions related to borrowing
 */
library BorrowLogic {

    using ReserveLogic         for ReserveCache;
    using ReserveLogic         for ReserveData;
    using GPv2SafeERC20        for IERC20;
    using UserConfiguration    for UserConfigurationMap;
    using ReserveConfiguration for ReserveConfigurationMap;
    using SafeCast             for uint256;

    // See `IPool` for descriptions
    event Borrow(
        address          indexed reserve,
        address                  user,
        address          indexed onBehalfOf,
        uint256                  amount,
        InterestRateMode         interestRateMode,
        uint256                  borrowRate,
        uint16           indexed referralCode
    );

    event Repay(
        address indexed reserve,
        address indexed user,
        address indexed repayer,
        uint256         amount,
        bool            useATokens
    );

    event RebalanceStableBorrowRate(address indexed reserve, address indexed user);

    event SwapBorrowRateMode(
        address          indexed reserve,
        address          indexed user,
        InterestRateMode         interestRateMode
    );

    event IsolationModeTotalDebtUpdated(address indexed asset, uint256 totalDebt);

    /**
     * @notice Implements the borrow feature. Borrowing allows users that provided collateral to
     *         draw liquidity from the Aave protocol proportionally to their collateralization
     *         power. For isolated positions, it also increases the isolated debt.
     * @dev    Emits the `Borrow()` event
     * @param  reservesData    The state of all the reserves
     * @param  reservesList    The addresses of all the active reserves
     * @param  eModeCategories The configuration of all the efficiency mode categories
     * @param  userConfig      The user configuration mapping that tracks the supplied/borrowed
     *                         assets
     * @param  params          The additional parameters needed to execute the borrow function
     */
    function executeBorrow(
        mapping(address => ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        mapping(uint8 => EModeCategory) storage eModeCategories,
        UserConfigurationMap storage userConfig,
        ExecuteBorrowParams memory params
    ) public {
        ReserveData storage reserve = reservesData[params.asset];

        ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);

        (
            bool    isolationModeActive,
            address isolationModeCollateralAsset,
            uint256 isolationModeDebtCeiling
        ) = userConfig.getIsolationModeState(reservesData, reservesList);

        ValidationLogic.validateBorrow(
            reservesData,
            reservesList,
            eModeCategories,
            ValidateBorrowParams({
                reserveCache                 : reserveCache,
                userConfig                   : userConfig,
                asset                        : params.asset,
                userAddress                  : params.onBehalfOf,
                amount                       : params.amount,
                interestRateMode             : params.interestRateMode,
                maxStableLoanPercent         : params.maxStableRateBorrowSizePercent,
                reservesCount                : params.reservesCount,
                oracle                       : params.oracle,
                userEModeCategory            : params.userEModeCategory,
                priceOracleSentinel          : params.priceOracleSentinel,
                isolationModeActive          : isolationModeActive,
                isolationModeCollateralAsset : isolationModeCollateralAsset,
                isolationModeDebtCeiling     : isolationModeDebtCeiling
            })
        );

        uint256 currentStableRate = 0;
        bool    isFirstBorrowing  = false;

        if (params.interestRateMode == InterestRateMode.STABLE) {
            currentStableRate = reserve.currentStableBorrowRate;

            (
                isFirstBorrowing,
                reserveCache.nextTotalStableDebt,
                reserveCache.nextAvgStableBorrowRate
            ) =
                IStableDebtToken(reserveCache.stableDebtToken)
                    .mint(
                        params.user,
                        params.onBehalfOf,
                        params.amount,
                        currentStableRate
                    );
        } else {
            ( isFirstBorrowing, reserveCache.nextScaledVariableDebt ) =
                IVariableDebtToken(reserveCache.variableDebtToken)
                    .mint(
                        params.user,
                        params.onBehalfOf,
                        params.amount,
                        reserveCache.nextVariableBorrowIndex
                    );
        }

        if (isFirstBorrowing) {
            userConfig.setBorrowing(reserve.id, true);
        }

        if (isolationModeActive) {
            uint256 nextIsolationModeTotalDebt = (
                reservesData[isolationModeCollateralAsset].isolationModeTotalDebt +=
                    (
                        params.amount /
                        (
                            10 **
                            (
                                reserveCache.reserveConfiguration.getDecimals() -
                                ReserveConfiguration.DEBT_CEILING_DECIMALS
                            )
                        )
                    ).toUint128()
            );

            emit IsolationModeTotalDebtUpdated(
                isolationModeCollateralAsset,
                nextIsolationModeTotalDebt
            );
        }

        reserve.updateInterestRates(
            reserveCache,
            params.asset,
            0,
            params.releaseUnderlying ? params.amount : 0
        );

        if (params.releaseUnderlying) {
            IAToken(reserveCache.aToken).transferUnderlyingTo(params.user, params.amount);
        }

        emit Borrow(
            params.asset,
            params.user,
            params.onBehalfOf,
            params.amount,
            params.interestRateMode,
            params.interestRateMode == InterestRateMode.STABLE
                ? currentStableRate
                : reserve.currentVariableBorrowRate,
            params.referralCode
        );
    }

    /**
     * @notice Implements the repay feature. Repaying transfers the underlying back to the aToken
     *         and clears the equivalent amount of debt for the user by burning the corresponding
     *         debt token. For isolated positions, it also reduces the isolated debt.
     * @dev    Emits the `Repay()` event
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  userConfig   The user configuration mapping that tracks the supplied/borrowed assets
     * @param  params       The additional parameters needed to execute the repay function
     * @return repaid       The actual amount being repaid
     */
    function executeRepay(
        mapping(address => ReserveData) storage reservesData,
        mapping(uint256 => address) storage reservesList,
        UserConfigurationMap storage userConfig,
        ExecuteRepayParams memory params
    ) external returns (uint256) {
        ReserveData storage reserve = reservesData[params.asset];

        ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);

        ( uint256 stableDebt, uint256 variableDebt ) =
            Helpers.getUserCurrentDebt(params.onBehalfOf, reserveCache);

        ValidationLogic.validateRepay(
            reserveCache,
            params.amount,
            params.interestRateMode,
            params.onBehalfOf,
            stableDebt,
            variableDebt
        );

        uint256 repaid =
            params.interestRateMode == InterestRateMode.STABLE ? stableDebt : variableDebt;

        // Allows a user to repay with aTokens without leaving dust from interest.
        if (params.useATokens && params.amount == type(uint256).max) {
            params.amount = IAToken(reserveCache.aToken).balanceOf(msg.sender);
        }

        if (params.amount < repaid) {
            repaid = params.amount;
        }

        if (params.interestRateMode == InterestRateMode.STABLE) {
            ( reserveCache.nextTotalStableDebt, reserveCache.nextAvgStableBorrowRate ) =
                IStableDebtToken(reserveCache.stableDebtToken)
                    .burn(params.onBehalfOf, repaid);
        } else {
            reserveCache.nextScaledVariableDebt =
                IVariableDebtToken(reserveCache.variableDebtToken)
                    .burn(params.onBehalfOf, repaid, reserveCache.nextVariableBorrowIndex);
        }

        reserve.updateInterestRates(
            reserveCache,
            params.asset,
            params.useATokens ? 0 : repaid,
            0
        );

        if (stableDebt + variableDebt - repaid == 0) {
            userConfig.setBorrowing(reserve.id, false);
        }

        IsolationModeLogic.updateIsolatedDebtIfIsolated(
            reservesData,
            reservesList,
            userConfig,
            reserveCache,
            repaid
        );

        if (params.useATokens) {
            IAToken(reserveCache.aToken).burn(
                msg.sender,
                reserveCache.aToken,
                repaid,
                reserveCache.nextLiquidityIndex
            );
        } else {
            IERC20(params.asset).safeTransferFrom(msg.sender, reserveCache.aToken, repaid);

            IAToken(reserveCache.aToken).handleRepayment(
                msg.sender,
                params.onBehalfOf,
                repaid
            );
        }

        emit Repay(params.asset, params.onBehalfOf, msg.sender, repaid, params.useATokens);
    }

    /**
     * @notice Implements the rebalance stable borrow rate feature. In case of liquidity crunches on
     *         the protocol, stable rate borrows might need to be rebalanced to bring back
     *         equilibrium between the borrow and supply APYs.
     * @dev    The rules that define if a position can be rebalanced are implemented in
     *         `ValidationLogic.validateRebalanceStableBorrowRate()`
     * @dev    Emits the `RebalanceStableBorrowRate()` event
     * @param  reserve The state of the reserve of the asset being repaid
     * @param  asset   The asset of the position being rebalanced
     * @param  user    The user being rebalanced
     */
    function executeRebalanceStableBorrowRate(
        ReserveData storage reserve,
        address asset,
        address user
    ) external {
        ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);
        ValidationLogic.validateRebalanceStableBorrowRate(reserve, reserveCache, asset);

        uint256 stableDebt = IERC20(reserveCache.stableDebtToken).balanceOf(user);

        IStableDebtToken(reserveCache.stableDebtToken).burn(user, stableDebt);

        ( , reserveCache.nextTotalStableDebt, reserveCache.nextAvgStableBorrowRate ) =
            IStableDebtToken(reserveCache.stableDebtToken)
                .mint(user, user, stableDebt, reserve.currentStableBorrowRate);

        reserve.updateInterestRates(reserveCache, asset, 0, 0);

        emit RebalanceStableBorrowRate(asset, user);
    }

    /**
     * @notice Implements the swap borrow rate feature. Borrowers can swap from variable to stable
     *         positions at any time.
     * @dev    Emits the `Swap()` event
     * @param  reserve          The of the reserve of the asset being repaid
     * @param  userConfig       The user configuration mapping that tracks the supplied/borrowed assets
     * @param  asset            The asset of the position being swapped
     * @param  interestRateMode The current interest rate mode of the position being swapped
     */
    function executeSwapBorrowRateMode(
        ReserveData storage reserve,
        UserConfigurationMap storage userConfig,
        address asset,
        InterestRateMode interestRateMode
    ) external {
        ReserveCache memory reserveCache = reserve.cache();

        reserve.updateState(reserveCache);

        ( uint256 stableDebt, uint256 variableDebt ) =
            Helpers.getUserCurrentDebt(msg.sender, reserveCache);

        ValidationLogic.validateSwapRateMode(
            reserve,
            reserveCache,
            userConfig,
            stableDebt,
            variableDebt,
            interestRateMode
        );

        if (interestRateMode == InterestRateMode.STABLE) {
            ( reserveCache.nextTotalStableDebt, reserveCache.nextAvgStableBorrowRate ) =
                IStableDebtToken(reserveCache.stableDebtToken).burn(msg.sender, stableDebt);

            ( , reserveCache.nextScaledVariableDebt ) =
                IVariableDebtToken(reserveCache.variableDebtToken)
                    .mint(msg.sender, msg.sender, stableDebt, reserveCache.nextVariableBorrowIndex);
        } else {
            reserveCache.nextScaledVariableDebt =
                IVariableDebtToken(reserveCache.variableDebtToken)
                    .burn(msg.sender, variableDebt, reserveCache.nextVariableBorrowIndex);

            ( , reserveCache.nextTotalStableDebt, reserveCache.nextAvgStableBorrowRate ) =
                IStableDebtToken(reserveCache.stableDebtToken)
                    .mint(msg.sender, msg.sender, variableDebt, reserve.currentStableBorrowRate);
        }

        reserve.updateInterestRates(reserveCache, asset, 0, 0);

        emit SwapBorrowRateMode(asset, msg.sender, interestRateMode);
    }

}
