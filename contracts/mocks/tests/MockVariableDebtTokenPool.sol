// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {IVariableDebtToken} from '../../interfaces/IVariableDebtToken.sol';

contract MockVariableDebtTokenPool {
  uint256 private _normalizedVariableDebt;

  constructor(uint256 normalizedVariableDebt) {
    _normalizedVariableDebt = normalizedVariableDebt;
  }

  function ADDRESSES_PROVIDER() external pure returns (IPoolAddressesProvider) {
    return IPoolAddressesProvider(address(0));
  }

  function getReserveNormalizedVariableDebt(address) external view returns (uint256) {
    return _normalizedVariableDebt;
  }

  function setReserveNormalizedVariableDebt(uint256 normalizedVariableDebt) external {
    _normalizedVariableDebt = normalizedVariableDebt;
  }

  function mintVariableDebtToken(
    IVariableDebtToken variableDebtToken,
    address user,
    address onBehalfOf,
    uint256 amount
  ) external {
    variableDebtToken.mint(user, onBehalfOf, amount, _normalizedVariableDebt);
  }
}
