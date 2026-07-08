// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { IFlashLoanReceiver }     from '../interfaces/IFlashLoanReceiver.sol';
import { IPoolAddressesProvider } from '../../interfaces/IPoolAddressesProvider.sol';

/**
 * @title  FlashLoanReceiverBase
 * @author Aave
 * @notice Base contract to develop a flashloan-receiver contract.
 */
abstract contract FlashLoanReceiverBase is IFlashLoanReceiver {

    address public immutable override ADDRESSES_PROVIDER;

    address public immutable override POOL;

    constructor(address provider) {
        ADDRESSES_PROVIDER = provider;
        POOL               = IPoolAddressesProvider(provider).getPool();
    }

}
