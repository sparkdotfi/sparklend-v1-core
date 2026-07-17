// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {MathUtils} from '../libraries/math/MathUtils.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {IInitializableDebtToken} from '../../interfaces/IInitializableDebtToken.sol';
import {IStableDebtToken} from '../../interfaces/IStableDebtToken.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {EIP712Base} from './base/EIP712Base.sol';
import {DebtTokenBase} from './base/DebtTokenBase.sol';
import {IncentivizedERC20} from './base/IncentivizedERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title  StableDebtToken
 * @author Aave
 * @notice Implements a stable debt token to track the borrowing positions of users at stable rate
 *         mode
 * @dev    Transfer and approve functionalities are disabled since its a non-transferable token
 */
contract StableDebtToken is DebtTokenBase, IncentivizedERC20, IStableDebtToken {

    using WadRayMath for uint256;
    using SafeCast   for uint256;

    uint256 public constant DEBT_TOKEN_REVISION = 0x1;

    // Map of users address and the timestamp of their last update
    // (userAddress => lastUpdateTimestamp)
    mapping(address => uint40) internal _timestamps;

    uint128 internal _avgStableRate;

    // Timestamp of the last update of the total supply
    uint40 internal _totalSupplyTimestamp;

    /**
     * @dev   Constructor.
     * @param pool The address of the Pool contract
     */
    constructor(address pool)
        DebtTokenBase()
        IncentivizedERC20(pool, 'STABLE_DEBT_TOKEN_IMPL', 'STABLE_DEBT_TOKEN_IMPL', 0)
    {
        // Intentionally left blank
    }

    /// @inheritdoc IInitializableDebtToken
    function initialize(
        address          initializingPool,
        address          underlyingAsset,
        address          incentivesController,
        uint8            debtTokenDecimals,
        string  memory   debtTokenName,
        string  memory   debtTokenSymbol,
        bytes   calldata params
    ) external override initializer {
        require(initializingPool == POOL, Errors.POOL_ADDRESSES_DO_NOT_MATCH);

        _setName(debtTokenName);
        _setSymbol(debtTokenSymbol);
        _setDecimals(debtTokenDecimals);

        _underlyingAsset      = underlyingAsset;
        _incentivesController = incentivesController;
        _domainSeparator      = _calculateDomainSeparator();

        emit Initialized(
            underlyingAsset,
            POOL,
            incentivesController,
            debtTokenDecimals,
            debtTokenName,
            debtTokenSymbol,
            params
        );
    }

    /// @inheritdoc VersionedInitializable
    function getRevision() internal pure virtual override returns (uint256) {
        return DEBT_TOKEN_REVISION;
    }

    /// @inheritdoc IStableDebtToken
    function getAverageStableRate() external view virtual override returns (uint256) {
        return _avgStableRate;
    }

    /// @inheritdoc IStableDebtToken
    function getUserLastUpdated(address user) external view virtual override returns (uint40) {
        return _timestamps[user];
    }

    /// @inheritdoc IStableDebtToken
    function getUserStableRate(address user) external view virtual override returns (uint256) {
        return _userState[user].additionalData;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual override returns (uint256) {
        uint256 balance = super.balanceOf(account);

        // For stable debt, interest accumulates based on the user's individual fixed borrow rate
        // compounded from their last update timestamp to the current block timestamp.
        return
            balance == 0
                ? 0
                : balance
                    .rayMul(
                        MathUtils.getCompoundedIndexToNow({
                            rate                : _userState[account].additionalData,
                            lastUpdateTimestamp : _timestamps[account]
                        })
                    );
    }

    struct MintLocalVars {
        uint256 previousSupply;
        uint256 nextSupply;
        uint256 amountInRay;
        uint256 stableRate;
        uint256 nextStableRate;
        uint256 avgStableRate;
    }

    /// @inheritdoc IStableDebtToken
    function mint(
        address user,
        address onBehalfOf,
        uint256 amount,
        uint256 rate
    ) external virtual override onlyPool returns (bool, uint256, uint256) {
        MintLocalVars memory vars;

        if (user != onBehalfOf) {
            _decreaseBorrowAllowance(onBehalfOf, user, amount);
        }

        // Fetch user's accrued interest since their last action (to capitalize/compound it).
        ( , uint256 startingBalance, uint256 balanceIncrease ) =
            _calculateBalanceIncrease(onBehalfOf);

        vars.previousSupply = totalSupply();
        vars.avgStableRate  = _avgStableRate;
        vars.nextSupply     = _totalSupply = vars.previousSupply + amount;
        vars.amountInRay    = amount.wadToRay();
        vars.stableRate     = _userState[onBehalfOf].additionalData;

        // Calculate the user's new weighted average stable borrow rate
        vars.nextStableRate =
            (
                vars.stableRate.rayMul(startingBalance.wadToRay()) +
                vars.amountInRay.rayMul(rate)
            ).rayDiv((startingBalance + amount).wadToRay());

        _userState[onBehalfOf].additionalData = vars.nextStableRate.toUint128();

        //solium-disable-next-line
        _totalSupplyTimestamp = _timestamps[onBehalfOf] = uint40(block.timestamp);

        // Calculate the pool's new weighted average stable borrow rate
        vars.avgStableRate =
            _avgStableRate =
                (
                    (
                        vars.avgStableRate.rayMul(vars.previousSupply.wadToRay()) +
                        rate.rayMul(vars.amountInRay)
                    ).rayDiv(vars.nextSupply.wadToRay())
                ).toUint128();

        // Capitalize/compound the user's accrued interest by minting the new borrow amount + the balance increase (accrued interest)
        uint256 amountToMint = amount + balanceIncrease;

        _mint(onBehalfOf, amountToMint, vars.previousSupply);

        emit Transfer(address(0), onBehalfOf, amountToMint);

        emit Mint(
            user,
            onBehalfOf,
            amountToMint,
            startingBalance,
            balanceIncrease,
            vars.nextStableRate,
            vars.avgStableRate,
            vars.nextSupply
        );

        return (startingBalance == 0, vars.nextSupply, vars.avgStableRate);
    }

    /// @inheritdoc IStableDebtToken
    function burn(
        address from,
        uint256 amount
    ) external virtual override onlyPool returns (uint256, uint256) {
        ( , uint256 startingBalance, uint256 balanceIncrease ) = _calculateBalanceIncrease(from);

        uint256 previousSupply    = totalSupply();
        uint256 nextAvgStableRate = 0;
        uint256 nextSupply        = 0;
        uint256 userStableRate    = _userState[from].additionalData;

        // Safely reduce the pool's average stable rate and total supply.
        // Because user debt and total supply accumulate separately, minor rounding/imprecision errors can occur.
        // If the repayment is the final portion of the supply, or exceeds previousSupply, zero out the rates to prevent underflow.
        if (previousSupply <= amount) {
            _avgStableRate = 0;
            _totalSupply   = 0;
        } else {
            nextSupply = _totalSupply = previousSupply - amount;

            uint256 firstTerm  = uint256(_avgStableRate).rayMul(previousSupply.wadToRay());
            uint256 secondTerm = userStableRate.rayMul(amount.wadToRay());

            // Similarly, if user rate * amount exceeds the pool's average rate * total supply due to precision rounding,
            // reset average stable rate to 0.
            if (secondTerm >= firstTerm) {
                nextAvgStableRate = _totalSupply = _avgStableRate = 0;
            } else {
                nextAvgStableRate =
                    _avgStableRate =
                        (firstTerm - secondTerm).rayDiv(nextSupply.wadToRay()).toUint128();
            }
        }

        if (amount == startingBalance) {
            _userState[from].additionalData = 0;
            _timestamps[from]               = 0;
        } else {
            //solium-disable-next-line
            _timestamps[from] = uint40(block.timestamp);
        }

        //solium-disable-next-line
        _totalSupplyTimestamp = uint40(block.timestamp);

        if (balanceIncrease > amount) {
            uint256 amountToMint = balanceIncrease - amount;

            _mint(from, amountToMint, previousSupply);

            emit Transfer(address(0), from, amountToMint);

            emit Mint(
                from,
                from,
                amountToMint,
                startingBalance,
                balanceIncrease,
                userStableRate,
                nextAvgStableRate,
                nextSupply
            );
        } else {
            uint256 amountToBurn = amount - balanceIncrease;

            _burn(from, amountToBurn, previousSupply);

            emit Transfer(from, address(0), amountToBurn);

            emit Burn(
                from,
                amountToBurn,
                startingBalance,
                balanceIncrease,
                nextAvgStableRate,
                nextSupply
            );
        }

        return ( nextSupply, nextAvgStableRate );
    }

    /**
     * @notice Calculates the increase in balance since the last user interaction
     * @param  user The address of the user for which the interest is being accumulated
     * @return previousPrincipalBalance The previous principal balance
     * @return newPrincipalBalance      The new principal balance
     * @return balanceIncrease          The balance increase
     */
    function _calculateBalanceIncrease(
        address user
    )
        internal
        view
        returns (
            uint256 previousPrincipalBalance,
            uint256 newPrincipalBalance,
            uint256 balanceIncrease
        )
    {
        previousPrincipalBalance = super.balanceOf(user);

        if (previousPrincipalBalance == 0) return ( 0, 0, 0 );

        newPrincipalBalance = balanceOf(user);
        balanceIncrease     = newPrincipalBalance - previousPrincipalBalance;
    }

    /// @inheritdoc IStableDebtToken
    function getSupplyData() external view override returns (uint256, uint256, uint256, uint40) {
        uint256 avgRate = _avgStableRate;

        return ( super.totalSupply(), _calcTotalSupply(avgRate), avgRate, _totalSupplyTimestamp );
    }

    /// @inheritdoc IStableDebtToken
    function getTotalSupplyAndAvgRate() external view override returns (uint256, uint256) {
        uint256 avgRate = _avgStableRate;

        return ( _calcTotalSupply(avgRate), avgRate );
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual override returns (uint256) {
        return _calcTotalSupply(_avgStableRate);
    }

    /// @inheritdoc IStableDebtToken
    function getTotalSupplyLastUpdated() external view override returns (uint40) {
        return _totalSupplyTimestamp;
    }

    /// @inheritdoc IStableDebtToken
    function principalBalanceOf(address user) external view virtual override returns (uint256) {
        return super.balanceOf(user);
    }

    /// @inheritdoc IStableDebtToken
    function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
        return _underlyingAsset;
    }

    /**
     * @notice Calculates the total supply
     * @param  avgRate   The average rate at which the total supply increases
     * @return debtDelta The debt balance of the user since the last burn/mint action
     */
    function _calcTotalSupply(uint256 avgRate) internal view returns (uint256) {
        uint256 principalSupply = super.totalSupply();

        return principalSupply == 0
            ? 0
            : principalSupply
                .rayMul(MathUtils.getCompoundedIndexToNow(avgRate, _totalSupplyTimestamp));
    }

    /**
     * @notice Mints stable debt tokens to a user
     * @param  account        The account receiving the debt tokens
     * @param  amount         The amount being minted
     * @param  oldTotalSupply The total supply before the minting event
     */
    function _mint(address account, uint256 amount, uint256 oldTotalSupply) internal {
        uint128 oldBalance = _userState[account].balance;

        _userState[account].balance = oldBalance + amount.toUint128();

        if (_incentivesController == address(0)) return;

        IAaveIncentivesController(_incentivesController)
            .handleAction(account, oldTotalSupply, oldBalance);
    }

    /**
     * @notice Burns stable debt tokens of a user
     * @param  account        The user getting his debt burned
     * @param  amount         The amount being burned
     * @param  oldTotalSupply The total supply before the burning event
     */
    function _burn(address account, uint256 amount, uint256 oldTotalSupply) internal {
        uint128 oldBalance = _userState[account].balance;

        _userState[account].balance = oldBalance - amount.toUint128();

        if (_incentivesController == address(0)) return;

        IAaveIncentivesController(_incentivesController)
            .handleAction(account, oldTotalSupply, oldBalance);
    }

    /// @inheritdoc EIP712Base
    function _EIP712BaseId() internal view override returns (string memory) {
        return name();
    }

    /**
     * @dev Being non transferrable, the debt token does not implement any of the standard ERC20
     *      functions for transfer and allowance.
     */
    function transfer(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function allowance(address, address) external view virtual override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function approve(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function transferFrom(address, address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function increaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function decreaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

}
