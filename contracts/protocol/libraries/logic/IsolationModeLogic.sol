// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

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

    using ReserveConfiguration for ReserveConfigurationMap;
    using UserConfiguration    for UserConfigurationMap;
    using SafeCast             for uint256;

    // See `IPool` for descriptions
    event IsolationModeTotalDebtUpdated(address indexed asset, uint256 totalDebt);

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
            userConfig.getIsolationModeState(reservesData, reservesList);

        if (!isInIsolation) return;

        uint128 isolationModeTotalDebt = reservesData[collateralAsset].isolationModeTotalDebt;

        uint128 isolatedDebtRepaid =
            (
                repayAmount /
                (
                    10 **
                    (
                        reserveCache.reserveConfiguration.getDecimals() -
                        ReserveConfiguration.DEBT_CEILING_DECIMALS
                    )
                )
            ).toUint128();

        // since the debt ceiling does not take into account the interest accrued, it might happen
        // that amount repaid > debt in isolation mode
        uint256 nextIsolationModeTotalDebt =
            isolationModeTotalDebt <= isolatedDebtRepaid
                ? 0
                : isolationModeTotalDebt - isolatedDebtRepaid;

        reservesData[collateralAsset].isolationModeTotalDebt = uint128(nextIsolationModeTotalDebt);

        emit IsolationModeTotalDebtUpdated(collateralAsset, nextIsolationModeTotalDebt);
    }

}
