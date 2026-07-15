import { expect } from 'chai';
import { BigNumber, Signer } from 'ethers';
import { getEthersSigners } from '@aave/deploy-v3';
import { AToken, AToken__factory, MockATokenPool, MockATokenPool__factory } from '../types';
import { RAY, ZERO_ADDRESS } from '../helpers/constants';
import { makeSuite } from './helpers/make-suite';

makeSuite('AToken: rounded transfer allowance', () => {
  const index = BigNumber.from(RAY).mul(3).div(2);
  const higherIndex = BigNumber.from(RAY).mul(8).div(5);
  const exactIndex = BigNumber.from(RAY).mul(2);
  const requestedAmount = BigNumber.from(2);

  let deployer: Signer;
  let owner: Signer;
  let spender: Signer;
  let recipient: Signer;
  let ownerAddress: string;
  let spenderAddress: string;
  let recipientAddress: string;
  let pool: MockATokenPool;
  let aToken: AToken;

  beforeEach(async () => {
    [deployer, owner, spender, recipient] = await getEthersSigners();
    ownerAddress = await owner.getAddress();
    spenderAddress = await spender.getAddress();
    recipientAddress = await recipient.getAddress();

    pool = await new MockATokenPool__factory(deployer).deploy(index);
    aToken = await new AToken__factory(deployer).deploy(pool.address);
    await aToken.initialize(
      pool.address,
      await deployer.getAddress(),
      ownerAddress,
      ZERO_ADDRESS,
      0,
      'Mock AToken',
      'aMOCK',
      '0x'
    );

    // At an index of 1.5, minting 150 unscaled units creates 100 scaled units.
    await pool.mintAToken(aToken.address, ownerAddress, 150);
  });

  it('decreases allowance by the sender balance decrease, not the recipient increase', async () => {
    await pool.setReserveNormalizedIncome(higherIndex);
    await aToken.connect(owner).approve(spenderAddress, 10);

    const senderBalanceBefore = await aToken.balanceOf(ownerAddress);
    const recipientBalanceBefore = await aToken.balanceOf(recipientAddress);
    const allowanceBefore = await aToken.allowance(ownerAddress, spenderAddress);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);

    const senderBalanceAfter = await aToken.balanceOf(ownerAddress);
    const recipientBalanceAfter = await aToken.balanceOf(recipientAddress);
    const allowanceAfter = await aToken.allowance(ownerAddress, spenderAddress);
    const actualAmountOut = senderBalanceBefore.sub(senderBalanceAfter);

    expect(actualAmountOut).to.equal(4);
    expect(recipientBalanceAfter.sub(recipientBalanceBefore)).to.equal(3);
    expect(allowanceBefore.sub(allowanceAfter)).to.equal(actualAmountOut);
  });

  it('consumes only the requested amount when the conversion is exact', async () => {
    await pool.setReserveNormalizedIncome(exactIndex);
    await aToken.connect(owner).approve(spenderAddress, 10);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(8);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(198);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(requestedAmount);
  });

  it('charges every split rounded transfer while allowance has headroom', async () => {
    const approvedAmount = BigNumber.from(9);
    await aToken.connect(owner).approve(spenderAddress, approvedAmount);

    for (const remainingAllowance of [6, 3, 0]) {
      await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);
      expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(remainingAllowance);
    }

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(0);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(approvedAmount);

    await expect(
      aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount)
    ).to.be.reverted;
    expect(await aToken.balanceOf(recipientAddress)).to.equal(approvedAmount);
  });

  it('limits split-call overrun to the final capped transfer', async () => {
    const approvedAmount = BigNumber.from(5);
    await aToken.connect(owner).approve(spenderAddress, approvedAmount);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);
    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(2);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);
    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(0);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(approvedAmount.add(1));

    await expect(
      aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount)
    ).to.be.revertedWithCustomError(aToken, 'ERC20InsufficientAllowance');
    expect(await aToken.balanceOf(recipientAddress)).to.equal(approvedAmount.add(1));
  });

  it('caps consumption when allowance covers the request but not the rounded decrease', async () => {
    await aToken.connect(owner).approve(spenderAddress, requestedAmount);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(0);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(147);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(3);
  });

  it('caps consumption when allowance is between the request and rounded decrease', async () => {
    await pool.setReserveNormalizedIncome(higherIndex);
    await aToken.connect(owner).approve(spenderAddress, 3);

    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(0);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(156);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(3);
  });

  it('reverts when allowance does not cover the requested amount', async () => {
    await aToken.connect(owner).approve(spenderAddress, requestedAmount.sub(1));

    await expect(
      aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, requestedAmount)
    )
      .to.be.revertedWithCustomError(aToken, 'ERC20InsufficientAllowance')
      .withArgs(spenderAddress, 1, requestedAmount);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(1);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(150);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(0);
  });

  it('allows a zero transfer with zero allowance and leaves state unchanged', async () => {
    await aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, 0);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(0);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(150);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(0);
  });

  it('consumes corrected allowance for a self-transfer without changing the balance', async () => {
    await aToken.connect(owner).approve(spenderAddress, 10);

    await aToken.connect(spender).transferFrom(ownerAddress, ownerAddress, requestedAmount);

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(7);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(150);
  });

  it('leaves allowance and balances unchanged when the sender balance is insufficient', async () => {
    const allowance = BigNumber.from(200);
    await aToken.connect(owner).approve(spenderAddress, allowance);

    await expect(aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, 151)).to.be
      .reverted;

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(allowance);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(150);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(0);
  });

  it('leaves state unchanged when the requested amount exceeds uint128', async () => {
    const amount = BigNumber.from(2).pow(128);
    await aToken.connect(owner).approve(spenderAddress, amount);

    await expect(aToken.connect(spender).transferFrom(ownerAddress, recipientAddress, amount)).to.be
      .reverted;

    expect(await aToken.allowance(ownerAddress, spenderAddress)).to.equal(amount);
    expect(await aToken.balanceOf(ownerAddress)).to.equal(150);
    expect(await aToken.balanceOf(recipientAddress)).to.equal(0);
  });
});
