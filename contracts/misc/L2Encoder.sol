// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { SafeCast }    from '../dependencies/openzeppelin/contracts/SafeCast.sol';
import { IPool }       from '../interfaces/IPool.sol';
import { ReserveData } from '../protocol/libraries/types/DataTypes.sol';

/**
 * @title  L2Encoder
 * @author Aave
 * @notice Helper contract to encode calldata, used to optimize calldata size in L2Pool for
 *         transaction cost reduction only indented to help generate calldata for users/frontends.
 */
contract L2Encoder {

    using SafeCast for uint256;

    address public immutable POOL;

    /**
    * @dev   Constructor.
    * @param pool The address of the Pool contract
    */
    constructor(address pool) {
        POOL = pool;
    }

    /**
     * @notice Encodes supply parameters from standard input to compact representation of 1 bytes32
     * @dev    Without an onBehalfOf parameter as the compact calls to L2Pool will use msg.sender as
     *         onBehalfOf
     * @param  asset        The address of the underlying asset to supply
     * @param  amount       The amount to be supplied
     * @param  referralCode referralCode Code used to register the integrator originating the
     *                      operation, for potential rewards. 0 if the action is executed directly
     *                      by the user, without any middle-man
     * @return params       Compact representation of supply parameters
     */
    function encodeSupplyParams(
        address asset,
        uint256 amount,
        uint16  referralCode
    ) external view returns (bytes32 params) {
        uint16  assetId         = IPool(POOL).getReserveData(asset).id;
        uint128 shortenedAmount = amount.toUint128();

        assembly {
            params := add(assetId, add(shl(16, shortenedAmount), shl(144, referralCode)))
        }
    }

    /**
     * @notice Encodes supplyWithPermit parameters from standard input to compact representation of
     *         3 bytes32
     * @dev    Without an onBehalfOf parameter as the compact calls to L2Pool will use msg.sender as
     *         onBehalfOf
     * @param  asset        The address of the underlying asset to supply
     * @param  amount       The amount to be supplied
     * @param  referralCode Code used to register the integrator originating the operation, for
     *                      potential rewards. 0 if the action is executed directly by the user,
     *                      without any middle-man
     * @param  deadline     The deadline timestamp that the permit is valid
     * @param  permitV      The V parameter of ERC712 permit sig
     * @param  permitR      The R parameter of ERC712 permit sig
     * @param  permitS      The S parameter of ERC712 permit sig
     * @return params       Compact representation of supplyWithPermit parameters
     * @return r            The R parameter of ERC712 permit sig
     * @return s            The S parameter of ERC712 permit sig
     */
    function encodeSupplyWithPermitParams(
        address asset,
        uint256 amount,
        uint16  referralCode,
        uint256 deadline,
        uint8   permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external view returns (bytes32 params, bytes32 r, bytes32 s) {
        uint16  assetId           = IPool(POOL).getReserveData(asset).id;
        uint128 shortenedAmount   = amount.toUint128();
        uint32  shortenedDeadline = deadline.toUint32();

        assembly {
            params := add(
                assetId,
                add(
                    shl(16, shortenedAmount),
                    add(shl(144, referralCode), add(shl(160, shortenedDeadline), shl(192, permitV)))
                )
            )
        }

        r = permitR;
        s = permitS;
    }

    /**
     * @notice Encodes withdraw parameters from standard input to compact representation of 1
     *         bytes32
     * @dev    Without a to parameter as the compact calls to L2Pool will use msg.sender as to
     * @param  asset  The address of the underlying asset to withdraw
     * @param  amount The underlying amount to be withdrawn
     * @return params Compact representation of withdraw parameters
     */
    function encodeWithdrawParams(
        address asset,
        uint256 amount
    ) external view returns (bytes32 params) {
        uint16 assetId = IPool(POOL).getReserveData(asset).id;

        uint128 shortenedAmount =
            amount == type(uint256).max ? type(uint128).max : amount.toUint128();

        assembly {
            params := add(assetId, shl(16, shortenedAmount))
        }
    }

    /**
     * @notice Encodes borrow parameters from standard input to compact representation of 1 bytes32
     * @dev    Without an onBehalfOf parameter as the compact calls to L2Pool will use msg.sender as
     *         onBehalfOf
     * @param  asset            The address of the underlying asset to borrow
     * @param  amount           The amount to be borrowed
     * @param  interestRateMode The interest rate mode at which the user wants to borrow: 1 for
     *                          Stable, 2 for Variable
     * @param  referralCode     The code used to register the integrator originating the operation,
     *                          for potential rewards. 0 if the action is executed directly by the
     *                          user, without any middle-man
     * @return params           Compact representation of withdraw parameters
     */
    function encodeBorrowParams(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16  referralCode
    ) external view returns (bytes32 params) {
        uint16  assetId                   = IPool(POOL).getReserveData(asset).id;
        uint128 shortenedAmount           = amount.toUint128();
        uint8   shortenedInterestRateMode = interestRateMode.toUint8();

        assembly {
            params := add(
                assetId,
                add(
                    shl(16, shortenedAmount),
                    add(shl(144, shortenedInterestRateMode), shl(152, referralCode))
                )
            )
        }
    }

    /**
    * @notice Encodes repay parameters from standard input to compact representation of 1 bytes32
    * @dev    Without an onBehalfOf parameter as the compact calls to L2Pool will use msg.sender as
    *         onBehalfOf
    * @param  asset            The address of the borrowed underlying asset previously borrowed
    * @param  amount           The amount to repay
    *                            - Send the value type(uint256).max in order to repay the whole debt
    *                              for `asset` on the specific `interestRateMode`
    * @param  interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for
    *                          Stable, 2 for Variable
    * @return params           Compact representation of repay parameters
    */
    function encodeRepayParams(
        address asset,
        uint256 amount,
        uint256 interestRateMode
    ) public view returns (bytes32 params) {
        uint16 assetId = IPool(POOL).getReserveData(asset).id;

        uint128 shortenedAmount =
            amount == type(uint256).max ? type(uint128).max : amount.toUint128();

        uint8 shortenedInterestRateMode = interestRateMode.toUint8();

        assembly {
            params := add(
                assetId, add(shl(16, shortenedAmount), shl(144, shortenedInterestRateMode))
            )
        }
    }

    /**
     * @notice Encodes repayWithPermit parameters from standard input to compact representation of 3
     *         bytes32
     * @dev    Without an onBehalfOf parameter as the compact calls to L2Pool will use msg.sender as
     *         onBehalfOf
     * @param  asset            The address of the borrowed underlying asset previously borrowed
     * @param  amount           The amount to repay
     *                            - Send the value type(uint256).max in order to repay the whole
     *                              debt for `asset` on the specific `debtMode`
     * @param  interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for
     *                          Stable, 2 for Variable
     * @param  deadline         The deadline timestamp that the permit is valid
     * @param  permitV          The V parameter of ERC712 permit sig
     * @param  permitR          The R parameter of ERC712 permit sig
     * @param  permitS          The S parameter of ERC712 permit sig
     * @return params           Compact representation of repayWithPermit parameters
     * @return r                The R parameter of ERC712 permit sig
     * @return s                The S parameter of ERC712 permit sig
     */
    function encodeRepayWithPermitParams(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint256 deadline,
        uint8   permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external view returns (bytes32 params, bytes32 r, bytes32 s) {
        uint16 assetId = IPool(POOL).getReserveData(asset).id;

        uint128 shortenedAmount =
            amount == type(uint256).max ? type(uint128).max : amount.toUint128();

        uint8  shortenedInterestRateMode = interestRateMode.toUint8();
        uint32 shortenedDeadline         = deadline.toUint32();

        assembly {
            params := add(
                assetId,
                add(
                    shl(16, shortenedAmount),
                    add(
                        shl(144, shortenedInterestRateMode),
                        add(shl(152, shortenedDeadline), shl(184, permitV))
                    )
                )
            )
        }

        r = permitR;
        s = permitS;
    }

    /**
     * @notice Encodes repay with aToken parameters from standard input to compact representation of
     *         1 bytes32
     * @param  asset            The address of the borrowed underlying asset previously borrowed
     * @param  amount           The amount to repay
     *                            - Send the value type(uint256).max in order to repay the whole
     *                              debt for `asset` on the specific `debtMode`
     * @param  interestRateMode The interest rate mode at of the debt the user wants to repay: 1 for
     *                          Stable, 2 for Variable
     * @return params           Compact representation of repay with aToken parameters
     */
    function encodeRepayWithATokensParams(
        address asset,
        uint256 amount,
        uint256 interestRateMode
    ) external view returns (bytes32 params) {
        return encodeRepayParams(asset, amount, interestRateMode);
    }

    /**
     * @notice Encodes swap borrow rate mode parameters from standard input to compact
     *         representation of 1 bytes32
     * @param  asset            The address of the underlying asset borrowed
     * @param  interestRateMode The current interest rate mode of the position being swapped: 1 for
     *                          Stable, 2 for Variable
     * @return params           Compact representation of swap borrow rate mode parameters
     */
    function encodeSwapBorrowRateMode(
        address asset,
        uint256 interestRateMode
    ) external view returns (bytes32 params) {
        uint16 assetId                   = IPool(POOL).getReserveData(asset).id;
        uint8  shortenedInterestRateMode = interestRateMode.toUint8();

        assembly {
            params := add(assetId, shl(16, shortenedInterestRateMode))
        }
    }

    /**
     * @notice Encodes rebalance stable borrow rate parameters from standard input to compact
     *         representation of 1 bytes32
     * @param  asset  The address of the underlying asset borrowed
     * @param  user   The address of the user to be rebalanced
     * @return params Compact representation of rebalance stable borrow rate parameters
     */
    function encodeRebalanceStableBorrowRate(
        address asset,
        address user
    ) external view returns (bytes32 params) {
        uint16 assetId = IPool(POOL).getReserveData(asset).id;

        assembly {
            params := add(assetId, shl(16, user))
        }
    }

    /**
     * @notice Encodes set user use reserve as collateral parameters from standard input to compact
     *         representation of 1 bytes32
     * @param  asset           The address of the underlying asset borrowed
     * @param  useAsCollateral True if the user wants to use the supply as collateral, false
     *                         otherwise
     * @return params          Compact representation of set user use reserve as collateral
     *                         parameters
     */
    function encodeSetUserUseReserveAsCollateral(
        address asset,
        bool    useAsCollateral
    ) external view returns (bytes32 params) {
        uint16 assetId = IPool(POOL).getReserveData(asset).id;

        assembly {
            params := add(assetId, shl(16, useAsCollateral))
        }
    }

    /**
     * @notice Encodes liquidation call parameters from standard input to compact representation of
     *         2 bytes32
     * @param  collateralAsset The address of the underlying asset used as collateral, to receive as
     *                         result of the liquidation
     * @param  debtAsset       The address of the underlying borrowed asset to be repaid with the
     *                         liquidation
     * @param  user            The address of the borrower getting liquidated
     * @param  debtToCover     The debt amount of borrowed `asset` the liquidator wants to cover
     * @param  receiveAToken   True if the liquidators wants to receive the collateral aTokens,
     *                         `false` if he wants to receive the underlying collateral asset
     *                         directly
     * @return params1         First half ot compact representation of liquidation call parameters
     * @return params2         Second half ot compact representation of liquidation call parameters
     */
    function encodeLiquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool    receiveAToken
    ) external view returns (bytes32 params1, bytes32 params2) {
        uint16 collateralAssetId = IPool(POOL).getReserveData(collateralAsset).id;
        uint16 debtAssetId       = IPool(POOL).getReserveData(debtAsset).id;

        uint128 shortenedDebtToCover =
            debtToCover == type(uint256).max ? type(uint128).max : debtToCover.toUint128();

        assembly {
            params1 := add(add(collateralAssetId, shl(16, debtAssetId)), shl(32, user))
            params2 := add(shortenedDebtToCover, shl(128, receiveAToken))
        }
    }

}
