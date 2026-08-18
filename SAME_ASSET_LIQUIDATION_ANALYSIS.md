# Same-Asset Liquidation Issue Analysis

## 1. Understanding the Issue

The invariant violation originally demonstrated by `test_sameAssetLiquidationLeak` (in https://github.com/sparkdotfi/sparklend-testing) was a subtle rate mispricing bug that occurred specifically when a user's `debtAsset` and `collateralAsset` were the **exact same reserve**, and the liquidator chose to receive the underlying asset (`receiveAToken == false`).

To understand why this happened, we can trace the original execution flow of `executeLiquidationCall` in `LiquidationLogic.sol`:

1. **Debt Repayment Rate Update (Line 171):**
   First, the protocol updated the rates for the `debtReserve`. It called `debtReserve.updateInterestRates` with `liquidityAdded = actualDebtToLiquidate` and `liquidityTaken = 0`. This correctly calculated the new interest rates based on the assumption that the debt would be repaid, adding to the total available liquidity of the reserve.

2. **Collateral Withdrawal Rate Update (Line 258):**
   Later, because `receiveAToken == false`, the protocol called `_burnCollateralATokens` to burn the user's collateral and send the underlying to the liquidator. Inside this function, it called `collateralReserve.updateInterestRates` with `liquidityAdded = 0` and `liquidityTaken = actualCollateralToLiquidate`.

**The Bug:**
Because `debtAsset` and `collateralAsset` were the same asset, `debtReserve` and `collateralReserve` were the **exact same reserve**.
The second call to `updateInterestRates` in `_burnCollateralATokens` calculated the new rates based on `totalLiquidity = aToken.balanceOf() + liquidityAdded - liquidityTaken`.
Since the liquidator hadn't transferred the debt repayment yet (this happened at the end of the function on line 220), `aToken.balanceOf()` did not include the repaid debt. By passing `liquidityAdded = 0` into the second `updateInterestRates` call, the protocol completely "forgot" about the `actualDebtToLiquidate` that was factored into the first call.

As a result, the final stored interest rates incorrectly assumed that the reserve had less liquidity than it actually did. This led to a continuously accruing inflated supply rate compared to the true utilization of the pool, minting unbacked claims over time until the next action on the reserve corrected the rates.

## 2. Confirmation of the Mitigation

The mitigation passes `actualDebtToLiquidate` as `liquidityAdded` to the second `updateInterestRates` call when the assets match.

`_burnCollateralATokens` in `LiquidationLogic.sol` was updated as follows:

```solidity
    collateralReserve.updateInterestRates(
      collateralReserveCache,
      params.collateralAsset,
      params.collateralAsset == params.debtAsset ? vars.actualDebtToLiquidate : 0,
      vars.actualCollateralToLiquidate
    );
```

Originally, `test_sameAssetLiquidationLeak` existed to demonstrate the issue and asserted that a shortfall accrued. After applying the fix, the test was converted into a regression test, `test_sameAssetLiquidation_doesNotLeak`, asserting that no shortfall occurs (`assertEq(unbacked, 0, "mispricing accrued a shortfall")`).

Running `forge test --mt test_sameAssetLiquidation_doesNotLeak` passes successfully:

```
[PASS] test_sameAssetLiquidation_doesNotLeak()
```

This confirms that unbacked claims remain at exactly `0` after 30 days of simulated time, proving that the mispricing was entirely eliminated and the fix successfully resolves the problem.

## 3. Investigation of Potential Side Effects

The investigated mitigation for potential side effects and edge cases:

- **Double counting of `actualDebtToLiquidate`?**
  No double counting occurs. The first call to `updateInterestRates` writes a rate to storage, but the second call recalculates the rate from scratch using the current `aToken.balanceOf()`. Since no underlying transfers occur between the two calls, `aToken.balanceOf()` is the same for both. The second calculation uses `aToken.balanceOf() + actualDebtToLiquidate - actualCollateralToLiquidate`, which perfectly reflects the true final liquidity of the transaction.
- **Double Index Accrual?**
  No. Both `updateInterestRates` calls happen in the exact same transaction (same block timestamp). The `updateState` function specifically prevents accruing indices twice in the same block (`if (lastUpdateTimestamp == uint40(block.timestamp)) return;`).
- **Different Assets (collateralAsset != debtAsset)?**
  If the assets differ, the condition `params.collateralAsset == params.debtAsset` is false, and `liquidityAdded` defaults back to `0`. This is perfectly correct because the collateral reserve is completely independent of the debt reserve and should only be impacted by the collateral withdrawal.
- **Liquidator Receives aTokens (`receiveAToken == true`)?**
  If `receiveAToken` is true, the `_burnCollateralATokens` function is never called (it branches to `_liquidateATokens` instead, which only transfers aTokens without touching underlying liquidity rates). Therefore, the mitigation does not affect this path, which is already correct.
- **Event Emission:**
  The only side effect is that `ReserveDataUpdated` will be emitted twice for the same reserve in the same transaction. This is completely harmless and functions identically to a transaction that performs two sequential actions on the same reserve.

**Conclusion:** The mitigation is completely safe, effectively resolves the invariant violation, and introduces no negative side effects.
