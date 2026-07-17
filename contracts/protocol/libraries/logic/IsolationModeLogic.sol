// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IPool } from '../../../interfaces/IPool.sol';

import {
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../types/DataTypes.sol';

import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { UserConfiguration }    from '../configuration/UserConfiguration.sol';
import { SafeCast }             from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title  IsolationModeLogic library
 * @author Aave
 * @notice Implements the base logic for handling repayments for assets borrowed in isolation mode
 */
library IsolationModeLogic {

    using SafeCast for uint256;

    /**
     * @notice updated the isolated debt whenever a position collateralized by an isolated asset is
     *         repaid or liquidated
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  userConfig   The user configuration mapping
     * @param  reserveCache The cached data of the reserve
     * @param  repayAmount  The amount being repaid
     */
    function updateIsolatedDebtIfIsolated(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        UserConfigurationMap             storage userConfig,
        ReserveCache                     memory  reserveCache,
        uint256                                  repayAmount
    ) internal {
        ( bool isInIsolation, address collateralAsset, ) =
            UserConfiguration.getIsolationModeState(userConfig, reservesData, reservesList);

        if (!isInIsolation) return;

        uint256 isolationModeTotalDebt = reservesData[collateralAsset].isolationModeTotalDebt;

        // Scale the repaid amount down from the asset's native decimals to the debt ceiling's decimals (DEBT_CEILING_DECIMALS = 2).
        // For example, if borrowing a 18-decimal asset, it divides by 10^(18 - 2) = 10^16 to get the value in 2 decimals.
        uint128 isolatedDebtRepaid =
            (
                repayAmount /
                (
                    10 **
                    (
                        ReserveConfiguration.getDecimals(reserveCache.configuration) -
                        ReserveConfiguration.DEBT_CEILING_DECIMALS
                    )
                )
            ).toUint128();

        // The isolation total debt tracks principal exposure. Repayments include both principal and accrued interest,
        // so the calculated isolatedDebtRepaid can occasionally exceed isolationModeTotalDebt.
        // Cap the reduction to prevent integer underflow.
        isolationModeTotalDebt =
            isolationModeTotalDebt <= isolatedDebtRepaid
                ? 0
                : isolationModeTotalDebt - isolatedDebtRepaid;

        reservesData[collateralAsset].isolationModeTotalDebt = uint128(isolationModeTotalDebt);

        emit IPool.IsolationModeTotalDebtUpdated(collateralAsset, isolationModeTotalDebt);
    }

}
