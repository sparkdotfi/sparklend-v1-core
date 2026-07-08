// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 }       from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { ReserveCache } from '../types/DataTypes.sol';

/**
 * @title Helpers library
 * @author Aave
 */
library Helpers {

    /**
     * @notice Fetches the user current stable and variable debt balances
     * @param  user The user address
     * @param  reserveCache The reserve cache data object
     * @return stableDebt The stable debt balance
     * @return variableDebt The variable debt balance
     */
    function getUserCurrentDebt(
        address user,
        ReserveCache memory reserveCache
    ) internal view returns (uint256, uint256) {
        return (
            IERC20(reserveCache.stableDebtToken).balanceOf(user),
            IERC20(reserveCache.variableDebtToken).balanceOf(user)
        );
    }

}
