# Additional adversarial tests

These tests extend the accepted suite without changing application code, dependencies, or configuration. They use the existing offline fixtures and the supplied threat model, property-testing references, and protected deployment checks.

| File | Additional coverage |
| --- | --- |
| `Imdex5SwapBoundaries.t.sol` | Both currency orderings and both rebalance directions: zero, one wei, one wei below the minimum half-value fill, the minimum, and one wei above. Fuzzed amounts and payouts. Rejected swaps must preserve holdings and pool reserves while list adoption completes. A zero-output redemption sale must pay in kind; an unmet IMD minimum must roll back the entire redemption, including earlier sales and payments. |
| `Imdex5Claims.invariant.t.sol` | Three actors, random mint/redeem/claim/share-transfer/failure sequences, one-wei and full exits, and new first mints while old claims remain. An independent creditor ledger includes idle IMD. Checks share issuance/burning, backing, mint floors and budgets, per-share non-dilution, rollback of failed calls, and repayment after recovery. Every sequence ends by redeeming all shares and claiming all debts. |
| `Imdex5OracleAuthentication.t.sol` | Mutation of every signed attestation field and the consumer domain; a signed under-quorum answer following a quorate callback; replay after adoption; delivery after expiry. Invalid submissions must leave list, request, fees, and caller balances unchanged. |

Fuzz run counts are inline in the test files. The new invariant uses 256 runs, depth 64, and `fail-on-revert = true`; expected protocol failures are caught explicitly and their rollback is checked. A deterministic handler test establishes that successful mints, reverted mints, outstanding debts, failed claims, successful claims, and empty/refilled epochs are reachable.

The swap boundary fixture sets the relevant pool's pre-swap price to exactly 1:1. This makes the expected half-value bound independent of the implementation's square-root-price conversion and rounding. It uses actual settlement and balance changes through the existing mock manager. The claims suite uses tokens that revert, exhaust their payment stipend, or return false **without** changing balances; the distinct false-after-transfer case is reported below.

## Reported defect

**Medium — `_pay` can create a second claim for a transfer that already happened** (`src/Imdex5.sol:650`). A token can debit the index and credit the redeemer, then return `false`. The low-level call commits those changes, but `_pay` records the full amount as owed. Once the token returns normally, `claim` pays the entitlement a second time from other holders' backing. This requires unusual token behavior; it is not a claim that the current mainnet starting coins exhibit it.

The self-contained reproduction was run under `test/scratch/` and failed on the unchanged implementation: a 49.50125-coin redemption entitlement was paid as 99.0025 coins after claiming. The full failing source, concrete inputs, expected result, actual result, and suggested minimal fix are in the assignment's root `.imd-findings.json`. No passing test asserts that this behavior is correct. Application fixes and the root README are outside this tests-only assignment's write scope.

## Running

```sh
forge build
FOUNDRY_FUZZ_SEED=0x906f674ec82bd2e74061fa6aef3b6c6756390329a66f79e32b26b24c14dfbc97 forge test
```

Local checks direct generated artifacts and the compiler cache into `test/scratch/` using `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`; these do not change compiler settings or test behavior and are not required by the verifier. The intentionally failing proof is embedded in the findings report, not included as an executable submitted test.

No new dependency, RPC, network access, FFI, environment mutation, or storage overwrite is required. These are offline integration models, not a fresh mainnet verification. The existing seven fork test cases skip without a fork and still need a live-state run before deployment.
