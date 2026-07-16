// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { IERC20Detailed }       from '../dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import { ReserveConfiguration } from '../protocol/libraries/configuration/ReserveConfiguration.sol';
import { UserConfiguration }    from '../protocol/libraries/configuration/UserConfiguration.sol';
import { WadRayMath }           from '../protocol/libraries/math/WadRayMath.sol';

import {
    ReserveConfigurationMap,
    ReserveData,
    UserConfigurationMap
 } from '../protocol/libraries/types/DataTypes.sol';

import { IPoolAddressesProvider } from '../interfaces/IPoolAddressesProvider.sol';
import { IStableDebtToken }       from '../interfaces/IStableDebtToken.sol';
import { IVariableDebtToken }     from '../interfaces/IVariableDebtToken.sol';
import { IPool }                  from '../interfaces/IPool.sol';
import { IPoolDataProvider }      from '../interfaces/IPoolDataProvider.sol';

/**
 * @title  AaveProtocolDataProvider
 * @author Aave
 * @notice Peripheral contract to collect and pre-process information from the Pool.
 */
contract AaveProtocolDataProvider is IPoolDataProvider {

    using ReserveConfiguration for ReserveConfigurationMap;
    using UserConfiguration    for UserConfigurationMap;
    using WadRayMath           for uint256;

    address constant MKR = 0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2;
    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @inheritdoc IPoolDataProvider
    address public immutable ADDRESSES_PROVIDER;

    /**
    * @notice Constructor
    * @param  addressesProvider The address of the PoolAddressesProvider contract
    */
    constructor(address addressesProvider) {
        ADDRESSES_PROVIDER = addressesProvider;
    }

    /// @inheritdoc IPoolDataProvider
    function getAllReservesTokens()
        external
        view
        override
        returns (TokenData[] memory reservesTokens)
    {
        IPool pool = IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool());

        address[] memory reserves = pool.getReservesList();

        reservesTokens = new TokenData[](reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            if (reserves[i] == MKR) {
                reservesTokens[i] = TokenData({ symbol: 'MKR', token: reserves[i] });
                continue;
            }

            if (reserves[i] == ETH) {
                reservesTokens[i] = TokenData({ symbol: 'ETH', token: reserves[i] });
                continue;
            }

            reservesTokens[i] = TokenData({
                symbol: IERC20Detailed(reserves[i]).symbol(),
                token: reserves[i]
            });
        }
    }

    /// @inheritdoc IPoolDataProvider
    function getAllATokens() external view override returns (TokenData[] memory aTokens) {
        IPool pool = IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool());

        address[] memory reserves = pool.getReservesList();

        aTokens = new TokenData[](reserves.length);

        for (uint256 i = 0; i < reserves.length; i++) {
            address aToken = pool.getReserveData(reserves[i]).aToken;

            aTokens[i] = TokenData({
                symbol : IERC20Detailed(aToken).symbol(),
                token  : aToken
            });
        }
    }

    /// @inheritdoc IPoolDataProvider
    function getReserveConfigurationData(
        address asset
    )
        external
        view
        override
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool    usageAsCollateralEnabled,
            bool    borrowingEnabled,
            bool    stableBorrowRateEnabled,
            bool    isActive,
            bool    isFrozen
        )
    {
        ReserveConfigurationMap memory configuration =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool()).getConfiguration(asset);

        ( ltv, liquidationThreshold, liquidationBonus, decimals, reserveFactor, ) =
            configuration.getParams();

        ( isActive, isFrozen, borrowingEnabled, stableBorrowRateEnabled, ) =
            configuration.getFlags();

        usageAsCollateralEnabled = liquidationThreshold != 0;
    }

    /// @inheritdoc IPoolDataProvider
    function getReserveEModeCategory(address asset) external view override returns (uint256) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getEModeCategory();
    }

    /// @inheritdoc IPoolDataProvider
    function getReserveCaps(
        address asset
    ) external view override returns (uint256 borrowCap, uint256 supplyCap) {
        ( borrowCap, supplyCap ) =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getCaps();
    }

    /// @inheritdoc IPoolDataProvider
    function getPaused(address asset) external view override returns (bool isPaused) {
        ( , , , , isPaused ) =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getFlags();
    }

    /// @inheritdoc IPoolDataProvider
    function getSiloedBorrowing(address asset) external view override returns (bool) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getSiloedBorrowing();
    }

    /// @inheritdoc IPoolDataProvider
    function getLiquidationProtocolFee(address asset) external view override returns (uint256) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getLiquidationProtocolFee();
    }

    /// @inheritdoc IPoolDataProvider
    function getUnbackedMintCap(address asset) external view override returns (uint256) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getUnbackedMintCap();
    }

    /// @inheritdoc IPoolDataProvider
    function getDebtCeiling(address asset) external view override returns (uint256) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getDebtCeiling();
    }

    /// @inheritdoc IPoolDataProvider
    function getDebtCeilingDecimals() external pure override returns (uint256) {
        return ReserveConfiguration.DEBT_CEILING_DECIMALS;
    }

    /// @inheritdoc IPoolDataProvider
    function getReserveData(
        address asset
    )
        external
        view
        override
        returns (
        uint256 unbacked,
        uint256 accruedToTreasuryScaled,
        uint256 totalAToken,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 liquidityRate,
        uint256 variableBorrowRate,
        uint256 stableBorrowRate,
        uint256 averageStableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex,
        uint40 lastUpdateTimestamp
        )
    {
        ReserveData memory data =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool()).getReserveData(asset);

        return (
            data.unbacked,
            data.accruedToTreasury,
            IERC20Detailed(data.aToken).totalSupply(),
            IERC20Detailed(data.stableDebtToken).totalSupply(),
            IERC20Detailed(data.variableDebtToken).totalSupply(),
            data.liquidityRate,
            data.variableBorrowRate,
            data.stableBorrowRate,
            IStableDebtToken(data.stableDebtToken).getAverageStableRate(),
            data.liquidityIndex,
            data.variableBorrowIndex,
            data.lastUpdateTimestamp
        );
    }

    /// @inheritdoc IPoolDataProvider
    function getATokenTotalSupply(address asset) external view override returns (uint256) {
        return
            IERC20Detailed(
                IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                    .getReserveData(asset)
                    .aToken
            ).totalSupply();
    }

    /// @inheritdoc IPoolDataProvider
    function getTotalDebt(address asset) external view override returns (uint256) {
        ReserveData memory data =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool()).getReserveData(asset);

        return
            IERC20Detailed(data.stableDebtToken).totalSupply() +
            IERC20Detailed(data.variableDebtToken).totalSupply();
    }

    /// @inheritdoc IPoolDataProvider
    function getUserReserveData(
        address asset,
        address user
    )
        external
        view
        override
        returns (
            uint256 aTokenBalance,
            uint256 stableDebt,
            uint256 variableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40  stableRateLastUpdated,
            bool    usageAsCollateralEnabled
        )
    {
        IPool pool = IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool());

        ReserveData memory data = pool.getReserveData(asset);

        aTokenBalance            = IERC20Detailed(data.aToken).balanceOf(user);
        stableDebt               = IERC20Detailed(data.stableDebtToken).balanceOf(user);
        variableDebt             = IERC20Detailed(data.variableDebtToken).balanceOf(user);
        principalStableDebt      = IStableDebtToken(data.stableDebtToken).principalBalanceOf(user);
        scaledVariableDebt       = IVariableDebtToken(data.variableDebtToken).scaledBalanceOf(user);
        stableBorrowRate         = IStableDebtToken(data.stableDebtToken).getUserStableRate(user);
        liquidityRate            = data.liquidityRate;
        stableRateLastUpdated    = IStableDebtToken(data.stableDebtToken).getUserLastUpdated(user);
        usageAsCollateralEnabled = pool.getUserConfiguration(user).isUsingAsCollateral(data.id);
    }

    /// @inheritdoc IPoolDataProvider
    function getReserveTokensAddresses(
        address asset
    )
        external
        view
        override
        returns (
            address aToken,
            address stableDebtToken,
            address variableDebtToken
        )
    {
        ReserveData memory data =
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool()).getReserveData(asset);

        return (
            data.aToken,
            data.stableDebtToken,
            data.variableDebtToken
        );
    }

    /// @inheritdoc IPoolDataProvider
    function getInterestRateStrategyAddress(
        address asset
    ) external view override returns (address rateStrategy) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getReserveData(asset)
                .interestRateStrategy;
    }

    /// @inheritdoc IPoolDataProvider
    function getFlashLoanEnabled(address asset) external view override returns (bool) {
        return
            IPool(IPoolAddressesProvider(ADDRESSES_PROVIDER).getPool())
                .getConfiguration(asset)
                .getFlashLoanEnabled();
    }

}
