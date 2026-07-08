// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { UserConfiguration }    from '../libraries/configuration/UserConfiguration.sol';
import { ReserveConfiguration } from '../libraries/configuration/ReserveConfiguration.sol';
import { ReserveLogic }         from '../libraries/logic/ReserveLogic.sol';

import {
    EModeCategory,
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
} from '../libraries/types/DataTypes.sol';

/**
 * @title  PoolStorage
 * @author Aave
 * @notice Contract used as storage of the Pool contract.
 * @dev    It defines the storage layout of the Pool contract.
 */
contract PoolStorage {

    using ReserveLogic for ReserveData;
    using ReserveConfiguration for ReserveConfigurationMap;
    using UserConfiguration for UserConfigurationMap;

    // Map of reserves and their data (underlyingAssetOfReserve => reserveData)
    mapping(address => ReserveData) internal _reserves;

    // Map of users address and their configuration data (userAddress => userConfiguration)
    mapping(address => UserConfigurationMap) internal _usersConfig;

    // List of reserves as a map (reserveId => reserve).
    // It is structured as a mapping for gas savings reasons, using the reserve id as index
    mapping(uint256 => address) internal _reservesList;

    // List of eMode categories as a map (eModeCategoryId => eModeCategory).
    // It is structured as a mapping for gas savings reasons, using the eModeCategoryId as index
    mapping(uint8 => EModeCategory) internal _eModeCategories;

    // Map of users address and their eMode category (userAddress => eModeCategoryId)
    mapping(address => uint8) internal _usersEModeCategory;

    // Fee of the protocol bridge, expressed in bps
    uint256 internal _bridgeProtocolFee;

    // Total FlashLoan Premium, expressed in bps
    uint128 internal _flashLoanPremiumTotal;

    // FlashLoan premium paid to protocol treasury, expressed in bps
    uint128 internal _flashLoanPremiumToProtocol;

    // Available liquidity that can be borrowed at once at stable rate, expressed in bps
    uint64 internal _maxStableRateBorrowSizePercent;

    // Maximum number of active reserves there have been in the protocol. It is the upper bound of the reserves list
    uint16 internal _reservesCount;

}
