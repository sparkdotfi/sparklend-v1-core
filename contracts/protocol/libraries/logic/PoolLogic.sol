// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { Address }       from '../../../dependencies/openzeppelin/contracts/Address.sol';
import { IERC20 }        from '../../../dependencies/openzeppelin/contracts/IERC20.sol';

import { IAToken } from '../../../interfaces/IAToken.sol';
import { IPool }   from '../../../interfaces/IPool.sol';

import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { Errors }               from '../helpers/Errors.sol';
import { WadRayMath }           from '../math/WadRayMath.sol';

import {
    CalculateUserAccountDataParams,
    EModeCategory,
    InitReserveParams,
    ReserveConfigurationMap,
    ReserveData
} from '../types/DataTypes.sol';

import { ReserveLogic }    from './ReserveLogic.sol';
import { ValidationLogic } from './ValidationLogic.sol';
import { GenericLogic }    from './GenericLogic.sol';

/**
 * @title  PoolLogic library
 * @author Aave
 * @notice Implements the logic for Pool specific functions
 */
library PoolLogic {

    using GPv2SafeERC20 for IERC20;
    using WadRayMath    for uint256;

    /**
     * @notice Initialize an asset reserve and add the reserve to the list of reserves
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  params       Additional parameters needed for initiation
     * @return existed      true if appended, false if inserted at existing empty spot
     */
    function executeInitReserve(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        InitReserveParams                memory  params
    ) external returns (bool) {
        require(Address.isContract(params.asset), Errors.NOT_CONTRACT);

        ReserveLogic.init(
            reservesData[params.asset],
            params.aToken,
            params.stableDebt,
            params.variableDebt,
            params.interestRateStrategy
        );

        bool reserveAlreadyAdded =
            reservesData[params.asset].id != 0 || reservesList[0] == params.asset;

        require(!reserveAlreadyAdded, Errors.RESERVE_ALREADY_ADDED);

        // Search the existing reservesList for any empty/deleted slot (represented by address(0))
        // to re-use the index and keep the active list contiguous/compact, avoiding index expansion.
        for (uint16 i = 0; i < params.reservesCount; i++) {
            if (reservesList[i] != address(0)) continue;

            reservesData[params.asset].id = i;
            reservesList[i]               = params.asset;

            return false; // Returns false since it did not expand the reservesCount list size
        }

        require(params.reservesCount < params.maxNumberReserves, Errors.NO_MORE_RESERVES_ALLOWED);

        // If no empty slot was found, append the reserve to the end of the list.
        reservesData[params.asset].id      = params.reservesCount;
        reservesList[params.reservesCount] = params.asset;

        return true; // Returns true since it expanded the reservesCount list size
    }

    /**
     * @notice Rescue and transfer tokens locked in this contract
     * @param  token  The address of the token
     * @param  to     The address of the recipient
     * @param  amount The amount of token to transfer
     */
    function executeRescueTokens(address token, address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Mints the assets accrued through the reserve factor to the treasury in the form of
     *         aTokens
     * @param  reservesData The state of all the reserves
     * @param  assets       The list of reserves for which the minting needs to be executed
     */
    function executeMintToTreasury(
        mapping (address => ReserveData) storage  reservesData,
        address[]                        calldata assets
    ) external {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            ReserveData storage reserveData = reservesData[asset];

            // Only mint fees for active reserves.
            if (!ReserveConfiguration.getActive(reserveData.configuration)) continue;

            uint256 accruedToTreasury = reserveData.accruedToTreasury;

            if (accruedToTreasury == 0) continue;

            // Reset the storage value to 0 before executing external mint call (CEI pattern to prevent reentrancy issues).
            reserveData.accruedToTreasury = 0;

            // Convert the scaled accrued debt fee to unscaled token amount by multiplying by the current liquidity index (normalized income)
            uint256 normalizedIncome = ReserveLogic.getNormalizedIncome(reserveData);
            uint256 amountToMint     = accruedToTreasury.rayMul(normalizedIncome);

            IAToken(reserveData.aToken).mintToTreasury(amountToMint, normalizedIncome);

            emit IPool.MintedToTreasury(asset, amountToMint);
        }
    }

    /**
     * @notice Resets the isolation mode total debt of the given asset to zero
     * @dev    It requires the given asset has zero debt ceiling
     * @param  reservesData The state of all the reserves
     * @param  asset        The address of the underlying asset to reset the isolationModeTotalDebt
     */
    function executeResetIsolationModeTotalDebt(
        mapping (address => ReserveData) storage reservesData,
        address                                  asset
    ) external {
        require(
            ReserveConfiguration.getDebtCeiling(reservesData[asset].configuration) == 0,
            Errors.DEBT_CEILING_NOT_ZERO
        );

        reservesData[asset].isolationModeTotalDebt = 0;

        emit IPool.IsolationModeTotalDebtUpdated(asset, 0);
    }

    /**
     * @notice Drop a reserve
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  asset        The address of the underlying asset of the reserve
     */
    function executeDropReserve(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        address                                  asset
    ) external {
        ReserveData storage reserveData = reservesData[asset];

        ValidationLogic.validateDropReserve(reservesList, reserveData, asset);

        delete reservesList[reserveData.id];
        delete reservesData[asset];
    }

    /**
     * @notice Returns the user account data across all the reserves
     * @param  reservesData         The state of all the reserves
     * @param  reservesList         The addresses of all the active reserves
     * @param  eModeCategories      The configuration of all the efficiency mode categories
     * @param  params               Additional params needed for the calculation
     * @return totalCollateral      The total collateral of the user in the base currency used by
     *                              the price feed
     * @return totalDebt            The total debt of the user in the base currency used by the
     *                              price feed
     * @return availableBorrows     The borrowing power left of the user in the base currency used
     *                              by the price feed
     * @return liquidationThreshold The liquidation threshold of the user
     * @return ltv                  The loan to value of The user
     * @return healthFactor         The current health factor of the user
     */
    function executeGetUserAccountData(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        CalculateUserAccountDataParams   memory  params
    )
        external
        view
        returns (
            uint256 totalCollateral,
            uint256 totalDebt,
            uint256 availableBorrows,
            uint256 liquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        ( totalCollateral, totalDebt, ltv, liquidationThreshold, healthFactor, ) =
            GenericLogic.calculateUserAccountData(
                reservesData,
                reservesList,
                eModeCategories,
                params
            );

        availableBorrows = GenericLogic.calculateAvailableBorrows(totalCollateral, totalDebt, ltv);
    }

}
