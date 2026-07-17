// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }        from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { SafeCast }      from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';

import { IAToken } from '../../../interfaces/IAToken.sol';
import { IPool }   from '../../../interfaces/IPool.sol';

import {
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../types/DataTypes.sol';

import { UserConfiguration }    from '../configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { WadRayMath }           from '../math/WadRayMath.sol';
import { PercentageMath }       from '../math/PercentageMath.sol';
import { Errors }               from '../helpers/Errors.sol';
import { ValidationLogic }      from './ValidationLogic.sol';
import { ReserveLogic }         from './ReserveLogic.sol';

library BridgeLogic {

    using WadRayMath     for uint256;
    using PercentageMath for uint256;
    using SafeCast       for uint256;
    using GPv2SafeERC20  for IERC20;

    /**
     * @notice Mint unbacked aTokens to a user and updates the unbacked for the reserve.
     * @dev    Essentially a supply without transferring the underlying.
     * @dev    Emits the `MintUnbacked` event
     * @dev    Emits the `ReserveUsedAsCollateralEnabled` if asset is set as collateral
     * @param  reservesData The state of all the reserves
     * @param  reservesList The addresses of all the active reserves
     * @param  userConfig   The user configuration mapping that tracks the supplied/borrowed assets
     * @param  asset        The address of the underlying asset to mint aTokens of
     * @param  amount       The amount to mint
     * @param  onBehalfOf   The address that will receive the aTokens
     * @param  referralCode Code used to register the integrator originating the operation, for
     *                      potential rewards. 0 if the action is executed directly by the user,
     *                      without any middle-man
     */
    function executeMintUnbacked(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        UserConfigurationMap             storage userConfig,
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  referralCode
    ) external {
        ReserveData storage reserveData = reservesData[asset];

        // Cache reserve storage fields to memory
        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        // Accrue interest and update indexes up to the current block
        ReserveLogic.updateState(reserveData, reserveCache);
        ValidationLogic.validateSupply(reserveCache, reserveData, amount);

        uint256 unbackedMintCap = ReserveConfiguration.getUnbackedMintCap(reserveCache.configuration);
        uint256 reserveDecimals = ReserveConfiguration.getDecimals(reserveCache.configuration);
        uint256 unbacked        = reserveData.unbacked += amount.toUint128();

        // Enforce the unbacked mint cap (scaled by underlying asset decimals)
        require(
            unbacked <= unbackedMintCap * (10 ** reserveDecimals),
            Errors.UNBACKED_MINT_CAP_EXCEEDED
        );

        // Update interest rates (liquidity added is 0, taken is 0 because no actual tokens are transferred)
        ReserveLogic.updateInterestRates(reserveData, reserveCache, asset, 0, 0);

        // Mint the unbacked aTokens to the receiver, using the updated liquidity index
        bool isFirstSupply =
            IAToken(reserveCache.aToken)
                .mint(msg.sender, onBehalfOf, amount, reserveCache.liquidityIndex);

        // If this is the user's first time supplying this asset, check if it should be automatically enabled as collateral
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

            emit IPool.ReserveUsedAsCollateralEnabled(asset, onBehalfOf);
        }

        emit IPool.MintUnbacked(asset, msg.sender, onBehalfOf, amount, referralCode);
    }

    /**
     * @notice Back the current unbacked with `amount` and pay `fee`.
     * @dev    It is not possible to back more than the existing unbacked amount of the reserve
     * @dev    Emits the `BackUnbacked` event
     * @param  reserveData    The reserve to back unbacked for
     * @param  asset          The address of the underlying asset to repay
     * @param  amount         The amount to back
     * @param  fee            The amount paid in fees
     * @param  protocolFeeBps The fraction of fees in basis points paid to the protocol
     * @return backingAmount  The backed amount
     */
    function executeBackUnbacked(
        ReserveData storage reserveData,
        address             asset,
        uint256             amount,
        uint256             fee,
        uint256             protocolFeeBps
    ) external returns (uint256 backingAmount) {
        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        // Accrue interest and update indexes before changing underlying reserve amounts
        ReserveLogic.updateState(reserveData, reserveCache);

        // Cannot back more than the current total outstanding unbacked amount
        backingAmount = (amount < reserveData.unbacked) ? amount : reserveData.unbacked;

        // Split backing fee: protocol gets its BPS share, liquidity providers get the rest
        uint256 feeToProtocol = fee.percentMul(protocolFeeBps);
        uint256 feeToLP       = fee - feeToProtocol;
        uint256 added         = backingAmount + fee;

        // LP fee is directly accumulated into the liquidity index.
        // This increases the value of all existing LPs' aTokens (compounding their earnings).
        reserveCache.liquidityIndex =
            ReserveLogic.cumulateToLiquidityIndex(
                reserveData,
                IERC20(reserveCache.aToken).totalSupply() +
                uint256(reserveData.accruedToTreasury).rayMul(reserveCache.liquidityIndex),
                feeToLP
            );

        // Protocol fee share is converted to scaled balance and added to the accrued treasury index
        reserveData.accruedToTreasury +=
            feeToProtocol.rayDiv(reserveCache.liquidityIndex).toUint128();

        // Reduce outstanding unbacked debt by the backed amount
        reserveData.unbacked -= backingAmount.toUint128();

        // Update interest rates with the newly injected backing + fee liquidity
        ReserveLogic.updateInterestRates(reserveData, reserveCache, asset, added, 0);

        // Transfer backing funds + fee from the caller directly to the aToken contract
        IERC20(asset).safeTransferFrom(msg.sender, reserveCache.aToken, added);

        emit IPool.BackUnbacked(asset, msg.sender, backingAmount, fee);
    }

}
