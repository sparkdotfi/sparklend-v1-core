// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {WadRayMath} from '../math/WadRayMath.sol';

/**
 * @title TokenMath
 * @notice Conversion helpers between rebased amounts and scaled balances for aTokens and variable
 *         debt tokens, applying protocol-favouring floor/ceil rounding (Aave v3.5 model).
 * @dev Ported from aave-v3-origin (BGD Labs) and adapted to the SparkLend v3.0.2 substrate. The
 *      conversions live here, called from the Pool logic libraries, so that the scaled amount is
 *      computed exactly once and passed into the token together with the rebased amount.
 */
library TokenMath {
  using WadRayMath for uint256;

  /// @notice Scaled aTokens to mint on supply; rounded DOWN so credited claim <= amount supplied.
  function getATokenMintScaledAmount(
    uint256 amount,
    uint256 liquidityIndex
  ) internal pure returns (uint256) {
    return amount.rayDivFloor(liquidityIndex);
  }

  /// @notice Scaled aTokens to burn on withdraw; rounded UP so the balance is sufficiently reduced.
  function getATokenBurnScaledAmount(
    uint256 amount,
    uint256 liquidityIndex
  ) internal pure returns (uint256) {
    return amount.rayDivCeil(liquidityIndex);
  }

  /// @notice Scaled aTokens to transfer; rounded UP so the recipient receives at least `amount`.
  function getATokenTransferScaledAmount(
    uint256 amount,
    uint256 liquidityIndex
  ) internal pure returns (uint256) {
    return amount.rayDivCeil(liquidityIndex);
  }

  /// @notice Actual aToken balance from a scaled balance; rounded DOWN to avoid overstating claims.
  function getATokenBalance(
    uint256 scaledAmount,
    uint256 liquidityIndex
  ) internal pure returns (uint256) {
    return scaledAmount.rayMulFloor(liquidityIndex);
  }

  /// @notice Scaled variable debt to mint on borrow; rounded UP so debt is never understated.
  function getVTokenMintScaledAmount(
    uint256 amount,
    uint256 variableBorrowIndex
  ) internal pure returns (uint256) {
    return amount.rayDivCeil(variableBorrowIndex);
  }

  /// @notice Scaled variable debt to burn on repay; rounded DOWN to avoid over-burning debt.
  function getVTokenBurnScaledAmount(
    uint256 amount,
    uint256 variableBorrowIndex
  ) internal pure returns (uint256) {
    return amount.rayDivFloor(variableBorrowIndex);
  }

  /// @notice Actual variable debt balance from a scaled balance; rounded UP to avoid understating debt.
  function getVTokenBalance(
    uint256 scaledAmount,
    uint256 variableBorrowIndex
  ) internal pure returns (uint256) {
    return scaledAmount.rayMulCeil(variableBorrowIndex);
  }
}
