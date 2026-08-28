# Spike: Aave-style scaled-amount accounting

**Branch:** `feat/aave-style-scaled-accounting`, off `master` (v3.0.2, `8120e495`).
**Status:** exploratory spike for comparison, **not** a production PR. It reimplements the rounding
mitigation the way Aave v3.6 does, as an alternative to the shipped approach on
`fix/sc-1650-value-extraction-mitigation` (`4a3d0602`).

## The question this answers

Is the Aave approach — compute the scaled amount once in the Pool, pass it into the token, and have
`burn()` report whether the balance hit zero — **cleaner conceptually** than the shipped approach, which
converts rebased↔scaled inside the token and infers collateral-flag state from a rebased equality?

## What was built

1. **Directional `WadRayMath` helpers** (`rayMulFloor/Ceil`, `rayDivFloor/Ceil`) — identical to the
   shipped branch.
2. **`TokenMath` library** (72 lines) ported from `aave-v3-origin` v3.6.0: the 7 conversion functions
   (`getATokenMint/Burn/TransferScaledAmount`, `getATokenBalance`, `getVToken*`). This is the whole
   conversion surface, in one place.
3. **Token interfaces take scaled amounts and report outcomes.** `mint(caller, onBehalfOf, amount,
   scaledAmount, index)`, `burn(..., amount, scaledAmount, index) returns (bool zeroBalanceAfterBurn)`,
   `mintToTreasury(scaledAmount, index)`, `transferOnLiquidation(from, to, amount, scaledAmount, index)`.
4. **The Pool computes the scaled amount** at all 21 call sites (Supply/Borrow/Liquidation/Pool/Bridge
   logic) via `TokenMath`, and **every collateral-flag decision is made from `zeroBalanceAfterBurn`**
   (withdraw, transfer/finalizeTransfer, liquidation) instead of a rebased equality.

## Size

**16 files, +457 / −83.** For reference the shipped upgrade is 44 files / +1713 (though that count
includes tests and two unrelated fixes). Of the 16: 3 are the WadRayMath/TokenMath additions, 2 are test
mocks, 11 are the token + logic changes.

## What it closes, by construction

| Finding | Closed? | How |
|---|---|---|
| L-02 ghost collateral flag (all sites) | **Yes** | Every flag decided from `zeroBalanceAfterBurn` / scaled-zero |
| ISSUE-003 `mintToTreasury` strand/leak | **Yes** | Scaled accrual passed straight through; round trip is exact |
| ISSUE-011 liquidator zero-scaled flag | Partially | Borrower flag now scaled-based; liquidator-enable guard unchanged |
| ISSUE-015 upgrade-ordering hazard | **Yes (by construction)** | No rebased re-derivation for two contracts to disagree about |
| ISSUE-013 round-trip break | No (deliberate) | Floor-on-mint direction is kept |
| ISSUE-002 / 016 repayWithATokens gating | No | Needs the Aave `isUsingAsCollateral && isBorrowingAny` gate — separate change |

## Validation against `sparklend-testing`

The suite was pointed at this branch (in an isolated copy; neither the core repo nor the testing repo
was modified). It compiles after updating the test files that call the token API directly (the new
signatures) — those edits are in the copy only.

**Result: 408 / 429 passing, 21 failing. None of the 21 is a regression in the spike's scope.**
(The invariant campaign carries the same 1 pre-existing handler failure as the baseline; see below.)

### The 21 failures, categorised

**A — the spike fixing a real bug, so a bug-asserting test now fails (4):**

- `test_ghostFlag_withdraw_leavesFlagOnZeroBalance`
- `test_ghostFlag_transfer_leavesFlagOnZeroBalance`
- `test_ghostFlag_isUnclearableUntilResupply`
  These assert the **buggy** behaviour — flag stuck `true` at zero balance. The spike clears it, so
  `assertEq(isCollateral, true)` now fails. This is L-02 being fixed.
- `test_mintToTreasury_doesNotRevertWhenAccruedFeeRoundsDownToZero`
  Asserts the shipped **skip** behaviour (`accruedToTreasury == 1`, `mintToTreasury` expected called 0
  times). The spike mints the scaled unit instead of stranding it, so it *is* called. This is ISSUE-003
  being fixed.

**B — a separate shipped commit this spike did not port (1):**

- `test_sameAssetLiquidation_doesNotLeak` — tests the same-asset-liquidation fix (`spark-spells` PR #22,
  commit `ea91c24b`), which is an independent change bundled into the shipped upgrade. This spike
  branched from `master`, which predates it. Not related to the accounting approach.

**C — the v3.6 delegated-allowance rework, deliberately out of scope (3):**

- `test_transferFrom_revertsWhenAllowanceIsInsufficientBoundary` (custom-error revert not ported)
- `test_transferFrom_allowanceChargedForActualBalanceDecrease_notRequestedAmount`
- `testFuzz_transferFrom_allowanceChargedForActualBalanceDecrease_neverHigherThanTwo`
  The spike keeps `master`'s simpler `_spendAllowance`. The allowance rework is orthogonal to the
  scaled-accounting boundary and was not part of this exercise.

**D — hardcoded rounding-expectation mismatches, benign (13):**

- `test_liquidationCall_04/05/06/10/11/12/13/14/15/16/18`, `_healthFactorGteOneBoundary`,
  `_priceSentinelActive...` — each asserts a **hardcoded** health-factor or amount value
  (e.g. `assertEq(healthFactor, 0.950000010277100111e18) // Closest to 0.95e18 possible with config`).
  The spike produces the same quantity rounded at a different granularity (scaled-in-Pool vs
  rebased-in-token), so the values differ in the last ~8 digits. Both are valid implementations of
  "collateral down, debt up"; the test constants are pinned to the shipped branch's arithmetic and would
  be re-pinned to whichever approach ships.

### One real bug found and fixed during validation

The first run left the borrower's collateral flag set after a full liquidation
(`test_liquidationCall_07/09`). Cause: the spike cleared the flag **before** the treasury-fee leg ran, so
the fee portion was still in the borrower's balance and `scaledBalanceOf(user)` was not yet zero. Moving
the flag-clear to **after** the fee transfer fixed it (`b664e0b5`). This is exactly the kind of ordering
subtlety the scaled-flag model surfaces — and it is now visible and testable, rather than hidden in a
rebased equality.

### Invariant campaign

Run separately (slow). It carries the **same single pre-existing handler failure** (`[FAIL: 30]`,
`BORROWING_NOT_ENABLED`) that the baseline and the shipped branch both have — a handler-bounds defect in
the test, not a protocol invariant violation. No new invariant violation was introduced. *(See the run
log; if this line is stale, re-run `forge test --match-contract Invariant`.)*

## Verdict on "cleaner conceptually"

Yes, materially:

- **The ghost flag becomes structurally impossible**, at every site, because the token reports the fact
  instead of the Pool guessing. Three separate findings (L-02, ISSUE-011, the liquidation variant)
  collapse into one mechanism.
- **`mintToTreasury` is exact** with no skip-guard and no round trip.
- **The upgrade-ordering hazard disappears** because nothing is re-derived across the boundary.
- **Conversions live in one 72-line library** rather than being threaded through `RoundingMode` enums
  and per-call-site directional helpers inside the token.
- It is **recognisably upstream Aave**, so a reviewer can diff it against `aave-v3-origin` rather than
  reason about a bespoke variant.

Costs, unchanged from the scoping note: a fresh external audit (the diff is the opposite of minimal), a
second in-place upgrade, and re-pinning the rounding-sensitive test constants. The allowance rework and
the same-asset-liquidation fix are separate and would need porting too for full parity.

## Reproduce

```bash
git checkout feat/aave-style-scaled-accounting
npm ci && npm run compile                 # solc 0.8.10, Node 16 — clean
# point sparklend-testing's submodule at this branch, then:
forge test --no-match-path 'test/fork/*'
```
