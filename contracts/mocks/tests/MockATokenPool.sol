// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IAToken} from '../../interfaces/IAToken.sol';
import {IPoolAddressesProvider} from '../../interfaces/IPoolAddressesProvider.sol';
import {TokenMath} from '../../protocol/libraries/helpers/TokenMath.sol';

contract MockATokenPool {
  using TokenMath for uint256;

  uint256 private _normalizedIncome;

  constructor(uint256 normalizedIncome) {
    _normalizedIncome = normalizedIncome;
  }

  function ADDRESSES_PROVIDER() external pure returns (IPoolAddressesProvider) {
    return IPoolAddressesProvider(address(0));
  }

  function getReserveNormalizedIncome(address) external view returns (uint256) {
    return _normalizedIncome;
  }

  function setReserveNormalizedIncome(uint256 normalizedIncome) external {
    _normalizedIncome = normalizedIncome;
  }

  function mintAToken(IAToken aToken, address onBehalfOf, uint256 amount) external {
    aToken.mint(
      msg.sender,
      onBehalfOf,
      amount,
      amount.getATokenMintScaledAmount(_normalizedIncome),
      _normalizedIncome
    );
  }

  function finalizeTransfer(address, address, address, uint256, uint256, uint256) external pure {
    // Intentionally left blank
  }
}
