# FT UMA Oracle Adapter

> **Disclaimer:** This is an independent implementation for learning purposes. It is not affiliated with or endorsed by the FortyTwo protocol team. This codebase has been reviewed using Pashov AI auditor but has not gone through a manual security review. Do not use in production without a proper audit.

## Overview

This repository contains contracts used to resolve [FortyTwo](https://fortytwo.xyz/) prediction markets via UMA's [Optimistic Oracle V3](https://docs.uma.xyz/developers/optimistic-oracle-v3).

Uses V3's assertion model (`assertTruth`) instead of V2's request-response model (`requestPrice`). See [docs/design.md](./docs/design.md) for the comparison.

## Integration

Grant the adapter resolution roles on `FTMarketController`:

```solidity
controller.grantRole(QUESTION_RESOLVER_ROLE, address(adapter));
controller.grantRole(QUESTION_FINALISER_ROLE, address(adapter));
```

## Architecture

![Contract Architecture](./docs/diagrams/architecture.png)

The Adapter holds `QUESTION_RESOLVER_ROLE` and `QUESTION_FINALISER_ROLE` on FortyTwo's `FTMarketController`. It supports two resolution paths:

### Primary: UMA Oracle Resolution

When a market expires, anyone can `proposeAnswer` on the Adapter:

1. The proposed answer and bond are forwarded to UMA via `assertTruth`
2. The assertion's parameters (questionId, answer, proposer) are stored onchain
3. If undisputed after the liveness period (default: 2 hours), anyone calls `settleAssertion` on UMA
4. UMA calls `assertionResolvedCallback` on the Adapter, which resolves and finalises the market
5. Bond is returned directly to the proposer by UMA

If disputed, the Adapter clears the pending proposal so new proposals can be submitted while UMA's [DVM](https://docs.uma.xyz/protocol-overview/dvm-2.0) votes (48-72 hours).

### Fallback: Admin Emergency Resolution

When UMA is unavailable or produces a wrong result:

1. Admin calls `flag` — pauses UMA resolution, starts a 1-hour safety period
2. Community can observe the flag on-chain
3. After the safety period, admin calls `emergencyResolve` to resolve directly on the controller

## Docs

See [docs/](./docs/) for design rationale, flow diagrams, test coverage, and known issues.

## Development

Clone the repo: `git clone https://github.com/user/ft-uma-oracle-adapter.git --recurse-submodules`

---

### Set-up

Install [Foundry](https://github.com/foundry-rs/foundry/).

To build contracts: `forge build`

---

### Testing

To run all tests: `forge test`

Set `-vv` to see logs or `-vvv` for a stack trace on failed tests.
