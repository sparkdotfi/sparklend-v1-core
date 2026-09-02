# Rounding Direction Mitigation Report

## Scope

This repository is a SparkLend fork based on older Aave V3 code. The implemented mitigation is a narrow backport of the protocol-favoring rounding directions introduced in Aave v3.5 for high-value, low-decimal assets, together with Aave v3.6's correction to delegated variable-debt allowance accounting. It does not wholesale-backport Aave's intervening scaled-accounting, interface, event, or flag-management changes. It selectively adopts the before-and-after allowance calculations for aToken transfers and delegated variable borrowing, including their exact-request compatibility behavior.

> **Status update (2026-09-02, `dev` @ `900c189f`).** This report was originally written for the initial rounding PR (#12) and has been updated to reflect follow-up changes merged since then (post-action health-factor checks from the SC-1650 mitigation in #23/#24, the `useATokens` repay flag handling in #27/#29, the `ReserveUsedAsCollateralDisabled` event fix in #28, the `MintableScaledBalanceToken` rename in #20, and the `mintToTreasury` zero-mint guard). Two sections were added at the end: **Known Issues and Accepted Risks** (the acknowledged-findings reference for external auditors) and **Deployment Constraints** (operational requirements for the upgrade spell).

The fix is focused on the scaled-accounting and risk-valuation boundaries used by aTokens and variable debt tokens:

- unscaled asset amount to scaled balance: `amount / index`;
- scaled balance to unscaled balance: `scaledBalance * index`;
- asset amount to base-currency value: `amount * price / assetUnit`.

## Problem

The original fork used half-up rounding for ray arithmetic. In `WadRayMath`, `rayMul` adds `HALF_RAY` before division and `rayDiv` adds half of the divisor before division. Consequently, conversions between asset amounts and scaled balances can round either in favor of the user or in favor of the protocol depending on the reserve index and the exact amount.

For an 18-decimal asset, a one-wei discrepancy is normally economically negligible. A high-value, low-decimal asset assigns more value to each smallest unit. Repeated supply, withdrawal, transfer, borrow, repay, or liquidation operations can therefore turn an atomic-unit user-favoring rounding error into an extractable loop.

The protocol needs deterministic, pessimistic rounding at each accounting boundary:

| Operation                               | Required direction | Safety property                                                    |
| --------------------------------------- | ------------------ | ------------------------------------------------------------------ |
| aToken mint/supply                      | Down               | The user is not credited with more claim value than supplied.      |
| aToken burn/withdraw                    | Up                 | The user burns enough scaled balance for the amount withdrawn.     |
| aToken transfer                         | Up                 | The sender burns enough scaled balance for the amount transferred. |
| aToken balance and total supply         | Down               | The indexed aToken amount is not rounded above its exact value.    |
| Variable debt mint/borrow               | Up                 | The recorded debt is not smaller than the amount borrowed.         |
| Variable debt burn/repay                | Down               | Repayment does not erase more scaled debt than it covers.          |
| Variable debt balance and total supply  | Up                 | Variable debt is not rounded below its exact indexed obligation.   |
| Collateral base-currency conversion     | Down               | Account collateral is not overstated.                              |
| Aggregate debt base-currency conversion | Up                 | The final price conversion does not discard positive debt dust.    |

The variable-debt guarantees in this table do not extend to the stable debt token's own balance calculation. Stable debt is deprecated and is not an intended supported borrowing path, so updating its internal rounding would add complexity without providing useful protection for supported protocol operations. `StableDebtToken.balanceOf` therefore retains legacy half-up ray multiplication; `GenericLogic` still rounds up the final base-currency conversion of any aggregate variable-plus-legacy-stable debt amount.

## Resources

### Upstream references

- [Aave v3.5 feature document](https://github.com/aave-dao/aave-v3-origin/blob/main/docs/3.5/Aave-v3.5-features.md)
- [Aave v3.5.0 source](https://github.com/aave-dao/aave-v3-origin/tree/v3.5.0)
- [Aave v3.4.0 pre-change source](https://github.com/aave-dao/aave-v3-origin/tree/v3.4.0)
- [Aave v3.5 TokenMath](https://github.com/aave-dao/aave-v3-origin/blob/v3.5.0/src/contracts/protocol/libraries/helpers/TokenMath.sol)
- [Aave v3.5 WadRayMath](https://github.com/aave-dao/aave-v3-origin/blob/v3.5.0/src/contracts/protocol/libraries/math/WadRayMath.sol)
- Aave v3.5 token implementations: `AToken.sol`, `VariableDebtToken.sol`, `ScaledBalanceTokenBase.sol`, and `IncentivizedERC20.sol`
- Aave v3.5 protocol logic: `SupplyLogic.sol`, `BorrowLogic.sol`, `ValidationLogic.sol`, `GenericLogic.sol`, `ReserveLogic.sol`, and `LiquidationLogic.sol`
- [Aave v3.6.0 `VariableDebtToken`](https://github.com/aave-dao/aave-v3-origin/blob/v3.6.0/src/contracts/protocol/tokenization/VariableDebtToken.sol)
- [Aave v3.6.0 `DebtTokenBase`](https://github.com/aave-dao/aave-v3-origin/blob/v3.6.0/src/contracts/protocol/tokenization/base/DebtTokenBase.sol)
- [Aave v3.6 correction using the `onBehalfOf` balance](https://github.com/aave-dao/aave-v3-origin/commit/0e4bedf6)

### Relevant local files

- `contracts/protocol/libraries/math/WadRayMath.sol`
- `contracts/protocol/tokenization/base/IncentivizedERC20.sol`
- `contracts/protocol/tokenization/base/MintableScaledBalanceToken.sol` (introduced as `ScaledBalanceTokenBase` in the original PR, renamed in #20)
- `contracts/protocol/tokenization/base/DebtTokenBase.sol`
- `contracts/protocol/tokenization/AToken.sol`
- `contracts/protocol/tokenization/VariableDebtToken.sol`
- `contracts/protocol/libraries/logic/SupplyLogic.sol`
- `contracts/protocol/libraries/logic/GenericLogic.sol`
- `contracts/protocol/libraries/logic/LiquidationLogic.sol`
- `contracts/mocks/tests/WadRayMathWrapper.sol`
- `contracts/mocks/tests/MockATokenPool.sol`
- `contracts/mocks/tests/MockVariableDebtTokenPool.sol`
- `test-suites/wadraymath.spec.ts`
- `test-suites/atoken-allowance-rounding.spec.ts`
- `test-suites/variable-debt-token-allowance-rounding.spec.ts`
- `certora/specs/AToken.spec` and `certora/specs/VariableDebtToken.spec`, which still model the previous half-up rounding slack and require a separate formal-verification update

## Chosen Approach: Explicit Rounding With Corrected Transfer and Borrow Allowances

The chosen design represents the operation-specific mint and burn rounding context with an internal enum and passes it explicitly into the shared scaled-token accounting functions:

```solidity
enum RoundingMode {
  INACTIVE,
  ROUND_DOWN,
  ROUND_UP
}
```

Each mint or burn entry point selects the required direction before invoking shared accounting. The shared conversion function consumes that explicit mode and reverts if it receives `INACTIVE`.

Transfers do not accept a rounding mode because their direction does not vary: aToken transfers always round the scaled amount up with `rayDivCeil`. Variable debt tokens are non-transferable, so there is no valid transfer path that needs `ROUND_DOWN`. Encoding this invariant directly prevents a future caller from accidentally selecting an unsafe transfer direction.

The term _flag_ describes the operation-specific mint or burn direction, but the flag is passed as an internal function argument rather than stored in contract state. It is therefore short-lived, visible at each call site, and cannot remain active across an external call.

### Rationale

This approach was selected because it provides the required operation-specific rounding while keeping the patch narrow and compatible with the existing fork:

- It preserves the public Pool, aToken, and variable debt token function signatures.
- It does not add a state variable and therefore does not change upgradeable-token storage layouts.
- It avoids state set-and-clear gas costs on common mint and burn paths.
- It makes each rounding decision explicit at the call site, which improves auditability.
- It centralizes the conversion logic instead of duplicating separate up/down mint and burn helpers.
- It fails closed: a future shared mint or burn caller that supplies `INACTIVE` cannot silently fall back to half-up rounding.
- It hardcodes the single safe transfer direction, removing an unnecessary mode parameter and its misuse surface.
- It charges `transferFrom` allowance for the sender's actual indexed balance decrease whenever the allowance has sufficient headroom, preventing the rounding delta from recurring for free on every call.
- It charges delegated borrow allowance for the debt owner's actual indexed debt increase whenever the allowance has sufficient headroom, preventing a delegatee from obtaining the rounded increment for free on every borrow.
- It leaves existing half-up ray functions intact for unrelated protocol math, limiting behavioral change to the vulnerable boundaries.

A persistent storage flag was not used because storage added to `MintableScaledBalanceToken` could shift child-contract storage, while leaf-level flags would require hooks or duplicated state handling. Persistent state would also introduce extra gas and hidden mutable context. Transient storage was not used because the repository targets Solidity `0.8.10` and the London EVM, where it is unavailable without a broader compiler and deployment-target migration.

## Implementation Details

### Explicit floor and ceiling ray math

`contracts/protocol/libraries/math/WadRayMath.sol` adds four helpers:

- `rayMulFloor`;
- `rayMulCeil`;
- `rayDivFloor`;
- `rayDivCeil`.

The multiplication helpers compute `floor(a * b / RAY)` and `ceil(a * b / RAY)`. The division helpers compute `floor(a * RAY / b)` and `ceil(a * RAY / b)`. The ceiling variants add one only when the division has a non-zero remainder, so exact results are not over-rounded. The implementations and their overflow and division-by-zero guards are aligned with Aave v3.5.

The original half-up `rayMul` and `rayDiv` functions remain unchanged for protocol calculations outside the scope of this mitigation.

### Shared scaled-balance accounting

`contracts/protocol/tokenization/base/MintableScaledBalanceToken.sol` defines `RoundingMode` and adds `_getScaledAmount(rebasedAmount, index, roundingMode)`.

The shared mint and burn functions require a rounding mode:

- `_mintScaled(..., RoundingMode roundingMode)`;
- `_burnScaled(..., RoundingMode roundingMode)`.

`_getScaledAmount` selects `rayDivFloor` for `ROUND_DOWN`, selects `rayDivCeil` for `ROUND_UP`, and reverts with `Errors.INVALID_AMOUNT` for `INACTIVE`. The existing zero-scaled-amount checks remain in place and continue to use `INVALID_MINT_AMOUNT` or `INVALID_BURN_AMOUNT`.

The shared `_transfer(sender, recipient, amount, index)` helper does not accept a rounding mode or return a value. It always converts the transfer amount with `amount.rayDivCeil(index)`. `AToken` applies the same ceiling conversion when emitting `BalanceTransfer`. This matches Aave v3.5's transfer rule: at the same index, rounding scaled shares up ensures the recipient's indexed balance increases by at least the requested unscaled amount.

### aToken mapping

`contracts/protocol/tokenization/AToken.sol` applies the following directions:

- `mint`: `ROUND_DOWN`;
- `mintToTreasury`: `ROUND_DOWN`;
- `burn`: `ROUND_UP`;
- ordinary and liquidation transfers: direct `rayDivCeil` conversion.

The visible balance conversions were also changed:

- `balanceOf` uses `rayMulFloor`;
- `totalSupply` uses `rayMulFloor`;
- the pre-transfer balances sent to `Pool.finalizeTransfer` use `rayMulFloor`.

`BalanceTransfer` emits the scaled amount calculated with the same `rayDivCeil` conversion used by the shared transfer helper. The ordinary ERC-20 `Transfer` event and the amount passed to `Pool.finalizeTransfer` remain the caller-requested unscaled amount; the precise rounded share movement is exposed by `BalanceTransfer`. Together, these changes prevent supply from over-crediting a user and ensure that withdrawal or transfer consumes enough scaled balance for the requested asset amount.

### aToken transfer allowance alignment

Ceiling conversion can make the sender's displayed aToken balance decrease by more than the requested transfer amount. Previously, `transferFrom` consumed only the requested unscaled amount from the allowance, so a spender could repeatedly move more aTokens than the owner had approved.

Inspired by Aave v3.5, `AToken.transferFrom` now computes the sender-side unscaled `amountOut` from the sender's indexed balance before and after subtracting the ceiling-rounded scaled transfer:

```text
scaledAmount = ceil(amount * RAY / index)
amountOut = floor(senderScaledBalance * index / RAY)
          - floor((senderScaledBalance - scaledAmount) * index / RAY)
```

`AToken` passes both the requested `amount` and corrected `amountOut` to the Aave-inspired `_spendAllowance` helper. The helper first requires the current allowance to cover the requested amount. It then consumes `amountOut` when possible, capped at the current allowance.

For an ordinary transfer, `amountOut` is the sender's actual displayed-balance decrease. It is deliberately not derived from the recipient's displayed-balance increase (`amountIn`), which can differ because the sender and recipient can have different floor-rounding positions. A self-transfer still consumes the corrected sender-side allowance even though crediting the same account restores its net balance, consistent with ERC-20 `transferFrom` allowance semantics.

The cap matches Aave v3.5's compatibility behavior: if an owner approves exactly the requested amount, `transferFrom` still succeeds even when ceiling rounding makes `amountOut` larger. In that case the complete remaining allowance is consumed. The same cap applies when the remaining allowance is between `amount` and `amountOut`.

This compatibility rule means the absolute property “total balance moved can never exceed the nominal allowance” does not hold. If split transfers leave at least the requested `amount` but less than `amountOut` for the final call, that call can move the correction gap beyond the remaining allowance. The overrun is bounded to that final call because the allowance becomes zero; preceding calls with sufficient headroom consume their complete `amountOut`, and subsequent non-zero calls fail. The change therefore prevents one free rounding increment per split call while preserving exact-allowance compatibility. It adds no public function or storage variable and does not alter the upgradeable storage layout.

### Variable debt mapping

`contracts/protocol/tokenization/VariableDebtToken.sol` applies the opposite debt-safe directions:

- `mint`: `ROUND_UP`;
- `burn`: `ROUND_DOWN`;
- `balanceOf`: `rayMulCeil`;
- `totalSupply`: `rayMulCeil`.

Borrowing therefore records at least the requested debt, while repayment or liquidation cannot erase more scaled debt than the paid amount covers.

### Variable debt delegation allowance alignment

Rounding variable-debt minting up can make the debt recorded for `onBehalfOf` increase by more than the unscaled `amount` requested by the delegatee. Previously, `VariableDebtToken.mint` consumed only `amount` from the borrow allowance. A delegatee could therefore split borrowing into many rounding-sensitive calls and repeatedly receive a larger debt increase than the allowance consumed, potentially creating substantially more debt than the delegator approved.

The mitigation follows Aave v3.6 and computes the exact before-and-after displayed debt increase of the debt owner:

```text
scaledAmount = ceil(amount * RAY / index)
debtIncrease = ceil((ownerScaledBalance + scaledAmount) * index / RAY)
             - ceil(ownerScaledBalance * index / RAY)
```

The owner balance is `super.balanceOf(onBehalfOf)`, not `super.balanceOf(user)`. This distinction is security-relevant: `user` is the delegatee initiating the borrow, while `onBehalfOf` is the delegator whose scaled balance and debt phase actually change. It also incorporates the Aave v3.6 correction to the earlier implementation that read the wrong account's balance.

Because this fork's `VariableDebtToken.mint` ABI receives the unscaled `amount` rather than a precomputed scaled amount, it calculates `scaledAmount` internally with the same `rayDivCeil(index)` conversion used by `_mintScaled`. No Pool or public token interface was changed.

`VariableDebtToken` passes the requested `amount` and corrected `debtIncrease` to the four-argument `DebtTokenBase._decreaseBorrowAllowance` helper. The helper:

1. requires the current borrow allowance to cover the requested `amount`;
2. consumes `debtIncrease` when the allowance has sufficient headroom;
3. otherwise consumes the full remaining allowance, capping the corrected consumption at that allowance.

The existing three-argument helper remains as a wrapper that passes `amount` as both values because `StableDebtToken` still uses nominal allowance accounting. The local `BorrowAllowanceDelegated` event behavior is also retained.

As with Aave's aToken allowance correction, the cap deliberately preserves exact-request compatibility. If the allowance equals the requested `amount` but `debtIncrease` is larger because of rounding, the borrow succeeds and consumes the complete allowance. Consequently, the implementation does not establish the absolute property that recorded debt can never exceed nominal allowance. Instead, it prevents the correction from recurring for free: calls made while allowance headroom exists consume their actual debt increase, the boundary call consumes all remaining allowance, and later non-zero delegated borrows fail. Any nominal-allowance overrun is therefore limited to the rounding correction of the final successful call rather than accumulating across every split call.

### Maximum-withdraw alignment

`contracts/protocol/libraries/logic/SupplyLogic.sol` recomputes the withdraw-side user balance with `rayMulFloor`.

This keeps `withdraw(type(uint256).max)` aligned with the floor-rounded value returned by `AToken.balanceOf`. Without this alignment, the maximum-withdraw path could request an amount that makes the new ceiling burn attempt to consume one scaled unit more than the user owns.

### Account-data valuation

`contracts/protocol/libraries/logic/GenericLogic.sol` now applies risk-pessimistic rounding when calculating account data:

- scaled variable debt is converted to unscaled debt with `rayMulCeil`;
- the resulting variable debt is added to the stable debt token's reported balance;
- that aggregate debt amount is converted to base currency with ceiling division;
- scaled aToken collateral is converted to an unscaled balance with `rayMulFloor`;
- collateral-to-base-currency conversion remains floor division.

The private `_divCeil` helper returns zero for a zero numerator and otherwise implements `ceil(value / divisor)` without an addition that could overflow. With a positive asset price, any non-zero aggregate debt therefore contributes at least one base-currency unit. For variable debt and aToken collateral, health-factor calculations no longer understate debt or overstate collateral at these conversion boundaries. Any legacy stable debt can still inherit half-up error from `StableDebtToken.balanceOf`; changing that deprecated path is intentionally outside the mitigation.

### Liquidation protocol-fee alignment

`contracts/protocol/libraries/logic/LiquidationLogic.sol` converts the liquidation protocol fee to scaled units with `rayDivCeil`, matching the aToken liquidation transfer's `ROUND_UP` direction. If the required fee exceeds the user's remaining scaled collateral, the fallback unscaled fee is derived with `rayMulFloor`.

This prevents the fee pre-check from passing with a smaller half-up value and then reverting when the actual liquidation transfer rounds up by one scaled unit.

## Security Effect

The mitigation removes user-favoring half-up rounding from the affected scaled-accounting loop:

1. Supplying cannot mint excess aToken claim value.
2. Withdrawing or transferring cannot release value without consuming enough scaled aTokens.
3. Borrowing cannot record less variable debt than the value received.
4. Repayment cannot cancel more variable debt than the payment covers.
5. aToken collateral and variable-debt reads use the same pessimistic directions in account-data calculations.
6. The final aggregate-debt price conversion rounds up, preventing positive, positively priced debt dust from disappearing solely in that division.
7. `AToken.transferFrom` normally consumes the sender's actual indexed balance decrease, preventing the ceiling-rounding difference from being extracted for free on every call. The final call can retain Aave's bounded compatibility overrun when only the requested amount remains approved.
8. Delegated variable borrowing normally consumes the debt owner's actual indexed debt increase, preventing the delegatee from accumulating one free rounding correction per split borrow. The final call retains the same bounded compatibility behavior when only the requested amount remains approved.

The result is a protocol-favoring invariant at the changed aToken and variable-debt boundaries, while unrelated interest-index, flash-loan, bridge-fee, and general percentage math retain their existing behavior. It is not a complete backport of all Aave v3.5 or v3.6 precision, scaled-accounting, and validation changes.

## Scope Boundaries and Follow-up Work

- Stable debt is deprecated and is not an intended supported borrowing path. Its rounding was intentionally left unchanged because backporting new behavior into an obsolete path would add implementation and verification cost without improving the supported variable-debt flow. Any legacy stable debt remains subject to `StableDebtToken.balanceOf`'s half-up rounding; the ceiling base-currency division cannot correct an amount already rounded down by that calculation.
- Production public interfaces and Pool/token function signatures were not changed. As in Aave v3.5, the aToken ABI metadata now includes the inherited `ERC20InsufficientAllowance` custom error. Test-only helper contracts exercise the new math functions and deterministic reserve indices.
- No persistent or transient storage was added.
- Operation amounts still cross the existing production interfaces in unscaled units and are converted inside the tokens. The broader v3.5 change to pass scaled amounts through Pool validations and token calls was not backported.
- Delegated variable borrowing now corrects allowance consumption using the `onBehalfOf` debt owner's before-and-after indexed debt. The correction is intentionally capped at the current allowance, so an exact-request final borrow can still create the single-call rounding delta beyond the nominal remaining allowance. This is Aave's backward-compatible mitigation, not a strict post-mint debt-versus-allowance assertion.
- Post-action health-factor checks **were subsequently added** by the SC-1650 mitigation (PR #23, refactored in #24), superseding the original statement here that none were added: `BorrowLogic.executeBorrow` now calls `ValidationLogic.validateHealthFactor` unconditionally after the debt mint, and the `useATokens` branch of `executeRepay` calls it after the aToken and debt burns whenever the repaid asset is flagged as collateral. Both checks enforce the absolute `HEALTH_FACTOR_LIQUIDATION_THRESHOLD` (1.0), not a no-worse-than-before comparison. Two consequences of the absolute threshold are accepted by design: a user with a health factor below one cannot partially deleverage through `repayWithATokens` even when the repay raises the health factor (such users are expected to repay with the underlying or be liquidated), and the check gives `repayWithATokens` a price-oracle dependency for every asset in the user's configuration.
- Legacy `Mint`, `Burn`, and ERC-20 `Transfer` event values remain based on requested amounts and accrued interest rather than being recomputed from exact before/after indexed balances. `BalanceTransfer` is the exception and now reports the exact ceiling-rounded scaled transfer amount.
- Withdraw, transfer, and liquidation collateral-flag updates still compare the requested unscaled amount with the floor-rounded pre-operation balance. A ceiling-rounded burn or transfer can consume the entire scaled balance even when a near-full explicit amount is slightly smaller than that displayed balance, so the legacy equality check can leave the collateral flag set with a zero scaled balance ("ghost flag"). The `useATokens` branch of `executeRepay` was later fixed to clear the flag from the post-burn scaled balance (PR #27/#29), and the disable path of `setUserUseReserveAsCollateral` no longer requires a nonzero balance, so an affected user can clear the flag manually; the withdraw, `finalizeTransfer`, and liquidation sites intentionally keep the legacy check. This is an acknowledged finding (Certora L-02) — see Known Issues and Accepted Risks below for its downstream consequences.
- The final `mintToTreasury` unscaled-to-scaled conversion now rounds down, but reserve-side treasury-accrual calculations were not changed. A later follow-up added a guard in `PoolLogic.executeMintToTreasury` that skips a reserve (keeping its accrual) when the floor conversion would mint zero scaled units. The remaining half-up-to-floor round trip can still credit the treasury one scaled unit less than the `accruedToTreasury` value it zeroes; this reconciliation loss is bounded at one scaled unit per call and is accepted as negligible. Broader cap, interest-index, flash-loan, bridge-fee, and percentage math was also intentionally left outside this patch.
- Existing Certora specifications and harness assumptions were not updated: `certora/specs/AToken.spec` and `certora/specs/VariableDebtToken.spec` still model the legacy half-up (`+ HALF_RAY`) arithmetic, so their verification results do not apply to the shipped floor/ceiling code. Until they are revised to assert the new exact floor/ceiling properties, these specifications must be treated as stale and must not be cited as evidence about the current implementation.
- Added tests validate the four math helpers, the aToken allowance cases, and delegated variable-debt allowance accounting. The variable-debt suite covers allowance consumption by actual debt increase, the `onBehalfOf` versus delegatee balance distinction, an existing owner balance phase, repeated split borrows, exact-request compatibility, exact conversions, and insufficient allowance. The focused suite passes 7 tests, and the combined variable- and stable-debt-token test run passes 37 tests. Broader integration properties should still cover supply/withdraw, transfer, borrow/repay, account-data valuation, and liquidation-fee boundaries. In particular, maximum and near-maximum aToken burns/transfers should assert both scaled-balance clearing and collateral-flag behavior.

## Known Issues and Accepted Risks

This section is the acknowledged-findings reference for external review. Each item has been analyzed and either accepted or scoped out; none is an unknown. Reviewers who reach these are confirming known ground.

**Out of deployment scope**

- **`StableDebtToken` will not be upgraded.** Its source changed in this branch (balance-read plumbing, `_decreaseBorrowAllowance` moved in), but `DEBT_TOKEN_REVISION` remains `0x1` and no `updateStableDebtToken` call is planned. Live proxies keep the deployed v1.0.0 stable-debt implementation; the modified source in this repository does not ship and is out of scope for the release. (If a stable-debt upgrade is ever planned, the revision must be bumped first — `VersionedInitializable` rejects a revision that does not increase.)

**Acknowledged — ghost collateral flag family (Certora L-02 and consequences)**

- A near-full withdraw, aToken transfer, or liquidation can burn the entire scaled balance while the rebased-equality flag check keeps `isUsingAsCollateral` set on a zero balance. The liquidation variant is third-party-triggerable via the liquidator's choice of `debtToCover`. The state is operational, self-clearable via `setUserUseReserveAsCollateral(asset, false)`, and known to exist for a handful of wallets under the pre-change code as well.
- Downstream consequences, accepted with the flag itself: a stale bit on an asset later moved to LTV 0 sets `hasZeroLtvCollateral` for a zero balance; a stale bit plus a real collateral bit defeats the single-bit isolation-mode detection if a debt ceiling is later set; a stale bit survives `executeDropReserve` (which checks only token supplies), becomes unclearable on the inactive reserve, and re-binds to the next asset listed at the reused id by `executeInitReserve`. Governance mitigations for the last two are listed under Deployment Constraints.
- A full-collateral, partial-debt liquidation of an isolated position clears the isolation flag while debt remains, so later repays no longer decrement `isolationModeTotalDebt`; the stranded amount consumes debt-ceiling capacity until governance zeroes the ceiling and calls `resetIsolationModeTotalDebt`.

**Accepted — rounding residue and validation/execution boundaries**

- `executeMintToTreasury` reconciliation loss of at most one scaled unit per call (see Scope Boundaries above): accepted as negligible.
- The absolute post-action health-factor threshold on `executeBorrow` and the `useATokens` repay branch (see Scope Boundaries above): accepted; an underwater holder of collateral aTokens repaying that same asset is considered an edge case, and the underlying-repay path remains open.
- Dust operations that pass validation and revert in the token (`INVALID_MINT_AMOUNT` / `INVALID_BURN_AMOUNT`): supply, repay, or liquidation amounts below one scaled unit revert; the caller retries with a larger amount. Dust positions below one scaled unit of debt resist liquidation until interest grows them.
- Allowance over-consumption: `AToken._spendAllowance` and `VariableDebtToken._decreaseBorrowAllowance` charge the actual indexed balance change, which can exceed the nominal amount by up to one scaled unit per call, capped at the allowance. Proven bounded and never under-consuming; exact-total integrators must approve with headroom.
- `transferOnLiquidation` (ROUND_DOWN, no zero-scaled guard) can move zero shares for a dust value while events report the rebased amount; a liquidator receiving zero shares can still gain the collateral flag; a full aToken-path liquidation can clear the flag with one scaled unit left. All dust-bounded.
- Stable-debt paths (half-up `balanceOf` inside the health factor, `burn` supply-zeroing branches returning a stale `nextSupply`): stable borrowing is deprecated and disabled on all SparkLend markets; these paths are dormant and intentionally unchanged.
- `supplyWithPermit` / `repayWithPermit` do not wrap the `permit` call in try/catch, so a front-run signature replay reverts the transaction (Aave v3.0.2 pattern not backported); the caller resubmits with a plain approve.
- `Pool.supply` accepts `onBehalfOf = address(0)`, minting unburnable aTokens that keep `totalSupply` above zero and block a later `dropReserve`; grief-only, joins the other `dropReserve` preconditions tracked under Deployment Constraints.
- Isolation-mode debt-ceiling accounting truncates to `DEBT_CEILING_DECIMALS` (2) on both the borrow increment and the repay decrement, so sub-0.01-token amounts do not move the counter; and the `10 ** (decimals - 2)` normalization underflows for assets with fewer than 2 decimals, which makes repay and liquidation revert for isolated users of such an asset. Both are inherited from upstream Aave v3 and gated on listing decisions (see Deployment Constraints).
- Certora acknowledgements I-01 through I-04 from the "SparkLend Rounding Mitigation" report (borrow-cap rounding dust; legacy half-up math outside the mint/burn boundary; flash-loan premium index inflation, inert while `FLASHLOAN_PREMIUM_TOTAL` is 0; supply-then-withdraw-same-amount round-trip reverts for integrators that reuse the exact opening amount).

## Deployment Constraints

Operational requirements for the upgrade spell and for later governance actions. These are not code changes; they must be enforced in the spell and in listing/offboarding checklists.

1. **Atomic upgrade, Pool together with every token implementation, in one transaction.** `executeWithdraw` computes `userBalance` in Pool code (`rayMulFloor` at this branch) while the burn rounds in the aToken (`rayDivCeil`). A window with new aTokens and the old Pool makes `withdraw(max)` revert for roughly half of all holders at live indices; the reverse window mixes half-up and directed rounding in one flow. Pool-first or fully atomic is safe; aTokens-before-Pool is not. Do not stage the upgrade across transactions.
2. **Per-reserve `initialize` parameters must be sourced per token, not from a uniform constant.** `ConfiguratorLogic._upgradeTokenImplementation` always re-runs `initialize`, overwriting treasury, incentives-controller, name/symbol/decimals and underlying parameters with no equality check. The spDAI treasury address differs from the other reserves' treasury; a spell that passes one uniform treasury constant silently redirects spDAI revenue. Read each proxy's current parameters and pass them back explicitly.
3. **Reserve offboarding pre-flight.** `dropReserve` requires zero aToken and debt supplies and zero `accruedToTreasury`; known blockers are treasury accrual stuck at one scaled unit (skip-guard), dust shares left by aToken-path liquidations, and aTokens minted to `address(0)`. Before any drop, and before listing a new asset into a vacated id, enumerate stale collateral bits from `ReserveUsedAsCollateralEnabled` events — user bitmap flags survive a drop and re-bind to the reused id.
4. **Listing checklist.** Never list an asset with fewer than 2 decimals (isolation-mode normalization underflow bricks repay/liquidation for isolated users) and treat low-decimal assets as high-risk for the dust-revert family. Never set an eMode category `priceSource` (shared-price misvaluation, and `setUserEMode` skips the health-factor check on a 0-to-category transition). Keep `FLASHLOAN_PREMIUM_TOTAL` at 0 unless the liquidity-index inflation acknowledgement (Certora I-03) is revisited.
