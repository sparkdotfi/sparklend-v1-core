// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { SafeMath }                    from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import { IERC20 }                      from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import { GPv2SafeERC20 }               from '../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import { IPoolAddressesProvider }      from '../../interfaces/IPoolAddressesProvider.sol';
import { FlashLoanSimpleReceiverBase } from '../../flashloan/base/FlashLoanSimpleReceiverBase.sol';
import { MintableERC20 }               from '../tokens/MintableERC20.sol';
import { IPool }                       from '../../interfaces/IPool.sol';

contract FlashloanAttacker is FlashLoanSimpleReceiverBase {

    using GPv2SafeERC20 for IERC20;
    using SafeMath      for uint256;

    address internal _provider;

    address internal _pool;

    constructor(address provider) FlashLoanSimpleReceiverBase(provider) {
        _pool = IPoolAddressesProvider(provider).getPool();
    }

    function supplyAsset(address asset, uint256 amount) public {
        MintableERC20(asset).mint(amount);
        MintableERC20(asset).approve(_pool, type(uint256).max);
        IPool(_pool).supply(asset, amount, address(this), 0);
    }

    function _innerBorrow(address asset) internal {
        uint256 avail = IERC20(asset).balanceOf(IPool(_pool).getReserveData(asset).aToken);

        IPool(_pool).borrow(asset, avail, 2, 0, address(this));
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address, // initiator
        bytes memory // params
    ) public override returns (bool) {
        uint256 amountToReturn = amount.add(premium);

        // Also do a normal borrow here in the middle
        _innerBorrow(asset);

        MintableERC20(asset).mint(premium);
        IERC20(asset).approve(address(POOL), amountToReturn);

        return true;
    }

}
