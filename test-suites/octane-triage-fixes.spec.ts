import { expect } from 'chai';
import { BigNumber, utils } from 'ethers';
import { ethers, getChainId } from 'hardhat';
import { evmRevert, evmSnapshot, increaseTime, waitForTx } from '@aave/deploy-v3';
import { MAX_UINT_AMOUNT, RAY } from '../helpers/constants';
import { buildPermitParams, getSignatureFromTypedData } from '../helpers/contracts-helpers';
import { RateMode } from '../helpers/types';
import { getTestWallets } from './helpers/utils/wallets';
import { makeSuite, TestEnv } from './helpers/make-suite';
import './helpers/utils/wadraymath';

const ray = BigNumber.from(RAY);

/**
 * Grows the DAI liquidity index above 1.0 and then removes all DAI debt, so that the index
 * stays constant across the following blocks (the liquidity rate is zero with no debt).
 */
const growAndFreezeDaiIndex = async (testEnv: TestEnv) => {
  const {
    pool,
    dai,
    weth,
    users: [depositor, borrower],
  } = testEnv;

  const daiLiquidity = utils.parseEther('10000');
  await waitForTx(await dai.connect(depositor.signer)['mint(uint256)'](daiLiquidity));
  await waitForTx(await dai.connect(depositor.signer).approve(pool.address, MAX_UINT_AMOUNT));
  await waitForTx(
    await pool.connect(depositor.signer).supply(dai.address, daiLiquidity, depositor.address, 0)
  );

  const wethCollateral = utils.parseEther('100');
  await waitForTx(await weth.connect(borrower.signer)['mint(uint256)'](wethCollateral));
  await waitForTx(await weth.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
  await waitForTx(
    await pool.connect(borrower.signer).supply(weth.address, wethCollateral, borrower.address, 0)
  );
  await waitForTx(
    await pool
      .connect(borrower.signer)
      .borrow(dai.address, utils.parseEther('8000'), RateMode.Variable, 0, borrower.address)
  );

  await increaseTime(365 * 24 * 60 * 60);

  await waitForTx(await dai.connect(borrower.signer)['mint(uint256)'](utils.parseEther('10000')));
  await waitForTx(await dai.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
  await waitForTx(
    await pool
      .connect(borrower.signer)
      .repay(dai.address, MAX_UINT_AMOUNT, RateMode.Variable, borrower.address)
  );

  const index = await pool.getReserveNormalizedIncome(dai.address);
  expect(index).to.be.gt(ray);
  return index;
};

/**
 * Finds a scaled balance `b` such that withdrawing / transferring `floor(b * index) - 1` rebased
 * units rounds the scaled amount up to exactly `b`, zeroing the scaled balance while the rebased
 * amount is strictly below the rebased balance. Returns the supply amount producing `b` and the
 * rebased amount to move.
 */
const findGhostFlagAmounts = (index: BigNumber) => {
  let scaled = utils.parseEther('1');
  for (let i = 0; i < 10000; i++) {
    const rebasedBalance = scaled.mul(index).div(ray);
    const amount = rebasedBalance.sub(1);
    const scaledConsumed = amount.mul(ray).add(index).sub(1).div(index); // ceil(amount / index)
    if (scaledConsumed.eq(scaled)) {
      // ceil(scaled * index / RAY) mints exactly `scaled` scaled units (mint rounds down).
      const supplyAmount = scaled.mul(index).add(ray).sub(1).div(ray);
      return { scaled, supplyAmount, amount, rebasedBalance };
    }
    scaled = scaled.add(1);
  }
  throw new Error('no ghost-flag amount found');
};

makeSuite('Octane triage fixes', (testEnv: TestEnv) => {
  let snapshot: string;

  beforeEach(async () => {
    snapshot = await evmSnapshot();
  });

  afterEach(async () => {
    await evmRevert(snapshot);
  });

  describe('permit front-running (issue 1)', () => {
    it('supplyWithPermit succeeds when the permit was already consumed by a third party', async () => {
      const {
        pool,
        dai,
        aDai,
        deployer,
        users: [, , attacker],
      } = testEnv;

      const chainId = Number(await getChainId());
      const nonce = await dai.nonces(deployer.address);
      const amount = utils.parseEther('100');
      const highDeadline = '3000000000';
      const userPrivateKey = getTestWallets()[0].secretKey;

      const msgParams = buildPermitParams(
        chainId,
        dai.address,
        '1',
        await dai.symbol(),
        deployer.address,
        pool.address,
        nonce.toNumber(),
        highDeadline,
        amount.toString()
      );
      const { v, r, s } = getSignatureFromTypedData(userPrivateKey, msgParams);

      await waitForTx(await dai.connect(deployer.signer)['mint(uint256)'](amount));

      // Front-run: the attacker submits the same signature directly to the token.
      await waitForTx(
        await dai
          .connect(attacker.signer)
          .permit(deployer.address, pool.address, amount, highDeadline, v, r, s)
      );
      expect(await dai.nonces(deployer.address)).to.eq(nonce.add(1));
      expect(await dai.allowance(deployer.address, pool.address)).to.eq(amount);

      await expect(
        pool
          .connect(deployer.signer)
          .supplyWithPermit(dai.address, amount, deployer.address, 0, highDeadline, v, r, s)
      )
        .to.emit(pool, 'Supply')
        .withArgs(dai.address, deployer.address, deployer.address, amount, 0);

      expect(await aDai.balanceOf(deployer.address)).to.eq(amount);
    });

    it('repayWithPermit succeeds when the permit was already consumed by a third party', async () => {
      const {
        pool,
        dai,
        usdc,
        helpersContract,
        deployer,
        users: [depositor, , attacker],
      } = testEnv;

      // USDC liquidity to borrow from.
      const usdcLiquidity = utils.parseUnits('10000', 6);
      await waitForTx(await usdc.connect(depositor.signer)['mint(uint256)'](usdcLiquidity));
      await waitForTx(await usdc.connect(depositor.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool
          .connect(depositor.signer)
          .supply(usdc.address, usdcLiquidity, depositor.address, 0)
      );

      // Deployer supplies DAI as collateral and borrows USDC.
      const daiCollateral = utils.parseEther('10000');
      await waitForTx(await dai.connect(deployer.signer)['mint(uint256)'](daiCollateral));
      await waitForTx(await dai.connect(deployer.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(deployer.signer).supply(dai.address, daiCollateral, deployer.address, 0)
      );
      const borrowed = utils.parseUnits('100', 6);
      await waitForTx(
        await pool
          .connect(deployer.signer)
          .borrow(usdc.address, borrowed, RateMode.Variable, 0, deployer.address)
      );

      const chainId = Number(await getChainId());
      const nonce = await usdc.nonces(deployer.address);
      const highDeadline = '3000000000';
      const userPrivateKey = getTestWallets()[0].secretKey;

      const msgParams = buildPermitParams(
        chainId,
        usdc.address,
        '1',
        await usdc.symbol(),
        deployer.address,
        pool.address,
        nonce.toNumber(),
        highDeadline,
        MAX_UINT_AMOUNT
      );
      const { v, r, s } = getSignatureFromTypedData(userPrivateKey, msgParams);

      await waitForTx(await usdc.connect(deployer.signer)['mint(uint256)'](borrowed.mul(2)));

      // Front-run: the attacker submits the same signature directly to the token.
      await waitForTx(
        await usdc
          .connect(attacker.signer)
          .permit(deployer.address, pool.address, MAX_UINT_AMOUNT, highDeadline, v, r, s)
      );
      expect(await usdc.nonces(deployer.address)).to.eq(nonce.add(1));

      await expect(
        pool
          .connect(deployer.signer)
          .repayWithPermit(
            usdc.address,
            MAX_UINT_AMOUNT,
            RateMode.Variable,
            deployer.address,
            highDeadline,
            v,
            r,
            s
          )
      ).to.emit(pool, 'Repay');

      expect(
        (await helpersContract.getUserReserveData(usdc.address, deployer.address))
          .currentVariableDebt
      ).to.eq(0);
    });
  });

  describe('withdraw to the aToken address (issue 19)', () => {
    it('does not account the withdrawn amount as liquidity taken when the recipient is the aToken', async () => {
      const {
        pool,
        dai,
        aDai,
        weth,
        users: [depositor, borrower],
      } = testEnv;

      const daiLiquidity = utils.parseEther('10000');
      await waitForTx(await dai.connect(depositor.signer)['mint(uint256)'](daiLiquidity));
      await waitForTx(await dai.connect(depositor.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(depositor.signer).supply(dai.address, daiLiquidity, depositor.address, 0)
      );

      const wethCollateral = utils.parseEther('100');
      await waitForTx(await weth.connect(borrower.signer)['mint(uint256)'](wethCollateral));
      await waitForTx(await weth.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool
          .connect(borrower.signer)
          .supply(weth.address, wethCollateral, borrower.address, 0)
      );
      await waitForTx(
        await pool
          .connect(borrower.signer)
          .borrow(dai.address, utils.parseEther('5000'), RateMode.Variable, 0, borrower.address)
      );

      const withdrawAmount = utils.parseEther('4000');
      const rateBefore = (await pool.getReserveData(dai.address)).currentVariableBorrowRate;

      // Control: a regular withdrawal to the depositor spikes utilization (and thus the rate).
      const controlSnapshot = await evmSnapshot();
      await waitForTx(
        await pool
          .connect(depositor.signer)
          .withdraw(dai.address, withdrawAmount, depositor.address)
      );
      const rateWithLiquidityTaken = (await pool.getReserveData(dai.address))
        .currentVariableBorrowRate;
      await evmRevert(controlSnapshot);
      expect(rateWithLiquidityTaken).to.be.gt(rateBefore);

      // Withdrawal to the aToken: no underlying leaves the reserve.
      const aTokenUnderlyingBefore = await dai.balanceOf(aDai.address);
      const depositorScaledBefore = await aDai.scaledBalanceOf(depositor.address);
      await waitForTx(
        await pool.connect(depositor.signer).withdraw(dai.address, withdrawAmount, aDai.address)
      );
      const rateAfter = (await pool.getReserveData(dai.address)).currentVariableBorrowRate;

      expect(await dai.balanceOf(aDai.address)).to.eq(aTokenUnderlyingBefore);
      expect(await aDai.scaledBalanceOf(depositor.address)).to.be.lt(depositorScaledBefore);
      expect(rateAfter).to.be.lt(rateWithLiquidityTaken);
      // Only one block of interest accrual separates the two rates.
      expect(rateAfter).to.be.closeTo(rateBefore, rateBefore.div(1000));
    });
  });

  describe('collateral flag cleared on zero scaled balance (issues 6 and 26)', () => {
    it('withdraw that zeroes the scaled balance below the rebased balance clears the flag', async () => {
      const {
        pool,
        dai,
        aDai,
        helpersContract,
        users: [, , user],
      } = testEnv;

      const index = await growAndFreezeDaiIndex(testEnv);
      const { scaled, supplyAmount, amount, rebasedBalance } = findGhostFlagAmounts(index);

      await waitForTx(await dai.connect(user.signer)['mint(uint256)'](supplyAmount));
      await waitForTx(await dai.connect(user.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(user.signer).supply(dai.address, supplyAmount, user.address, 0)
      );

      expect(await pool.getReserveNormalizedIncome(dai.address)).to.eq(index);
      expect(await aDai.scaledBalanceOf(user.address)).to.eq(scaled);
      expect(await aDai.balanceOf(user.address)).to.eq(rebasedBalance);
      expect(amount).to.be.lt(rebasedBalance);
      expect(
        (await helpersContract.getUserReserveData(dai.address, user.address))
          .usageAsCollateralEnabled
      ).to.be.true;

      await expect(pool.connect(user.signer).withdraw(dai.address, amount, user.address))
        .to.emit(pool, 'ReserveUsedAsCollateralDisabled')
        .withArgs(dai.address, user.address);

      expect(await aDai.scaledBalanceOf(user.address)).to.eq(0);
      expect(
        (await helpersContract.getUserReserveData(dai.address, user.address))
          .usageAsCollateralEnabled
      ).to.be.false;
    });

    it('transfer that zeroes the scaled balance below the rebased balance clears the flag', async () => {
      const {
        pool,
        dai,
        aDai,
        helpersContract,
        users: [, , user, recipient],
      } = testEnv;

      const index = await growAndFreezeDaiIndex(testEnv);
      const { scaled, supplyAmount, amount, rebasedBalance } = findGhostFlagAmounts(index);

      await waitForTx(await dai.connect(user.signer)['mint(uint256)'](supplyAmount));
      await waitForTx(await dai.connect(user.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(user.signer).supply(dai.address, supplyAmount, user.address, 0)
      );

      expect(await aDai.scaledBalanceOf(user.address)).to.eq(scaled);
      expect(amount).to.be.lt(rebasedBalance);

      await expect(aDai.connect(user.signer).transfer(recipient.address, amount))
        .to.emit(pool, 'ReserveUsedAsCollateralDisabled')
        .withArgs(dai.address, user.address);

      expect(await aDai.scaledBalanceOf(user.address)).to.eq(0);
      expect(
        (await helpersContract.getUserReserveData(dai.address, user.address))
          .usageAsCollateralEnabled
      ).to.be.false;
      expect(
        (await helpersContract.getUserReserveData(dai.address, recipient.address))
          .usageAsCollateralEnabled
      ).to.be.true;
    });

    it('withdraw that leaves a scaled balance keeps the flag', async () => {
      const {
        pool,
        dai,
        aDai,
        helpersContract,
        users: [, , user],
      } = testEnv;

      await growAndFreezeDaiIndex(testEnv);

      const supplyAmount = utils.parseEther('100');
      await waitForTx(await dai.connect(user.signer)['mint(uint256)'](supplyAmount));
      await waitForTx(await dai.connect(user.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(user.signer).supply(dai.address, supplyAmount, user.address, 0)
      );

      await expect(
        pool.connect(user.signer).withdraw(dai.address, supplyAmount.div(2), user.address)
      ).to.not.emit(pool, 'ReserveUsedAsCollateralDisabled');

      expect(await aDai.scaledBalanceOf(user.address)).to.be.gt(0);
      expect(
        (await helpersContract.getUserReserveData(dai.address, user.address))
          .usageAsCollateralEnabled
      ).to.be.true;
    });

    for (const receiveAToken of [false, true]) {
      it(`full liquidation clears the flag and partial liquidation keeps it (receiveAToken=${receiveAToken})`, async () => {
        const {
          pool,
          dai,
          weth,
          aWETH,
          oracle,
          addressesProvider,
          configurator,
          helpersContract,
          users: [depositor, borrower, liquidator],
        } = testEnv;

        await waitForTx(await addressesProvider.setPriceOracle(oracle.address));
        // With no protocol fee the full-balance burn consumes the whole scaled balance exactly.
        await waitForTx(await configurator.setLiquidationProtocolFee(weth.address, 0));

        const daiLiquidity = utils.parseEther('100000');
        await waitForTx(await dai.connect(depositor.signer)['mint(uint256)'](daiLiquidity));
        await waitForTx(await dai.connect(depositor.signer).approve(pool.address, MAX_UINT_AMOUNT));
        await waitForTx(
          await pool
            .connect(depositor.signer)
            .supply(dai.address, daiLiquidity, depositor.address, 0)
        );

        const collateral = utils.parseEther('1');
        await waitForTx(await weth.connect(borrower.signer)['mint(uint256)'](collateral));
        await waitForTx(await weth.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
        await waitForTx(
          await pool.connect(borrower.signer).supply(weth.address, collateral, borrower.address, 0)
        );

        const { availableBorrowsBase } = await pool.getUserAccountData(borrower.address);
        const daiPrice = await oracle.getAssetPrice(dai.address);
        const borrowAmount = availableBorrowsBase.mul(utils.parseEther('1')).div(daiPrice);
        await waitForTx(
          await pool
            .connect(borrower.signer)
            .borrow(dai.address, borrowAmount, RateMode.Variable, 0, borrower.address)
        );

        // Crash the collateral so that the whole collateral is worth less than the debt.
        const wethPrice = await oracle.getAssetPrice(weth.address);
        await waitForTx(await oracle.setAssetPrice(weth.address, wethPrice.div(4)));
        expect((await pool.getUserAccountData(borrower.address)).healthFactor).to.be.lt(
          utils.parseEther('0.95')
        );

        await waitForTx(await dai.connect(liquidator.signer)['mint(uint256)'](daiLiquidity));
        await waitForTx(
          await dai.connect(liquidator.signer).approve(pool.address, MAX_UINT_AMOUNT)
        );

        // Partial liquidation: flag stays.
        await expect(
          pool
            .connect(liquidator.signer)
            .liquidationCall(
              weth.address,
              dai.address,
              borrower.address,
              borrowAmount.div(10),
              receiveAToken
            )
        ).to.not.emit(pool, 'ReserveUsedAsCollateralDisabled');
        expect(await aWETH.scaledBalanceOf(borrower.address)).to.be.gt(0);
        expect(
          (await helpersContract.getUserReserveData(weth.address, borrower.address))
            .usageAsCollateralEnabled
        ).to.be.true;

        // Full liquidation of the remaining collateral: the flag is cleared iff no scaled
        // balance remains. Burning the underlying rounds the scaled amount up and clears the
        // balance exactly; transferring aTokens rounds down and can leave one scaled unit.
        const fullLiquidation = pool
          .connect(liquidator.signer)
          .liquidationCall(
            weth.address,
            dai.address,
            borrower.address,
            MAX_UINT_AMOUNT,
            receiveAToken
          );
        if (receiveAToken) {
          await waitForTx(await fullLiquidation);
        } else {
          await expect(fullLiquidation)
            .to.emit(pool, 'ReserveUsedAsCollateralDisabled')
            .withArgs(weth.address, borrower.address);
        }

        const scaledAfter = await aWETH.scaledBalanceOf(borrower.address);
        const flagAfter = (await helpersContract.getUserReserveData(weth.address, borrower.address))
          .usageAsCollateralEnabled;
        if (!receiveAToken) {
          expect(scaledAfter).to.eq(0);
        }
        expect(flagAfter).to.eq(scaledAfter.gt(0));
      });
    }
  });
});
