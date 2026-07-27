// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeCast} from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {Errors} from '../../libraries/helpers/Errors.sol';
import {WadRayMath} from '../../libraries/math/WadRayMath.sol';
import {IPool} from '../../../interfaces/IPool.sol';
import {IScaledBalanceToken} from '../../../interfaces/IScaledBalanceToken.sol';
import {MintableIncentivizedERC20} from './MintableIncentivizedERC20.sol';

/**
 * @title ScaledBalanceTokenBase
 * @author Aave
 * @notice Basic ERC20 implementation of scaled balance token
 */
abstract contract ScaledBalanceTokenBase is MintableIncentivizedERC20, IScaledBalanceToken {
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
  ) MintableIncentivizedERC20(pool, name, symbol, decimals) {
    // Intentionally left blank
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledBalanceOf(address user) external view override returns (uint256) {
    return super.balanceOf(user);
  }

  /// @inheritdoc IScaledBalanceToken
  function getScaledUserBalanceAndSupply(
    address user
  ) external view override returns (uint256, uint256) {
    return (super.balanceOf(user), super.totalSupply());
  }

  /// @inheritdoc IScaledBalanceToken
  function scaledTotalSupply() public view virtual override returns (uint256) {
    return super.totalSupply();
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
    uint256 amountScaled = _getScaledAmount(rebasedAmount, index, roundingMode);
    require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

    uint256 scaledBalance = super.balanceOf(onBehalfOf);

    uint256 rebasedAccruedBalance = scaledBalance.rayMul(index) -
      scaledBalance.rayMul(_userState[onBehalfOf].additionalData);

    _userState[onBehalfOf].additionalData = index.toUint128();

    _mint(onBehalfOf, amountScaled.toUint128());

    uint256 rebasedAmountToMint = rebasedAmount + rebasedAccruedBalance;
    emit Transfer(address(0), onBehalfOf, rebasedAmountToMint);
    emit Mint(caller, onBehalfOf, rebasedAmountToMint, rebasedAccruedBalance, index);

    return (scaledBalance == 0);
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
    uint256 amountScaled = _getScaledAmount(rebasedAmount, index, roundingMode);
    require(amountScaled != 0, Errors.INVALID_BURN_AMOUNT);

    uint256 scaledBalance = super.balanceOf(user);
    uint256 rebasedAccruedBalance = scaledBalance.rayMul(index) -
      scaledBalance.rayMul(_userState[user].additionalData);

    _userState[user].additionalData = index.toUint128();

    _burn(user, amountScaled.toUint128());

    if (rebasedAccruedBalance > rebasedAmount) {
      uint256 rebasedAmountToMint = rebasedAccruedBalance - rebasedAmount;
      emit Transfer(address(0), user, rebasedAmountToMint);
      emit Mint(user, user, rebasedAmountToMint, rebasedAccruedBalance, index);
    } else {
      uint256 rebasedAmountToBurn = rebasedAmount - rebasedAccruedBalance;
      emit Transfer(user, address(0), rebasedAmountToBurn);
      emit Burn(user, target, rebasedAmountToBurn, rebasedAccruedBalance, index);
    }
  }

  /**
   * @notice Implements the basic logic to transfer scaled balance tokens between two users
   * @dev It emits a mint event with the interest accrued per user
   * @dev The scaled transfer amount is rounded up so the recipient receives at least the requested amount
   * @param sender The source address
   * @param recipient The destination address
   * @param rebasedAmount The amount getting transferred
   * @param index The next liquidity index of the reserve
   */
  function _transfer(
    address sender,
    address recipient,
    uint256 rebasedAmount,
    uint256 index
  ) internal {
    uint256 senderScaledBalance = super.balanceOf(sender);
    uint256 senderRebasedAccruedBalance = senderScaledBalance.rayMul(index) -
      senderScaledBalance.rayMul(_userState[sender].additionalData);

    uint256 recipientScaledBalance = super.balanceOf(recipient);
    uint256 recipientRebasedAccruedBalance = recipientScaledBalance.rayMul(index) -
      recipientScaledBalance.rayMul(_userState[recipient].additionalData);

    _userState[sender].additionalData = index.toUint128();
    _userState[recipient].additionalData = index.toUint128();

    super._transferScaled(
      sender,
      recipient,
      _getScaledAmount(rebasedAmount, index, RoundingMode.ROUND_UP).toUint128()
    );

    if (senderRebasedAccruedBalance > 0) {
      emit Transfer(address(0), sender, senderRebasedAccruedBalance);
      emit Mint(
        _msgSender(),
        sender,
        senderRebasedAccruedBalance,
        senderRebasedAccruedBalance,
        index
      );
    }

    if (sender != recipient && recipientRebasedAccruedBalance > 0) {
      emit Transfer(address(0), recipient, recipientRebasedAccruedBalance);
      emit Mint(
        _msgSender(),
        recipient,
        recipientRebasedAccruedBalance,
        recipientRebasedAccruedBalance,
        index
      );
    }

    emit Transfer(sender, recipient, rebasedAmount);
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
