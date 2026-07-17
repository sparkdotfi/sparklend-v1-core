// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20 }        from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { SafeCast }      from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import { GPv2SafeERC20 } from '../../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';

import { IStableDebtToken }             from '../../../interfaces/IStableDebtToken.sol';
import { IVariableDebtToken }           from '../../../interfaces/IVariableDebtToken.sol';
import { IReserveInterestRateStrategy } from '../../../interfaces/IReserveInterestRateStrategy.sol';
import { IPool }                        from '../../../interfaces/IPool.sol';

import { ReserveConfiguration } from '../configuration/ReserveConfiguration.sol';
import { MathUtils }            from '../math/MathUtils.sol';
import { WadRayMath }           from '../math/WadRayMath.sol';
import { PercentageMath }       from '../math/PercentageMath.sol';
import { Errors }               from '../helpers/Errors.sol';

import {
    CalculateInterestRatesParams,
    ReserveCache,
    ReserveConfigurationMap,
    ReserveData
} from '../types/DataTypes.sol';

/**
 * @title  ReserveLogic library
 * @author Aave
 * @notice Implements the logic to update the reserves state
 */
library ReserveLogic {

    using WadRayMath     for uint256;
    using PercentageMath for uint256;
    using SafeCast       for uint256;
    using GPv2SafeERC20  for IERC20;

    /**
     * @notice Returns the ongoing normalized income for the reserve.
     * @dev    A value of 1e27 means there is no income. As time passes, the income is accrued
     * @dev    A value of 2*1e27 means for each unit of asset one unit of income has been accrued
     * @param  data   The reserve object
     * @return income The normalized income, expressed in ray
     */
    function getNormalizedIncome(ReserveData storage data) internal view returns (uint256) {
        uint40 timestamp = data.lastUpdateTimestamp;

        // If the index was already updated in the same block, return the stored index directly.
        // Otherwise, calculate the ongoing linear index interest accrued since the last update.
        //solium-disable-next-line
        return timestamp == block.timestamp
            ? data.liquidityIndex
            : getNextIndex({
                    currentIndex  : data.liquidityIndex,
                    rate          : data.liquidityRate,
                    lastTimestamp : timestamp,
                    getIndex      : MathUtils.getLinearIndexToNow
                });
    }

    /**
     * @notice Returns the ongoing normalized variable debt for the reserve.
     * @dev    A value of 1e27 means there is no debt. As time passes, the debt is accrued
     * @dev    A value of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
     * @param  data The reserve object
     * @return debt The normalized variable debt, expressed in ray
     */
    function getNormalizedDebt(ReserveData storage data) internal view returns (uint256) {
        uint40 timestamp = data.lastUpdateTimestamp;

        // if the index was updated in the same block, no need to perform any calculation
        //solium-disable-next-line
        return timestamp == block.timestamp
            ? data.variableBorrowIndex
            : getNextIndex({
                    currentIndex  : data.variableBorrowIndex,
                    rate          : data.variableBorrowRate,
                    lastTimestamp : timestamp,
                    getIndex      : MathUtils.getCompoundedIndexToNow
                });
    }

    /**
     * @notice Updates the liquidity cumulative index and the variable borrow index.
     * @param  data  The reserve object
     * @param  cache The caching layer for the reserve data
     */
    function updateState(ReserveData storage data, ReserveCache memory cache) internal {
        // If time didn't pass since last stored timestamp, skip state update
        //solium-disable-next-line
        if (data.lastUpdateTimestamp == block.timestamp) return;

        updateIndexes(data, cache);
        accrueToTreasury(data, cache);

        //solium-disable-next-line
        data.lastUpdateTimestamp = uint40(block.timestamp);
    }

    /**
     * @notice Accumulates a predefined amount of asset to the reserve as a fixed, instantaneous
     *         income. Used for example to accumulate the flashloan fee to the reserve, and spread it between all the suppliers.
     * @param  data           The reserve object
     * @param  totalLiquidity The total liquidity available in the reserve
     * @param  amount         The amount to accumulate
     * @return liquidityIndex The next liquidity index of the reserve
     */
    function cumulateToLiquidityIndex(
        ReserveData storage data,
        uint256             totalLiquidity,
        uint256             amount
    ) internal returns (uint256 liquidityIndex) {
        // next liquidity index is calculated as: `((amount / totalLiquidity) + 1) * liquidityIndex`
        // division `amount / totalLiquidity` is done in ray for precision
        // This spreads the accrued fee (amount) across all existing LPs by proportionally inflating the liquidity index.
        liquidityIndex =
            (
                amount.wadToRay().rayDiv(totalLiquidity.wadToRay()) + WadRayMath.RAY
            ).rayMul(data.liquidityIndex);

        data.liquidityIndex = liquidityIndex.toUint128();
    }

    /**
     * @notice Initializes a reserve.
     * @param  data                 The reserve object
     * @param  aToken               The address of the overlying atoken contract
     * @param  stableDebtToken      The address of the overlying stable debt token contract
     * @param  variableDebtToken    The address of the overlying variable debt token contract
     * @param  interestRateStrategy The address of the interest rate strategy contract
     */
    function init(
        ReserveData storage data,
        address             aToken,
        address             stableDebtToken,
        address             variableDebtToken,
        address             interestRateStrategy
    ) internal {
        require(data.aToken == address(0), Errors.RESERVE_ALREADY_INITIALIZED);

        data.liquidityIndex       = uint128(WadRayMath.RAY);
        data.variableBorrowIndex  = uint128(WadRayMath.RAY);
        data.aToken               = aToken;
        data.stableDebtToken      = stableDebtToken;
        data.variableDebtToken    = variableDebtToken;
        data.interestRateStrategy = interestRateStrategy;
    }

    struct UpdateInterestRatesLocalVars {
        uint256 nextLiquidityRate;
        uint256 nextStableRate;
        uint256 nextVariableRate;
        uint256 totalVariableDebt;
    }

    /**
     * @notice Updates the reserve current stable borrow rate, the current variable borrow rate and
     *         the current liquidity rate.
     * @param  data           The reserve data to be updated
     * @param  cache          The caching layer for the reserve data
     * @param  reserve        The address of the reserve to be updated
     * @param  liquidityAdded The amount of liquidity added to the protocol (supply or repay) in the
     *                        previous action
     * @param  liquidityTaken The amount of liquidity taken from the protocol (redeem or borrow)
     */
    function updateInterestRates(
        ReserveData  storage data,
        ReserveCache memory  cache,
        address              reserve,
        uint256              liquidityAdded,
        uint256              liquidityTaken
    ) internal {
        UpdateInterestRatesLocalVars memory vars;

        vars.totalVariableDebt =
            cache.scaledVariableDebt.rayMul(cache.variableBorrowIndex);

        ( vars.nextLiquidityRate, vars.nextStableRate, vars.nextVariableRate ) =
            IReserveInterestRateStrategy(data.interestRateStrategy).calculateInterestRates(
                CalculateInterestRatesParams({
                    unbacked            : data.unbacked,
                    liquidityAdded      : liquidityAdded,
                    liquidityTaken      : liquidityTaken,
                    totalStableDebt     : cache.totalStableDebt,
                    totalVariableDebt   : vars.totalVariableDebt,
                    avgStableBorrowRate : cache.avgStableBorrowRate,
                    reserveFactor       : cache.reserveFactor,
                    reserve             : reserve,
                    aToken              : cache.aToken
                })
            );

        data.liquidityRate      = vars.nextLiquidityRate.toUint128();
        data.stableBorrowRate   = vars.nextStableRate.toUint128();
        data.variableBorrowRate = vars.nextVariableRate.toUint128();

        emit IPool.ReserveDataUpdated(
            reserve,
            vars.nextLiquidityRate,
            vars.nextStableRate,
            vars.nextVariableRate,
            cache.liquidityIndex,
            cache.variableBorrowIndex
        );
    }

    struct AccrueToTreasuryLocalVars {
        uint256 previousTotalStableDebt;
        uint256 previousTotalVariableDebt;
        uint256 totalVariableDebt;
        uint256 cumulatedStableInterest;
        uint256 totalDebtAccrued;
        uint256 amountToMint;
    }

    /**
     * @notice Mints part of the repaid interest to the reserve treasury as a function of the
     *         reserve factor for the specific asset.
     * @param  data  The reserve to be updated
     * @param  cache The caching layer for the reserve data
     */
    function accrueToTreasury(ReserveData storage data, ReserveCache memory cache) internal {
        AccrueToTreasuryLocalVars memory vars;

        // If the reserve factor is 0, no interest is redirected to the protocol treasury
        if (cache.reserveFactor == 0) return;

        // 1. Calculate the total variable debt at the moment of the last interaction
        vars.previousTotalVariableDebt =
            cache.startingScaledVariableDebt.rayMul(cache.startingVariableBorrowIndex);

        // 2. Calculate the new total variable debt after compounding the variable index up to the current block
        vars.totalVariableDebt =
            cache.startingScaledVariableDebt.rayMul(cache.variableBorrowIndex);

        // 3. Compounded stable interest index since the last update
        vars.cumulatedStableInterest =
            MathUtils.getCompoundedIndex(
                cache.startingAvgStableBorrowRate,
                cache.stableDebtLastUpdateTimestamp,
                cache.reserveLastUpdateTimestamp
            );

        vars.previousTotalStableDebt =
            cache.principalStableDebt.rayMul(vars.cumulatedStableInterest);

        // 4. Calculate total debt accrued (interest accumulated) on both stable and variable borrow sides
        vars.totalDebtAccrued =
            vars.totalVariableDebt +
            cache.startingTotalStableDebt -
            vars.previousTotalVariableDebt -
            vars.previousTotalStableDebt;

        // 5. The protocol's share of interest is calculated using the reserve factor percentage (in BPS)
        vars.amountToMint = vars.totalDebtAccrued.percentMul(cache.reserveFactor);

        if (vars.amountToMint == 0) return;

        // 6. Convert the minted fee value into a scaled representation by dividing by the next liquidity index,
        // and register it as accruedToTreasury so it can be minted as aTokens later.
        data.accruedToTreasury +=
            vars.amountToMint.rayDiv(cache.liquidityIndex).toUint128();
    }

    /**
     * @notice Updates the reserve indexes and the timestamp of the update.
     * @param  data  The reserve reserve to be updated
     * @param  cache The cache layer holding the cached protocol data
     */
    function updateIndexes(ReserveData storage data, ReserveCache memory cache) internal {
        // Only cumulating on the supply side if there is any income being produced
        // The case of Reserve Factor 100% is not a problem (liquidityRate == 0),
        // as liquidity index should not be updated
        if (cache.liquidityRate != 0) {
            data.liquidityIndex =
                (
                    cache.liquidityIndex = getNextIndex({
                        currentIndex  : cache.liquidityIndex,
                        rate          : cache.liquidityRate,
                        lastTimestamp : cache.reserveLastUpdateTimestamp,
                        getIndex      : MathUtils.getLinearIndexToNow
                    })
                ).toUint128();
        }

        // Variable borrow index only gets updated if there is any variable debt.
        // cache.variableBorrowRate != 0 is not a correct validation,
        // because a positive base variable rate can be stored on
        // cache.variableBorrowRate, but the index should not increase
        if (cache.startingScaledVariableDebt != 0) {
            data.variableBorrowIndex =
                (
                    cache.variableBorrowIndex = getNextIndex({
                        currentIndex  : cache.startingVariableBorrowIndex,
                        rate          : cache.variableBorrowRate,
                        lastTimestamp : cache.reserveLastUpdateTimestamp,
                        getIndex      : MathUtils.getCompoundedIndexToNow
                    })
                ).toUint128();
        }
    }

    function getNextIndex(
        uint256  currentIndex,
        uint256  rate,
        uint40   lastTimestamp,
        function (uint256, uint40) internal view returns (uint256) getIndex
    ) internal view returns (uint256) {
        return getIndex(rate, lastTimestamp).rayMul(currentIndex);
    }

    /**
     * @notice Creates a cache object to avoid repeated storage reads and external contract calls
     *         when updating state and interest rates.
     * @param  data  The reserve object for which the cache will be filled
     * @return cache The cache object
     */
    function cache(ReserveData storage data) internal view returns (ReserveCache memory cache) {
        // Pre-fill the cache object with basic reserve config parameters to avoid repeating storage reads (SLOAD)
        cache.configuration               = data.configuration;
        cache.reserveFactor               = ReserveConfiguration.getReserveFactor(cache.configuration);
        cache.startingLiquidityIndex      = data.liquidityIndex;
        cache.startingVariableBorrowIndex = data.variableBorrowIndex;
        cache.liquidityRate               = data.liquidityRate;
        cache.variableBorrowRate          = data.variableBorrowRate;
        cache.aToken                      = data.aToken;
        cache.reserveLastUpdateTimestamp  = data.lastUpdateTimestamp;
        cache.variableDebtToken           = data.variableDebtToken;
        cache.stableDebtToken             = data.stableDebtToken;

        // Perform external contract calls to get variable debt scaled total supply and stable supply statistics
        cache.startingScaledVariableDebt =
            IVariableDebtToken(cache.variableDebtToken).scaledTotalSupply();

        (
            cache.principalStableDebt,
            cache.startingTotalStableDebt,
            cache.startingAvgStableBorrowRate,
            cache.stableDebtLastUpdateTimestamp
        ) = IStableDebtToken(cache.stableDebtToken).getSupplyData();


        // By default, the actions are considered as not affecting the debt balances.
        // If the action involves minting or burning debt, the cache needs to be updated manually in logic flows.
        cache.liquidityIndex      = cache.startingLiquidityIndex;
        cache.scaledVariableDebt  = cache.startingScaledVariableDebt;
        cache.totalStableDebt     = cache.startingTotalStableDebt;
        cache.avgStableBorrowRate = cache.startingAvgStableBorrowRate;
        cache.variableBorrowIndex = cache.startingVariableBorrowIndex;
    }

}
