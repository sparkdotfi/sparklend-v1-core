// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {Errors} from '../../libraries/helpers/Errors.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';

import {IPool} from '../../../interfaces/IPool.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {IncentivizedERC20} from './IncentivizedERC20.sol';

/**
 * @title ScaledBalanceTokenBase
 * @author Aave
 * @notice Basic ERC20 implementation of scaled balance token
 */
abstract contract ScaledBalanceTokenBase is IncentivizedERC20, IScaledBalanceToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;

  enum RoundingMode {
    INACTIVE,
    ROUND_DOWN,
    ROUND_UP
  }

  /**
   * @dev Constructor.
   * @param pool The reference to the main Pool contract
   * @param name The name of the token
   * @param symbol The symbol of the token
   * @param decimals The number of decimals of the token
   */
  constructor(
    IPool pool,
    string memory name,
    string memory symbol,
    uint8 decimals
  ) IncentivizedERC20(pool, name, symbol, decimals) {
    // Intentionally left blank
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledBalanceOf(address user) public view override returns (uint256) {
    return _userState[user].balance;
  }

  /// @inheritdoc IScaledBalanceToken
  function getScaledUserBalanceAndSupply(
    address user
  ) external view override returns (uint256, uint256) {
    return (_userState[user].balance, _totalSupply);
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledTotalSupply() public view virtual override returns (uint256) {
    return _totalSupply;
  }

  /// @inheritdoc IScaledBalanceToken
  function getPreviousIndex(address user) external view virtual override returns (uint256) {
    return _userState[user].additionalData;
  }

  /**
   * @notice Implements the basic logic to mint a scaled balance token.
   * @param caller The address performing the mint
   * @param onBehalfOf The address of the user that will receive the scaled tokens
   * @param rebasedAmount The amount of tokens getting minted
   * @param index The next liquidity index of the reserve
   * @return `true` if the the previous balance of the user was 0
   */
  function _mintScaled(
    address caller,
    address onBehalfOf,
    uint256 rebasedAmount,
    uint256 index,
    RoundingMode roundingMode
  ) internal returns (bool) {
    uint128 scaledAmount = _getScaledAmount(rebasedAmount, index, roundingMode).toUint128();
    require(scaledAmount != 0, Errors.INVALID_MINT_AMOUNT);

    uint256 oldScaledBalance = _userState[onBehalfOf].balance;

    // Since the last moment the account's balance was altered, it has accrued balance that needs to
    // be reflected in the `Transfer` and `Mint` events in addition to the amount being minted.
    uint256 accruedRebasedBalance = oldScaledBalance.rayMul(index) -
      oldScaledBalance.rayMul(_userState[onBehalfOf].additionalData);

    _userState[onBehalfOf].additionalData = index.toUint128();

    uint256 oldScaledTotalSupply = _totalSupply;

    _totalSupply = oldScaledTotalSupply + scaledAmount;
    _userState[onBehalfOf].balance = oldScaledBalance.toUint128() + scaledAmount;

    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(onBehalfOf, oldScaledTotalSupply, oldScaledBalance);
    }

    uint256 rebasedAmountToMint = rebasedAmount + accruedRebasedBalance;
    emit Transfer(address(0), onBehalfOf, rebasedAmountToMint);
    emit Mint(caller, onBehalfOf, rebasedAmountToMint, accruedRebasedBalance, index);

    return (oldScaledBalance == 0);
  }

  /**
   * @notice Implements the basic logic to burn a scaled balance token.
   * @dev In some instances, a burn transaction will emit a mint event
   * if the amount to burn is less than the interest that the user accrued
   * @param user The user which debt is burnt
   * @param target The address that will receive the underlying, if any
   * @param rebasedAmount The amount getting burned
   * @param index The variable debt index of the reserve
   */
  function _burnScaled(
    address user,
    address target,
    uint256 rebasedAmount,
    uint256 index,
    RoundingMode roundingMode
  ) internal {
    uint128 scaledAmount = _getScaledAmount(rebasedAmount, index, roundingMode).toUint128();
    require(scaledAmount != 0, Errors.INVALID_BURN_AMOUNT);

    uint256 oldScaledBalance = _userState[user].balance;

    // Since the last moment the account's balance was altered, it has accrued balance that needs to
    // be reflected in the `Transfer` and `Burn`/`Mint` events in addition to the amount being
    // burned.
    uint256 accruedRebasedBalance = oldScaledBalance.rayMul(index) -
      oldScaledBalance.rayMul(_userState[user].additionalData);

    _userState[user].additionalData = index.toUint128();

    uint256 oldScaledTotalSupply = _totalSupply;

    _totalSupply = oldScaledTotalSupply - scaledAmount;
    _userState[user].balance = oldScaledBalance.toUint128() - scaledAmount;

    if (address(_incentivesController) != address(0)) {
      _incentivesController.handleAction(user, oldScaledTotalSupply, oldScaledBalance);
    }

    if (accruedRebasedBalance > rebasedAmount) {
      uint256 rebasedAmountToMint = accruedRebasedBalance - rebasedAmount;
      emit Transfer(address(0), user, rebasedAmountToMint);
      emit Mint(user, user, rebasedAmountToMint, accruedRebasedBalance, index);
    } else {
      uint256 rebasedAmountToBurn = rebasedAmount - accruedRebasedBalance;
      emit Transfer(user, address(0), rebasedAmountToBurn);
      emit Burn(user, target, rebasedAmountToBurn, accruedRebasedBalance, index);
    }
  }

  function _getScaledAmount(
    uint256 rebasedAmount,
    uint256 index,
    RoundingMode roundingMode
  ) internal pure returns (uint256) {
    if (roundingMode == RoundingMode.ROUND_DOWN) {
      return rebasedAmount.rayDivFloor(index);
    }
    if (roundingMode == RoundingMode.ROUND_UP) {
      return rebasedAmount.rayDivCeil(index);
    }
    revert('Invalid Rounding Mode');
  }

  function _getRebasedAmount(
    uint256 amount,
    uint256 index,
    RoundingMode roundingMode
  ) internal pure returns (uint256) {
    if (roundingMode == RoundingMode.ROUND_DOWN) {
      return amount.rayMulFloor(index);
    }
    if (roundingMode == RoundingMode.ROUND_UP) {
      return amount.rayMulCeil(index);
    }
    revert('Invalid Rounding Mode');
  }
}
