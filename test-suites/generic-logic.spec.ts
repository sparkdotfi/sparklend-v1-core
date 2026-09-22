import { expect } from 'chai';
import { utils } from 'ethers';
import { MAX_UINT_AMOUNT } from '../helpers/constants';
import { RateMode } from '../helpers/types';
import { makeSuite, TestEnv } from './helpers/make-suite';
import { convertToCurrencyDecimals } from '../helpers/contracts-helpers';
import { evmSnapshot, evmRevert, waitForTx } from '@aave/deploy-v3';

makeSuite('GenericLogic: Health factor', (testEnv: TestEnv) => {
  before(async () => {
    const { addressesProvider, oracle } = testEnv;

    await waitForTx(await addressesProvider.setPriceOracle(oracle.address));
  });

  after(async () => {
    const { aaveOracle, addressesProvider } = testEnv;

    await waitForTx(await addressesProvider.setPriceOracle(aaveOracle.address));
  });

  it('Supplying collateral on behalf of a user cannot decrease that user health factor', async () => {
    const { pool, users, dai, usdc, weth, oracle } = testEnv;

    const borrower = users[0];
    const donor = users[1];
    const wethProvider = users[2];

    // USDC has a 8500 bps liquidation threshold and DAI 8000 bps. The prices are picked so that one
    // DAI is worth far less than one basis point of the USDC collateral below, which makes the
    // weighted average threshold of the position dip just under 8500 once the DAI is supplied.
    await waitForTx(await oracle.setAssetPrice(weth.address, utils.parseUnits('1', 18)));
    await waitForTx(await oracle.setAssetPrice(usdc.address, utils.parseUnits('1', 15)));
    await waitForTx(await oracle.setAssetPrice(dai.address, utils.parseUnits('1', 12)));

    const wethToProvide = utils.parseEther('10');
    const usdcToSupply = await convertToCurrencyDecimals(usdc.address, '10000');
    const wethToBorrow = utils.parseEther('1');
    const daiDust = await convertToCurrencyDecimals(dai.address, '1');

    // Give the borrower something to borrow.
    await waitForTx(await weth.connect(wethProvider.signer)['mint(uint256)'](wethToProvide));
    await waitForTx(await weth.connect(wethProvider.signer).approve(pool.address, MAX_UINT_AMOUNT));
    await waitForTx(
      await pool
        .connect(wethProvider.signer)
        .supply(weth.address, wethToProvide, wethProvider.address, 0)
    );

    // The borrower holds USDC only, so the weighted average threshold is exactly 8500 bps.
    await waitForTx(await usdc.connect(borrower.signer)['mint(uint256)'](usdcToSupply));
    await waitForTx(await usdc.connect(borrower.signer).approve(pool.address, MAX_UINT_AMOUNT));
    await waitForTx(
      await pool.connect(borrower.signer).supply(usdc.address, usdcToSupply, borrower.address, 0)
    );
    await waitForTx(
      await pool
        .connect(borrower.signer)
        .borrow(weth.address, wethToBorrow, RateMode.Variable, 0, borrower.address)
    );

    await waitForTx(await dai.connect(donor.signer)['mint(uint256)'](daiDust));
    await waitForTx(await dai.connect(donor.signer).approve(pool.address, MAX_UINT_AMOUNT));

    // Both health factors are read exactly one block after the snapshot so that the same amount of
    // borrow interest has accrued in each branch and the comparison isolates the collateral change.
    const snap = await evmSnapshot();

    await waitForTx(await dai.connect(donor.signer)['mint(uint256)'](daiDust));
    const { healthFactor: healthFactorBefore } = await pool.getUserAccountData(borrower.address);

    await evmRevert(snap);

    await waitForTx(
      await pool.connect(donor.signer).supply(dai.address, daiDust, borrower.address, 0)
    );
    const { healthFactor: healthFactorAfter } = await pool.getUserAccountData(borrower.address);

    expect(healthFactorAfter).to.be.gte(
      healthFactorBefore,
      'Health factor decreased after collateral was added'
    );
  });
});
