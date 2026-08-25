// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {GPv2SafeERC20} from '../../dependencies/gnosis/contracts/GPv2SafeERC20.sol';
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';
import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {IPool} from '../../interfaces/IPool.sol';
import {IAToken} from '../../interfaces/IAToken.sol';
import {IAaveIncentivesController} from '../../interfaces/IAaveIncentivesController.sol';
import {IInitializableAToken} from '../../interfaces/IInitializableAToken.sol';
import {MintableScaledBalanceToken} from './base/MintableScaledBalanceToken.sol';
import {EIP712Base} from './base/EIP712Base.sol';

/**
 * @title Aave ERC20 AToken
 * @author Aave
 * @notice Implementation of the interest bearing token for the Aave protocol
 */
contract AToken is VersionedInitializable, MintableScaledBalanceToken, EIP712Base, IAToken {
  using WadRayMath for uint256;
  using SafeCast for uint256;
  using GPv2SafeERC20 for IERC20;

  /**
   * @dev   Indicates a failure with the `spender`'s allowance. Used in transfers.
   * @param spender   Address that may be allowed to operate on tokens without being their owner
   * @param allowance Amount of tokens a `spender` is allowed to operate with
   * @param needed    Minimum amount required to perform a transfer
   */
  error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

  bytes32 public constant PERMIT_TYPEHASH =
    keccak256('Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)');

  uint256 public constant ATOKEN_REVISION = 0x2;

  address internal _treasury;
  address internal _underlyingAsset;

  /// @inheritdoc VersionedInitializable
  function getRevision() internal pure virtual override returns (uint256) {
    return ATOKEN_REVISION;
  }

  /**
   * @dev Constructor.
   * @param pool The address of the Pool contract
   */
  constructor(
    IPool pool
  ) MintableScaledBalanceToken(pool, 'ATOKEN_IMPL', 'ATOKEN_IMPL', 0) EIP712Base() {
    // Intentionally left blank
  }

  /// @inheritdoc IInitializableAToken
  function initialize(
    IPool initializingPool,
    address treasury,
    address underlyingAsset,
    IAaveIncentivesController incentivesController,
    uint8 aTokenDecimals,
    string calldata aTokenName,
    string calldata aTokenSymbol,
    bytes calldata params
  ) public virtual override initializer {
    require(initializingPool == POOL, Errors.POOL_ADDRESSES_DO_NOT_MATCH);
    _setName(aTokenName);
    _setSymbol(aTokenSymbol);
    _setDecimals(aTokenDecimals);

    _treasury = treasury;
    _underlyingAsset = underlyingAsset;
    _incentivesController = incentivesController;

    _domainSeparator = _calculateDomainSeparator();

    emit Initialized(
      underlyingAsset,
      address(POOL),
      treasury,
      address(incentivesController),
      aTokenDecimals,
      aTokenName,
      aTokenSymbol,
      params
    );
  }

  /// @inheritdoc IAToken
  function mint(
    address caller,
    address onBehalfOf,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool returns (bool) {
    return _mintScaled(caller, onBehalfOf, amount, index, RoundingMode.ROUND_DOWN);
  }

  /// @inheritdoc IAToken
  function burn(
    address from,
    address receiverOfUnderlying,
    uint256 amount,
    uint256 index
  ) external virtual override onlyPool {
    _burnScaled(from, receiverOfUnderlying, amount, index, RoundingMode.ROUND_UP);
    if (receiverOfUnderlying != address(this)) {
      IERC20(_underlyingAsset).safeTransfer(receiverOfUnderlying, amount);
    }
  }

  /// @inheritdoc IAToken
  function mintToTreasury(uint256 amount, uint256 index) external virtual override onlyPool {
    if (amount == 0) {
      return;
    }
    _mintScaled(address(POOL), _treasury, amount, index, RoundingMode.ROUND_DOWN);
  }

  /// @inheritdoc IAToken
  function transferOnLiquidation(
    address from,
    address to,
    uint256 value
  ) external virtual override onlyPool {
    // Being a normal transfer, the Transfer() and BalanceTransfer() are emitted
    // so no need to emit a specific event here
    _transfer(from, to, value, false, RoundingMode.ROUND_DOWN);
  }

  /// @inheritdoc IERC20
  function balanceOf(address user) public view returns (uint256) {
    return
      _getRebasedAmount(scaledBalanceOf(user), POOL.getReserveNormalizedIncome(_underlyingAsset));
  }

  /// @inheritdoc IERC20
  function totalSupply() public view returns (uint256) {
    uint256 currentSupplyScaled = scaledTotalSupply();

    if (currentSupplyScaled == 0) {
      return 0;
    }

    return
      _getRebasedAmount(currentSupplyScaled, POOL.getReserveNormalizedIncome(_underlyingAsset));
  }

  /// @inheritdoc IAToken
  function RESERVE_TREASURY_ADDRESS() external view override returns (address) {
    return _treasury;
  }

  /// @inheritdoc IAToken
  function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
    return _underlyingAsset;
  }

  /// @inheritdoc IAToken
  function transferUnderlyingTo(address target, uint256 amount) external virtual override onlyPool {
    IERC20(_underlyingAsset).safeTransfer(target, amount);
  }

  /// @inheritdoc IAToken
  function handleRepayment(
    address user,
    address onBehalfOf,
    uint256 amount
  ) external virtual override onlyPool {
    // Intentionally left blank
  }

  /// @inheritdoc IAToken
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external override {
    require(owner != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
    //solium-disable-next-line
    require(block.timestamp <= deadline, Errors.INVALID_EXPIRATION);
    uint256 currentValidNonce = _nonces[owner];
    bytes32 digest = keccak256(
      abi.encodePacked(
        '\x19\x01',
        DOMAIN_SEPARATOR(),
        keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, currentValidNonce, deadline))
      )
    );
    require(owner == ecrecover(digest, v, r, s), Errors.INVALID_SIGNATURE);
    _nonces[owner] = currentValidNonce + 1;
    _approve(owner, spender, value);
  }

  /// @inheritdoc IERC20
  function transfer(address recipient, uint256 amount) external virtual override returns (bool) {
    _transfer(_msgSender(), recipient, amount.toUint128(), true, RoundingMode.ROUND_UP);
    return true;
  }

  /// @inheritdoc IERC20
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) external virtual returns (bool) {
    _spendAllowance(sender, _msgSender(), amount);

    _transfer(sender, recipient, amount.toUint128(), true, RoundingMode.ROUND_UP);

    return true;
  }

  /**
   * @notice Transfers the aTokens between two users. Validates the transfer
   * (ie checks for valid HF after the transfer) if required
   * @param from The source address
   * @param to The destination address
   * @param rebasedAmount The amount getting transferred
   * @param validate True if the transfer needs to be validated, false otherwise
   */
  function _transfer(
    address from,
    address to,
    uint256 rebasedAmount,
    bool validate,
    RoundingMode roundingMode
  ) internal virtual {
    address underlyingAsset = _underlyingAsset;

    uint256 index = POOL.getReserveNormalizedIncome(underlyingAsset);

    uint256 senderStartingRebasedBalance = _getRebasedAmount(scaledBalanceOf(from), index);
    uint256 recipientStartingRebasedBalance = _getRebasedAmount(scaledBalanceOf(to), index);

    _transferScaled(from, to, rebasedAmount, index, roundingMode);

    if (validate) {
      POOL.finalizeTransfer(
        underlyingAsset,
        from,
        to,
        rebasedAmount,
        senderStartingRebasedBalance,
        recipientStartingRebasedBalance
      );
    }

    emit BalanceTransfer(from, to, _getScaledAmount(rebasedAmount, index), index);
  }

  /**
   * @notice Implements the basic logic to transfer scaled balance tokens between two users
   * @dev It emits a mint event with the interest accrued per user
   * @dev The scaled transfer amount is rounded up so the recipient receives at least the requested amount
   * @param sender The source address
   * @param recipient The destination address
   * @param rebasedAmount The amount getting transferred
   * @param index The next liquidity index of the reserve
   */
  function _transferScaled(
    address sender,
    address recipient,
    uint256 rebasedAmount,
    uint256 index,
    RoundingMode roundingMode
  ) internal {
    uint128 scaledAmount = _getScaledAmount(rebasedAmount, index, roundingMode).toUint128();

    uint256 senderScaledOldBalance = _userState[sender].balance;
    uint256 senderAccruedRebasedBalance = senderScaledOldBalance.rayMul(index) -
      senderScaledOldBalance.rayMul(_userState[sender].additionalData);

    _userState[sender].balance = senderScaledOldBalance.toUint128() - scaledAmount;

    uint256 recipientScaledOldBalance = _userState[recipient].balance;
    uint256 recipientAccruedRebasedBalance = recipientScaledOldBalance.rayMul(index) -
      recipientScaledOldBalance.rayMul(_userState[recipient].additionalData);

    _userState[recipient].balance = recipientScaledOldBalance.toUint128() + scaledAmount;

    _userState[sender].additionalData = index.toUint128();
    _userState[recipient].additionalData = index.toUint128();

    if (address(_incentivesController) != address(0)) {
      uint256 currentTotalSupply = _totalSupply;
      _incentivesController.handleAction(sender, currentTotalSupply, senderScaledOldBalance);
      if (sender != recipient) {
        _incentivesController.handleAction(
          recipient,
          currentTotalSupply,
          recipientScaledOldBalance
        );
      }
    }

    if (senderAccruedRebasedBalance > 0) {
      emit Transfer(address(0), sender, senderAccruedRebasedBalance);
      emit Mint(
        _msgSender(),
        sender,
        senderAccruedRebasedBalance,
        senderAccruedRebasedBalance,
        index
      );
    }

    if (sender != recipient && recipientAccruedRebasedBalance > 0) {
      emit Transfer(address(0), recipient, recipientAccruedRebasedBalance);
      emit Mint(
        _msgSender(),
        recipient,
        recipientAccruedRebasedBalance,
        recipientAccruedRebasedBalance,
        index
      );
    }

    emit Transfer(sender, recipient, rebasedAmount);
  }

  /**
   * @notice Updates `owner`'s allowance for `spender` based on `correctedAmount` spent
   * @param owner The owner of the tokens
   * @param spender The user allowed to spend on behalf of the owner
   * @param rebasedAmount The nominal amount being transferred
   */
  function _spendAllowance(address owner, address spender, uint256 rebasedAmount) internal virtual {
    uint256 currentAllowance = _allowances[owner][spender];
    if (currentAllowance < rebasedAmount) {
      revert ERC20InsufficientAllowance(spender, currentAllowance, rebasedAmount);
    }

    uint256 index = POOL.getReserveNormalizedIncome(_underlyingAsset);
    uint256 scaledBalance = scaledBalanceOf(owner);
    uint256 scaledAmount = _getScaledAmount(rebasedAmount, index);
    uint256 startingRebasedBalance = _getRebasedAmount(scaledBalance, index);
    uint256 endingRebasedBalance = _getRebasedAmount(scaledBalance - scaledAmount, index);

    // Consume allowance based on the owner's actual balance decrease rather than `rebasedAmount`
    // (inspired by Aave v3.5). Because the scaled amount is rounded up, the owner's balance can
    // drop by slightly more than `rebasedAmount`, so we measure the real decrease from the
    // resulting scaled balance to keep the invariant: allowance consumed == balance transferred.
    // The consumption is capped at the current allowance.
    uint256 rebasedBalanceDecrease = startingRebasedBalance - endingRebasedBalance;

    uint256 consumption = currentAllowance >= rebasedBalanceDecrease
      ? rebasedBalanceDecrease
      : currentAllowance;
    _approve(owner, spender, currentAllowance - consumption);
  }

  /// @inheritdoc IERC20
  function approve(address spender, uint256 amount) external virtual override returns (bool) {
    _approve(_msgSender(), spender, amount);
    return true;
  }

  /**
   * @notice Increases the allowance of spender to spend _msgSender() tokens
   * @param spender The user allowed to spend on behalf of _msgSender()
   * @param addedValue The amount being added to the allowance
   * @return `true`
   */
  function increaseAllowance(address spender, uint256 addedValue) external virtual returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
    return true;
  }

  /**
   * @notice Decreases the allowance of spender to spend _msgSender() tokens
   * @param spender The user allowed to spend on behalf of _msgSender()
   * @param subtractedValue The amount being subtracted to the allowance
   * @return `true`
   */
  function decreaseAllowance(
    address spender,
    uint256 subtractedValue
  ) external virtual returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender] - subtractedValue);
    return true;
  }

  /**
   * @notice Approve `spender` to use `rebasedAmount` of `owner`s balance
   * @param owner The address owning the tokens
   * @param spender The address approved for spending
   * @param rebasedAmount The amount of tokens to approve spending of
   */
  function _approve(address owner, address spender, uint256 rebasedAmount) internal virtual {
    _allowances[owner][spender] = rebasedAmount;
    emit Approval(owner, spender, rebasedAmount);
  }

  /**
   * @dev Overrides the base function to fully implement IAToken
   * @dev see `EIP712Base.DOMAIN_SEPARATOR()` for more detailed documentation
   */
  function DOMAIN_SEPARATOR() public view override(IAToken, EIP712Base) returns (bytes32) {
    return super.DOMAIN_SEPARATOR();
  }

  /**
   * @dev Overrides the base function to fully implement IAToken
   * @dev see `EIP712Base.nonces()` for more detailed documentation
   */
  function nonces(address owner) public view override(IAToken, EIP712Base) returns (uint256) {
    return super.nonces(owner);
  }

  /// @inheritdoc EIP712Base
  function _EIP712BaseId() internal view override returns (string memory) {
    return name();
  }

  /// @inheritdoc IERC20
  function allowance(
    address owner,
    address spender
  ) external view virtual override returns (uint256) {
    return _allowances[owner][spender];
  }

  /// @inheritdoc IAToken
  function rescueTokens(address token, address to, uint256 amount) external override onlyPoolAdmin {
    require(token != _underlyingAsset, Errors.UNDERLYING_CANNOT_BE_RESCUED);
    IERC20(token).safeTransfer(to, amount);
  }

  function _getScaledAmount(uint256 rebasedAmount, uint256 index) internal pure returns (uint256) {
    return _getScaledAmount(rebasedAmount, index, RoundingMode.ROUND_UP);
  }

  function _getRebasedAmount(uint256 scaledAmount, uint256 index) internal pure returns (uint256) {
    return _getRebasedAmount(scaledAmount, index, RoundingMode.ROUND_DOWN);
  }
}
