// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { IReserveInterestRateStrategy } from './IReserveInterestRateStrategy.sol';

/**
 * @title  IDefaultInterestRateStrategy
 * @author Aave
 * @notice Defines the basic interface of the DefaultReserveInterestRateStrategy
 */
interface IDefaultInterestRateStrategy is IReserveInterestRateStrategy {

    /**
     * @notice Returns the usage ratio at which the pool aims to obtain most competitive borrow rates.
     * @return ratio The optimal usage ratio, expressed in ray.
     */
    function OPTIMAL_USAGE_RATIO() external view returns (uint256 ratio);

    /**
     * @notice Returns the optimal stable to total debt ratio of the reserve.
     * @return ratio The optimal stable to total debt ratio, expressed in ray.
     */
    function OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO() external view returns (uint256 ratio);

    /**
     * @notice Returns the excess usage ratio above the optimal.
     * @dev    It's always equal to 1-optimal usage ratio (added as constant for gas optimizations)
     * @return ratio The max excess usage ratio, expressed in ray.
     */
    function MAX_EXCESS_USAGE_RATIO() external view returns (uint256 ratio);

    /**
     * @notice Returns the excess stable debt ratio above the optimal.
     * @dev    It's always equal to 1-optimal stable to total debt ratio (added as constant for gas optimizations)
     * @return ratio The max excess stable to total debt ratio, expressed in ray.
     */
    function MAX_EXCESS_STABLE_TO_TOTAL_DEBT_RATIO() external view returns (uint256 ratio);

    /**
     * @notice Returns the address of the PoolAddressesProvider
     * @return provider The address of the PoolAddressesProvider contract
     */
    function ADDRESSES_PROVIDER() external view returns (address provider);

    /**
     * @notice Returns the variable rate slope below optimal usage ratio
     * @dev    It's the variable rate when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO
     * @return slope The variable rate slope, expressed in ray
     */
    function getVariableRateSlope1() external view returns (uint256 slope);

    /**
     * @notice Returns the variable rate slope above optimal usage ratio
     * @dev    It's the variable rate when usage ratio > OPTIMAL_USAGE_RATIO
     * @return slope The variable rate slope, expressed in ray
     */
    function getVariableRateSlope2() external view returns (uint256 slope);

    /**
     * @notice Returns the stable rate slope below optimal usage ratio
     * @dev    It's the stable rate when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO
     * @return slope The stable rate slope, expressed in ray
     */
    function getStableRateSlope1() external view returns (uint256 slope);

    /**
     * @notice Returns the stable rate slope above optimal usage ratio
     * @dev    It's the variable rate when usage ratio > OPTIMAL_USAGE_RATIO
     * @return slope The stable rate slope, expressed in ray
     */
    function getStableRateSlope2() external view returns (uint256 slope);

    /**
     * @notice Returns the stable rate excess offset
     * @dev    It's an additional premium applied to the stable when stable debt > OPTIMAL_STABLE_TO_TOTAL_DEBT_RATIO
     * @return offset The stable rate excess offset, expressed in ray
     */
    function getStableRateExcessOffset() external view returns (uint256 offset);

    /**
     * @notice Returns the base stable borrow rate
     * @return rate The base stable borrow rate, expressed in ray
     */
    function getBaseStableBorrowRate() external view returns (uint256 rate);

    /**
     * @notice Returns the base variable borrow rate
     * @return rate The base variable borrow rate, expressed in ray
     */
    function getBaseVariableBorrowRate() external view returns (uint256 rate);

    /**
     * @notice Returns the maximum variable borrow rate
     * @return rate The maximum variable borrow rate, expressed in ray
     */
    function getMaxVariableBorrowRate() external view returns (uint256 rate);

}
