// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { L2Pool } from '../../protocol/pool/L2Pool.sol';

contract MockL2Pool is L2Pool {
  function getRevision() internal pure override returns (uint256) {
    return 0x3;
  }

  constructor(address provider) L2Pool(provider) {}
}
