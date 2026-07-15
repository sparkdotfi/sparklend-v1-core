import { expect } from 'chai';
import { BigNumber, utils } from 'ethers';
import { evmRevert, evmSnapshot, waitForTx } from '@aave/deploy-v3';
import { MAX_UINT_AMOUNT } from '../helpers/constants';
import { RateMode } from '../helpers/types';
import { makeSuite, TestEnv } from './helpers/make-suite';
import './helpers/utils/wadraymath';

makeSuite('Isolation mode: full-collateral liquidation', (testEnv: TestEnv) => {
  let snapshot: string;

  before(async () => {
    const { addressesProvider, oracle, configurator, aave, dai } = testEnv;

    await waitForTx(await addressesProvider.setPriceOracle(oracle.address));
    await waitForTx(await configurator.setDebtCeiling(aave.address, '10000'));
    await waitForTx(await configurator.setBorrowableInIsolation(dai.address, true));
    await waitForTx(await configurator.setLiquidationProtocolFee(aave.address, '1000'));
  });

  beforeEach(async () => {
    snapshot = await evmSnapshot();
  });

  afterEach(async () => {
    await evmRevert(snapshot);
  });

  for (const receiveAToken of [false, true]) {
    it(`decrements isolated debt before disabling fully liquidated collateral (receiveAToken=${receiveAToken})`, async () => {
      const {
        pool,
        users: [depositor, borrower, liquidator],
        dai,
        aave,
        aAave,
        variableDebtDai,
        oracle,
        helpersContract,
      } = testEnv;

      const daiLiquidity = utils.parseEther('1000');
      await waitForTx(await dai.connect(depositor.signer)['mint(uint256)'](daiLiquidity));
      await waitForTx(await dai.connect(depositor.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool.connect(depositor.signer).supply(dai.address, daiLiquidity, depositor.address, 0)
      );

      const collateralAmount = utils.parseEther('1');
      await waitForTx(await aave.connect(borrower.signer)['mint(uint256)'](collateralAmount));
      await waitForTx(await aave.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
      await waitForTx(
        await pool
          .connect(borrower.signer)
          .supply(aave.address, collateralAmount, borrower.address, 0)
      );
      await waitForTx(
        await pool.connect(borrower.signer).setUserUseReserveAsCollateral(aave.address, true)
      );

      const borrowedAmount = utils.parseEther('50');
      await waitForTx(
        await pool
          .connect(borrower.signer)
          .borrow(dai.address, borrowedAmount, RateMode.Variable, 0, borrower.address)
      );

      const liquidatorFunds = utils.parseEther('100');
      await waitForTx(await dai.connect(liquidator.signer)['mint(uint256)'](liquidatorFunds));
      await waitForTx(await dai.connect(liquidator.signer).approve(pool.address, MAX_UINT_AMOUNT));

      const originalDaiPrice = await oracle.getAssetPrice(dai.address);
      await waitForTx(await oracle.setAssetPrice(dai.address, originalDaiPrice.mul(10)));

      const { healthFactor } = await pool.getUserAccountData(borrower.address);
      expect(healthFactor).to.be.lt(utils.parseEther('0.95'));
      expect(await helpersContract.getLiquidationProtocolFee(aave.address)).to.be.gt(0);

      const collateralBalanceBefore = await aAave.balanceOf(borrower.address);
      const debtBalanceBefore = await variableDebtDai.balanceOf(borrower.address);
      const isolationDebtBefore = (await pool.getReserveData(aave.address)).isolationModeTotalDebt;
      const aaveConfiguration = await helpersContract.getReserveConfigurationData(aave.address);
      const daiConfiguration = await helpersContract.getReserveConfigurationData(dai.address);
      const debtCeilingDecimals = await helpersContract.getDebtCeilingDecimals();
      const collateralAssetUnit = BigNumber.from(10).pow(aaveConfiguration.decimals);
      const debtAssetUnit = BigNumber.from(10).pow(daiConfiguration.decimals);
      const debtCeilingUnit = BigNumber.from(10).pow(
        daiConfiguration.decimals.sub(debtCeilingDecimals)
      );

      const aavePrice = await oracle.getAssetPrice(aave.address);
      const daiPrice = await oracle.getAssetPrice(dai.address);
      const expectedDebtToLiquidate = aavePrice
        .mul(collateralBalanceBefore)
        .mul(debtAssetUnit)
        .div(daiPrice.mul(collateralAssetUnit))
        .percentDiv(aaveConfiguration.liquidationBonus);
      const expectedIsolationDebtAfter = isolationDebtBefore.sub(
        expectedDebtToLiquidate.div(debtCeilingUnit)
      );

      expect(expectedDebtToLiquidate).to.be.lt(debtBalanceBefore);

      const liquidation = await pool
        .connect(liquidator.signer)
        .liquidationCall(
          aave.address,
          dai.address,
          borrower.address,
          MAX_UINT_AMOUNT,
          receiveAToken
        );

      await expect(liquidation)
        .to.emit(pool, 'IsolationModeTotalDebtUpdated')
        .withArgs(aave.address, expectedIsolationDebtAfter);

      expect(await aAave.balanceOf(borrower.address)).to.be.eq(0);
      expect(await variableDebtDai.balanceOf(borrower.address)).to.be.gt(0);
      expect((await pool.getReserveData(aave.address)).isolationModeTotalDebt).to.be.eq(
        expectedIsolationDebtAfter
      );
      expect(
        (await helpersContract.getUserReserveData(aave.address, borrower.address))
          .usageAsCollateralEnabled
      ).to.be.false;
    });
  }
});
