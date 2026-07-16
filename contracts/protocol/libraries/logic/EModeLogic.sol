// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { GPv2SafeERC20 }      from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { IERC20 }             from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { IPriceOracleGetter } from '../../../interfaces/IPriceOracleGetter.sol';
import { UserConfiguration }  from '../configuration/UserConfiguration.sol';
import { Errors }             from '../helpers/Errors.sol';
import { WadRayMath }         from '../math/WadRayMath.sol';
import { PercentageMath }     from '../math/PercentageMath.sol';

import {
    EModeCategory,
    ExecuteSetUserEModeParams,
    ReserveCache,
    ReserveData,
    UserConfigurationMap
 } from '../types/DataTypes.sol';

import { ValidationLogic } from './ValidationLogic.sol';
import { ReserveLogic }    from './ReserveLogic.sol';

/**
 * @title  EModeLogic library
 * @author Aave
 * @notice Implements the base logic for all the actions related to the eMode
 */
library EModeLogic {

    using ReserveLogic for ReserveCache;
    using ReserveLogic for ReserveData;
    using GPv2SafeERC20 for IERC20;
    using UserConfiguration for UserConfigurationMap;
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    // See `IPool` for descriptions
    event UserEModeSet(address indexed user, uint8 categoryId);

    /**
     * @notice Updates the user efficiency mode category
     * @dev    Will revert if user is borrowing non-compatible asset or change will drop
     *         `HF < HEALTH_FACTOR_LIQUIDATION_THRESHOLD`
     * @dev    Emits the `UserEModeSet` event
     * @param  reservesData       The state of all the reserves
     * @param  reservesList       The addresses of all the active reserves
     * @param  eModeCategories    The configuration of all the efficiency mode categories
     * @param  usersEModeCategory The state of all users efficiency mode category
     * @param  userConfig         The user configuration mapping that tracks the supplied/borrowed
     *                            assets
     * @param  params             The additional parameters needed to execute the `setUserEMode`
     *                            function
     */
    function executeSetUserEMode(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        mapping (address => uint8)       storage usersEModeCategory,
        UserConfigurationMap             storage userConfig,
        ExecuteSetUserEModeParams        memory  params
    ) external {
        ValidationLogic.validateSetUserEMode(
            reservesData,
            reservesList,
            eModeCategories,
            userConfig,
            params.reservesCount,
            params.categoryId
        );

        uint8 previousCategoryId = usersEModeCategory[msg.sender];

        usersEModeCategory[msg.sender] = params.categoryId;

        if (previousCategoryId != 0) {
            ValidationLogic.validateHealthFactor(
                reservesData,
                reservesList,
                eModeCategories,
                userConfig,
                msg.sender,
                params.categoryId,
                params.reservesCount,
                params.oracle
            );
        }

        emit UserEModeSet(msg.sender, params.categoryId);
    }

    /**
     * @notice Gets the eMode configuration and calculates the eMode asset price if a custom oracle
     *         is configured
     * @dev    The eMode asset price returned is 0 if no oracle is specified
     * @param  category             The user eMode category
     * @param  oracle               The price oracle
     * @return ltv                  The eMode ltv
     * @return liquidationThreshold The eMode liquidation threshold
     * @return eModeAssetPrice      The eMode asset price
     */
    function getEModeConfiguration(
        EModeCategory storage category,
        address               oracle
    ) internal view returns (uint256 ltv, uint256 liquidationThreshold, uint256 eModeAssetPrice) {
        address eModePriceSource = category.priceSource;

        if (eModePriceSource != address(0)) {
            eModeAssetPrice = IPriceOracleGetter(oracle).getAssetPrice(eModePriceSource);
        }

        return ( category.ltv, category.liquidationThreshold, eModeAssetPrice );
    }

    /**
     * @notice Checks if eMode is active for a user and if yes, if the asset belongs to the eMode
     *         category chosen
     * @param  eModeUserCategory  The user eMode category
     * @param  eModeAssetCategory The asset eMode category
     * @return isEModeActive      True if eMode is active and the asset belongs to the eMode
     *                            category chosen by the user, false otherwise
     */
    function isInEModeCategory(
        uint256 eModeUserCategory,
        uint256 eModeAssetCategory
    ) internal pure returns (bool) {
        return (eModeUserCategory != 0) && (eModeAssetCategory == eModeUserCategory);
    }

}
