// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { GPv2SafeERC20 }          from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { SafeCast }               from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import { IERC20 }                 from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { IAToken }                from '../../../interfaces/IAToken.sol';
import { IPool }                  from '../../../interfaces/IPool.sol';
import { IFlashLoanReceiver }     from '../../../flashloan/interfaces/IFlashLoanReceiver.sol';
import { IPoolAddressesProvider } from '../../../interfaces/IPoolAddressesProvider.sol';
import { UserConfiguration }      from '../configuration/UserConfiguration.sol';
import { ReserveConfiguration }   from '../configuration/ReserveConfiguration.sol';
import { Errors }                 from '../helpers/Errors.sol';
import { WadRayMath }             from '../math/WadRayMath.sol';
import { PercentageMath }         from '../math/PercentageMath.sol';

import {
    IFlashLoanSimpleReceiver
} from '../../../flashloan/interfaces/IFlashLoanSimpleReceiver.sol';

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

    using ReserveLogic         for ReserveCache;
    using ReserveLogic         for ReserveData;
    using GPv2SafeERC20        for IERC20;
    using ReserveConfiguration for ReserveConfigurationMap;
    using WadRayMath           for uint256;
    using PercentageMath       for uint256;
    using SafeCast             for uint256;

    // See `IPool` for descriptions
    event FlashLoan(
        address          indexed target,
        address                  initiator,
        address          indexed asset,
        uint256                  amount,
        InterestRateMode         interestRateMode,
        uint256                  premium,
        uint16           indexed referralCode
    );

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

        ValidationLogic.validateFlashloan(reservesData, params.assets, params.amounts);

        FlashLoanLocalVars memory vars;

        vars.totalPremiums = new uint256[](params.assets.length);

        vars.receiver = IFlashLoanReceiver(params.recipient);

        ( vars.premiumTotal, vars.premiumToProtocol ) =
            params.isAuthorizedFlashBorrower
                ? ( 0, 0 )
                : ( params.premiumTotal, params.premiumToProtocol );

        for (vars.i = 0; vars.i < params.assets.length; vars.i++) {
            vars.amount = params.amounts[vars.i];

            vars.totalPremiums[vars.i] =
                params.interestRateModes[vars.i] == uint8(InterestRateMode.NONE)
                    ? vars.amount.percentMul(vars.premiumTotal)
                    : 0;

            IAToken(reservesData[params.assets[vars.i]].aToken)
                .transferUnderlyingTo(params.recipient, vars.amount);
        }

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
        uint256 premiumToProtocol = params.totalPremium.percentMul(params.premiumToProtocol);
        uint256 premiumToLP       = params.totalPremium - premiumToProtocol;
        uint256 amountPlusPremium = params.amount + params.totalPremium;

        ReserveCache memory reserveCache = reserveData.cache();

        reserveData.updateState(reserveCache);

        reserveCache.nextLiquidityIndex =
            reserveData.cumulateToLiquidityIndex(
                IERC20(reserveCache.aToken).totalSupply() +
                uint256(reserveData.accruedToTreasury).rayMul(reserveCache.nextLiquidityIndex),
                premiumToLP
            );

        reserveData.accruedToTreasury +=
            premiumToProtocol.rayDiv(reserveCache.nextLiquidityIndex).toUint128();

        reserveData.updateInterestRates(reserveCache, params.asset, amountPlusPremium, 0);

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

        emit FlashLoan(
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
