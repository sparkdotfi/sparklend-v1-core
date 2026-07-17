// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {WadRayMath} from './WadRayMath.sol';

/**
 * @title  MathUtils library
 * @author Aave
 * @notice Provides functions to perform linear and compounded interest calculations
 */
library MathUtils {

    using WadRayMath for uint256;

    /// @dev Ignoring leap years
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /**
     * @dev    Calculates the interest accumulated using a linear interest rate formula between the
     *         timestamp of the last update and the current block timestamp
     * @param  rate                The interest rate, in ray
     * @param  lastUpdateTimestamp The timestamp of the last update of the interest
     * @return index               The interest rate linearly accumulated during the time, in ray
     */
    function getLinearIndexToNow(
        uint256 rate,
        uint40  lastUpdateTimestamp
    ) internal view returns (uint256) {
        //solium-disable-next-line
        uint256 result = rate * (block.timestamp - uint256(lastUpdateTimestamp));

        unchecked {
            result = result / SECONDS_PER_YEAR;
        }

        return WadRayMath.RAY + result;
    }

    /**
     * @dev Function to calculate the interest using a compounded interest rate formula
     *      To avoid expensive exponentiation, the calculation is performed using a binomial
     *      approximation:
     *
     *      (1+x)^n = 1+n*x+[n/2*(n-1)]*x^2+[n/6*(n-1)*(n-2)*x^3...
     *
     *      The approximation slightly underpays liquidity providers and undercharges borrowers,
     *      with the advantage of great gas cost reductions. The whitepaper contains reference to
     *      the approximation and a table showing the margin of error per different time periods
     *
     * @param  rate                The interest rate, in ray
     * @param  lastUpdateTimestamp The timestamp of the last update of the interest
     * @return index               The interest rate compounded during the time delta, in ray
     */
    function getCompoundedIndex(
        uint256 rate,
        uint40  lastUpdateTimestamp,
        uint256 currentTimestamp
    ) internal pure returns (uint256) {
        //solium-disable-next-line
        uint256 exp = currentTimestamp - uint256(lastUpdateTimestamp);

        if (exp == 0) return WadRayMath.RAY;

        // Binomial approximation terms for (1 + rate/year)^exp:
        uint256 expMinusOne; // (n-1)
        uint256 expMinusTwo; // (n-2)
        uint256 basePowerTwo; // (rate/year)^2
        uint256 basePowerThree; // (rate/year)^3

        unchecked {
            expMinusOne    = exp - 1;
            expMinusTwo    = exp > 2 ? exp - 2 : 0;
            basePowerTwo   = rate.rayMul(rate) / (SECONDS_PER_YEAR * SECONDS_PER_YEAR);
            basePowerThree = basePowerTwo.rayMul(rate) / SECONDS_PER_YEAR;
        }

        // secondTerm = [n * (n - 1) / 2] * x^2
        uint256 secondTerm = exp * expMinusOne * basePowerTwo;

        unchecked {
            secondTerm /= 2;
        }

        // thirdTerm = [n * (n - 1) * (n - 2) / 6] * x^3
        uint256 thirdTerm = exp * expMinusOne * expMinusTwo * basePowerThree;

        unchecked {
            thirdTerm /= 6;
        }

        // Returns firstTerm + secondTerm + thirdTerm
        // firstTerm is (1 + rate/year * exp), represented as ((RAY * year + rate * exp) / year) to maintain high precision.
        return ((WadRayMath.RAY + (rate * exp)) / SECONDS_PER_YEAR) + secondTerm + thirdTerm;
    }

    /**
     * @dev    Calculates the compounded interest between the timestamp of the last update and the
     *         current block timestamp
     * @param  rate                The interest rate (in ray)
     * @param  lastUpdateTimestamp The timestamp from which the interest accumulation needs to be
     *                             calculated
     * @return index               The interest rate compounded between lastUpdateTimestamp and
     *                             current block timestamp, in ray
     */
    function getCompoundedIndexToNow(
        uint256 rate,
        uint40  lastUpdateTimestamp
    ) internal view returns (uint256) {
        return getCompoundedIndex(rate, lastUpdateTimestamp, block.timestamp);
    }

}
