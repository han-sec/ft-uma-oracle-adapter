# Design

## What This Adapter Does

The adapter translates between UMA's Optimistic Oracle V3 and FortyTwo's `FTMarketController`. It holds `QUESTION_RESOLVER_ROLE` and `QUESTION_FINALISER_ROLE` on the controller and is the only contract that calls `resolveOutcome()` and `finaliseOutcome()` during normal operation.

It stores only the translation mapping between a UMA assertionId and a FortyTwo questionId. Everything else — bond state, liveness, dispute tracking — is managed by UMA.

## Immediate Resolution (No Gap Between Resolve and Finalise)

The controller has two separate functions: `resolveOutcome` (set the answer, can be changed) and `finaliseOutcome` (lock it permanently). These exist as a two-step process for human-operated resolution — the admin resolves, reviews, then finalises.

The adapter calls both in the same transaction with no gap:

```
UMA path:       assertionResolvedCallback → resolveOutcome + finaliseOutcome (same tx)
Emergency path: emergencyResolve          → resolveOutcome + finaliseOutcome (same tx)
```

The review window happens **before** the adapter acts, not between the two calls:

- UMA path: 2-hour liveness period (public scrutiny on UMA)
- Emergency path: 1-hour safety period (community visibility after flag)

Adding a gap between resolve and finalise would delay user payouts without meaningful security benefit — if UMA's answer is wrong after 2 hours of public scrutiny, an additional human review is unlikely to catch it.

## UMA Default, Admin Fallback

The adapter has two resolution paths that never run simultaneously for the same question:

- **UMA (default):** permissionless proposal → liveness → callback → resolved. Handles 99% of cases.
- **Admin (fallback):** flag → safety period → emergency resolve. For when UMA is unavailable or produces a wrong result.

The `flag()` function is the switch. It sets `pausedQuestions = true`, which causes UMA callbacks to become no-ops. From that point, only the admin can resolve. The admin can also `unflag()` to hand control back to UMA if the flag was a mistake.

## V3 vs V2

Polymarket's [uma-ctf-adapter](https://github.com/Polymarket/uma-ctf-adapter) uses UMA V2. The key difference is the interaction model.

**V2 (request-response, pull-based):**

The protocol requests a price upfront at market creation. The request sits on UMA for days or weeks until someone proposes an answer. After the liveness period, anyone must call `resolve()` on the adapter to pull the result from UMA and forward it to the protocol.

V2 was designed for price feeds — "what is ETH/USD at timestamp X?" — where the protocol asks a question before the answer exists.

**V3 (assertion, push-based):**

Nobody talks to UMA until the outcome is known. A proposer asserts a truth claim with a bond. After the liveness period, settlement triggers a callback from UMA to the adapter. The adapter doesn't poll or pull — UMA pushes the result.

V3 was designed for exactly this use case — "the outcome is known, someone proposes it, the community validates."

**Practical differences:**

| | V2 | V3 |
|---|---|---|
| Transactions to resolve | 3 (request, propose, settle+resolve) | 2 (assert, settle) |
| State on UMA during trading | Open price request | None |
| Resolution trigger | Adapter pulls (`settleAndGetPrice`) | UMA pushes (callback) |
| Adapter state per question | 12 fields | 3 fields |
| Dispute handling | Manual reset, re-request, refund flags | Automatic cleanup via callback |
| Needs keeper bot to resolve | Yes (someone must call `resolve()`) | No (callback is automatic on settle) |

## Roles and Access Control

### Owner (Ownable)

The adapter uses OpenZeppelin's `Ownable` for admin functions. The owner is set to `msg.sender` in the constructor and can be transferred via `transferOwnership()`.

The owner can:

| Function | What it does |
|---|---|
| `flag(questionId)` | Pause UMA resolution, start 1-hour safety timer |
| `unflag(questionId)` | Cancel flag before safety period expires |
| `emergencyResolve(questionId, answer)` | Force-resolve after safety period |
| `pause(questionId)` | Pause UMA resolution without flagging |
| `unpause(questionId)` | Resume UMA resolution |
| `setDefaultBond(amount)` | Set bond for future proposals |
| `setDefaultLiveness(seconds)` | Set liveness for future proposals |

In production, the owner should be a **multisig** to prevent a single compromised key from emergency-resolving markets.

### onlyOracle Modifier

`assertionResolvedCallback` and `assertionDisputedCallback` verify `msg.sender == address(oracleV3)`. This is the primary security invariant. Without it, anyone could call the callback and resolve markets with arbitrary answers.

### Controller Roles

The adapter needs two roles granted on `FTMarketController`:

- `QUESTION_RESOLVER_ROLE` — to call `resolveOutcome()`
- `QUESTION_FINALISER_ROLE` — to call `finaliseOutcome()`

These can be revoked at any time by the controller admin, which effectively disables the adapter. This is the kill switch if the adapter has a bug.

## Security Guards

### ReentrancyGuard

All state-modifying functions use `nonReentrant`:

- `proposeAnswer` — external calls to bond token + UMA
- `assertionResolvedCallback` — external calls to controller
- `assertionDisputedCallback` — called by UMA during dispute
- `emergencyResolve` — external calls to controller

The concern: a malicious bond token or a controller with hooks could call back into the adapter during execution. `ReentrancyGuard` blocks this.

### Bond Flow

The adapter routes the bond but never holds it between transactions. The key is the `asserter` parameter in `assertTruth` — set to the proposer's address, not the adapter. UMA returns the bond directly to the asserter on settlement.

```
Propose:   proposer → adapter (transferFrom) → UMA (assertTruth pulls from adapter)
Settle:    UMA → proposer (directly, asserter = proposer)
```

After `proposeAnswer` completes, `bondToken.balanceOf(adapter) == 0`.
After settlement, the bond goes directly to the proposer — the adapter is never involved.

Uses `forceApprove` (not `approve`) when approving UMA to spend the bond. This handles tokens like USDT that revert if you `approve` when the current allowance is non-zero.

### Bond Slashing (confirmed from UMA V3 source)

Bond slashing is all-or-nothing:

- Proposer correct (no dispute or won dispute): gets full bond back, plus disputer's bond minus UMA fee
- Proposer wrong (lost dispute): loses entire bond. 50% goes to disputer, 50% to UMA protocol
- No dispute: proposer gets full bond back

The adapter doesn't handle any of this — UMA manages bond distribution directly between asserter and disputer.

### Answer Validation

Proposals are validated before touching UMA:

1. `block.timestamp >= timestampEnd` — question must have expired
2. `!isFinalised(questionId)` — not already resolved
3. `answer != 0` — must have at least one winner
4. `answer < (1 << numOutcomes)` — within valid bitmask range
5. `questionToAssertion[questionId] == bytes32(0)` — no pending proposal
6. `!pausedQuestions[questionId]` — not paused or flagged

If any check fails, the transaction reverts before transferring bond or calling UMA.

### Emergency Flag + Safety Period

The emergency path is intentionally slow:

1. Admin calls `flag()` — pauses UMA, starts 1-hour timer
2. `QuestionFlagged` event emitted — on-chain, visible to everyone
3. Community has 1 hour to notice and react
4. Admin can `unflag()` during this window if the flag was a mistake
5. After 1 hour, admin can `emergencyResolve()` — resolves directly on controller

This prevents impulsive or malicious emergency resolution. The safety period is a cooling-off mechanism, not a cryptographic guarantee — it relies on community monitoring.

### Stateless Between Cycles

After every resolution (happy path, dispute, or emergency), all translation mappings are deleted:

```solidity
delete assertions[assertionId];
delete questionToAssertion[questionId];
```

No residual state that could affect future proposals for the same question.

### Bond Token Blacklist Risk

Tokens like USDC and USDT have admin-controlled blacklists. If a proposer's address gets blacklisted after proposing, UMA's `settleAssertion` reverts because it can't transfer the bond back to the blacklisted asserter. The callback never fires and the market is stuck on the UMA path.

The failure scenario:

1. Proposer calls `proposeAnswer()` — bond goes to UMA, `asserter = proposer`
2. During the 2-hour liveness period, the proposer address gets blacklisted
3. Anyone calls `settleAssertion()` — UMA tries `safeTransfer(asserter, bond)` → reverts
4. Callback never fires. `questionToAssertion` still points to the stuck assertion
5. New proposals are blocked (`ProposalAlreadyPending`)

Recovery via emergency path:

1. Admin calls `flag(questionId)` — pauses UMA resolution, starts 1-hour timer
2. After safety period, admin calls `emergencyResolve(questionId, answer)`
3. Market resolves directly on the controller — users can claim
4. Stale adapter state (`assertions`, `questionToAssertion`) remains but is harmless — `isFinalised` check prevents any re-proposals
5. Proposer's bond is permanently locked in UMA (their loss, not the protocol's)

**Deployment consideration:** The bond token is an immutable chosen at deployment:

- **USDC** — most liquid, UMA standard, but has blacklist risk
- **DAI** — no blacklist, but less common on UMA
- **WETH** — no blacklist, different denomination

If the team is concerned about blacklist griefing, deploy with a non-blacklistable token. If using USDC, accept the risk with the emergency path as mitigation.

## Known Issues

### Stale state after emergency resolve with stuck UMA assertion

When admin emergency-resolves a market that has a stuck UMA assertion (e.g. blacklisted proposer), the adapter retains stale mappings:

- `assertions[assertionId]` — still contains the stuck assertion's data
- `questionToAssertion[questionId]` — still points to the stuck assertion

This is harmless in practice. The controller is already finalised, so `_validateProposal` rejects any new proposals at the `isFinalised` check before reaching the `questionToAssertion` check. The stale data just occupies storage slots that will never be read in a meaningful code path.

A `clearStuckAssertion()` admin function could clean this up but is not strictly necessary.

### Proposer bond locked on blacklist

If a proposer is blacklisted, their bond is permanently locked in UMA's contract. UMA's `settleAssertion` will always revert for that assertion. There is no on-chain recovery for the bond. This is a consequence of UMA's settlement design, not the adapter's.

### No financial incentive for proposers

The adapter does not offer rewards to proposers. A truthful proposer only gets their bond back — no profit. In practice, proposers are either:

- The protocol team running a keeper bot (most likely)
- Users who hold winning tokens and want the market resolved to unlock claims
- Altruistic actors (unreliable for ongoing operation)

This is the same model Polymarket uses.

### Callback revert blocks UMA settlement

UMA's `_callbackOnAssertionResolve` does NOT wrap the callback in a try/catch. If `assertionResolvedCallback` reverts in the adapter, `settleAssertion` on UMA reverts too — the assertion can never settle.

The adapter mitigates most cases: it checks `pausedQuestions` and `isFinalised` before calling the controller, skipping to cleanup if either is true. But if `controller.isFinalised()` itself reverts (e.g., controller proxy upgraded with a different interface, or controller self-destructed), the entire callback reverts with no fallback.

Potential triggers: controller role revoked from adapter, controller paused/upgraded, `resolveOutcome` or `finaliseOutcome` reverts for unexpected reasons.

Recovery: admin flags the question and emergency-resolves, bypassing UMA entirely. Same recovery path as the blacklist scenario.

### No minimum bond validation against UMA

`setDefaultBond` only checks `newBond == 0`. It does not verify against UMA's minimum: `oracleV3.getMinimumBond(address(bondToken))`. If admin sets bond below UMA's minimum, all proposals revert with "Bond amount too low" until admin corrects it. Not a security issue but a liveness risk.

The minimum bond is calculated as `finalFee * 1e18 / burnedBondPercentage`. With `burnedBondPercentage` at 50%, the minimum bond is 2x the final fee. UMA governance can change the final fee at any time via the Store contract, which could cause a previously valid bond to become invalid.

### No minimum liveness validation

`setDefaultLiveness` only checks `newLiveness == 0`. UMA documentation explicitly states liveness should not be set shorter than two hours. A compromised or careless admin could set 1-second liveness, allowing proposals to pass with no time for disputers to challenge.

For high-value markets, UMA recommends longer liveness periods (hours to days). The bond and liveness should be calibrated together based on the total value secured by the market.

### Currency whitelist removal breaks new proposals

`bondToken` is immutable. If UMA governance removes the token from their collateral whitelist, `assertTruth` reverts with "Unsupported currency" for all new proposals. Existing in-flight assertions can still settle (UMA caches whitelist status per assertion). Emergency path still works since it doesn't interact with UMA.

Note: UMA caches whitelist results in `cachedCurrencies`. The cache becomes stale if anyone calls `syncUmaParams()` after the token is removed. Before that call, cached assertions continue to work normally.

### Front-running proposals

`proposeAnswer` is permissionless. An MEV bot can observe a pending proposal in the mempool, copy the correct answer, and submit with higher gas priority. The honest proposer's transaction reverts (`ProposalAlreadyPending`), and the bot receives the bond back on settlement.

This does not harm the protocol — the correct outcome is still proposed. It steals value from honest proposers by denying them the bond return. This is a known and accepted tradeoff in permissionless oracle systems. Polymarket's adapter has the same characteristic.

### Escalation manager not used

The adapter sets `escalationManager: address(0)`, meaning UMA defaults apply: anyone can assert, anyone can dispute, disputes go to the DVM. UMA's Escalation Manager framework supports asserter whitelisting, disputer whitelisting, custom arbitration, and oracle result discarding.

This is a deliberate design choice favoring simplicity and permissionless operation. If the protocol later needs restricted proposals (e.g., only approved signers), the options are: deploy a new adapter with an escalation manager, or add an on-chain whitelist check in `_validateProposal`.

### Dispute-then-re-propose with wrong answer

An attacker can dispute a correct proposal, then immediately propose a wrong answer. If nobody disputes the wrong answer during the 2-hour liveness, the market finalizes incorrectly. The DVM later confirms the original was correct, but `isFinalised` means the callback is a no-op.

This is not a code bug — it's UMA's economic security model. The attack costs the attacker two bonds (one for the dispute, one for the wrong proposal) and only succeeds if nobody disputes the wrong answer for 2 hours. Anyone holding the correct outcome tokens is economically incentivized to dispute.

The defense is bond calibration: the bond must be large enough that the cost of the attack (2x bond lost) exceeds the profit from the wrong resolution. This is a configuration decision documented under bond economics.

### Bit-shift overflow at 256+ outcomes

The answer validation `answer >= (1 << numOutcomes)` would panic if `numOutcomes >= 256`, since `1 << 256` overflows a uint256. FortyTwo's controller caps outcomes at 255 (`MAX_NUM_OUTCOMES = 255`), so this can never be triggered in practice. Acknowledged but not fixed — the controller enforces the constraint.

### Shared state between pause and flag

`pause()`/`unpause()` and `flag()`/`unflag()` both write to the same `pausedQuestions` mapping. This creates two interactions:

1. `unflag()` silently cancels an independently-set `pause()` — admin pauses for one reason, flags for another, then unflag undoes both
2. `unpause()` after `flag()` re-enables UMA resolution, undermining the flag's intent to let admin take over

This is safe with a single owner (`Ownable`) because the same person controls both operations and knows what they did. It becomes a real coordination bug if the adapter moves to `AccessControl` with separate roles for pause and flag.

Fix for production with multiple roles: separate `pausedByAdmin` and `pausedByFlag` booleans, check both in the callback. Not implemented in this version — single owner makes it unnecessary.

## Assumptions

1. `bondToken` is UMA-approved on the target chain
2. `defaultBond` >= UMA's minimum bond for that token
3. Controller grants both roles to the adapter before use
4. `questionId == bytes32(0)` is never a valid question (used as sentinel for "not found")
5. UMA calls `assertionResolvedCallback` exactly once per assertion
6. `resolveOutcome()` then `finaliseOutcome()` on the controller does not revert for a valid question + answer
