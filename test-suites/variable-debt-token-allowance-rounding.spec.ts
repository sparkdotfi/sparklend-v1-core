import { expect } from 'chai';
import { BigNumber, Signer } from 'ethers';
import { getEthersSigners } from '@aave/deploy-v3';
import {
  MockVariableDebtTokenPool,
  MockVariableDebtTokenPool__factory,
  VariableDebtToken,
  VariableDebtToken__factory,
} from '../types';
import { RAY, ZERO_ADDRESS } from '../helpers/constants';
import { makeSuite } from './helpers/make-suite';

makeSuite('VariableDebtToken: rounded borrow allowance', () => {
  const index = BigNumber.from(RAY).mul(3).div(2);
  const exactIndex = BigNumber.from(RAY).mul(2);

  let deployer: Signer;
  let delegator: Signer;
  let delegatee: Signer;
  let delegatorAddress: string;
  let delegateeAddress: string;
  let pool: MockVariableDebtTokenPool;
  let variableDebtToken: VariableDebtToken;

  beforeEach(async () => {
    [deployer, delegator, delegatee] = await getEthersSigners();
    delegatorAddress = await delegator.getAddress();
    delegateeAddress = await delegatee.getAddress();

    pool = await new MockVariableDebtTokenPool__factory(deployer).deploy(index);
    variableDebtToken = await new VariableDebtToken__factory(deployer).deploy(pool.address);
    await variableDebtToken.initialize(
      pool.address,
      await deployer.getAddress(),
      ZERO_ADDRESS,
      0,
      'Mock Variable Debt Token',
      'variableDebtMOCK',
      '0x'
    );
  });

  const delegatedMint = async (amount: BigNumber | number) =>
    pool.mintVariableDebtToken(
      variableDebtToken.address,
      delegateeAddress,
      delegatorAddress,
      amount
    );

  it('consumes the delegator actual debt increase while allowance has headroom', async () => {
    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 10);

    const debtBefore = await variableDebtToken.balanceOf(delegatorAddress);
    const allowanceBefore = await variableDebtToken.borrowAllowance(
      delegatorAddress,
      delegateeAddress
    );

    await delegatedMint(1);

    const debtAfter = await variableDebtToken.balanceOf(delegatorAddress);
    const allowanceAfter = await variableDebtToken.borrowAllowance(
      delegatorAddress,
      delegateeAddress
    );

    expect(debtAfter.sub(debtBefore)).to.equal(2);
    expect(allowanceBefore.sub(allowanceAfter)).to.equal(debtAfter.sub(debtBefore));
    expect(allowanceAfter).to.equal(8);
  });

  it('uses the onBehalfOf balance rather than the delegatee balance', async () => {
    await pool.mintVariableDebtToken(
      variableDebtToken.address,
      delegateeAddress,
      delegateeAddress,
      1
    );
    expect(await variableDebtToken.scaledBalanceOf(delegateeAddress)).to.equal(1);
    expect(await variableDebtToken.scaledBalanceOf(delegatorAddress)).to.equal(0);

    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 10);
    await delegatedMint(1);

    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(2);
    expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(8);
  });

  it('uses the exact before-and-after debt delta for an existing delegator balance', async () => {
    await pool.mintVariableDebtToken(
      variableDebtToken.address,
      delegatorAddress,
      delegatorAddress,
      1
    );
    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(2);

    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 10);
    await delegatedMint(1);

    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(3);
    expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(9);
  });

  it('charges split rounded borrows and limits overrun to the final capped mint', async () => {
    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 4);

    for (const [remainingAllowance, debt] of [
      [2, 2],
      [1, 3],
      [0, 5],
    ]) {
      await delegatedMint(1);
      expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(
        remainingAllowance
      );
      expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(debt);
    }

    await expect(delegatedMint(1)).to.be.reverted;
    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(5);
  });

  it('preserves exact-request allowance compatibility', async () => {
    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 1);

    await delegatedMint(1);

    expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(0);
    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(2);
  });

  it('consumes only the requested amount when the debt conversion is exact', async () => {
    await pool.setReserveNormalizedVariableDebt(exactIndex);
    await variableDebtToken.connect(delegator).approveDelegation(delegateeAddress, 10);

    await delegatedMint(2);

    expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(8);
    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(2);
  });

  it('reverts without changing debt when allowance does not cover the request', async () => {
    await expect(delegatedMint(1)).to.be.reverted;

    expect(await variableDebtToken.borrowAllowance(delegatorAddress, delegateeAddress)).to.equal(0);
    expect(await variableDebtToken.scaledBalanceOf(delegatorAddress)).to.equal(0);
    expect(await variableDebtToken.balanceOf(delegatorAddress)).to.equal(0);
  });
});
