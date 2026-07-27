// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
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
  using WadRayMath for uint256;
  using SafeCast for uint256;

  uint256 public constant DEBT_TOKEN_REVISION = 0x2;

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
  function balanceOf(address user) public view returns (uint256) {
    uint256 scaledBalance = _scaledBalanceOf(user);

    if (scaledBalance == 0) {
      return 0;
    }

    return
      _getRebasedAmount(scaledBalance, POOL.getReserveNormalizedVariableDebt(_underlyingAsset));
  }

  /// @inheritdoc IVariableDebtToken
  function mint(
    address user,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool returns (bool, uint256) {
    if (user != onBehalfOf) {
      _decreaseBorrowAllowance(onBehalfOf, user, amount, index);
    }
    return (
      _mintScaled(user, onBehalfOf, amount, index, RoundingMode.ROUND_UP),
      scaledTotalSupply()
    );
  }

  /// @inheritdoc IVariableDebtToken
  function burn(
    address from,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool returns (uint256) {
    _burnScaled(from, address(0), amount, index, RoundingMode.ROUND_DOWN);
    return scaledTotalSupply();
  }

  /// @inheritdoc IERC20
  function totalSupply() public view virtual returns (uint256) {
    return
      _getRebasedAmount(
        _scaledTotalSupply(),
        POOL.getReserveNormalizedVariableDebt(_underlyingAsset)
      );
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

  function _getRebasedAmount(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
    return scaledAmount.rayMulCeil(index);
  }

  function _getScaledAmount(uint256 rebasedAmount, uint256 index) internal pure returns (uint256) {
    _getScaledAmount(rebasedAmount, index, RoundingMode.ROUND_UP);
  }

  /**
   * @notice Decreases the borrow allowance of a user on the specific debt token.
   * @param delegator The address delegating the borrowing power
   * @param delegatee The address receiving the delegated borrowing power
   * @param rebasedAmount The minimum amount to subtract from the current allowance
   * @param index The variable debt index of the reserve
   */
  function _decreaseBorrowAllowance(
    address delegator,
    address delegatee,
    uint256 rebasedAmount,
    uint256 index
  ) internal {
    uint256 currentAllowance = _borrowAllowances[delegator][delegatee];
    if (currentAllowance < rebasedAmount) {
      revert InsufficientBorrowAllowance(delegatee, currentAllowance, rebasedAmount);
    }

    uint256 scaledBalance = _scaledBalanceOf(delegator);
    uint256 scaledAmount = _getScaledAmount(rebasedAmount, index);
    uint256 startingRebasedBalance = _getRebasedAmount(scaledBalance, index);
    uint256 endingRebasedBalance = _getRebasedAmount(scaledBalance + scaledAmount, index);

    // Consume allowance based on the owner's actual balance increase rather than `rebasedAmount`
    // (inspired by Aave v3.5). Because the scaled amount is rounded up, the owner's balance can
    // increase by slightly more than `rebasedAmount`, so we measure the real increase from the
    // resulting scaled balance to keep the invariant: allowance consumed == balance minted.
    // The consumption is capped at the current allowance.
    uint256 rebasedBalanceIncrease = endingRebasedBalance - startingRebasedBalance;

    uint256 consumption = currentAllowance >= rebasedBalanceIncrease
      ? rebasedBalanceIncrease
      : currentAllowance;
    uint256 newAllowance = currentAllowance - consumption;

    _borrowAllowances[delegator][delegatee] = newAllowance;

    emit BorrowAllowanceDelegated(delegator, delegatee, _underlyingAsset, newAllowance);
  }
}
