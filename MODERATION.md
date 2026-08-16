# MODERATION.md — render-layer moderation, the meta court, and seeding

> **STATUS: v0.6 — round-5 vet ingested (2 lenses; 1 HIGH + 1 MED-HIGH, both
> breaking a v0.5 delta; verification lens returned CONVERGED with 2 LOW nits).
> VETTING; round 6 re-checks only the two v0.6 deltas — the multi-candidate
> ballot election and the pending-list honesty correction.** Trajectory:
> severity ceiling CRITICAL(r1/r2)→HIGH(r3/r4/r5), attacker HIGH-counts
> 2→2→(1 HIGH+1 MED-HIGH), findings converging on one root principle (below).
> The election has been the fix-of-fix locus (r3→r4→r5); v0.6's multi-candidate
> ballot is structurally different — it removes the *scarce excludable slot*
> every prior break exploited, so it should terminate the chain. Additive to
> launch-cleared V2 (PLAN v0.40; see the drift note and §13.1). PLAN/REGULATIONS
> edits deferred to integration (§15).

> **The root principle (four rounds earned it):** *address-keyed defenses fall
> to sybils; only capital-keyed, deadline-keyed, or residency-keyed defenses
> hold.* The round-2 per-address participation-slice bug, the round-4 election
> camp, and the round-4 pending-list flood are one bug. Every discovery-surface
> defense here is therefore priced (capital), ordered by actionable deadline
> (which a mill cannot manufacture without exposing the row to slashing), or
> balloted among bonded candidates — never gated by address identity.

> **Drift note (PLAN v0.40):** the live branch adopted a **draw-proportional
> anti-mill slash** — `slash = min(bond, max(4.5%·X̄, 1.6·midGross))`
> (`slashSizeFor`, quality.gno) — and a `SettleUndisputed` no-conclusive-low-
> tier-reset fix. §8's `settleSlash` phantom-params bug is **confirmed still
> live post-v0.40** (it changed slash *size*, not the top-up base); re-express
> §8's fix against HEAD's `slashSizeFor` at build. Reuse the other session's
> just-landed read-only queries: **`SettleDeadline`** (= `answerHeight +
> settleDelay`) is exactly the strip's deadline key; **`ClaimStatus`** gives
> most of a strip row's status line (add flag-slot + redaction state).

## 0. Posture

Owner-directed scope (2026-08-16): a global moderator DAO that can hide courts
from the front page; per-court moderator sets that can hide items; a META court
deployed by default overriding any court's moderators; cheap moderator seeding;
an edit story for claim text. Owner position overridden with consent: **staked-
on text is never rewritten** — edits close at first stake; after, annotate.

Anchors (rounds 1–4):
1. **Discovery is economics** — money paths never read moderation state
   (I1/I2), yet hiding shapes who polices, and V2's junk defense is discovery-
   driven. Hence the policing surfaces (§5.3).
2. **Every discovery surface needs the full armature** — deadline ordering +
   per-actor caps + pagination + a priced entry door. The strip *and* the
   pending list both carry it (round 4: a half-armored surface just relocates
   the flood).
3. **The constitution bends in exactly two places, both legal-hold** — row-
   level **purge** and the **OpenClaim gate on purged courts** (§3.2).

## 1. The change in one paragraph

V2 already has the germ: `directory.gno` curates courts into
hidden/listed/featured tiers under a single `directoryAdmin`, "a hidden court
still works for anyone holding its address; moderation, not custody." This plan
generalizes that into a constitution and extends it downward (per-court item
moderation), upward (a meta court as the appeals layer, built from the court
machinery), and sideways (folders, seeding, a polish window). Moderation gains
one power — controlling *discovery* — plus two legally-forced exceptions, and
zero power over money.

## 2. The constitution — `REVISED (rounds 1–4)`

> **Moderation authority is render-layer authority. No moderation state is
> ever read by a money path to change a money outcome, no moderation entrypoint
> ever writes money state, and no moderation act may remove a claim from ALL
> discovery surfaces while it is still policeable.**

- Hidden ≠ voided: full lifecycle byte-identical (**I1**). Purge/redaction
  touch *text*, never lifecycle: votes proceed on tombstones; refunds and draws
  run unchanged.
- **Direction of dependency (round 4, F5)**: moderation → money is forbidden
  (I2); **money → moderation is permitted and unavoidable** — Gno has no
  observer/event hook, so `PostAnswer`/`Crystallize`/`provCloseClaim`/
  `CloseDeadClaim` must *call into* the moderation module to write strip/
  pending/parse state and to read the per-target latch. That is
  constitutional **iff those calls (a) never panic** (a moderation-side
  invariant must never be able to block a lifecycle transition) **and (b) the
  one money-gating read — PostAnswer's refuse-if-latch-held — reads only the
  latch, never a hide bit or a money-derived value.**
- **Read gates, now four (round 4)**: `OpenClaimSeeded` reads set+suspension;
  `OpenClaim`/`OpenClaimSeeded` refuse on a **purged court**; the strips read
  moderation state to *include*, never exclude; **`PostAnswer` on the meta
  court reads the per-target latch (refuse-if-held) — meta-court-local**.
  **Build guardrail**: the purged-court gate touches ONLY
  `OpenClaim`/`OpenClaimSeeded` — never `PostAnswer`/`Stake`/withdraw.
- Reachability (**I3**): deep links + per-claim positions render under
  courtMod/meta bits (banner); the **global** bit is all-surface text
  redaction (§3.2); money state/IDs/deadlines render everywhere. No on-chain
  "all my claims" index; clients enumerate via claim-lane events (no user
  text).
- Every act is attributed, **category-coded** (global-bit + purge) or reasoned
  (≤200 chars, sanitized; courtMod/meta editorial), evented (actor, act code,
  target, height, reason **hash** — never text), logged (**I6**).
- **User-text inventory** (purge must reach every row): claim titles;
  annotations; relabels; mod-log reasons; folder names/descriptions; **court
  names** (length-cap **added to the court.gno diff** — round 4 F1). Election
  proposals: addresses-only. Slugs: unpurgeable routing keys, aliased by
  whole-court purge.

**Exhaustive audited-file diff** (none change money math):

| audited file | edit |
|---|---|
| `stake.gno` | polish-window gate on Stake (Unstake redundant, kept as defense) |
| `court.gno` | `Params.stakeOpenDelayBlocks` + `mustSane` (I7); `StartCourt` grows the delay param + **name length-cap** + a burned-GNOT creation fee (`IsUserCall`+`OriginSend`+refund → keyless sink `…courtv2:burned`; makes StartCourt **user-call-only** — a composability change) + reserved-slug `meta` refusal; `startCourt(admin,slug,name)` extraction takes **no payment** |
| `answer.gno` | priority re-anchor (§9); **`PostAnswer` writes (non-panicking): strip entry, seeded/pending move, persisted binding parse; and reads the per-target latch (refuse-if-held)** |
| `crystallize.gno` | seeded gate on author draw AND `AuthorBonus` (I5); `openBlocks` re-anchor; strip exit |
| `quality.gno` | `settleSlash` bounty base = actual recorded burns, re-expressed vs v0.40 `slashSizeFor` (§8) |
| `dispute.gno` | strip exit in `provCloseClaim` |
| `claim.gno` | `OpenClaimSeeded` + pending entry; **title-edit entrypoint** (rewrites stored parse + pending enter/exit — **no latch op**, round 4 F4); pending drop in `CloseDeadClaim`; purged-court gate on OpenClaim; claim-lane events |
| `directory.gno` | `directoryAdmin`→global-DAO migration; `SetTier` logged/evented |
| `moderation.gno`/`modvote.gno`/`folders.gno`/`meta.gno` | new modules (state homes §4) |
| `session.gno` | none (re-verified vs the v0.40 `slotConsumed` tier-reset guard) |

## 3. The three authorities — `REVISED (rounds 1–4)`

Union of bits (courtMod/meta/global) + per-court suspension flag + purge rows.
Each authority sets/clears its own bits; meta clears the courtMod bit by
verdict; **global clears any bit AND the suspension flag** (recovery). Nobody
clears the global bit but global; nobody reverses a purge.

### 3.1 Court moderators (per court)

- Per-court set; render-layer powers: hide/unhide (own bit), annotate/relabel
  (§6), folders (§7), seeding (§8), polish acts (§9).
- **Appointment**: the creator (`Court.admin`) bootstraps the set until a
  **replacement election** passes; passage installs the elected set, unseats
  the creator's appointment power, clears the suspension flag, and resets the
  bond ladder. Dark set → another election (quorum nets escrow, so viable).
- **The election** (court-local sealed tally, `modvote.gno`; no governor
  slots; the quality-vote idiom). Rebuilt three times (r3 latch-camp → r4
  per-proposer-sybil → r5 auction ballot-veto); v0.6 removes the property every
  break exploited — **a scarce slot capital could win to *exclude* a proposal
  from the vote**:
  - **latch = per-court (one open election window)** — pinned; a per-proposer
    latch splits quorum across concurrent elections.
  - **multi-candidate ballot; bonds ADD candidates, never EXCLUDE one**
    (round 5 F1 — the auction let a capital-dominant but vote-*minority*
    incumbent, or a pure griefer, win the latch and run a doomed status-quo
    proposal, so the community's real proposal was never voted → capital
    overriding a vote majority, defeating the recovery §3.1 exists to protect).
    When the latch opens, a fixed **nomination window** (≈1 day) collects
    **all** bonded candidate-sets onto **one ballot** (each candidate costs the
    bond, capped per election); **"retain the current set" is the implicit
    floor**. The electorate votes by **approval** (approve any number of
    candidate-sets — approval, not plurality, so adding a candidate cannot
    split a majority). A set installs iff it clears **5001 bps of approving
    weight AND the quorum floor**, highest-approval among those that do;
    otherwise the current set is retained (fail-safe on indecision). Capital
    can *place* a candidate, never keep one *off* — a vote-majority always
    reaches its decision.
  - weights: `PastVotes` at the epoch **pinned at nomination-window open**
    (governor idiom, not the answer-time qualityEpoch); quorum floor
    **max(1, 5%·(PastTotal(at) − PastVotes(escrow, at)))** (escrow = the realm
    address; netting it is the election's own rule, analogous to the dispute
    floor's votable arm); length `votingBlocks`.
  - **per-candidate bond scales with court size**: `max(flagMinCC,
    β·PastTotal(at))` (a flat 1-CC bond can't deter spamming a large court's
    ballot); β a frozen constant. A candidate's bond **returns if it installs
    or is approved above the quorum floor, half-burns otherwise** (deters
    throwaway-candidate spam without taxing serious nominations); a fully-failed
    election (no candidate cleared) starts a per-court `flagCooldownBlocks`
    cooldown. No withdrawal path.
  - **I2 carve-out**: candidate-bond legs move the poster's *own* CC to escrow
    and burn on failure — the one money write a moderation-adjacent entrypoint
    makes (the flag lane's bond legs are identical).
- Meta may **suspend** a set: bits masked at render (kept); **all set writes
  refuse except clearing own bits**; elections stay proposable; `unsuspend`
  requires the voted route.

### 3.2 The global moderator DAO (realm-wide)

Generalizes `directoryAdmin` into an admin-managed set. Verbs:
- **court tiers** (existing `SetTier`, logged/evented);
- **global hide = all-surface text redaction** (strips, deep links, positions:
  banner + IDs/state/deadlines/money, no user text). **Single-key to set**
  (legal speed); reversal is an explicit logged global act, never
  silence/timer/meta; **reason strings are category codes only**. This is the
  DMCA disable-access verb (put-back = manual clear; purge never the DMCA
  verb). **Re-set rule (round 4, F5 — disjunction resolved)**: re-setting a
  redaction that a global act cleared **within the §512(g) counter-notice
  window (~10–14 business days) requires m-of-n**; outside that window a fresh
  notice is a fresh single-key hide (speed preserved).
- **clear-any**: any bit, any suspension flag.
- **purge — row-level, m-of-n**: tombstone any single §2-inventory row (scope,
  id), category-code reason, irreversible, unappealable, never touches a vote
  or lifecycle (I1/I2).
- **whole-court purge**: all text tombstones (incl. future rows), name
  tombstoned, slug aliased `court-<n>`, routes serve money — plus carve-out #2:
  **OpenClaim/OpenClaimSeeded refuse on a purged court** (unwind stays intact:
  unanswered stakers `Unstake` anytime; answered claims reach a verdict via
  permissionless settle/finalize/provClose then withdraw).

**Operating rules** (rendered): (1) legal takedowns use global-bit/purge only;
(2) runbook: notice/knowledge → single-key global hide + evidence snapshot;
hosting-is-offense → m-of-n purge within 72h + NCMEC; DMCA stops at hide;
(3) courtMod hides citing illegality escalate to global review; (4) global-bit/
purge never editorial.

### 3.3 The meta court (the appeals layer)

- **A court** — own CC, own electorate, its **own** 56-slot governor pool
  (appeal-dispute pressure never spills to other courts), created at realm init
  under reserved slug `meta` (refused to `StartCourt`), undeletable, listed.
  Init calls `startCourt(admin,slug,name)` with the deployer
  (`unsafe.OriginCaller()`) as admin.
- **Bootstrap truth**: zero supply → inert; one buyer → appeals pass by
  silence. Deployer genesis buy sized to stay **vote-dominant** (the real
  security parameter; the route gate is forgery-able), earmarked to dispute
  junk appeals (**+EV only while dominant** — and note §13.4: near-zero
  emission neutralizes this +EV while raising the forgery price to ~20%·X̄).
- Reserved schemas (strict parse; near-miss → "not a valid appeal" badge):
  `mod:unhide:<c>/<id>` · `mod:clear:<c>/<id>` · `mod:hide:<c>/<id>` ·
  `mod:suspend:<c>` / `mod:unsuspend:<c>`.
  - **Parse = stored structured state** in `meta.gno` (keyed by claimID, not
    the shared `claimState`): written at open, rewritten on each edit. **Purge
    marks the stored parse render-only / non-bindable** (round 4 F3, resolving
    the "surviving purge" ambiguity): a purged parse still *renders* verb+target
    on redacted rows (category-code-class speech, so the appeal's electorate
    isn't blinded), but cannot *bind* an execution.
  - **The binding persists at `PostAnswer`, only from a non-poisoned stored
    parse; if the parse is poisoned/invalid at answer, no binding persists and
    no latch is acquired.** `ExecuteMetaVerdict` executes only from a persisted
    binding.
  - **Per-target latch binds at `PostAnswer`** (not open); pre-answer the
    pending-list banner shows "appeal pending" with no lock; **first-to-answer
    takes the latch**. The **title-edit entrypoint does NOT touch the latch**
    (round 4 F4: edits are provably pre-answer — the edit window closes ≥2,160
    blocks before any answer can land — so the only edit-time membership ops
    are stored-parse rewrite + pending enter/exit; an edit that acquired a
    latch would reopen M-A32).
  - **Latch releases** at verdict-final when the verdict is **non-executable**
    (NO / route-gated / no-op), and otherwise at Crystallize/provClose/
    CloseDeadClaim (round 4 F4: the `executedAt`-window hold is only needed for
    an executable YES — this cuts a griefer's firm hold from ~10d to ~3d and
    removes the dispute-prolongs-hold perversity). A **restorative** appeal may
    proceed under an **aggressive**-verb latch-holder (the griefing victim's
    lane is never blocked by the griefer's pre-latch).
- **Execution** (`ExecuteMetaVerdict(metaClaimID)`, permissionless). **Fixed
  check order** (round 4 F6 — validity before state, so a non-final call can
  never stamp anything): (1) target exists & strictly predates `openedAt`;
  (2) a persisted binding parse exists; (3) `Verdict()==YES` (the `provisional`
  field, non-provClose — note `route`'s third value `"closed"` is excluded
  here); (4) aggressive verbs (`hide`/`suspend`/`unsuspend`) require
  `route=="vote"`; (5) **not already executed** (a per-appeal `executed` flag
  in `meta.gno` — round 4 F1, the exactly-once guard); (6) staleness; then
  apply, set `executed`, and stamp `executedAt` **at most once per appeal**.
  - **Exactly-once (round 4 F1, HIGH)**: without it, guard-1's "no-op success
    still stamps `executedAt`" let anyone re-call a settled restorative appeal
    every `votingBlocks−1` to *perpetually* extend the moderator's re-hide
    cooldown — the M-A21 livelock mirrored onto the mod side. The `executed`
    flag makes a second call a no-op that **stamps nothing**.
  - **Staleness, actor-scoped + direction-scoped (round 4 F2, MED-HIGH)**: the
    verdict binds the authority, not the individuals, and executes against the
    *current* set. Only **election passages** stamp the refusing field
    `lastElectionAt`; respondent self-acts never refuse. **For `unhide`,
    staleness = `lastElectionAt < openedAt` only** — a third-party *clear* (a
    global clear-any, another meta unhide) is same-direction as the verdict, so
    it must not refuse (v0.4's `bitLastAct_by_others` term wrongly killed a
    still-needed unhide when the mod re-hid after a global clear, handing a free
    re-hide). The general `max(bitLastAct_by_others, lastElectionAt) <
    openedAt` form is kept **only for suspend/unsuspend**, whose flag genuinely
    takes opposite-direction third-party writes.
  - **No-op executions stamp nothing (round 5 hardening)**: an `unhide` whose
    target bit is already clear is a true no-op — it sets `executed` (exactly-
    once) but does **not** stamp `executedAt`, so it starts no re-hide cooldown
    on an item that was never hidden. Closes a pre-emptive-hide-block residual
    (a chain of fresh passed `unhide` appeals on an always-visible item can no
    longer hold a courtMod's hide-ability off), and tightens M-A39's spirit:
    `executedAt` reflects only real transitions.
  - **`executedAt` cooldown**: the respondent may not re-transition the bit **in
    the reversed direction** for one `votingBlocks` (re-hide blocked after a
    *real* `unhide`; clearing own bit stays open). Enforced at the courtMod hide
    entrypoint; global-DAO verbs and later meta executions exempt (**guard 5
    cross-ref, round 4 F7**: a mod who is also a global member can escape a lost
    war via the single-key global bit — bounded by attribution + category codes
    + the m-of-n re-set window + operating rules; accepted as intended
    supremacy).
- **Asymmetric supremacy**: meta never clears the global bit / reverses purge;
  global clears meta's bits/suspensions. Meta is moderated by its own set +
  global. No fourth layer.

## 4. Moderation state — `REVISED (round 4)`

Per claim (`moderation.gno`, keyed by claimID): hide word (3 bits + per-row
purge flags); per-bit `lastActHeight` split by actor class (so respondent acts
don't set the refusing stamp) + `executedAt`; append-only act log with a
**monotone row id per entry**; `stripEnteredAt` (idempotent index key). Meta-
side (`meta.gno`, keyed by claimID): stored parse (with a non-bindable/purged
flag), per-target latch, per-appeal `executed`. Per court: mod set + set-level
`lastActHeight` + `lastElectionAt`; suspension flag + `lastActHeight`; folders;
tier; election latch/ballot/candidate-bond state; **the per-court policing index AND
pending list, each carrying the full armature** (deadline order, per-actor
caps, page cap). Realm-level: one global policing index + a courts-with-entries
structure for the directory strip.

Indexes write at the **membership sites only**, never vote sites; per-row
status reads live at render (reuse `ClaimStatus` + flag-slot state + bits).
Routes carved before the numeric-ID parse: `<slug>/mod` (paged log); the
strips; the pending list; a paginated **read entrypoint** for pages beyond the
first on **all three** surfaces.

## 5. Hiding: exact render semantics — `REVISED (rounds 1–4)`

### 5.1 Discovery surfaces (bits apply)
Court-page listings, folder listings, featured strips, the directory.

### 5.2 Non-discovery surfaces
Deep links + positions always render under courtMod/meta (banner); under global,
redacted (money/IDs/deadlines, no text); purged → tombstones. Money everywhere.

### 5.3 The policing surfaces — the load-bearing guarantee — `REVISED (round 4)`

Two indexed strips (per-court + directory) plus a per-court **pending list** —
**all three carry the identical armature** (round 4 F2: a half-armored surface
just relocates the flood).

- **Membership**: strip entry uniformly `PostAnswer`; span `frozenAt != 0 &&
  !crystallized && !provClose && !closed`; exits Crystallize/provClose/
  CloseDeadClaim. Pending list: unanswered `mod:` appeals + unanswered seeded
  claims enter at open, **move to the strip at `PostAnswer`**, drop at
  `CloseDeadClaim` (its only two transitions). `stripEnteredAt` makes entry
  idempotent (no list→strip double-row).
- **Ordering: ascending actionable deadline (nearest-to-mint first)** — the
  sybil-proof spine **on the two strips** (round 4). Reuse `SettleDeadline`
  (= `answerHeight + settleDelay`) as the render ordering/selection key on the
  dominant path; a disputed/flagged claim's deadline is its later actionable
  height (escrow/flag/counter window). This is strictly better than entry-height
  ordering against the **pre-position blockade**: a mill cannot keep its
  about-to-settle target off the nearest-to-mint segment, so the target is
  **discoverable-for-policing** there for its whole settle window. (Prose
  precision, round 5: the spine delivers *discovery*, not a self-financing
  slash — actually slashing a near-mint junk blocker is turnout-gated, and
  without turnout the flag resolves inconclusive-mid and half-burns the
  *defender's* bond while the mill crystallizes in the flag cooldown; that
  economics is pre-v0.5 dispositioned and unchanged. The spine's job is to
  *surface* the target so a funded court can police it.) `stripEnteredAt` is the
  membership/storage key; `SettleDeadline` is the render key (selection vs
  display separated).
- **Per-actor sub-caps** (answerer + author), **binding only under page
  overflow** (round 4 F3b: an uncontended page renders all rows). Stated
  honestly: caps key the *free* dimensions, so they blunt but don't alone
  defeat a sybil blockade — **the deadline ordering is what defeats it on the
  strips**; the caps stop one actor monopolizing a *contended* page, and the
  paginated read entrypoint backstops enumeration. **Seeded rows are exempt
  from the cap** (round 4 code-truth F4: a seed-farm self-burying past the cap
  is covered by the badge — one visible seeded row exposes the farm — so
  capping them only hides the evidence).
- **Directory strip**: per-court sub-cap **selects**; the representative is the
  court's **nearest-to-mint** row (not oldest); when courts exceed the page,
  select courts by their nearest representative deadline. Selection vs display
  separated; the chosen page renders by deadline. Honest residual (round 4 F3c):
  no within-court rule binds a court-*dominant* actor — the representative is
  best-effort; the honest row keeps its own court-strip slot regardless.
- **Pending list armature (round 4 F2; corrected round 5 F2)**: page cap,
  pagination, per-actor (author) caps, **and a priced door** — but **NOT the
  deadline spine**. Honest statement (round 5): a pending row is pre-answer, so
  it has no `SettleDeadline`; its only monotone key is `openedAt`, whose
  dead-close deadline (`openedAt + 12wk`) sorts a *flood earliest*, i.e.
  flooder-first. So on the pending list the guarantee is **pagination + the
  paginated read entrypoint (enumeration is preserved), plus the priced deposit
  as a nuisance-cost lever** — the deadline ordering that defeats the blockade
  on the strips has no sybil-proof analog here, and neither the address-keyed
  per-actor cap nor a linear deposit is a true flood gate (a funded adversary
  mimics N appellants; the deposit taxes poor legitimate appellants equally).
  The harm is therefore bounded to discovery-*friction*, not discovery-denial.
  Render order: key on **live deposit-at-risk descending** (a flooder can't
  cluster-control it as cheaply as `openedAt`) or accept flooder-first and rely
  on pagination — a build choice, documented as such, not a claimed spine.
  Because meta-CC is one-way GNOT-sunk and non-transferable, set
  `minClaimDepositCC` high enough to make a 50-row flood park real capital 12
  weeks without pricing out a single appeal — accepting this is a nuisance-cost
  ceiling, not a flood *gate*.
- **Bits**: strips/pending ignore courtMod+meta bits; the **global** bit redacts
  text but still renders the stored parse for `mod:` rows (open or persisted).
  Tier-hidden courts' rows appear on the directory strip (redacted iff global).
- **Residency & cranks**: an answered-uncrystallized claim is correctly
  resident (still flaggable = policeable); no exit timer. Every terminal path
  is permissionlessly reachable (`SettleUndisputed`/`ResolveDispute`/`Finalize`/
  `provCloseClaim`; Crystallize permissionless after the 1-week grace) but the
  cranks **pay the caller nothing** — mods/deployer are the implied janitors.
  *Optional courtv2 coordination item (touches the other session's
  `crystallize.gno`)*: reducing the participant-only Crystallize grace for
  verdict-final, flag-quiet claims lets defenders evict blockers faster — the
  one residency-attacking lever, flagged not assumed.

## 6. Text: immutable after first stake; annotations after — `VETTING`
Edit window `now < openedAt + delay` (the `stake==0` conjunct redundant, kept).
First stake / window close freezes text forever; edits evented (hash-only) +
**re-run the parser (stored-parse rewrite + pending enter/exit — no latch op)**.
After freeze: annotations (attributed, sanitized, ≤200, append-only with row
ids, above the original) + ≤1 relabel/authority; purge rows the sole text
mutation (I4). Mod-copy rule (first-party speech, no §230 shield, incl. seeded
titles + reasons + relabels + folder names): category codes / claim-about-the-
claim phrasing, never assertions of fact about persons; token/APR language
removal-grade.

## 7. Folders — `VETTING`
Membership gates nothing; flat list always remains; names/descriptions
sanitized, length-capped, purgeable rows; moderator-writable; suspension
refuses writes. "Zero economic weight" = zero on-chain coupling; the tripwire
(ordered visibility sold for consideration) applies verbatim.

## 8. Seeding — `REVISED`
Fee waiver = bootstrap convenience; the **discovery guarantee (§5.3) is the
anti-farm mechanism** (answered seeded claims are strip-resident, deadline-
ordered, cap-exempt-but-badged); the author-slice zero is provenance (I5), not
protection (winner 80/93 + answerer 5/93 still mint).
- `OpenClaimSeeded`: mod-only (reads set+suspension), waives CC deposit+fee;
  GNOT storage still paid; "seeded" badge + seeder address; unanswered seeds on
  the pending list.
- **I5 lands twice** (author draw AND `AuthorBonus`).
- **`settleSlash` fix** re-expressed against v0.40's `slashSizeFor`: record the
  claim's actual burns at `ResolveFlag`; `settleSlash` reads them, not
  `c.params` (the phantom-params under-pay is confirmed live post-v0.40).
- Zero-deposit tolerated end-to-end (four `>0`-guarded terminal sites).

## 9. The polish window — `REVISED (rounds 2–3)`
`Params.stakeOpenDelayBlocks`, `mustSane` [0, 17_280]. Staking closed in-window;
auto-opens. `StartCourt` grows the delay param. Fixture sweep count re-derived
at build (~6 direct StartCourt sites + a `testCourt` helper at ~42 call sites +
1 txtar; absorb delay=0 into the helper). Priority re-anchor at `openedAt +
stakeOpenDelayBlocks + answerWindow`. `openBlocks` = `frozenAt − (openedAt +
delay)`, floor 1.

## 10. Invariants (deploy/test gate)
- **I1** — hidden/redacted/purged lifecycle equivalence; votes proceed on
  tombstones across {dispute rounds incl. meta appeals, quality flag/ride/
  counter tallies, elections}; purged authors still refund.
- **I2** — no moderation entrypoint writes money **except the election
  candidate-bond legs (poster's own CC)**; money→moderation write-calls never
  panic; the four read gates enumerated; PostAnswer's latch read touches no
  bit/money value.
- **I3** — deep links/positions render under courtMod/meta (banner); global
  redacts (no text); purged → tombstones.
- **I4** — title reverts after window close/first stake; annotations append-
  only; edit runs parser (no latch); purge rows sole text mutation.
- **I5** — seeded: author draw = 0 AND AuthorBonus = 0, always.
- **I6** — every act logs a row + a no-user-text event; `VoteWithReason` never
  exposed.
- **I7** — `stakeOpenDelayBlocks ∈ [0, 17_280]`.
- **I8** — `ExecuteMetaVerdict`: fixed check order (exists→binding→verdict→
  route→**not-already-executed**→staleness); exactly-once (`executed` flag,
  stamp `executedAt` ≤ once, **and never on a no-op unhide of an already-clear
  bit**); `unhide` staleness = `lastElectionAt<openedAt` only, general form for
  suspend/unsuspend; direction-scoped cooldown; binding only from a non-poisoned
  parse; latch bound at PostAnswer, released at non-executable verdict-final.
- **I9** — **the two strips** carry deadline ordering (the sybil-proof spine) +
  per-actor caps (bind under overflow; seeded exempt) + pagination; **the
  pending list carries per-actor caps + pagination + priced door, but NOT the
  deadline spine** — its guarantee is enumeration via pagination, harm bounded
  to discovery-friction (round 5 F2). The undisputed/unflagged/all-bits-set
  answered claim appears on its strip (the named M-A13 fixture). Unanswered
  `mod:`/seeded on the pending list not the strip; provClosed/swept exit;
  directory
  representative nearest-to-mint; selection vs display separated.
- **I10** — suspension masks + refuses set writes except clearing own bits;
  voted unsuspend restores bit-for-bit; election passage clears the flag +
  resets the ladder; global clear-any reaches the flag.
- **I11** — purge m-of-n, row-level with stable row ids; category codes parse
  (code set **final/shape-extensible before deploy**); unrecoverable; whole-
  court purge tombstones future rows + gates OpenClaim.
- **I12** — election: per-court latch; **multi-candidate approval ballot (bonds
  add candidates, never exclude one; "retain current set" is the floor;
  installs iff ≥5001 bps approving weight AND quorum, else current set
  retained)**; court-size-scaled per-candidate bond, returned if installed/above-
  quorum else half-burned; escrow-netted quorum; epoch at nomination-window
  open; fully-failed election starts a cooldown; no withdrawal.

## 11. Attack ledger
(rounds 1–3 rows retained; round-4 additions/status below; M-A1–A29 as v0.4
except where noted)

| # | Attack | Disposition | Status |
|---|---|---|---|
| M-A30 | Pre-position blockade | **Deadline ordering (sybil-proof, strips)** + per-actor caps (contended pages) + priced doors; spine delivers discovery not self-financing slash (r5 prose) | REVISED r4/r5 |
| M-A33 | Election incumbent camp / ballot-veto | **Multi-candidate approval ballot — bonds ADD candidates, never exclude one** (r5: the auction let capital veto ballot access, overriding a vote majority); per-court latch; court-scaled per-candidate bond | REVISED r4/**r5** |
| M-A38 | **Pending-list flood** | Pending list = pagination + priced door (enumeration preserved); **NOT** the deadline spine (r5: pre-answer rows have no SettleDeadline; harm bounded to discovery-friction) | REVISED r4/**r5** |
| M-A44 | **Auction ballot-veto** (capital wins the latch, runs a doomed proposal, community's proposal never voted) | Folded into M-A33's multi-candidate ballot | NEW r5 |
| M-A45 | **Pre-emptive no-op-unhide hide-block** (chain of unhide appeals on a visible item stamps cooldown) | No-op unhide stamps nothing | NEW r5 |
| M-A39 | **Perpetual moderator freeze** (no-op re-stamp extends cooldown forever) | Exactly-once `executed` flag; stamp `executedAt` ≤ once; validity-before-state ordering | NEW r4 |
| M-A40 | **Global-clear poisons a pending unhide** (same-direction third-party refuses a needed verdict) | Direction-scoped staleness: `unhide` reads `lastElectionAt` only | NEW r4 |
| M-A41 | **Edit-door latch camp** (non-schema→schema, never answer) | Edit entrypoint does no latch op; latch binds only at PostAnswer | NEW r4 |
| M-A42 | **Non-final call stamps executedAt** | Fixed order: final-verdict + not-executed checked before idempotence/stamp | NEW r4 |
| M-A43 | **Cross-authority global-bit war escape** | Bounded (attribution + category codes + m-of-n re-set window); intended supremacy, guard-5 cross-ref | NEW r4 (accepted) |
(M-A31/A32/A34/A36/A37 REVISED as v0.4; unchanged rows carried forward.)

## 12. Build plan (sequencing decision first — §13.1)
1. `moderation.gno` — bits + split `lastActHeight`/`executedAt`, log with row
   ids, sets + `lastElectionAt`, suspension, global DAO migration, redaction +
   windowed-m-of-n re-set, row/whole-court purge, clear-any, `stripEnteredAt`.
   Tests I1–I3, I6, I10, I11.
2. `claim.gno`+`stake.gno`+`court.gno` — polish window (I7), StartCourt delay +
   name-cap + burned fee (user-call-only) + `meta` refusal, title-edit
   entrypoint (no latch), `OpenClaimSeeded`, purged-court gate (OpenClaim
   only), events; fixture sweep. Tests I4, I7.
3. `answer.gno`+`crystallize.gno`+`quality.gno`+`dispute.gno` — membership-site
   index writes (non-panicking, idempotent) + PostAnswer latch read + binding
   persist; I5 both gates; `settleSlash` actual-burn base (v0.40); openBlocks +
   priority re-anchors. Tests I5, I9-core.
4. `folders.gno`. 5. `modvote.gno` — election (per-court latch, multi-candidate approval ballot,
   court-scaled bond, escrow-netted quorum, addresses-only). Tests I12.
6. `render.gno` — filtering, banners, redaction (stored-parse for `mod:`),
   tombstones, `<slug>/mod`, three surfaces with the full armature (deadline
   order via `SettleDeadline`, per-actor caps, nearest-to-mint representative,
   paginated reads), status via `ClaimStatus`+slot+bits, badges, meta header,
   §7.4 hygiene. Tests I3, I9-full, goldens.
7. `meta.gno` — `startCourt` + init deploy, parser (stored at open, binding at
   PostAnswer, non-bindable-on-purge, re-parse on edit), PostAnswer-bound latch
   (released at non-executable verdict-final), `ExecuteMetaVerdict` (I8 fixed
   order + exactly-once + direction-scoped staleness). txtar: appeal round-trip,
   overturn, refused stale (election-passage), refused re-execute (exactly-
   once), global-clear-then-unhide-still-executes, first-to-answer latch,
   post-persistence-purge execution.
8. Integration (§15) + full audit, after convergence.

## 13. Owner flags
1. **Sequencing — realms are write-once.** Moderation ships inside courtv2
   (hold launch) or as a new realm never attaching to live-V2 state. Draft
   assumes hold-launch. The purge category-code set must be final/shape-
   extensible before deploy.
2. **Asymmetric supremacy**: keep.
3. **Global DAO custody**: hide single-key; **re-set (windowed) + purge
   m-of-n**; keys — owner call.
4. **Meta genesis + emission (coupled)**: genesis buy stays vote-dominant;
   meta-CC **non-transferable at launch** (escrow + curve mints exempt);
   **near-zero meta emission** is a two-sided fork (kills the deployer's +EV
   junk-appeal policing AND raises the forgery price ~5×). Owner call.
5. **StartCourt creation fee** (burned GNOT; makes StartCourt user-call-only) +
   **court-size bond constant β** for elections — amounts owner calls.
6. **Terminology**: "supreme" never in render/public copy; prefer "review".

## 14. Changelog
- **v0.1–v0.4**: see prior entries (constitution; policing strips; purge; meta
  court; suspension; election; write-once sequencing). r1 ~40/1 CRITICAL-legal;
  r2 24/1 CRITICAL-econ+8 HIGH; r3 ~19/4 HIGH.
- **v0.6** — round 5 (1 HIGH + 1 MED-HIGH; verification lens CONVERGED):
  - *Election, structurally different fix* (M-A33/M-A44, HIGH): the v0.5 bond
    auction put the capital key on *ballot access* — a capital-dominant but
    vote-minority incumbent (or a griefer) could win the latch and run a doomed
    proposal, so the community's real proposal was never voted (capital over
    vote majority). Replaced with a **multi-candidate approval ballot**: bonds
    *add* candidates to one ballot and can never keep one off it; "retain
    current set" is the floor; a set installs iff ≥5001 bps approving weight +
    quorum, else the current set is retained. Removes the scarce excludable slot
    the last three election breaks all exploited.
  - *Pending-list honesty* (M-A38, MED-HIGH): a pending row is pre-answer and
    has no `SettleDeadline`, so it cannot carry the nearest-to-mint spine — its
    only key (`openedAt`→dead-close) sorts a flood first. Corrected: the pending
    list's guarantee is **pagination + priced door** (enumeration preserved,
    harm bounded to discovery-friction), not a deadline spine; I9 scopes the
    spine to the two strips; render order keys on deposit-at-risk or documents
    flooder-first + pagination.
  - *Two holds hardened*: the deadline spine delivers *discovery* not a self-
    financing slash (M-A30 prose softened — slashing is turnout-gated, pre-v0.5
    dispositioned); a no-op `unhide` of an already-clear bit stamps nothing,
    closing a pre-emptive hide-block (M-A45).
  - *LOW nits from the verification lens*: `SettleDeadline` (render key) vs
    `stripEnteredAt` (membership key) glossed; the M-A13 named fixture restored
    to I9.
- **v0.5** — round 4 (~16 findings, 3 HIGH + 1 MED-HIGH, all local fixes;
  named the root principle up top):
  - *Discovery armature completed*: deadline (nearest-to-mint) ordering as the
    sybil-proof spine reusing `SettleDeadline` (M-A30); pending list given the
    full armature + priced meta deposit (M-A38); per-actor caps rescoped
    (contended-only, seeded-exempt) and stated honestly.
  - *Election rebuilt on price*: per-court latch + **bond auction** + court-
    size-scaled bond replace the sybil-prone per-proposer cooldown (M-A33).
  - *Guard machinery fixed*: exactly-once `executed` flag stops the perpetual
    moderator freeze (M-A39); fixed validity-before-state check order
    (M-A42); direction-scoped `unhide` staleness stops the global-clear poison
    (M-A40); latch removed from the edit path (M-A41); binding-parse source
    pinned (non-bindable on purge); PostAnswer latch enumerated as read gate
    #4 with the non-panicking money→moderation rule.
  - *Latch economics*: releases at non-executable verdict-final (griefer hold
    ~10d→~3d); restorative proceeds under an aggressive holder.
  - *Redaction*: m-of-n scoped to the §512(g) window (disjunction resolved).
  - *Code-truth*: court-name length-cap added to the court.gno diff; `route`
    third value `"closed"` named; `SettleDeadline`/`ClaimStatus` reuse
    pointers; settleSlash bug re-confirmed live post-v0.40; M-A18 reconciled
    with the cap (seeded exempt, badge sufficient); cross-authority escape
    (M-A43) documented as intended supremacy.

## 15. Integration items (deferred — do not race the build session)
- REGULATIONS.md — content/platform-liability axis: CDA 230 contours incl.
  §230(e)(2) IP carve-out (ROP outside §230, 3d Cir. Hepp) + moderating-doesn't-
  waive-§230; purge rationale; DMCA trio (registered agent; §512(i) repeat-
  infringer policy as an address-level render analog; §512(g) put-back + the
  m-of-n re-set window); NCMEC §2258A; purge category-code table; whole-court
  facilitation question.
- REGULATIONS.md exposure map — row 6 meta-CC (non-transferable, near-zero-
  emission option, functional-only copy); row 2 curation/seeding prong-3/4 +
  counter-facts; row 3 Ooki wording; DUNA (meta electorate = cohort candidate;
  global DAO + mod sets = operator/agent exposure).
- PLAN.md §7.4 (seeding/featured/meta-CC/mod-string hygiene), §7.5 counsel
  (DMCA agent, NCMEC, category codes, whole-court lifecycle), §12 owner rows.
