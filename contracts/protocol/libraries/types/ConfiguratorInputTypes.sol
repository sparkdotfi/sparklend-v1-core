// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

struct InitReserveInput {
    address aTokenImplementation;
    address stableDebtTokenImplementation;
    address variableDebtTokenImplementation;
    uint8   underlyingAssetDecimals;
    address interestRateStrategy;
    address underlyingAsset;
    address treasury;
    address incentivesController;
    string  aTokenName;
    string  aTokenSymbol;
    string  variableDebtTokenName;
    string  variableDebtTokenSymbol;
    string  stableDebtTokenName;
    string  stableDebtTokenSymbol;
    bytes   params;
}

struct UpdateATokenInput {
    address asset;
    address treasury;
    address incentivesController;
    string  name;
    string  symbol;
    address implementation;
    bytes   params;
}

struct UpdateDebtTokenInput {
    address asset;
    address incentivesController;
    string  name;
    string  symbol;
    address implementation;
    bytes   params;
}
