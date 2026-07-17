// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { SafeCast }      from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import { IERC20 }        from '../../../dependencies/openzeppelin/contracts/IERC20.sol';

import { IAToken }                from '../../../interfaces/IAToken.sol';
import { IPool }                  from '../../../interfaces/IPool.sol';
import { IPoolAddressesProvider } from '../../../interfaces/IPoolAddressesProvider.sol';

import { IFlashLoanReceiver }     from '../../../flashloan/interfaces/IFlashLoanReceiver.sol';

import {
    IFlashLoanSimpleReceiver
} from '../../../flashloan/interfaces/IFlashLoanSimpleReceiver.sol';

import { UserConfiguration }    from '../configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { Errors }               from '../helpers/Errors.sol';
import { WadRayMath }           from '../math/WadRayMath.sol';
import { PercentageMath }       from '../math/PercentageMath.sol';


import {
    EModeCategory,
    FlashloanParams,
    FlashLoanRepaymentParams,
    FlashloanSimpleParams,
    InterestRateMode,
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../types/DataTypes.sol';

import { ValidationLogic } from './ValidationLogic.sol';
import { BorrowLogic }     from './BorrowLogic.sol';
import { ReserveLogic }    from './ReserveLogic.sol';

/**
 * @title  FlashLoanLogic library
 * @author Aave
 * @notice Implements the logic for the flash loans
 */
library FlashLoanLogic {

    using GPv2SafeERC20  for IERC20;
    using WadRayMath     for uint256;
    using PercentageMath for uint256;
    using SafeCast       for uint256;

    // Helper struct for internal variables used in the `executeFlashLoan` function
    struct FlashLoanLocalVars {
        IFlashLoanReceiver receiver;
        uint256            i;
        address            asset;
        uint256            amount;
        uint256[]          totalPremiums;
        uint256            premiumTotal;
        uint256            premiumToProtocol;
    }

    /**
     * @notice Implements the flashloan feature that allow users to access liquidity of the pool for
     *         one transaction as long as the amount taken plus fee is returned or debt is opened.
     * @dev    For authorized flashborrowers the fee is waived
     * @dev    At the end of the transaction the pool will pull amount borrowed + fee from the
     *         receiver, if the receiver have not approved the pool the transaction will revert.
     * @dev    Emits the `FlashLoan()` event
     * @param  reservesData    The state of all the reserves
     * @param  reservesList    The addresses of all the active reserves
     * @param  eModeCategories The configuration of all the efficiency mode categories
     * @param  userConfig      The user configuration mapping that tracks the supplied/borrowed
     *                         assets
     * @param  params          The additional parameters needed to execute the flashloan function
     */
    function executeFlashLoan(
        mapping (address => ReserveData) storage reservesData,
        mapping (uint256 => address)     storage reservesList,
        mapping (uint8 => EModeCategory) storage eModeCategories,
        UserConfigurationMap             storage userConfig,
        FlashloanParams                  memory  params
    ) external {
        // For flashloans, the usual action flow
        // (cache -> updateState -> validation -> changeState -> updateRates)
        // is altered to
        // (validation -> user payload -> cache -> updateState -> changeState -> updateRates)
        // to protect against reentrance and rate manipulation within the user specified payload.

        // Flash loan execution order is modified to prevent reentrancy and rate manipulation attacks.
        // By calling the user's payload (`executeOperation()`) BEFORE updating interest rates and caching states,
        // any actions inside the user payload (e.g., borrowing or depositing) will execute against accurate state representation,
        // and cannot exploit the transient/intermediate state of the flash loan itself.

        ValidationLogic.validateFlashloan(reservesData, params.assets, params.amounts);

        FlashLoanLocalVars memory vars;

        vars.totalPremiums = new uint256[](params.assets.length);

        vars.receiver = IFlashLoanReceiver(params.recipient);

        ( vars.premiumTotal, vars.premiumToProtocol ) =
            params.isAuthorizedFlashBorrower
                ? ( 0, 0 )
                : ( params.premiumTotal, params.premiumToProtocol );

        // Transfer the underlying assets to the recipient contract before invoking the user payload.
        for (vars.i = 0; vars.i < params.assets.length; vars.i++) {
            vars.amount = params.amounts[vars.i];

            vars.totalPremiums[vars.i] =
                params.interestRateModes[vars.i] == uint8(InterestRateMode.NONE)
                    ? vars.amount.percentMul(vars.premiumTotal)
                    : 0;

            IAToken(reservesData[params.assets[vars.i]].aToken)
                .transferUnderlyingTo(params.recipient, vars.amount);
        }

        // Execute the user's custom payload logic.
        require(
            vars.receiver.executeOperation(
                params.assets,
                params.amounts,
                vars.totalPremiums,
                msg.sender,
                params.params
            ),
            Errors.INVALID_FLASHLOAN_EXECUTOR_RETURN
        );

        // Verify and process repayments for all borrowed assets.
        for (vars.i = 0; vars.i < params.assets.length; vars.i++) {
            vars.asset  = params.assets[vars.i];
            vars.amount = params.amounts[vars.i];

            if (params.interestRateModes[vars.i] != uint8(InterestRateMode.NONE)) {
                revert('FLASHLOAN_INTO_BORROW_DEPRECATED');
            }

            _handleFlashLoanRepayment(
                reservesData[vars.asset],
                FlashLoanRepaymentParams({
                    asset             : vars.asset,
                    recipient         : params.recipient,
                    amount            : vars.amount,
                    totalPremium      : vars.totalPremiums[vars.i],
                    premiumToProtocol : vars.premiumToProtocol,
                    referralCode      : params.referralCode
                })
            );
        }
    }

    /**
     * @notice Implements the simple flashloan feature that allow users to access liquidity of ONE
     *         reserve for one transaction as long as the amount taken plus fee is returned.
     * @dev    Does not waive fee for approved flashborrowers nor allow taking on debt instead of
     *         repaying to save gas
     * @dev    At the end of the transaction the pool will pull amount borrowed + fee from the
     *         receiver, if the receiver have not approved the pool the transaction will revert.
     * @dev    Emits the `FlashLoan()` event
     * @param  reserveData The state of the flashloaned reserve
     * @param  params      The additional parameters needed to execute the simple flashloan function
     */
    function executeFlashLoanSimple(
        ReserveData           storage reserveData,
        FlashloanSimpleParams memory  params
    ) external {
        // For flashloans, the usual action flow
        // (cache -> updateState -> validation -> changeState -> updateRates)
        // is altered to
        // (validation -> user payload -> cache -> updateState -> changeState -> updateRates)
        // to protect against reentrance and rate manipulation within the user specified payload.

        ValidationLogic.validateFlashloanSimple(reserveData);

        uint256 totalPremium = params.amount.percentMul(params.premiumTotal);

        IAToken(reserveData.aToken).transferUnderlyingTo(params.recipient, params.amount);

        require(
            IFlashLoanSimpleReceiver(params.recipient)
                .executeOperation(
                    params.asset,
                    params.amount,
                    totalPremium,
                    msg.sender,
                    params.params
            ),
            Errors.INVALID_FLASHLOAN_EXECUTOR_RETURN
        );

        _handleFlashLoanRepayment(
            reserveData,
            FlashLoanRepaymentParams({
                asset             : params.asset,
                recipient         : params.recipient,
                amount            : params.amount,
                totalPremium      : totalPremium,
                premiumToProtocol : params.premiumToProtocol,
                referralCode      : params.referralCode
            })
        );
    }

    /**
     * @notice Handles repayment of flashloaned assets + premium
     * @dev    Will pull the amount + premium from the receiver, so must have approved pool
     * @param  reserveData The state of the flashloaned reserve
     * @param  params      The additional parameters needed to execute the repayment function
     */
    function _handleFlashLoanRepayment(
        ReserveData              storage reserveData,
        FlashLoanRepaymentParams memory  params
    ) internal {
        // Split the total premium: protocol fee is stored in accruedToTreasury, LP fee is compounded directly.
        uint256 premiumToProtocol = params.totalPremium.percentMul(params.premiumToProtocol);
        uint256 premiumToLP       = params.totalPremium - premiumToProtocol;
        uint256 amountPlusPremium = params.amount + params.totalPremium;

        ReserveCache memory reserveCache = ReserveLogic.cache(reserveData);

        ReserveLogic.updateState(reserveData, reserveCache);

        // Cumulate LP share of the premium directly into the liquidity index (compounding supplier rates).
        reserveCache.liquidityIndex =
            ReserveLogic.cumulateToLiquidityIndex(
                reserveData,
                IERC20(reserveCache.aToken).totalSupply() +
                uint256(reserveData.accruedToTreasury).rayMul(reserveCache.liquidityIndex),
                premiumToLP
            );

        // Protocol share is scaled down and registered under accruedToTreasury.
        reserveData.accruedToTreasury +=
            premiumToProtocol.rayDiv(reserveCache.liquidityIndex).toUint128();

        ReserveLogic.updateInterestRates(
            reserveData,
            reserveCache,
            params.asset,
            amountPlusPremium,
            0
        );

        // Pull the underlying principal + total fee from the recipient contract.
        IERC20(params.asset).safeTransferFrom(
            params.recipient,
            reserveCache.aToken,
            amountPlusPremium
        );

        IAToken(reserveCache.aToken).handleRepayment(
            params.recipient,
            params.recipient,
            amountPlusPremium
        );

        emit IPool.FlashLoan(
            params.recipient,
            msg.sender,
            params.asset,
            params.amount,
            InterestRateMode(0),
            params.totalPremium,
            params.referralCode
        );
    }

}
