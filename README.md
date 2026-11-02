# SparkLend Protocol v1.1

This repository contains the smart contracts source code and markets configuration for SparkLend Protocol V3. The repository uses Hardhat as development environment for compilation, testing and deployment tasks.

## What is SparkLend?

SparkLend is a decentralized non-custodial liquidity markets protocol where users can participate as suppliers or borrowers. Suppliers provide liquidity to the market to earn a passive income, while borrowers are able to borrow in an overcollateralized (perpetually) or undercollateralized (one-block liquidity) fashion. SparkLend is forked off of Aave v3 and thus shares the same interface.

## Documentation

See the link to the technical paper or visit the Aave Developer docs

- [Technical Paper](./techpaper/Aave_V3_Technical_Paper.pdf)

- [Developer Documentation](https://docs.aave.com/developers/)

## Audits and Formal Verification

Audit reports are hosted on the auditors' public portfolio pages:

| Auditor | Report | Date |
| --- | --- | --- |
| ChainSecurity | [MakerDAO Core Updates to SparkLend](https://www.chainsecurity.com/security-audit/makerdao-core-updates-to-sparklend/) | 2024-03-15 |

ChainSecurity reports are cumulative: each portfolio page hosts the latest version of the report, which covers all previously reviewed versions.

### Other reports

The following reports are not available on an auditor portfolio page and are kept in this repository:

- [OpenZeppelin (01-11-2021_OpenZeppelin_AaveV3.pdf)](./audits/01-11-2021_OpenZeppelin_AaveV3.pdf)
- [Trail of Bits (07-01-2022_TrailOfBits_AaveV3.pdf)](./audits/07-01-2022_TrailOfBits_AaveV3.pdf)
- [PeckShield (09-12-2022_PeckShield_AaveV3-0-1.pdf)](./audits/09-12-2022_PeckShield_AaveV3-0-1.pdf)
- [PeckShield (14-01-2022_PeckShield_AaveV3.pdf)](./audits/14-01-2022_PeckShield_AaveV3.pdf)
- [Sigma Prime (19-04-2023_SigmaPrime_AaveV3-0-2.pdf)](./audits/19-04-2023_SigmaPrime_AaveV3-0-2.pdf)
- [Sigma Prime (23-12-2022_SigmaPrime_AaveV3-0-1.pdf)](./audits/23-12-2022_SigmaPrime_AaveV3-0-1.pdf)
- [ABDK (27-01-2022_ABDK_AaveV3.pdf)](./audits/27-01-2022_ABDK_AaveV3.pdf)
- [Sigma Prime (27-01-2022_SigmaPrime_AaveV3.pdf)](./audits/27-01-2022_SigmaPrime_AaveV3.pdf)

## Test

You can run the full test suite with the following commands:

```
# In one terminal
docker-compose up

# Open another tab or terminal
docker-compose exec contracts-env bash

# A new Bash terminal is prompted, connected to the container
npm run test
```
