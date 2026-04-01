# Test Coverage

27 tests, all passing.

## Happy Path

| Test | Verifies |
|---|---|
| `test_happyPath` | Full cycle: propose -> liveness -> settle -> resolved + finalised -> bond returned to proposer directly by UMA |

## Dispute Path

| Test | Verifies |
|---|---|
| `test_disputePath_proposerWasRight` | Dispute -> DVM in favor -> resolved, bond returned to proposer |
| `test_disputePath_proposerWasWrong` | Dispute -> DVM against -> NOT resolved, bond slashed, can re-propose |

## Emergency Path

| Test | Verifies |
|---|---|
| `test_emergencyResolve` | Flag -> can't propose -> can't resolve early -> safety passes -> resolved -> flag cleaned up |
| `test_unflag` | Flag -> unflag before safety -> can propose again |
| `test_unflag_revertsAfterSafetyPeriod` | Can't unflag after safety period expires |

## Edge Cases

| Test | Verifies |
|---|---|
| `test_flagWhileProposalPending` | Propose -> flag -> UMA callback skips resolution (paused) -> bond returned to proposer by UMA -> admin resolves with different answer |
| `test_staleDvmSettlement_onFinalisedMarket` | Dispute -> re-propose -> new settles -> old DVM settles on finalised market -> isFinalised check prevents revert, bond returned to proposer |
| `test_oldDvmSettlement_doesNotWipeNewProposal` | Dispute -> re-propose -> old DVM settles truthful -> new proposal NOT wiped |
| `test_oldDvmSettlement_false_doesNotWipeNewProposal` | Dispute -> re-propose -> old DVM settles false -> new proposal NOT wiped, new proposal resolves correctly |

## Proposal Validation

| Test | Expected revert |
|---|---|
| `test_revert_proposeBeforeExpiry` | `QuestionNotExpired` |
| `test_revert_proposeZeroAnswer` | `InvalidAnswer` |
| `test_revert_proposeAnswerOutOfRange` | `InvalidAnswer` |
| `test_revert_proposeDuplicate` | `ProposalAlreadyPending` |
| `test_revert_proposeAlreadyFinalised` | `QuestionAlreadyFinalised` |

## Callback Auth

| Test | Expected revert |
|---|---|
| `test_revert_callbackFromNonOracle` | `NotOracle` |
| `test_revert_disputeCallbackFromNonOracle` | `NotOracle` |

## Admin Auth

| Test | Expected revert |
|---|---|
| `test_revert_flagByNonOwner` | `OwnableUnauthorizedAccount` |
| `test_revert_emergencyResolveByNonOwner` | `OwnableUnauthorizedAccount` |

## Configuration

| Test | Verifies |
|---|---|
| `test_setDefaultBond` | Owner can update bond |
| `test_setDefaultLiveness` | Owner can update liveness |
| `test_revert_setZeroBond` | Bond = 0 rejected |
| `test_revert_setZeroLiveness` | Liveness = 0 rejected |

## Bond Flow

| Test | Verifies |
|---|---|
| `test_bondFlow` | Bond passes: proposer -> adapter -> UMA -> proposer (directly). Adapter balance = 0 at all checkpoints. |

## View Functions

| Test | Verifies |
|---|---|
| `test_ready_falseWhenNoPendingProposal` | `ready()` returns false when no proposal |
| `test_ready_falseWhenPaused` | `ready()` returns false when paused |

## Multi-Outcome

| Test | Verifies |
|---|---|
| `test_multiOutcome` | 3-outcome market with bitmask answer = 5 (0b101) resolves correctly |
