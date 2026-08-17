# r/kourt/court — implementation plan (v2, after 3-subagent review)

The consuming realm composing the six audited `/p/` primitives into the court of
`COURTS_TOKENOMICS.md` (V4) and `COURTS_STRUCTURE.md`. **v2 folds in three
independent plan reviews that converged on the same load-bearing fixes** — recorded
inline as **[R]**. The primitives stay court-agnostic; the court holds every rule.

## 0. Trusted `/p/` (audited rounds 1+2, see AUDIT.md)

    checkpoint  grc20votes  governor  twap  cshares  tickbook

Two of them get a small, separately-audited extension for the court (below):
`cshares.CloseAt` (fractional close) and nothing else.

## 1. `p/kourt/curve/v0` — the bonding curve (build FIRST)

Linear, one-way, `p(s) = s/D`. **[R] `k` is a reciprocal denominator `D`, never a
numerator scale** — with a numerator `k·(s1²−s0²)`, a realistic `k≈1e9` gives
`1e9·(9.2e14)² ≈ 8.5e38 > 2¹²⁸` and the single `bits.Mul64` product overflows. As
`1/D` the numerator is only `s1²−s0² ≤ (9.2e14)² ≈ 8.46e29 ≈ 2¹⁰⁰`, always
128-bit-safe, and `D` sits in the divisor.

Pure functions over an externally-held **monotonic curve position** `s`
(= `curveMinted`, see §3); the curve holds no state:

- `Cost(from, delta int64) (coin int64, ok bool)` — `ceil((s1²−s0²)/(2D))` where
  `s1=from+delta`; `s1²`,`s0²` via `bits.Mul64` (128-bit), subtract, `ceil`-divide
  by `2D`. `ok=false` if `s1>MaxSupply` or the quotient exceeds `MaxInt64`.
- `Minted(from, coin int64) (delta, spent int64)` — **[R2] short-circuit: if `coin ≥
  Cost(from, cap−from)`, return `(cap−from, that cost)`** (buy the whole remaining
  curve), which bounds the isqrt operand to `cap²` and makes the huge-coin case
  explicit. Otherwise `s1 = isqrt(s0² + 2·D·coin)`, clamp to cap, then a **±1
  correction against the canonical `Cost`**: `for Cost(from,s1+1−from) ≤ coin: s1++`,
  `for Cost(from,s1−from) > coin: s1--`. `spent = Cost(from,delta)`.
- `isqrt` — **bit-by-bit 128-bit integer sqrt** (64 iters, division-free,
  deterministic), taking the `hi:lo` word from `bits.Mul64`/add.
- `Backing(s) = s/(2D)` — half the marginal price (scale-invariant; holds ∀ D>0).
- `D` is a construction parameter; the realm pins it from economics
  (≈1 GNOT-per-CC marginal near ~1M CC ⇒ `D≈1e9`).

**No-over-issue proof [R] (all three reviews agree):** `Cost` rounds UP so
`backing = Σ integral ≤ Σ charged = treasury`, always. `Minted`'s isqrt floors, so
`s1² ≤ s0²+2D·coin ⇒ (s1²−s0²)/(2D) ≤ coin ⇒ Cost(from,delta) ≤ coin` (coin is
integral, so the ceil still ≤ coin); the ±1 loop re-checks the canonical `Cost`, so
issued ≤ paid even if isqrt is off by one, and `delta=0` when one unit costs more
than `coin` — no free coin. The `Minted-re-verifies-Cost` step is **mandatory**;
without it an isqrt off-by-one over-issues.

**Deserves `/p/`:** yes — a 128-bit-safe monotonic bonding curve is reusable by any
one-way issuance token. The one-way policy (GNOT stays as treasury) is the realm's.
Process: converge design (isqrt + round directions), interrealm/security review,
implement, adversarial fuzz `Cost(s0,s0+Minted.delta) ≤ coin < Cost(s0,delta+1)`,
monotonic, no panic/brick at the cap, no purchase nets a free base unit.

## 1b. `cshares.CloseAt` — the fractional close (small, separately audited)

**[R] cshares is winner-take-all and cannot express "close at pre-answer TWAP p"**
(§3.7). ONE conservation-safe method, now BUILT (see §8, 3 tests):

- `CloseAt(id, num, den int64)` — freeze the claim at fractional price `p=num/den`
  (`0≤num≤den`), a new terminal status distinct from Resolved.
- `RedeemClosed(id, acct) int64` — pays `floor(y·num/den) + floor(n·(den−num)/den)`
  for the holder's YES `y` / NO `n`, clears the packed position, returns the coin.
  **[R2] `y·num` must not overflow int64** — use `pmkt.MulDivFloor` (128-bit) or
  bound `den` to the price grid (`den=100`), since `y` can approach the supply cap.

Conservation holds for ANY p: while open `ΣY=ΣN=supply`, so total payout
`= p·supply + (1−p)·supply = supply` — the same collateral a winner-take-all
resolve pays. Floor rounds toward the pool (dust safe). This gets its own
adversarial test (fractional conservation, p=0 and p=1 degenerate to Resolve).

## 2. Realm layout (`r/kourt/court/`)

    court.gno      Court type; per-court grc20votes + governor + curve position; params
    buy.gno        one-way curve Buy (GNOT in → CC), treasury, curveMinted
    claim.gno      claims: title + append-only body, folders/slugs, support/counter edges, deposit-escrow
    market.gno     per-claim cshares + tickbook + price/OI twaps + the escrow pools + OI ceiling
    answer.gno     answers + answer bond; answerDisputes + doubling dispute bond; pre-answer price snapshot
    dispute.gno    the non-reserved dispute Kind; court.Vote (intermediated); permissionless Resolve
    session.gno    weekly undisputed-settlement sessions; escrow windows; fees
    directory.gno  multi-court directory, tiers, min deposit (>0), promote/hide
    render.gno     Render(path) — sanitized, chain-carries-everything
    params.gno     governance-set params with the realm's hard bounds
    *_test.gno + integration testdata/*.txtar

**[R] One realm, many courts** (settled by STRUCTURE §2/§11, not open): each court
is realm-allocated state keyed by `courtID`, with its **own** `governor` instance
(the ~56-open-dispute ceiling is per-instance; a shared governor would starve
disputes). Directory + tiers + cross-court reads come free; cap courts/realm.

## 3. Composition — the wiring, with the review's corrections

- **courtcoin (CC)** = one `grc20votes.Ledger` per court. **Collateral IS CC** (1
  set = 1 CC base unit), so `X = cshares.Supply(claim)` is directly comparable to CC
  supply/turnout. The curve is the only mint.
- **[R] `curveMinted` monotonic counter** per court — the curve's position `s`.
  Buys increment it; **burns (failed-quorum forfeit) and pair-redeems NEVER
  decrement it**, or the price and inverse desync. Treasury = GNOT taken in.
  "Backing per coin" render = treasury / circulating CC (`grc20votes.TotalSupply`),
  which a burn correctly RAISES.
- **governor** per court, electorate = the court's CC ledger. **[R] votable nets
  escrow:** the court holds all escrowed collateral CC in one **escrow address**
  that never votes; the quorum floor uses `votable = PastTotal(at) −
  PastVotes(escrowAddr, at)`, computed at the **same `Epoch()−1`** the governor
  snapshots, same tx. **[R2] Exact only under V1 no-delegation** (then
  `PastVotes(escrow)=balance(escrow)`); revisit if delegation ships. Floor =
  `max(5%·total, min(1×X̄, votable/3))` fed via `ProposeWithQuorum`, with **X̄ read
  from the OI twap at the dispute-open height** and gated on a small `StaleBy` and
  `mature==true`. **[R3] V1 cut:** this floor drops §3.5's `0.9×warmth` adaptive
  raise and `fall(t)` decay — omitting `fall` is conservative (the bar never eases
  mid-vote); warmth is a deliberate V1 simplification to restore later.
- **per claim:** a `cshares` claim (YES/NO) + a `tickbook` book + a **price twap**
  (bpp=1, per-Take) + an **open-interest twap** (bpp=8, hourly, n=168; per-minute
  would overflow the sum-guard — twap round-1 F3). **[R] Observe on EVERY change:**
  OI in `MintSet/RedeemSet/RedeemClosed/RedeemWinning`, price after every `Take`;
  gate flash-sensitive reads on small `StaleBy`, observe at the read height, AND
  **[R3] require `mature==true`** — a partial-window average is flash-crossable
  (a young claim's min-OI-to-answer gate is otherwise defeatable).
- **[R] court-wide OI ceiling (§3.5a):** an incremental `totalOI` counter (bump on
  MintSet, drop on any redeem); refuse a mint past `0.2·CC-supply`. Never walk claims.

## 4. Court mechanics (from the tokenomics)

- **One-way curve Buy** (§2): GNOT in → `curve.Minted(curveMinted, gnotAsCC)` → mint
  CC, GNOT → treasury, `curveMinted += delta`. **[R] the court's own/treasury
  address may not buy.**
- **Claims:** immutable title + append-only chunked body; folder-claims w/ slugs;
  support/counter edges (counter inert). **[R] deposit-escrow ledger:** record who
  paid each claim's (never-zero) deposit; a sweep repays the RECORDED payer, never
  the tx sweeper (STRUCTURE §9.3 / attack table).
- **Answers** (§3): one answer, single-funded, bond `min(50%X, gov-cap)`. **[R2] the
  min-open-interest-to-answer gate reads the OI TWAP X̄, not instant `Supply`** —
  instant supply is flash-crossable (§3.5a mandates the trailing average here).
  **[R] snapshot `preAnswerPrice = priceTwap.Average(...)` as a CLAIM-level scalar,
  set once at the FIRST answer ever and never overwritten on re-answer** (the
  rolling window rolls off over 3 rounds ≈ weeks; a per-answer snapshot would
  contaminate the 3-round `CloseAt` source); immature/stale → equal split.
- **AnswerDisputes** (§3): co-fundable (lazy bptree of `(claim,round,funder)`), bond
  `max(gov-min, 20%X)`, **doubling per failed round** (keyed to per-claim
  `failedRounds`: base, 2×, 4× = 7× total). A dispute **bypasses sessions** (§3.2b)
  → `ProposeWithQuorum`, `VotingBlocks = 7d = 120960 blocks`, `DelayBlocks ≈ 0`
  (escrow is the real timelock), **[R3] `GraceBlocks` MODEST** so a won-but-unexecuted
  proposal's slot frees via `Sweep` rather than pressuring the 56-slot ceiling;
  a reopen re-proposes with a fresh round index (see §4a).
- **[R3] Resolution & reopen model — CONVERGED across three review rounds.** The
  dispute vote asks **"overturn the answer?"** (yes = overturn). The dispute Kind is
  **court-declared and NON-reserved** (a `govern:` name caps at 8 gov-lanes, not the
  56 `maxOpen`); its `Do` is unused for a V1 verdict. **`ThresholdBps = 5001`, NOT 0**
  — at 0 a lone yes-voter holding the floor flips the proposal to Succeeded the
  instant they vote (freezing the tally, buying the verdict); at 5001 early-settle
  fires only on a >50.008%-of-supply landslide, so the 7-day sealed window holds.
  - **Per-round unique payload.** Open each dispute with `ProposeWithQuorum(who =
    court address, payload = claimID|round|nonce, floor)`. **[R3-A] The round index
    is load-bearing:** the plan never calls `Execute`, so a Succeeded proposal keeps
    its `openIdx` slot for its whole grace window — a reopen reusing the same payload
    would panic "identical proposal already open" and defeat the escrow safety net.
    A fresh round index makes each reopen a distinct proposal.
  - **court.Vote(claim, choice)** → `governor.Vote` (sole roll authority), recording
    per-**proposal-id** `{yes,no,abstain}` sums + per-`(proposal,voter)` choice+weight
    rows, weight `= PastVotes(who, EpochOf(pid))`. The court does NOT surface the live
    tally until the vote closes (§3.4).
  - **court.Resolve(claim)** (permissionless; only when the claim's CURRENT-round
    proposal has `State != active`; rejects a superseded round). **[R3] Re-derive the
    verdict PURELY from the frozen `Tally`+`QuorumFloor`** — never the `State` string
    (Execute/Settle are permissionless, so a won proposal can already read
    executed/expired). `cast = yes+no+abstain`:
    - `cast < floor` → **FAILED-QUORUM round**: disputer forfeits (½ answerer-comp / ½
      burn via `grc20votes.Burn`), `failedRounds++`, no voter pay, still disputable;
      **3rd → provisional close at `preAnswerPrice`** (`cshares.CloseAt` at Finalize).
    - `yes>0 && yes·10000 ≥ (yes+no)·5001` → **OVERTURN**: provisional = opposite of
      the answer; disputer wins (bond + comp); fees paid (60% all / 40% overturn).
    - else (quorum met) → **UPHOLD** (tie, all-abstain, razor, no-majority all land
      here): provisional = the answer; disputer forfeits bond to the answerer;
      adjudication fee charged; `failedRounds` NOT incremented (quorum met = terminal).
    Resolve records a **PROVISIONAL** verdict + fee snapshot + `escrowUntil = now +
    clamp(1wk + 1d/500-GNOT-of-X̄, 1wk, 3wk)`; it does NOT touch cshares.
  - **Reopen** (only while `now < escrowUntil`): opens a NEW-round dispute (unique
    payload, doubled bond) whose vote can flip the provisional verdict before shares
    lock; may extend the lock by one 7-day vote, bounded by the 3-round close.
  - **court.Finalize(claim)** (permissionless; only when `now ≥ escrowUntil` AND **no
    ACTIVE dispute vote** on the claim — a slot-holding-but-closed proposal does NOT
    block it) does the IRREVERSIBLE `cshares.Resolve`/`CloseAt`, enabling
    `RedeemWinning`/`RedeemClosed`. Deferring the irreversible step past escrow is
    what lets a reopen overturn a wrong verdict first.
  - No sub-realm identity is needed for a V1 verdict — resolution mutates the
    court's OWN `/p/` ledgers under the court's authority. `cur.Sub(kind)` is
    reserved for the DEFERRED GNOT-payout kinds.
- **[R] Fees need a data source the governor doesn't expose** (the roll is
  deliberately non-enumerable). **Voting is court-intermediated:** `court.Vote(claim,
  choice)` forwards to `governor.Vote` (the sole roll authority — a double-vote
  panics and atomically rolls back the court's record) AND records per-claim
  `{yes,no,abstain}` weight sums. **[R2] Record `w = ledger.PastVotes(who,
  governor.EpochOf(id))`** (the proposal's SNAPSHOT epoch, not `Epoch()−1`
  recomputed at vote time, or the sums desync from the tally). The court exposes NO
  non-intermediated vote path. The sums are only the DENOMINATORS; per-voter
  NUMERATORS need durable per-`(claim,voter)` rows (choice + weight). Fees are
  pull-based: adjudication
  `min(3%X, 200 GNOT)` **skimmed from collateral** (winning shares redeem at
  `1−feeRate`; the remainder is a pull pool: 60% all voters / 40% winning voters,
  divided by the recorded sums); settlement ~1% on the **undisputed path only** —
  never both in one resolution.
- **Failed quorum:** disputer forfeits — ½ answerer-comp, **½ burn** (`grc20votes.
  Burn`; monotonic `curveMinted` unaffected). No turnout pay (ugnot never pays
  voters — the whole V4 quorum design).
- **Sessions** (§10): weekly (`120960` blocks) settlement of UNDISPUTED answers only;
  eligible at first session `≥ answerHeight + 72h(51840 blocks)`; permissionless
  `Settle(claim)` writes the verdict, starts escrow `clamp(1wk + 1d/500-GNOT-of-X̄,
  1wk, 3wk)`. Reopen does NOT restamp `escrowUntil`.
- **Directory** (§8): tiers, **never-zero** min claim deposit, promote/hide (admin).

## 5. Payment & security guards [R] (realm is a /r/ with crossing functions)

- **Only two GNOT inflows:** curve `Buy` and the court-start deposit. Each crossing
  entrypoint: `cur.IsCurrent()` → `cur.Previous().IsUserCall()` (**NOT `IsUser()`** —
  a `maketx run` realm would consume the OriginSend envelope) → read
  `banker.OriginSend()`. Refuse the court's own/treasury address on Buy.
- **Bonds and fees are CC**, moved by `grc20votes.Transfer(from = cur.Previous().
  Address())` after `cur.IsCurrent()` — no OriginSend concern.
- **Never `import chain/runtime/unsafe`.** Never read `PreviousRealm()` in a crossing
  fn without `cur.IsCurrent()` first.
- **[R] Reach `governor.Execute` NON-crossing** so `cur` stays topmost for any future
  `cur.Sub` dispatch (a crossing Execute makes `cur.Sub` panic).
- **[R] No returned `/p/` interior pointers** — never hand back `*Book`, `*Ledger`,
  `*Governor`, a `twap.Ring` by pointer, or a `*claim`/`*Court` with exported
  mutators (borrow rule #2 runs the mutator under the court's authority). Reads
  return values/copies only.
- **[R3] Authenticate the actor on every redeem/collect.** cshares and tickbook
  TRUST the acting address, so the court's redeem/collect/cancel crossing-functions
  must pass `cur.Previous().Address()` (after `cur.IsCurrent()`), never a
  caller-supplied address — otherwise anyone drains anyone's position.
- **[R3] Do not surface the live dispute tally.** The governor exposes `Tally`/its
  Render while a vote is active; the court must NOT expose it before the vote closes
  (§3.4 sealed-vote), or votes become strategic.

## 6. Render / read contract (for the website)

**[R] Sanitize is normative (STRUCTURE §8.4):** titles/slugs/folder/section names
through `sanitize.InlineText`/`TableCell`; bodies/charters wrapped in `gno-foreign`;
no body inside a list; page every user-controlled scan. The chain carries all the
information; the overlay only prettifies. Enumerate the read methods each of the 10
wireframe screens needs and make `Render(path)` (or typed reads) supply them; every
action a `txlink`, never a private API.

## 7. Testing — two-ledger conservation [R]

An invariant harness over RANDOMIZED op-sequences asserting **after every op**:
- **GNOT:** `Σ intake == treasury` (one-way — GNOT never leaves in V1).
- **CC:** `curveMinted == Σ balances + Σ set-collateral + Σ bid-pool + Σ bonds + Σ
  session-escrow + feePool + Σ burned`.
- **shares:** per-claim per-outcome `Σ == supply`; ask-pool shares == Σ resting asks;
  bid-pool coin solvent.
- `X == cshares.Supply`; `totalOI ≤ 0.2·supply`; each pool ≥ its obligations.
Plus: curve round-trip fuzz; each STRUCTURE §6 attack (sweep-refund, escrow-vote,
flash-mint→redeem moves X̄ < ~2 CC); min-order-size; cancel-after-partial;
reopen-in-escrow (no new fee, clock unchanged); bond-doubling ladder (7×); a
self-dealing fee farmer nets only pro-rata; the fractional close pays the snapshot.
Unit tests per file; `.txtar` for the full buy→claim→mint→trade→answer→dispute→
vote→resolve→redeem lifecycle. `make realm-test` green after each package.

## 8. Build order

1. `p/kourt/curve/v0` [BUILT — 12 tests, reciprocal-D + fill-to-cap guard +
   Minted-verifies-Cost] + `cshares.CloseAt`/`RedeemClosed` [BUILT — 3 tests,
   128-bit `mulDivFloor`, conservation verified]. Both `make realm-test` green.
2. `r/kourt/court` bottom-up (11 tests so far, make realm-test green):
   **court/params ✓** (Court+Params+directory+StartCourt) → **buy ✓** (one-way curve
   Buy: IsUserCall+OriginSend guard, monotonic curveMinted, treasury, refund) →
   **claim ✓** (title + append-only chunked body, deposit-escrow, author guard) →
   **market ✓ (collateral half)** (MintSet/RedeemSet, 20% OI ceiling, OI-twap
   observe-on-every-change; priceScale=100 → a set = 100 CC, book prices integer CC)
   → **book ✓** (RestSell/RestBid/TakeBuy/TakeSell/Collect/CancelOrder with ask/bid
   escrow pools; tickbook gained `OrderTick`/`OrderSide`; price-twap observed each
   take) → **answer ✓** (PostAnswer: bond min(50%X̄,cap), answerability = mature OI
   X̄, pre-answer price snapshot once) → **dispute ✓** (dispute Kind ThresholdBps=5001
   adopted per court; OpenDispute+bond+quorum-floor via ProposeWithQuorum;
   VoteDispute intermediated; **ResolveDispute reclassifies from the frozen Tally**:
   failed-quorum / overturn / uphold, with bond conservation; provisional verdict +
   escrowUntil; FinalizeDispute gated on escrow+no-active-dispute → cshares.Resolve;
   RedeemWinning/RedeemClosed — full lifecycle tested) → [next] session/fees →
   directory → render. **Deferred increments** (same classifier, fields already in
   place): reopen/bond-doubling/3-round-CloseAt; the 60/40 adjudication-fee split
   (needs the per-voter rows); the X̄-scaled escrow-window clamp. **Owed:** an
   adversarial two-ledger conservation audit of the bond/escrow/pool flows.
3. Website (Phase C, parallel) against §6's read contract.

*Converged decisions above resolve the v1 §8 open questions; no open criticals
remain. One confirming 3-subagent review of this v2, then build.*
