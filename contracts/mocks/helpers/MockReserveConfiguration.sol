// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {
    ReserveConfiguration
} from '../../protocol/libraries/configuration/ReserveConfiguration.sol';

import { ReserveConfigurationMap } from '../../protocol/libraries/types/DataTypes.sol';

contract MockReserveConfiguration {

    ReserveConfigurationMap public configuration;

    function setLtv(uint256 ltv) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setLtv(config, ltv);

        configuration = config;
    }

    function getLtv() external view returns (uint256) {
        return ReserveConfiguration.getLtv(configuration);
    }

    function setLiquidationBonus(uint256 bonus) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setLiquidationBonus(config, bonus);

        configuration = config;
    }

    function getLiquidationBonus() external view returns (uint256) {
        return ReserveConfiguration.getLiquidationBonus(configuration);
    }

    function setLiquidationThreshold(uint256 threshold) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setLiquidationThreshold(config, threshold);

        configuration = config;
    }

    function getLiquidationThreshold() external view returns (uint256) {
        return ReserveConfiguration.getLiquidationThreshold(configuration);
    }

    function setDecimals(uint256 decimals) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setDecimals(config, decimals);

        configuration = config;
    }

    function getDecimals() external view returns (uint256) {
        return ReserveConfiguration.getDecimals(configuration);
    }

    function setFrozen(bool frozen) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setFrozen(config, frozen);

        configuration = config;
    }

    function getFrozen() external view returns (bool) {
        return ReserveConfiguration.getFrozen(configuration);
    }

    function setBorrowingEnabled(bool enabled) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setBorrowingEnabled(config, enabled);

        configuration = config;
    }

    function getBorrowingEnabled() external view returns (bool) {
        return ReserveConfiguration.getBorrowingEnabled(configuration);
    }

    function setStableRateBorrowingEnabled(bool enabled) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setStableRateBorrowingEnabled(config, enabled);

        configuration = config;
    }

    function getStableRateBorrowingEnabled() external view returns (bool) {
        return ReserveConfiguration.getStableRateBorrowingEnabled(configuration);
    }

    function setReserveFactor(uint256 reserveFactor) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setReserveFactor(config, reserveFactor);

        configuration = config;
    }

    function getReserveFactor() external view returns (uint256) {
        return ReserveConfiguration.getReserveFactor(configuration);
    }

    function setBorrowCap(uint256 borrowCap) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setBorrowCap(config, borrowCap);

        configuration = config;
    }

    function getBorrowCap() external view returns (uint256) {
        return ReserveConfiguration.getBorrowCap(configuration);
    }

    function getEModeCategory() external view returns (uint256) {
        return ReserveConfiguration.getEModeCategory(configuration);
    }

    function setEModeCategory(uint256 categoryId) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setEModeCategory(config, categoryId);

        configuration = config;
    }

    function setFlashLoanEnabled(bool enabled) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setFlashLoanEnabled(config, enabled);

        configuration = config;
    }

    function getFlashLoanEnabled() external view returns (bool) {
        return ReserveConfiguration.getFlashLoanEnabled(configuration);
    }

    function setSupplyCap(uint256 supplyCap) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setSupplyCap(config, supplyCap);

        configuration = config;
    }

    function getSupplyCap() external view returns (uint256) {
        return ReserveConfiguration.getSupplyCap(configuration);
    }

    function setLiquidationProtocolFee(uint256 liquidationProtocolFee) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setLiquidationProtocolFee(config, liquidationProtocolFee);

        configuration = config;
    }

    function getLiquidationProtocolFee() external view returns (uint256) {
        return ReserveConfiguration.getLiquidationProtocolFee(configuration);
    }

    function setUnbackedMintCap(uint256 unbackedMintCap) external {
        ReserveConfigurationMap memory config = configuration;

        ReserveConfiguration.setUnbackedMintCap(config, unbackedMintCap);

        configuration = config;
    }

    function getUnbackedMintCap() external view returns (uint256) {
        return ReserveConfiguration.getUnbackedMintCap(configuration);
    }

    function getFlags() external view returns (bool, bool, bool, bool, bool) {
        return ReserveConfiguration.getFlags(configuration);
    }

    function getParams()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return ReserveConfiguration.getParams(configuration);
    }

    function getCaps() external view returns (uint256, uint256) {
        return ReserveConfiguration.getCaps(configuration);
    }

}
