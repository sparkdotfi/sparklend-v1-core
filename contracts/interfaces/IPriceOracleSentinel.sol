// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

/**
 * @title  IPriceOracleSentinel
 * @author Aave
 * @notice Defines the basic interface for the PriceOracleSentinel
 */
interface IPriceOracleSentinel {

    /**
     * @dev   Emitted after the sequencer oracle is updated
     * @param oracle The new sequencer oracle
     */
    event SequencerOracleUpdated(address oracle);

    /**
     * @dev   Emitted after the grace period is updated
     * @param gracePeriod The new grace period value
     */
    event GracePeriodUpdated(uint256 gracePeriod);

    /**
     * @notice Returns the PoolAddressesProvider
     * @return provider The address of the PoolAddressesProvider contract
     */
    function ADDRESSES_PROVIDER() external view returns (address provider);

    /**
     * @notice Returns true if the `borrow` operation is allowed.
     * @dev    Operation not allowed when PriceOracle is down or grace period not passed.
     * @return isAllowed True if the `borrow` operation is allowed, false otherwise.
     */
    function isBorrowAllowed() external view returns (bool isAllowed);

    /**
     * @notice Returns true if the `liquidation` operation is allowed.
     * @dev    Operation not allowed when PriceOracle is down or grace period not passed.
     * @return isAllowed True if the `liquidation` operation is allowed, false otherwise.
     */
    function isLiquidationAllowed() external view returns (bool isAllowed);

    /**
     * @notice Updates the address of the sequencer oracle
     * @param  oracle The address of the new Sequencer Oracle to use
     */
    function setSequencerOracle(address oracle) external;

    /**
     * @notice Updates the duration of the grace period
     * @param  gracePeriod The value of the new grace period duration
     */
    function setGracePeriod(uint256 gracePeriod) external;

    /**
     * @notice Returns the SequencerOracle
     * @return oracle The address of the sequencer oracle contract
     */
    function getSequencerOracle() external view returns (address oracle);

    /**
     * @notice Returns the grace period
     * @return gracePeriod The duration of the grace period
     */
    function getGracePeriod() external view returns (uint256 gracePeriod);

}
