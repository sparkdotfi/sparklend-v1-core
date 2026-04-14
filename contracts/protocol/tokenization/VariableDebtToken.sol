// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {TokenMath} from '../libraries/helpers/TokenMath.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {IInitializableDebtToken} from '../../interfaces/IInitializableDebtToken.sol';
import {IVariableDebtToken} from '../../interfaces/IVariableDebtToken.sol';
import {EIP712Base} from './base/EIP712Base.sol';
import {DebtTokenBase} from './base/DebtTokenBase.sol';
import {ScaledBalanceTokenBase} from './base/ScaledBalanceTokenBase.sol';

/**
 * @title VariableDebtToken
 * @author Aave
 * @notice Implements a variable debt token to track the borrowing positions of users
 * at variable rate mode
 * @dev Transfer and approve functionalities are disabled since its a non-transferable token
 */
contract VariableDebtToken is DebtTokenBase, ScaledBalanceTokenBase, IVariableDebtToken {
  using TokenMath for uint256;
  using SafeCast for uint256;

  uint256 public constant DEBT_TOKEN_REVISION = 0x1;

  /**
   * @dev Constructor.
   * @param pool The address of the Pool contract
   */
  constructor(
    IPool pool
  )
    DebtTokenBase()
    ScaledBalanceTokenBase(pool, 'VARIABLE_DEBT_TOKEN_IMPL', 'VARIABLE_DEBT_TOKEN_IMPL', 0)
  {
    // Intentionally left blank
  }

  /// @inheritdoc IInitializableDebtToken
  function initialize(
    IPool initializingPool,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 debtTokenDecimals,
    string memory debtTokenName,
    string memory debtTokenSymbol,
    bytes calldata params
  ) external override initializer {
    require(initializingPool == POOL, Errors.POOL_ADDRESSES_DO_NOT_MATCH);
    _setName(debtTokenName);
    _setSymbol(debtTokenSymbol);
    _setDecimals(debtTokenDecimals);

    _underlyingAsset = underlyingAsset;
    _incentivesController = incentivesController;

    _domainSeparator = _calculateDomainSeparator();

    emit Initialized(
      underlyingAsset,
      address(POOL),
      address(incentivesController),
      debtTokenDecimals,
      debtTokenName,
      debtTokenSymbol,
      params
    );
  }

  /// @inheritdoc VersionedInitializable
  function getRevision() internal pure virtual override returns (uint256) {
    return DEBT_TOKEN_REVISION;
  }

  /// @inheritdoc IERC20
  function balanceOf(address user) public view virtual override returns (uint256) {
    return
      super.balanceOf(user).getVTokenBalance(
        POOL.getReserveNormalizedVariableDebt(_underlyingAsset)
      );
  }

  /// @inheritdoc IVariableDebtToken
  function mint(
    address user,
    address onBehalfOf,
    uint256 amount,
    uint256 scaledAmount,
    uint256 index
  ) external virtual override onlyPool returns (uint256) {
    uint256 scaledBalanceOfUser = super.balanceOf(user);

    if (user != onBehalfOf) {
      // This comment explains the logic behind the borrow allowance spent calculation.
      //
      // Problem:
      // Simply decreasing the allowance by the input `amount` is not ideal for scaled-balance tokens.
      // Due to rounding, the actual increase in the user's debt (`debt_increase`) can be slightly
      // larger than the input `amount`.
      //
      // Definitions:
      // - `amount`: The unscaled amount to be borrowed, passed as the `amount` argument.
      // - `debt_increase`: The actual unscaled debt increase for the user.
      // - `allowance_spent`: The unscaled amount deducted from the delegatee's borrow allowance. Equivalent to `debt_increase`.
      //
      // Solution:
      // To handle this, `allowance_spent` must be exactly equal to `debt_increase`.
      // We calculate `debt_increase` precisely by simulating the effect of the borrow on the user's balance.
      // By passing `debt_increase` to `_decreaseBorrowAllowance`, we ensure `allowance_spent` is as close as possible to `debt_increase`.
      //
      // Backward Compatibility & Guarantees:
      // This implementation is backward-compatible and secure. The `_decreaseBorrowAllowance` function has a critical feature:
      // 1. It REQUIRES the borrow allowance to be >= `amount` (the user's requested borrow amount).
      // 2. The amount consumed from the allowance is `debt_increase`, but it is capped at the `currentAllowance`.
      // This means if a user has a borrow allowance of 100 wei and `borrow` is called with an `amount` of 100, the call will succeed
      // even if the calculated `debt_increase` is 101 wei. In that specific scenario, the allowance consumed will be 100 wei (since that is the `currentAllowance`),
      // and the transaction will not revert. But if the allowance is 101 wei, then the allowance consumed will be 101 wei.
      //
      // uint256 debt_increase = balanceAfter - balanceBefore = (scaledBalanceOfUser + scaledAmount).getVTokenBalance(index) - scaledBalanceOfUser.getVTokenBalance(index);
      // Due to limitations of the solidity compiler, the calculation is inlined for gas efficiency.
      _decreaseBorrowAllowance(
        onBehalfOf,
        user,
        amount,
        (scaledBalanceOfUser + scaledAmount).getVTokenBalance(index) -
          scaledBalanceOfUser.getVTokenBalance(index)
      );
    }
    _mintScaled({
      caller: user,
      onBehalfOf: onBehalfOf,
      amountScaled: scaledAmount,
      index: index,
      getTokenBalance: TokenMath.getVTokenBalance
    });
    return scaledTotalSupply();
  }

  /// @inheritdoc IVariableDebtToken
  function burn(
    address from,
    uint256 scaledAmount,
    uint256 index
  ) external virtual override onlyPool returns (bool, uint256) {
    return (
      _burnScaled({
        user: from,
        target: address(0),
        amountScaled: scaledAmount,
        index: index,
        getTokenBalance: TokenMath.getVTokenBalance
      }),
      scaledTotalSupply()
    );
  }

  /// @inheritdoc IERC20
  function totalSupply() public view virtual override returns (uint256) {
    return
      super.totalSupply().getVTokenBalance(POOL.getReserveNormalizedVariableDebt(_underlyingAsset));
  }

  /// @inheritdoc EIP712Base
  function _EIP712BaseId() internal view override returns (string memory) {
    return name();
  }

  /**
   * @dev Being non transferrable, the debt token does not implement any of the
   * standard ERC20 functions for transfer and allowance.
   */
  function transfer(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function allowance(address, address) external view virtual override returns (uint256) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function approve(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function transferFrom(address, address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function increaseAllowance(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  function decreaseAllowance(address, uint256) external virtual override returns (bool) {
    revert(Errors.OPERATION_NOT_SUPPORTED);
  }

  /// @inheritdoc IVariableDebtToken
  function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
    return _underlyingAsset;
  }
}
