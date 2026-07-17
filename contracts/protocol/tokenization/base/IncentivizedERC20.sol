// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { Context }                   from '../../../dependencies/openzeppelin/contracts/Context.sol';
import { IERC20 }                    from '../../../dependencies/openzeppelin/contracts/IERC20.sol';
import { IERC20Detailed }            from '../../../dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import { SafeCast }                  from '../../../dependencies/openzeppelin/contracts/SafeCast.sol';
import { WadRayMath }                from '../../libraries/math/WadRayMath.sol';
import { Errors }                    from '../../libraries/helpers/Errors.sol';
import { IAaveIncentivesController } from '../../../interfaces/IAaveIncentivesController.sol';
import { IPoolAddressesProvider }    from '../../../interfaces/IPoolAddressesProvider.sol';
import { IPool }                     from '../../../interfaces/IPool.sol';
import { IACLManager }               from '../../../interfaces/IACLManager.sol';

/**
 * @title  IncentivizedERC20
 * @author Aave, inspired by the Openzeppelin ERC20 implementation
 * @notice Basic ERC20 implementation
 */
abstract contract IncentivizedERC20 is Context, IERC20Detailed {

    using WadRayMath for uint256;
    using SafeCast   for uint256;

    /**
     * @dev Only pool admin can call functions marked by this modifier.
     */
    modifier onlyPoolAdmin() {
        require(
            IACLManager(IPoolAddressesProvider(_addressesProvider).getACLManager())
                .isPoolAdmin(msg.sender),
            Errors.CALLER_NOT_POOL_ADMIN
        );

        _;
    }

    /**
     * @dev Only pool can call functions marked by this modifier.
     */
    modifier onlyPool() {
        require(_msgSender() == POOL, Errors.CALLER_MUST_BE_POOL);

        _;
    }

    /**
     * @dev `additionalData` is a flexible field. ATokens and VariableDebtTokens use this field
     *      store the index of the user's last supply/withdrawal/borrow/repayment. StableDebtTokens
     *      use this field to store the user's stable rate.
     */
    struct UserState {
        uint128 balance;
        uint128 additionalData;
    }

    address internal immutable _addressesProvider;

    address public immutable POOL;

    // Map of users address and their state data (userAddress => userStateData)
    mapping(address => UserState) internal _userState;

    // Map of allowances (delegator => delegatee => allowance)
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 internal _totalSupply;

    string private _name;
    string private _symbol;

    uint8 private _decimals;

    address internal _incentivesController;

    /**
     * @dev   Constructor.
     * @param pool     The reference to the main Pool contract
     * @param name     The name of the token
     * @param symbol   The symbol of the token
     * @param decimals The number of decimals of the token
     */
    constructor(address pool, string memory name, string memory symbol, uint8 decimals) {
        _addressesProvider = IPool(pool).ADDRESSES_PROVIDER();
        _name              = name;
        _symbol            = symbol;
        _decimals          = decimals;
        POOL               = pool;
    }

    /// @inheritdoc IERC20Detailed
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC20Detailed
    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC20Detailed
    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    /// @inheritdoc IERC20
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /// @inheritdoc IERC20
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _userState[account].balance;
    }

    /**
     * @notice Returns the address of the Incentives Controller contract
     * @return controller The address of the Incentives Controller
     */
    function getIncentivesController() external view virtual returns (address) {
        return _incentivesController;
    }

    /**
     * @notice Sets a new Incentives Controller
     * @param  controller the new Incentives controller
     */
    function setIncentivesController(address controller) external onlyPoolAdmin {
        _incentivesController = controller;
    }

    /// @inheritdoc IERC20
    function transfer(address recipient, uint256 amount) external virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount.toUint128());

        return true;
    }

    /// @inheritdoc IERC20
    function allowance(
        address owner,
        address spender
    ) external view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 amount) external virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);

        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external virtual override returns (bool) {
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()] - amount);
        _transfer(sender, recipient, amount.toUint128());

        return true;
    }

    /**
     * @notice Increases the allowance of spender to spend _msgSender() tokens
     * @param  spender The user allowed to spend on behalf of _msgSender()
     * @param  amount  The amount being added to the allowance
     * @return success `true`
     */
    function increaseAllowance(address spender, uint256 amount) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + amount);

        return true;
    }

    /**
     * @notice Decreases the allowance of spender to spend _msgSender() tokens
     * @param  spender The user allowed to spend on behalf of _msgSender()
     * @param  amount  The amount being subtracted to the allowance
     * @return success `true`
     */
    function decreaseAllowance(address spender, uint256 amount) external virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] - amount);

        return true;
    }

    /**
     * @notice Transfers tokens between two users and apply incentives if defined.
     * @param  sender    The source address
     * @param  recipient The destination address
     * @param  amount    The amount getting transferred
     */
    function _transfer(address sender, address recipient, uint128 amount) internal virtual {
        uint128 oldSenderBalance    = _userState[sender].balance;
        uint128 oldRecipientBalance = _userState[recipient].balance;

        _userState[sender].balance    = oldSenderBalance - amount;
        _userState[recipient].balance = oldRecipientBalance + amount;

        IAaveIncentivesController controller = IAaveIncentivesController(_incentivesController);

        if (address(controller) == address(0)) return;

        uint256 totalSupply = _totalSupply;

        // Notify incentives controller for the sender's updated balance state.
        controller.handleAction(sender, totalSupply, oldSenderBalance);

        if (sender == recipient) return;

        // Notify incentives controller for the recipient's updated balance state.
        controller.handleAction(recipient, totalSupply, oldRecipientBalance);
    }

    /**
     * @notice Approve `spender` to use `amount` of `owner`s balance
     * @param  owner   The address owning the tokens
     * @param  spender The address approved for spending
     * @param  amount  The amount of tokens to approve spending of
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        _allowances[owner][spender] = amount;

        emit Approval(owner, spender, amount);
    }

    /**
     * @notice Update the name of the token
     * @param  name The new name for the token
     */
    function _setName(string memory name) internal {
        _name = name;
    }

    /**
     * @notice Update the symbol for the token
     * @param  symbol The new symbol for the token
     */
    function _setSymbol(string memory symbol) internal {
        _symbol = symbol;
    }

    /**
     * @notice Update the number of decimals for the token
     * @param  decimals The new number of decimals for the token
     */
    function _setDecimals(uint8 decimals) internal {
        _decimals = decimals;
    }

}
