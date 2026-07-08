// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { IFlashLoanSimpleReceiver } from '../interfaces/IFlashLoanSimpleReceiver.sol';
import { IPoolAddressesProvider   } from '../../interfaces/IPoolAddressesProvider.sol';

/**
 * @title FlashLoanSimpleReceiverBase
 * @author Aave
 * @notice Base contract to develop a flashloan-receiver contract.
 */
abstract contract FlashLoanSimpleReceiverBase is IFlashLoanSimpleReceiver {

    address public immutable override ADDRESSES_PROVIDER;

    address public immutable override POOL;

    constructor(address provider) {
        ADDRESSES_PROVIDER = provider;
        POOL = IPoolAddressesProvider(provider).getPool();
    }

}
