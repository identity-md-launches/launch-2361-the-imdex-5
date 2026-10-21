# Corrected Imdex5 launch adaptation

The deliverable is the existing `Imdex5` application for a new Ethereum mainnet (chain id 1)
`evm_contracts` launch. It has a nonpayable, argument-free constructor that calls no other
contract. Deployment starts with zero IMDEX5 supply. The supplied build configuration and
dependencies remain unchanged: solc 0.8.26, optimizer 200 runs, via IR, Cancun, bytecode hash none.
No deployment, signing or broadcasting is performed by this work. The existing manifest is
untouched; launch handoff belongs to the subsequent manifest/deployment step.

## This launch: commit a578235 (launch 2343's code with the 705dd677 fixes), audited again

The repository arrived at commit `a578235` and is deployed as it is: one contract, `Imdex5`, no
constructor arguments, no owner, no launch token, Ethereum mainnet (chain id 1). The brief: fix
every finding of medium or above from the new audit with the smallest change, document the low
and informational ones, keep everything else. The audit reported one low and three informational
findings and nothing of medium or above, so `src/` is unchanged (runtime 23,552 bytes, as before).

### Changes

1. **`test/Imdex5DocumentedLimits.t.sol` (new).** Each finding reproduced and pinned as a
   documented limit, so a later change of behaviour shows up: a pool pumped 44% before a
   rebalance is bought at the pumped price and booked (65-75% of the fair fill, the same IMD
   spent, `held` equal to the balance); a leaver dumped 31% first is sold at the dumped price and
   booked (at least 60% of the fair proceeds); a limited sale sells 0.95-1.05% of the pool's coin
   reserve, the residual stays at index 5 of `coins()`, is redeemed proportionally and is sold
   whole by the next week's rebalance once it is under 1% of the reserve; a failed and a closed
   request each leave `lastAsk` in place, so `ask` reverts `AskTooSoon` until seven days after the
   failed ask and then opens a new request; a failed request keeps the IMD balance equal to
   `feeImd + idleImd` before, during and after, through a mint, a redeemToImd and the next ask.
2. **`README.md`, `THREAT_MODEL.md`, this file.** The findings table, the accepted limits and the
   reproductions below. Test count 171 to 177.

Nothing else: no change to the constructor, the constants, the accounting, the swap rules, the
oracle flow, the tests that existed, or the protected configuration. `launch.json` is the file
that arrived with the repository and is left to the manifest step.

### The audit's findings, reproduced

- **Low, `9f216ca3…` (`PoorFill` and the 2% limit measured against a spot price the caller can
  set first): reproduced, documented, not redesigned.** The audit's numbers hold on the mocks:
  alice `mintFirst(1000e18)`, the fifth coin replaced by launch 2000, bob `rebalance()` books
  2,035.6e18 of the new coin; from the same snapshot with the new coin's pool set to 833,333
  coins / 12,000 IMD (price +44%), `rebalance()` books 1,414.1e18 (30.5% fewer) for the same IMD,
  with no `SwapSkipped`. The sale side behaves the same: the leaver's pool set to 1,200,000 /
  8,333 (price -31%) sells at that price. `PoorFill` compares against `p0`, read in `swapSelf`
  right before the swap, so a moved pool passes it at about 98%. The loss is bounded: a limited
  swap trades at most what moves the sqrt price 1% (about 1% of the pool's reserve per coin per
  weekly rebalance), the mover pays the pool fee twice on mainnet (1.25% each way), and the
  index's IMD never leaves the accounting (`held` equals the balance, the IMD balance equals
  `feeImd + idleImd`). A caller-independent reference price (a TWAP, an oracle) is a redesign
  of the rebalance; the brief says low findings are documented, not redesigned.
- **Info, `0a7c3762…` (a limited sell clears only part of a leaver per rebalance): reproduced
  with a correction to the rate.** After the first mint `held[leaver]` is 19,511.7e18 and one
  rebalance leaves 9,607.8e18 (49%), as the audit says. The rule is not "half": the sale stops at
  a 1% sqrt-price move, which on a constant-product pool is 1/0.99 - 1 = 1.01% of the pool's coin
  reserve (9,904e18 of 980,488e18 here). A residual under that is sold whole by the next
  rebalance, which the test shows: after a 10% redeem the 8,652e18 left clears a week later and
  the coin leaves `coins()`. A leaver worth more than about 1% of its pool's reserve takes as
  many weekly rebalances as that ratio says. Gas: one coin per unsold leaver in every loop, with
  `SWAP_GAS` and `PAY_GAS` per coin, as the README's security notes already said.
- **Info, `18ca8bf9…` (`ask` commits the interval before the outcome): reproduced.** Fund 2e18,
  `ask()` at T (`lastAsk` = T, `feeImd` 1.25e18), `onOracleFailure` at T + 1 hour closes the
  request (`openSince` 0, `lastAsk` still T), `ask()` at T + 1 hour + 1 second reverts
  `AskTooSoon`, `ask()` at T + 7 days opens request 2 and `feeImd` is 0.5e18. The same for a
  request `closeRequest` closes at T + 2 days. This is the brief's "weekly at most"; a retry on
  failure would be a new rule. Documented.
- **Info, `e2325942…` (IMD the Intake might return on a failed request would be stranded): does
  not reproduce; the premise is false for the live Intake.** The auditor had no fork and could not
  read the Intake. Its source is published on Sourcify for chain 1 at
  `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` with a full creation and runtime match
  (verified 2026-10-10): the contract "holds nothing: every payment is forwarded to `payTo` in the
  same call" (`_collect` does `safeTransferFrom(msg.sender, payTo, amount)`), and `complete` on a
  non-zero status only calls the payer's failure selector with the arguments the writer supplies;
  there is no transfer on that path. So no IMD comes back, nothing can be stranded, and the mock
  Intake (which keeps the 0.5 IMD) matches. `test_aFailedRequestLeavesEveryImdAccounted` pins
  invariant 1 across a failed request. The audit's suggested change (`feeImd += ORACLE_PRICE`
  when the balance shows a refund) is not made: it would credit any IMD sent to the contract by
  mistake to the fee pot on the next failure, a behaviour nobody asked for.

### Validation

```sh
forge build --sizes
FOUNDRY_FUZZ_SEED=0x906f674ec82bd2e74061fa6aef3b6c6756390329a66f79e32b26b24c14dfbc97 forge test
```

Imdex5 runtime 23,552 bytes (1,024 under EIP-170), initcode 26,127 bytes, nonpayable constructor
with no arguments that calls no contract; no DELEGATECALL, CALLCODE or SELFDESTRUCT. 177 tests
pass with the verifier's seed; the 7 mainnet fork tests skip without a fork URL (not run here).
Every suite uses local mocks and reads no environment. The protected floor's needs are
unchanged: one contract, zero ETH, no arguments, no owner or admin, nothing assigned to the
factory or to IMD.

## The previous revision: the code of 1668 with the 886e7c22 fixes, audited again

The repository arrived at commit `6ee29fbc` (launch 1668's code, the minimum-shares floor on
`mint`, and the fixes audit 886e7c22 asked for). The brief: deploy it as it is, fix every finding
of medium or above from the new audit with the smallest change, document the rest, keep
everything else. One contract, `Imdex5`, no constructor arguments, no owner, no launch token.

### Changes

1. **`src/Imdex5.sol`, `_mintMore`, residual branch (audit 3bd5e1aa, medium, reproduced and
   fixed).** The `catch` of the residual's `swapSelf` now does `revert BuyFailed(coin.token)`
   instead of falling through to the spot-price charge. The short-fill path (`got < need` after a
   swap that succeeded) is unchanged: the pool traded, and the price read after the buy is one the
   mint's own buy moved up to. Nothing else in the contract changed; the mint NatSpec already said
   a buy that fails reverts. Runtime 23,230 to 23,266 bytes.
2. **`test/Imdex5ResidualSpot.t.sol` (new).** The audit's reproduction, now asserting the fix:
   alice holds the whole index, the list drops coin 5 whose limited sale leaves a residual worth
   about 98 IMD, the attacker moves the residual pool's price down 1,000x and makes the index's buy
   revert (mock `dead`; on mainnet a hook rule or a swap that cannot finish inside `SWAP_GAS`), bob
   mints `shares = totalSupply`: the mint reverts `BuyFailed(coin5)`, bob keeps every IMD, `held`
   and `idleImd` are unchanged and alice's full redeem pays her the whole residual. Fuzzed over
   every dump factor up to a million and every size up to twice the supply. Two hook variants on
   MARG as a residual (a hook that burns all gas; one that leaves a delta unsettled) also revert
   `BuyFailed` and take nothing, and the mint buys the residual proportionally once the hook
   behaves. A dumped pool that still trades is bought in full (`held` grows by exactly the ceiling
   fraction, equals the balance, holders keep at least as much per share, idle grows by the issued
   fraction only), fuzzed. A short fill is charged at least the shortfall's fair value.
3. **`test/Imdex5Edges.t.sol`.** The test that pinned the old rule (a dead residual is charged at
   spot and does not block mint) now asserts the new one: `BuyFailed`, no IMD taken, redeem and
   redeemToImd keep paying the residual in kind, and the mint buys it again once the pool is back.
4. **`test/Imdex5.invariant.t.sol`.** Comment only. The mint handler already absorbs a reverting
   mint; a residual's short fill is still checked to be paid into idle.
5. **`test/Fix3.fork.t.sol`, `test/Fix3Floor.fork.t.sol`, `test/Fix3Rebalance.fork.t.sol`.** Each
   skips (`vm.skip(true)`) when the mainnet IMD address has no code. Before, a plain `forge test`
   with no network failed 7 of them (`EvmError: Revert` deploying against absent contracts); the
   acceptance criteria want `forge test` to pass with the project's own configuration and the
   verifier runs with no network. With `--fork-url` they run exactly as before.
6. **`README.md`, `THREAT_MODEL.md`.** Describe the shipped behaviour (the informational finding
   357a7068): `submit` checks the signed quorum and the validity window; a residual whose buy
   reverts blocks mint while a short fill does not; the low and informational findings are listed
   as documented limits. Runtime size and test counts updated.

### The audit's findings, reproduced

- **Medium, `3bd5e1aa…`: reproduced, fixed (change 1).** On the unchanged code, with the state
  above (residual of 9,607.79 coin 5 worth 97.95 IMD at the undisturbed price, pool dumped 1,000x
  and dead), bob's `mint(995e18, 100,000e18, 0)` succeeded: bob received 995e18 shares (half the
  index) for 944.03 IMD, `held[coin5]` was unchanged, and the residual half (fair value 48.98 IMD)
  was charged at 0.096 IMD into idle IMD. After the fix the same call reverts `BuyFailed(coin5)`
  and takes nothing. The successful-buy path was checked too: a dumped pool that trades delivers
  the full fraction, so holders are not diluted and the minter gains only what the pool priced.
- **Low, `be08f42a…` (a residual pool with no buy-side liquidity blocks mint through
  `TooExpensive`): not reproducible against the mock,** which leaves the price where a partial
  fill stopped rather than at the limit as v4 does; the reasoning about v4 is correct. Documented
  in README (Security notes) and THREAT_MODEL as a bound: a mint can request at most what every
  residual's pool can deliver. Not redesigned, as the brief asks for low findings. The audit's
  alternative (treat `got == 0` as `BuyFailed`) would not change the outcome on v4, where that
  case already reverts `TooExpensive`.
- **Low, `4acb1b2e…` (residual and idle charges use the requested `shares` after a list coin's
  short fill): reproduced by reading the code** (`need` for every coin is `held * shares /
  supply`; `minted` only lowers the idle contribution). Documented in README and THREAT_MODEL; a
  buyer who refuses a short fill sets `minShares`. Not redesigned.
- **Info, `357a7068…` (README out of date): reproduced, fixed by documentation (change 6).**
- **Info, `57e3696c…` (`submit` does not compare `requestId` or `questionHash`): confirmed as
  described,** no change of outcome; documented in README (Security notes).
- **Info, `f094a9a7…` (`ask` debits `feeImd` before the Intake pulls): confirmed as a trust
  assumption** on the version 2 Intake; documented in README (Security notes).

### Validation

```sh
forge build --sizes
FOUNDRY_FUZZ_SEED=0x2934a24a147e5e24f611da550ab8a7b8fb388d8b1ed6efb669d70fab713eec2a forge test
```

Imdex5 runtime 23,266 bytes (1,310 bytes under EIP-170), initcode 25,841 bytes, nonpayable
constructor with no arguments, no DELEGATECALL, CALLCODE or SELFDESTRUCT. 145 tests pass, 7 fork
tests skip without a fork URL; all suites use local mocks and read no environment. The fork
tests were not run here (no RPC); their code is unchanged apart from the skip guard.

The protected floor is unchanged in what it needs: one contract, deployed with zero ETH and no
arguments, no owner or admin, and so nothing assigned to the factory or to IMD.

## Changes and reasons

1. **`src/Imdex5.sol`, `_swap`:** measure the output-token balance immediately before and after
   `PoolManager.take`. Return and emit the increase, so `_mintFirst`, `_mintMore` and `_tryBuy`
   only credit actual receipts. This implements requested change 1 and fixes the reproduced
   transfer-tax accounting/last-holder finding.
2. **`src/Imdex5.sol`, `_mintMore` and mint NatSpec:** initialize `minted = shares`. For each
   nonempty holding whose buy delivers less than `need`, take the minimum with
   `Math.mulDiv(shares, out, need)` (rounding down). Reject a zero resulting amount with
   `BuyFailed(coin)`; this also rejects zero output because `need > 0` on this path. Mint and
   emit `minted`. Every executed buy and the existing fee are still paid. This implements
   requested change 2 without changing pricing, fee accounting, refund behavior or the public ABI.
   **Revision 2:** the idle IMD contribution is `Math.mulDiv(idleImd, minted, supply, Ceil)`,
   computed after the buys once `minted` is known, instead of the requested `shares`. The idle
   contribution is not a buy, so the brief's "the buyer still pays for every buy made" does not
   cover it, and charging the requested fraction for fewer shares was a systematic transfer to
   the existing holders on every mint while SwarmCity is listed (reproduced: 0.995 IMD on a
   100-share mint after a 1,000 IMD first mint with 495 IMD idle). Required by the review
   finding `a034ecce…`.
2b. **`src/Imdex5.sol`, `ask`:** when a new request opens, clear `answerHash`. An answer of the
   previous cycle that nobody submitted could otherwise be submitted, and rebalanced on, while
   the new request is open, so the index churned twice in one cycle on a week-old expired
   attestation (reproduced). The early return under 0.75 IMD of fees changes nothing, as before.
   Required by the review finding `fa8ae134…`; no new role, setting or parameter.
3. **`test/mocks/Mocks.sol` and new `test/mocks/PoolTaxERC20.sol`:** make the plain mock's
   `transfer` public/virtual to extend it, then add a mock that retains 2% of transfers whose
   sender is the PoolManager. It preserves the plain mock's storage and failure modes; index
   payments and pool settlement are untaxed. No production token or new dependency is added.
4. **`test/Imdex5.t.sol`:** retain the failed-buy assertion but replace the one-wei short-fill
   revert assertion with the expected reduced issuance, supply, receipt and balance checks.
5. **New `test/Imdex5ShortFill.t.sol`:** reproduce the audit's fourth-coin short fill; fuzz
   different shortfalls in every list position and assert the least fraction, backing for
   every holding, all buys' full cost, fees, refunds and `Minted` event. Verify zero-output
   buys, nonzero fills rounding to zero shares, and `maxImdIn` failures roll back earlier buys,
   shares, payment, fees and holdings.
6. **New `test/Imdex5TaxedCoin.t.sol`:** reproduce the first-mint overstatement and last-holder
   payout failure using the actual starting SwarmCity address. Exercise first mint, two later
   mints, a partial IMD exit, and in-kind redemption by each of three holders. Check
   `balanceOf(index) == held + sum(owed)` for every coin after each step, and independently
   bound every mint by the fraction of each holding actually added. The last holder receives
   all remaining coins; all coin balances, held, owed and idle IMD clear. Only the intentionally
   retained `feeImd` remains. Repeat this lifecycle with fuzzed amounts. Also verify net-output
   `Swapped` events, `mintFirst.minOut`, rebalance receipts, and a debt that stays backed through
   a later mint and can be claimed in full.
7. **`test/Imdex5.invariant.t.sol`:** update the mint handler's obsolete full-request issuance
   assumption to assert the delivered fraction using actual token balance changes, including
   the bound `oldHolding * minted <= received * oldSupply` for every holding. Retain all
   existing invariants, including `invariant_coinBalancesAreHeldPlusOwed`. Add an inherited suite
   running the same stateful sequences with the 2% SwarmCity mock as well as the plain suite.
8. **`README.md` and this file:** document each change, updated runtime size, actual receipt
   accounting, fractional issuance, payment consequences, audit evidence and validation.

The five initial coins and addresses, 0.50% fees, `feeImd`, `idleImd`, redeem, redeemToImd,
claim, fund, oracle question and flow, rewards, 25% rule and 2% stops retain their original
implementation. There is no owner, role, admin, setting, pause, upgrade, launch token, pool or
website added. The constructor and all other production files are unchanged.

## Imported audit findings

- **Critical — `ad6922bcd29010e53f2bd3be96444222566134e26a8429119dc4c6a01956c7d1`: reproduced.**
  Before the fix, `test_firstMintCreditsOnlyWhatArrives` observed
  `held[SC] = 19511716834983821943327` versus actual balance
  `19121482498284145504461`, exactly the reported values. Independently,
  `test_lastHolderCanReceiveEveryCoinAfterAnImdExit` observed the last holder receiving zero
  SwarmCity instead of `3921953132660064712227` units. The balance-delta fix addresses both.
- **High — `31ed5eca6a835a8650fce4020326d941263cbafa6e6dc06b1ca3c33c1a4b8bb2`: reproduced.**
  Before the fix, `test_shortFillMintsTheDeliveredFraction` reverted with
  `BuyFailed(0x54C68a4D0A21DBb1ad72FaA052db159d26F967EA)` for the fourth coin's 2% short fill.
  The fractional-issuance fix permits nonzero fills and preserves full payment for the buys.
- **Low — `3a80a3d9d6d3ec90dfdbb5d7f9e35de129d19ae1161c7bd37c0ceab25731bae3`: reproduced, with a
  citation correction.** The original 107 tests passed with the supplied seed despite the
  above failures. `test/Imdex5.t.sol` pinned the old nonzero short-fill revert; it is updated.
  The cited `test/Imdex5Revised.t.sol:40–42` actually tests a **zero-output first mint**, not a
  nonzero later-mint short fill. That case remains a required revert and is left unchanged.
  The new taxed-coin mock, lifecycle regressions and second invariant suite close the identified
  coverage gap. No application defect was dismissed as unreproducible.
- **Info — `83b7f0a5608d6208ed87e5305fc5f2a1e5b921279da2569d6311fe2baee924c1`: intentional behavior,
  confirmed by the new payment tests.** With a 2% SwarmCity tax, later mints normally issue about
  98% of requested shares, subject to integer rounding. The buyer still pays every buy, the
  idle contribution for the shares issued (revision 2) and the 0.50% buy-cost fee. Other receipts
  remain backing the index. The README explains that `maxImdIn` limits cost and
  `Minted.shares` is the actual issuance; no new minimum-share parameter is introduced.

## Independent review findings (revision 2)

Each was reproduced on the accepted tree with a scratch test before anything changed; the
answers are in `.imd-responses.json`.

- **Medium — `a034ecce04b48ed30150f0587157950fc2f790f4a640dd6037dda8b8b2041e44`: reproduced,
  fixed in part.** (a) Idle over-charge: with the taxed SwarmCity mock and 100 IMD swap caps,
  after a 1,000 IMD first mint (supply 995e18, idle 495e18) a 100-share mint issued 98e18 shares
  and charged `49748743718592964825` wei of idle IMD where the issued shares own
  `48753768844221105528`; the reported numbers exactly. Fixed by computing the idle contribution
  from `minted` (change 2, revision 2). `test_shortFillChargesIdleImdForTheSharesIssuedOnly`,
  `_mintAndCheck` in the taxed-coin suite and the invariant mint handler now assert it, and that
  the minter's pro-rata idle claim right after the mint equals its deposit to rounding.
  (b) Sliver fill: with coin 0 delivering 1e15 of 1.96e21 asked, bob paid
  `102705360721442885777` wei and received `50994999999999` wei of shares, as reported. This is
  the behaviour the brief's change 2 specifies ("the buyer still pays for every buy made") and a
  minimum-shares argument or threshold is a new safeguard the brief forbids, so it is not
  changed. The holders are never diluted (`held * minted <= received * supply` for every coin,
  asserted) and the minter is never over-issued. It is documented in the README's mint section
  so the requester accepts it knowingly, and `test_sliverFillIssuesASliverAndChargesEveryBuy`
  pins what is bounded.
- **Low — `fa8ae134b55f8950588f85d31a6c6fdb006b4c92ca62a3ac613408a9ae5ccc51`: reproduced,
  fixed.** After an answer was delivered and not submitted, a second `ask()` seven days later
  left `answerHash` in place; `submit` of the expired attestation succeeded while the new request
  was open, and `rebalance` moved the index to the stale three-coin list. Fixed by clearing
  `answerHash` when `ask` opens a request (change 2b). `test_aLaterAskReplacesAnUnsubmittedAnswer`
  now asserts the stale attestation is rejected the moment the new request opens, and
  `test_anUnsubmittedAnswerDoesNotSurviveAFailedLaterAsk` the failed-round case. Clearing at
  `ask` was preferred to an `expiresAt` check in `submit`, which would lose any answer not
  submitted within its one-day validity and leave the index waiting seven days for nothing.
- **Low — `aee12528f0bc6fdf6fba316d89c48b7a9d9a250e1a495e1fa0a1f298a548fa66`: reproduced,
  disputed (not changed).** A leftover whose pool is dead reverts every `mint` with the pool's
  error while `redeem` keeps working. This is the project's documented design: `mint` buys the
  fraction of every holding so a mint never dilutes a leftover's backing, and "a dead pool
  blocking mint (never redeem)" is accepted by the brief. Skipping the coin or paying its
  fraction another way is a new feature outside the two requested changes. The README now says
  explicitly that the acceptance covers a leftover, and that the way out is the pool working
  again and a rebalance selling it. `test_residualsAreRedeemedAndBlockMintWhileTheirPoolIsDead`
  already covers the behaviour.
- **Info — `4c473a96b373a84290409a95ac25989dc0aefef008d053e67f0549625acb11db`: reproduced,
  disputed (not changed).** Unsellable leftovers stay in `_coins` until sold, growing the loops
  by one coin each. Pre-existing in launch 1636, outside the brief, no accounting error, bounded
  by five leavers per weekly rebalance, `PAY_GAS` per coin in `redeem`. Documented in the README.

## Validation

The original code passed 107 tests. The added first-receipt, minimum-output, last-holder and
scripted-lifecycle tests failed against that code, as did the fourth-coin short-fill regression.
All tests use local mocks; no RPC, keys, environment secrets or network dependencies are needed.

Validation uses the requested seed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x6bb26254590bb38e9b4480c1eb0169dec48994a727877f3f2823a28b11fb9cf1 forge test
```

Results: `forge build --sizes` passed. Imdex5 runtime is **22,662 bytes**, with **1,914 bytes**
of EIP-170 headroom; initcode is 25,237 bytes. The full seeded test run passed **123 tests**
across eight suites, with no failures or skips. This includes all eight original conservation,
fee, supply, list and oracle invariants on both plain and taxed-coin sequences. A runtime scan
using the protected check's PUSH-data skipping rule found no DELEGATECALL, CALLCODE or
SELFDESTRUCT. The ABI confirms a nonpayable constructor with no arguments.

An additional local-only `test/scratch/DeploymentCheck.t.sol` rehearses CREATE2 deployment
through a factory with zero ETH and no arguments on chain id 1, with all configured external
dependencies absent, and checks runtime size and the forbidden opcodes. It passed. Scratch scaffolding
is excluded from submission as specified by the assignment. No fork, Slither or Mythril run is
claimed; the accounting evidence comes from deterministic, fuzz and stateful Foundry tests.
