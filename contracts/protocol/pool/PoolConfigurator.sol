// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { VersionedInitializable } from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import { ReserveConfiguration }   from '../libraries/configuration/ReserveConfiguration.sol';
import { IPoolAddressesProvider } from '../../interfaces/IPoolAddressesProvider.sol';
import { Errors }                 from '../libraries/helpers/Errors.sol';
import { PercentageMath }         from '../libraries/math/PercentageMath.sol';
import { ConfiguratorLogic }      from '../libraries/logic/ConfiguratorLogic.sol';

import {
    EModeCategory,
    ReserveConfigurationMap,
    ReserveData
} from '../libraries/types/DataTypes.sol';

import {
    InitReserveInput,
    UpdateATokenInput,
    UpdateDebtTokenInput
} from '../libraries/types/ConfiguratorInputTypes.sol';

import { IPoolConfigurator } from '../../interfaces/IPoolConfigurator.sol';
import { IPool } from '../../interfaces/IPool.sol';
import { IACLManager } from '../../interfaces/IACLManager.sol';
import { IPoolDataProvider } from '../../interfaces/IPoolDataProvider.sol';

/**
 * @title  PoolConfigurator
 * @author Aave
 * @dev    Implements the configuration methods for the Aave protocol
 */
contract PoolConfigurator is VersionedInitializable, IPoolConfigurator {

    using PercentageMath for uint256;

    address internal _addressesProvider;
    address internal _pool;

    /**
     * @dev Only pool admin can call functions marked by this modifier.
     */
    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    /**
     * @dev Only emergency admin can call functions marked by this modifier.
     */
    modifier onlyEmergencyAdmin() {
        _onlyEmergencyAdmin();
        _;
    }

    /**
     * @dev Only emergency or pool admin can call functions marked by this modifier.
     */
    modifier onlyEmergencyOrPoolAdmin() {
        _onlyPoolOrEmergencyAdmin();
        _;
    }

    /**
     * @dev Only asset listing or pool admin can call functions marked by this modifier.
     */
    modifier onlyAssetListingOrPoolAdmins() {
        _onlyAssetListingOrPoolAdmins();
        _;
    }

    /**
     * @dev Only risk or pool admin can call functions marked by this modifier.
     */
    modifier onlyRiskOrPoolAdmins() {
        _onlyRiskOrPoolAdmins();
        _;
    }

    uint256 public constant CONFIGURATOR_REVISION = 0x1;

    /// @inheritdoc VersionedInitializable
    function getRevision() internal pure virtual override returns (uint256) {
        return CONFIGURATOR_REVISION;
    }

    function initialize(address provider) public initializer {
        _pool = IPoolAddressesProvider(_addressesProvider = provider).getPool();
    }

    /// @inheritdoc IPoolConfigurator
    function initReserves(
        InitReserveInput[] calldata input
    ) external override onlyAssetListingOrPoolAdmins {
        address pool = _pool;

        for (uint256 i = 0; i < input.length; i++) {
            ConfiguratorLogic.executeInitReserve(pool, input[i]);
        }
    }

    /// @inheritdoc IPoolConfigurator
    function dropReserve(address asset) external override onlyPoolAdmin {
        IPool(_pool).dropReserve(asset);

        emit ReserveDropped(asset);
    }

    /// @inheritdoc IPoolConfigurator
    function updateAToken(UpdateATokenInput calldata input) external override onlyPoolAdmin {
        ConfiguratorLogic.executeUpdateAToken(_pool, input);
    }

    /// @inheritdoc IPoolConfigurator
    function updateStableDebtToken(
        UpdateDebtTokenInput calldata input
    ) external override onlyPoolAdmin {
        ConfiguratorLogic.executeUpdateStableDebtToken(_pool, input);
    }

    /// @inheritdoc IPoolConfigurator
    function updateVariableDebtToken(
        UpdateDebtTokenInput calldata input
    ) external override onlyPoolAdmin {
        ConfiguratorLogic.executeUpdateVariableDebtToken(_pool, input);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveBorrowing(
        address asset,
        bool    enabled
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        require(
            enabled || !ReserveConfiguration.getStableRateBorrowingEnabled(config),
            Errors.STABLE_BORROWING_ENABLED
        );

        ReserveConfiguration.setBorrowingEnabled(config, enabled);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveBorrowing(asset, enabled);
    }

    /// @inheritdoc IPoolConfigurator
    function configureReserveAsCollateral(
        address asset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external override onlyRiskOrPoolAdmins {
        // Enforce that LTV <= liquidationThreshold. If LTV was greater, any borrow would be immediately liquidatable.
        require(ltv <= liquidationThreshold, Errors.INVALID_RESERVE_PARAMS);

        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        if (liquidationThreshold != 0) {
            // Liquidation bonus must be > 100% (10000 bps) to incentivize liquidators to participate.
            require(
                liquidationBonus > PercentageMath.PERCENTAGE_FACTOR,
                Errors.INVALID_RESERVE_PARAMS
            );

            // Enforce (liquidationThreshold * liquidationBonus) <= 100%. This guarantees that when a position
            // crosses the liquidation threshold, the user still has enough collateral to cover the full liquidation bonus.
            require(
                liquidationThreshold.percentMul(liquidationBonus) <=
                PercentageMath.PERCENTAGE_FACTOR,
                Errors.INVALID_RESERVE_PARAMS
            );
        } else {
            require(liquidationBonus == 0, Errors.INVALID_RESERVE_PARAMS);

            // If the liquidation threshold is being set to 0, the reserve is being disabled as collateral.
            // Enforce that no users have existing deposits of this asset before disabling it.
            _checkNoSuppliers(asset);
        }

        ReserveConfiguration.setLtv(config, ltv);
        ReserveConfiguration.setLiquidationThreshold(config, liquidationThreshold);
        ReserveConfiguration.setLiquidationBonus(config, liquidationBonus);

        IPool(_pool).setConfiguration(asset, config);

        emit CollateralConfigurationChanged(asset, ltv, liquidationThreshold, liquidationBonus);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveStableRateBorrowing(
        address asset,
        bool    enabled
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        require(
            !enabled || ReserveConfiguration.getBorrowingEnabled(config),
            Errors.BORROWING_NOT_ENABLED
        );

        ReserveConfiguration.setStableRateBorrowingEnabled(config, enabled);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveStableRateBorrowing(asset, enabled);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveFlashLoaning(
        address asset,
        bool    enabled
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        ReserveConfiguration.setFlashLoanEnabled(config, enabled);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveFlashLoaning(asset, enabled);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveActive(address asset, bool active) external override onlyPoolAdmin {
        if (!active) {
            _checkNoSuppliers(asset);
        }

        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        ReserveConfiguration.setActive(config, active);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveActive(asset, active);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveFreeze(address asset, bool freeze) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        ReserveConfiguration.setFrozen(config, freeze);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveFrozen(asset, freeze);
    }

    /// @inheritdoc IPoolConfigurator
    function setBorrowableInIsolation(
        address asset,
        bool    borrowable
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        ReserveConfiguration.setBorrowableInIsolation(config, borrowable);
        IPool(_pool).setConfiguration(asset, config);

        emit BorrowableInIsolationChanged(asset, borrowable);
    }

    /// @inheritdoc IPoolConfigurator
    function setReservePause(address asset, bool paused) public override onlyEmergencyOrPoolAdmin {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        ReserveConfiguration.setPaused(config, paused);
        IPool(_pool).setConfiguration(asset, config);

        emit ReservePaused(asset, paused);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveFactor(
        address asset,
        uint256 newReserveFactor
    ) external override onlyRiskOrPoolAdmins {
        require(
            newReserveFactor <= PercentageMath.PERCENTAGE_FACTOR,
            Errors.INVALID_RESERVE_FACTOR
        );

        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldReserveFactor = ReserveConfiguration.getReserveFactor(config);

        ReserveConfiguration.setReserveFactor(config, newReserveFactor);
        IPool(_pool).setConfiguration(asset, config);

        emit ReserveFactorChanged(asset, oldReserveFactor, newReserveFactor);
    }

    /// @inheritdoc IPoolConfigurator
    function setDebtCeiling(
        address asset,
        uint256 newDebtCeiling
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldDebtCeiling = ReserveConfiguration.getDebtCeiling(config);

        // If configuring a debt ceiling for the first time, ensure there are no existing suppliers
        // of this asset to avoid retroactively isolating pre-existing collateral positions.
        if (oldDebtCeiling == 0) {
            _checkNoSuppliers(asset);
        }

        ReserveConfiguration.setDebtCeiling(config, newDebtCeiling);
        IPool(_pool).setConfiguration(asset, config);

        // If the debt ceiling is set to 0, isolation mode is disabled. Reset the isolated total debt tracking.
        if (newDebtCeiling == 0) {
            IPool(_pool).resetIsolationModeTotalDebt(asset);
        }

        emit DebtCeilingChanged(asset, oldDebtCeiling, newDebtCeiling);
    }

    /// @inheritdoc IPoolConfigurator
    function setSiloedBorrowing(
        address asset,
        bool    newSiloed
    ) external override onlyRiskOrPoolAdmins {
        if (newSiloed) {
            _checkNoBorrowers(asset);
        }

        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        bool oldSiloed = ReserveConfiguration.getSiloedBorrowing(config);

        ReserveConfiguration.setSiloedBorrowing(config, newSiloed);
        IPool(_pool).setConfiguration(asset, config);

        emit SiloedBorrowingChanged(asset, oldSiloed, newSiloed);
    }

    /// @inheritdoc IPoolConfigurator
    function setBorrowCap(
        address asset,
        uint256 newBorrowCap
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldBorrowCap = ReserveConfiguration.getBorrowCap(config);

        ReserveConfiguration.setBorrowCap(config, newBorrowCap);
        IPool(_pool).setConfiguration(asset, config);

        emit BorrowCapChanged(asset, oldBorrowCap, newBorrowCap);
    }

    /// @inheritdoc IPoolConfigurator
    function setSupplyCap(
        address asset,
        uint256 newSupplyCap
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldSupplyCap = ReserveConfiguration.getSupplyCap(config);

        ReserveConfiguration.setSupplyCap(config, newSupplyCap);
        IPool(_pool).setConfiguration(asset, config);

        emit SupplyCapChanged(asset, oldSupplyCap, newSupplyCap);
    }

    /// @inheritdoc IPoolConfigurator
    function setLiquidationProtocolFee(
        address asset,
        uint256 newFee
    ) external override onlyRiskOrPoolAdmins {
        require(
            newFee <= PercentageMath.PERCENTAGE_FACTOR,
            Errors.INVALID_LIQUIDATION_PROTOCOL_FEE
        );

        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldFee = ReserveConfiguration.getLiquidationProtocolFee(config);

        ReserveConfiguration.setLiquidationProtocolFee(config, newFee);
        IPool(_pool).setConfiguration(asset, config);

        emit LiquidationProtocolFeeChanged(asset, oldFee, newFee);
    }

    /// @inheritdoc IPoolConfigurator
    function setEModeCategory(
        uint8            categoryId,
        uint16           ltv,
        uint16           liquidationThreshold,
        uint16           liquidationBonus,
        address          oracle,
        string  calldata label
    ) external override onlyRiskOrPoolAdmins {
        require(ltv != 0,                  Errors.INVALID_EMODE_CATEGORY_PARAMS);
        require(liquidationThreshold != 0, Errors.INVALID_EMODE_CATEGORY_PARAMS);

        // validation of the parameters: the LTV can only be lower or equal than the liquidation
        // threshold (otherwise a loan against the asset would cause instantaneous liquidation)
        require(ltv <= liquidationThreshold, Errors.INVALID_EMODE_CATEGORY_PARAMS);

        require(
            liquidationBonus > PercentageMath.PERCENTAGE_FACTOR,
            Errors.INVALID_EMODE_CATEGORY_PARAMS
        );

        // if threshold * bonus is less than PERCENTAGE_FACTOR, it's guaranteed that at the moment a
        // loan is taken there is enough collateral available to cover the liquidation bonus
        require(
            uint256(liquidationThreshold).percentMul(liquidationBonus) <=
            PercentageMath.PERCENTAGE_FACTOR,
            Errors.INVALID_EMODE_CATEGORY_PARAMS
        );

        address[] memory reserves = IPool(_pool).getReservesList();

        for (uint256 i = 0; i < reserves.length; i++) {
            ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(reserves[i]);

            if (categoryId != ReserveConfiguration.getEModeCategory(config)) continue;

            require(
                ltv > ReserveConfiguration.getLtv(config),
                Errors.INVALID_EMODE_CATEGORY_PARAMS
            );

            require(
                liquidationThreshold > ReserveConfiguration.getLiquidationThreshold(config),
                Errors.INVALID_EMODE_CATEGORY_PARAMS
            );
        }

        IPool(_pool).configureEModeCategory(
            categoryId,
            EModeCategory({
                ltv                  : ltv,
                liquidationThreshold : liquidationThreshold,
                liquidationBonus     : liquidationBonus,
                priceSource          : oracle,
                label                : label
            })
        );

        emit EModeCategoryAdded(
            categoryId,
            ltv,
            liquidationThreshold,
            liquidationBonus,
            oracle,
            label
        );
    }

    /// @inheritdoc IPoolConfigurator
    function setAssetEModeCategory(
        address asset,
        uint8   newCategoryId
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        require(
            (newCategoryId == 0) ||
            (
                IPool(_pool).getEModeCategoryData(newCategoryId).liquidationThreshold >
                ReserveConfiguration.getLiquidationThreshold(config)
            ),
            Errors.INVALID_EMODE_CATEGORY_ASSIGNMENT
        );

        uint256 oldCategoryId = ReserveConfiguration.getEModeCategory(config);

        ReserveConfiguration.setEModeCategory(config, newCategoryId);
        IPool(_pool).setConfiguration(asset, config);

        emit EModeAssetCategoryChanged(asset, uint8(oldCategoryId), newCategoryId);
    }

    /// @inheritdoc IPoolConfigurator
    function setUnbackedMintCap(
        address asset,
        uint256 newUnbackedMintCap
    ) external override onlyRiskOrPoolAdmins {
        ReserveConfigurationMap memory config = IPool(_pool).getConfiguration(asset);

        uint256 oldUnbackedMintCap = ReserveConfiguration.getUnbackedMintCap(config);

        ReserveConfiguration.setUnbackedMintCap(config, newUnbackedMintCap);
        IPool(_pool).setConfiguration(asset, config);

        emit UnbackedMintCapChanged(asset, oldUnbackedMintCap, newUnbackedMintCap);
    }

    /// @inheritdoc IPoolConfigurator
    function setReserveInterestRateStrategyAddress(
        address asset,
        address rateStrategy
    ) external override onlyRiskOrPoolAdmins {
        address oldRateStrategyAddress = IPool(_pool).getReserveData(asset).interestRateStrategy;

        IPool(_pool).setReserveInterestRateStrategyAddress(asset, rateStrategy);

        emit ReserveInterestRateStrategyChanged(asset, oldRateStrategyAddress, rateStrategy);
    }

    /// @inheritdoc IPoolConfigurator
    function setPoolPause(bool paused) external override onlyEmergencyAdmin {
        address[] memory reserves = IPool(_pool).getReservesList();

        for (uint256 i = 0; i < reserves.length; i++) {
            if (reserves[i] == address(0)) continue;

            setReservePause(reserves[i], paused);
        }
    }

    /// @inheritdoc IPoolConfigurator
    function updateBridgeProtocolFee(uint256 newBridgeProtocolFee) external override onlyPoolAdmin {
        require(
            newBridgeProtocolFee <= PercentageMath.PERCENTAGE_FACTOR,
            Errors.BRIDGE_PROTOCOL_FEE_INVALID
        );

        uint256 oldBridgeProtocolFee = IPool(_pool).BRIDGE_PROTOCOL_FEE();

        IPool(_pool).updateBridgeProtocolFee(newBridgeProtocolFee);

        emit BridgeProtocolFeeUpdated(oldBridgeProtocolFee, newBridgeProtocolFee);
    }

    /// @inheritdoc IPoolConfigurator
    function updateFlashloanPremiumTotal(
        uint128 newFlashloanPremiumTotal
    ) external override onlyPoolAdmin {
        require(
            newFlashloanPremiumTotal <= PercentageMath.PERCENTAGE_FACTOR,
            Errors.FLASHLOAN_PREMIUM_INVALID
        );

        uint128 oldFlashloanPremiumTotal = IPool(_pool).FLASHLOAN_PREMIUM_TOTAL();

        IPool(_pool)
            .updateFlashloanPremiums(
                newFlashloanPremiumTotal,
                IPool(_pool).FLASHLOAN_PREMIUM_TO_PROTOCOL()
            );

        emit FlashloanPremiumTotalUpdated(oldFlashloanPremiumTotal, newFlashloanPremiumTotal);
    }

    /// @inheritdoc IPoolConfigurator
    function updateFlashloanPremiumToProtocol(
        uint128 newFlashloanPremiumToProtocol
    ) external override onlyPoolAdmin {
        require(
            newFlashloanPremiumToProtocol <= PercentageMath.PERCENTAGE_FACTOR,
            Errors.FLASHLOAN_PREMIUM_INVALID
        );

        uint128 oldFlashloanPremiumToProtocol = IPool(_pool).FLASHLOAN_PREMIUM_TO_PROTOCOL();

        IPool(_pool)
            .updateFlashloanPremiums(
                IPool(_pool).FLASHLOAN_PREMIUM_TOTAL(),
                newFlashloanPremiumToProtocol
            );

        emit FlashloanPremiumToProtocolUpdated(
            oldFlashloanPremiumToProtocol,
            newFlashloanPremiumToProtocol
        );
    }

    function _checkNoSuppliers(address asset) internal view {
        ( , uint256 accruedToTreasury, uint256 totalATokens, , , , , , , , , ) =
            IPoolDataProvider(IPoolAddressesProvider(_addressesProvider).getPoolDataProvider())
                .getReserveData(asset);

        require(totalATokens == 0 && accruedToTreasury == 0, Errors.RESERVE_LIQUIDITY_NOT_ZERO);
    }

    function _checkNoBorrowers(address asset) internal view {
        uint256 totalDebt =
            IPoolDataProvider(IPoolAddressesProvider(_addressesProvider).getPoolDataProvider())
                .getTotalDebt(asset);

        require(totalDebt == 0, Errors.RESERVE_DEBT_NOT_ZERO);
    }

    function _onlyPoolAdmin() internal view {
        IACLManager aclManager = IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager());
        require(aclManager.isPoolAdmin(msg.sender), Errors.CALLER_NOT_POOL_ADMIN);
    }

    function _onlyEmergencyAdmin() internal view {
        require(
            IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager())
                .isEmergencyAdmin(msg.sender),
            Errors.CALLER_NOT_EMERGENCY_ADMIN
        );
    }

    function _onlyPoolOrEmergencyAdmin() internal view {
        IACLManager aclManager =
            IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager());

        require(
            aclManager.isPoolAdmin(msg.sender) || aclManager.isEmergencyAdmin(msg.sender),
            Errors.CALLER_NOT_POOL_OR_EMERGENCY_ADMIN
        );
    }

    function _onlyAssetListingOrPoolAdmins() internal view {
        IACLManager aclManager =
            IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager());

        require(
            aclManager.isAssetListingAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_ASSET_LISTING_OR_POOL_ADMIN
        );
    }

    function _onlyRiskOrPoolAdmins() internal view {
        IACLManager aclManager =
            IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager());

        require(
            aclManager.isRiskAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_RISK_OR_POOL_ADMIN
        );
    }

}
