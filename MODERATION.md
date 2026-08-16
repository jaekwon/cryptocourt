# MODERATION.md — render-layer moderation, the meta court, and seeding

> **STATUS: v0.3 — round-2 vet ingested (4 fresh lenses re-attacked the round-1
> fixes; 1 CRITICAL, 8 HIGH found and dispositioned below). VETTING continues;
> round 3 re-attacks v0.3.** Statuses: `DRAFT` → `VETTING` → `ACCEPTED` /
> `REVISED`. Additive to launch-cleared V2 (PLAN v0.38) — see §13.1 for the
> write-once-realm sequencing decision. PLAN.md / REGULATIONS.md edits are
> deferred to integration (§15) to avoid racing the active build session.

## 0. Posture

Owner-directed scope (2026-08-16): a global moderator DAO that can hide courts
from the front page; per-court moderator sets that can hide items; a META court
deployed by default that overrides any court's moderators; cheap moderator
seeding; an edit story for claim text. Owner position overridden with consent:
**staked-on text is never rewritten** — edits close at the first stake; after
that, moderators annotate.

Three understandings now anchor the design (rounds 1–2):

1. **Discovery is economics.** Money paths never read moderation state (I1/I2)
   — and that is insufficient: hiding shapes who shows up to police, and V2's
   junk defense is discovery-driven. Hence the policing-window guarantee
   (§5.3), the load-bearing clause.
2. **Visibility guarantees die by flooding, not by bits.** Round 2's CRITICAL:
   a newest-first, page-capped strip is buried by cheap volume. Every §5.3
   surface is therefore ordered by **ascending entry height** — a key that
   cannot be manufactured after the fact — with per-court sub-caps and priced
   court creation.
3. **The constitution bends in exactly two places, both legal-hold.** A
   row-level **purge** (text tombstoning) and an **OpenClaim gate on purged
   courts** (§3.2). Everything else is discovery only.

## 1. The change in one paragraph

V2 already has the germ: `directory.gno` curates courts into
hidden/listed/featured tiers under a single `directoryAdmin`, with the comment
"a hidden court still works for anyone holding its address; moderation, not
custody." This plan generalizes that sentence into a constitution and extends
it downward (per-court item moderation), upward (a meta court as the appeals
layer, built from the court machinery itself), and sideways (folders as
curation metadata, moderator seeding, a pre-stake polish window). Moderation
gains one power — controlling *discovery* — plus two legally-forced
exceptions, and zero power over money.

## 2. The constitution — `REVISED (rounds 1–2)`

> **Moderation authority is render-layer authority. No moderation state is
> ever read by a money path, no moderation entrypoint ever writes one — and
> no moderation act may remove a claim from ALL discovery surfaces while it
> is still policeable.**

- Hidden ≠ voided: a hidden claim's full lifecycle runs byte-identically
  (**I1**). Purge and global redaction touch *text*, never lifecycle: votes
  proceed on the tombstone; refunds and draws run unchanged.
- Moderation entrypoints never write money state (**I2**). Three read-side
  carve-outs, enumerated, all read-only gates: `OpenClaimSeeded` (§8) reads
  the mod set + suspension; `OpenClaim` refuses on a **purged court** (§3.2 —
  legal-hold, blocks new content only, touches nothing existing); the strips
  (§5.3) read moderation state to *include*, never to exclude.
- Reachability (**I3**): deep links and the per-claim positions view render
  regardless of courtMod/meta bits (banner). The **global** bit is stronger
  by design — all-surface *text redaction* (§3.2) — but money state, IDs, and
  deadlines render everywhere, always. No on-chain "all my claims" index
  exists or is added; claim-lane events (no user text) let clients enumerate.
- Every act is attributed, category-coded or reasoned (sanitized, ≤ 200
  chars), evented, and rendered in the per-court moderation log (**I6**).
  **Events carry actor, act code, target, height, and a reason *hash* — never
  reason/annotation/title text** (events are unpurgeable history; verified:
  no current courtv2 event carries user text; `VoteWithReason` is never
  exposed).
- **The user-text inventory** (round 2: purge must reach every row, so name
  them all): claim titles; annotations; relabels; mod-log reasons; folder
  names/descriptions; **court names** (length-capped at StartCourt; the
  grc20votes ledger's name copy is render-dead — the realm renders names only
  from the Court struct); replacement-vote proposals are **addresses-only, no
  free text**. Court *slugs* are `[a-z0-9-]` routing keys and unpurgeable by
  construction — the whole-court purge (§3.2) aliases them at render.

**Exhaustive audited-file diff** (corrected round 2; none change money math,
all get regressions):

| audited file | edit |
|---|---|
| `stake.gno` | polish-window gate on Stake (§9); Unstake needs none — stake is provably zero in-window (Stake is the only inflow); the belt-and-braces gate stays but is documented as redundant |
| `court.gno` | `Params.stakeOpenDelayBlocks` + `mustSane` (I7); `StartCourt` grows the delay param + a **burned GNOT creation fee** (frozen constant — court-count attacks price like claim-count attacks) + reserved-slug `meta` refusal; `startCourt` extraction (§3.3) |
| `answer.gno` | priority-window re-anchor (§9); **strip-index entry write in `PostAnswer`** (§5.3) |
| `crystallize.gno` | seeded gate on author draw AND `AuthorBonus` (I5); `openBlocks` re-anchor (§9); strip-index exit in `Crystallize` |
| `quality.gno` | `settleSlash` bounty base = the claim's actual burns recorded at `ResolveFlag` (§8) |
| `dispute.gno` | strip-index exit in `provCloseClaim` |
| `claim.gno` | `OpenClaimSeeded` + seeded-list entry; title-edit rule (I4); seeded exit in `CloseDeadClaim`; purged-court gate on `OpenClaim`; claim-lane events |
| `directory.gno` | `directoryAdmin` → global-DAO set migration; `SetTier` logged + evented (I6) |
| `session.gno` | none (verified: `SettleUndisputed` changes no strip membership and tolerates zero-deposit/seeded/window claims) |

## 3. The three authorities — `REVISED (rounds 1–2)`

Hiding composes as a union of independent bits (courtMod / meta / global) plus
the per-court suspension flag and purge rows. Each authority sets and clears
its own bits. Cross-authority powers, complete list: meta clears the courtMod
bit by verdict; **the global DAO clears any bit AND the per-court suspension
flag** (round 2: suspension is a flag, not a bit — the recovery power now
names it, or a captured meta court's mass-suspends were unrecoverable).
Nobody clears the global bit but the global DAO; nobody reverses a purge.

### 3.1 Court moderators (per court)

- Per-court address set. Powers (render-layer): hide/unhide items (own bit),
  annotate/relabel (§6), folders (§7), seeding (§8), polish-window acts (§9).
- **Appointment**: the court creator (`Court.admin`) bootstraps and manages
  the set until a **replacement election** passes; passage installs the
  elected set, permanently unseats the creator's appointment power, and
  **clears the court's suspension flag** (a new set starts armed; if a
  captured electorate re-elects rogues, meta re-suspends — a full vote each
  way, no free toggle). If an elected set goes dark, the only path is another
  election — viable because the quorum nets escrow (below).
- **The election** (court-local sealed tally in `modvote.gno` — no governor
  slots, reusing the quality-vote machinery):
  - latch: one open election per court;
  - proposal: **addresses only**, no free text;
  - proposer bond: `flagMinCC`, **doubling per failed election, frozen at
    4×**, plus a cooldown after any failure (round 2: a flat 1-CC bond made
    the latch itself a ~1 CC/week denial lever — mirror the flag lane's
    escalators exactly);
  - weights: `coin.PastVotes` at the epoch **pinned at vote open** (the
    qualityEpoch idiom); threshold 5001 bps; length `votingBlocks`;
  - quorum floor: **max(1, 5%·(PastTotal(at) − PastVotes(escrow, at)))** —
    netting the escrow like the dispute quorum does (round 2: raw supply made
    elections unpassable on active courts, where most CC sits in escrow).
- Meta may **suspend** a set. Suspension semantics (round 2, unified):
  - the set's bits are **masked at render** (kept, not deleted);
  - **all the set's write-entrypoints refuse** (hide-set, annotate, relabel,
    folders, seeding, polish acts) **except clearing its own bits** —
    strictly de-escalatory, so a suspended set cannot queue masked hides or
    poison staleness guards, and the state restored at unsuspend is exactly
    the state the suspending electorate judged;
  - elections remain proposable during suspension (proposer-driven, no mod
    entrypoint involved);
  - `unsuspend` **requires the voted route** (round 2, three lenses
    independently: unsuspend re-applies a mass-hide and re-arms the set — it
    is aggressive, not restorative; the unsuspending electorate votes with
    the restorable bit-set renderable in the mod log).

### 3.2 The global moderator DAO (realm-wide)

Generalizes `directoryAdmin` into a small address set; membership managed by
an admin seat (transferable; DAO-ification V3). Verbs:

- **court tiers** (existing `SetTier`, now logged/evented);
- **global hide = all-surface text redaction** (round 2, legal: the v0.2
  redacted-strip-row + full-text-deep-link combination was internally
  inconsistent and under-complied with "disable access"): while the global
  bit is set, *every* surface — strips, deep links, positions — renders
  banner + IDs + state + deadlines + money figures, **no user text**.
  Single-key (speed), reversible only by an explicit logged global act —
  **never by silence, timer, or meta verdict**. This is the DMCA verb:
  hide on notice, manual put-back after a counter-notice window; purge is
  never the DMCA verb (put-back must remain possible).
- **clear-any** (recovery): any bit, any court's suspension flag.
- **purge — row-level** (round 2, legal: claim-atomic purge couldn't reach an
  illegal annotation on an innocent claim, a court name, a folder, or a log
  row): tombstone any single row of the §2 user-text inventory, addressed as
  (scope, id) — claim-title, annotation, relabel, log-row, folder,
  court-name. m-of-n of the set; reason = **statutory category code**, never
  a description (a free-text banner republishes the libel); irreversible;
  unappealable on-chain. Purge never touches an open vote or lifecycle state
  (I1/I2): votes proceed on the tombstone, refunds and draws run unchanged.
- **whole-court purge**: every text render in the court tombstones (including
  future rows), name tombstoned, slug rendered as a neutral alias
  (`court-<n>`), routes still serve money state so exits complete — plus the
  constitution's second carve-out: **`OpenClaim`/`OpenClaimSeeded` refuse on
  a purged court** (an illegal-*theme* court must not accrete new content;
  existing lifecycle runs to completion). Counsel item: whether continued
  lifecycle service on such a court needs a harder stop (§15).

**Operating rules** (rendered policy copy, not just this doc):

1. All legal-compliance takedowns use the global bit or purge, exclusively —
   courtMod/meta hides are editorial only (otherwise a `mod:unhide` passing
   by silence auto-restores content the operator was noticed on, outside any
   put-back procedure).
2. Runbook: on notice/knowledge — single-key global hide immediately +
   evidence snapshot at hide-time; for hosting-is-offense categories, m-of-n
   purge within 72h + NCMEC report per counsel; for DMCA, the process stops
   at hide.
3. Any courtMod hide whose reason cites illegality escalates to global-DAO
   review within the runbook window — adopt onto the global bit or decline.
4. The global bit and purge are never editorial; editorial disagreement goes
   to the meta court.

### 3.3 The meta court (the appeals layer)

- **It is a court** — own CC, own electorate, created at realm init under the
  reserved slug `meta` (refused to `StartCourt`), undeletable (no court-
  deletion path exists in courtv2 — verified), listed by default. Init calls
  an extracted `startCourt(admin, slug, name)` with the deployer
  (`unsafe.OriginCaller()`, the r/govern/token.gno pattern) as admin —
  init has no `cur`, and a self-cross would set `directoryAdmin` to the realm
  address and brick tiers.
- **Bootstrap truth**: at zero supply the meta court is fully inert (no CC —
  no claim can open). The moment one buyer exists the danger inverts: with no
  electorate, appeals pass by **silence**. Dispositions: the deployer makes a
  visible genesis buy sized to stay **vote-dominant** (this, not the route
  gate, is the real security parameter — see the forgery note below), holds
  it earmarked to dispute junk appeals (**+EV while dominant**: winning an
  overturn returns the dispute bond *and* mints comp while the attacker's
  answer bond burns — verified against dispute.gno; the sign flips if
  dominance is lost, which is the sizing rule), and appeals are
  strip-resident from birth (§5.3).
- Reserved title schemas (strict parse; near-miss titles get a rendered
  "not a valid appeal" badge from the same parser):
  `mod:unhide:<court>/<claimID>` (clear courtMod bit) ·
  `mod:clear:<court>/<claimID>` (clear meta bit) ·
  `mod:hide:<court>/<claimID>` (set meta bit) ·
  `mod:suspend:<court>` / `mod:unsuspend:<court>`.
  - **Parse lifecycle** (round 2: purging an appeal's title must not veto a
    passed verdict, and titles are editable pre-freeze): parse at open for
    display, badges, the target-side "appeal pending" banner, and the latch;
    re-parse on title edit; **persist the binding {verb, court, claimID} at
    `PostAnswer`** (title frozen by then — stake precedes any answer);
    `ExecuteMetaVerdict` reads only the persisted parse.
  - **Per-target appeal latch**: one open schema claim per target item/court
    (re-keyed if an in-window edit changes the target) — bounds
    parallel-appeal governor-slot pressure (the meta court shares V2's
    56-slot pool) and appeal spam.
- **Execution** (`ExecuteMetaVerdict(metaClaimID)`, permissionless,
  idempotent-by-state — same-direction acts are no-op successes; I8 guards):
  1. **Final verdict**: executes iff `Verdict() == YES` — the `provisional`
     field, never `cs.answer` (overturns invert it); provClose, NO,
     non-final, purged-title (uses persisted parse), and nonexistent targets
     execute nothing.
  2. **Aggressive verbs need the voted route** (`route == "vote"`):
     `mod:hide`, `mod:suspend`, **`mod:unsuspend`** (round 2 move).
     Restorative verbs (`unhide`, `clear`) may execute from the undisputed
     route — silence may restore item visibility, never remove it, disarm a
     court, or re-arm one. Honesty note (round 2, econ): the route gate
     defeats the *silent* override factory only — a meta-CC majority can
     forge `route == "vote"` by self-disputing (~4%·X̄ per act); against
     capture the defense is deployer vote-dominance (§13.4) plus global
     clear-any and full reversibility. Optional hardening if capture is ever
     observed: require minimum genuinely-opposed weight before an aggressive
     verb executes.
  3. **Staleness, actor-scoped** (round 2: the v0.2 "any transition refuses"
     rule was livelock-able — a mod re-toggles its bit for free, refusing
     every passed appeal forever): post-open transitions by the **respondent
     authority the verdict binds** (the courtMod set and its appointing
     creator, for unhide/suspend) never refuse execution — the verdict
     overrules that authority, mid-appeal re-assertions included.
     Transitions by *other* actors (global DAO, another meta verdict, an
     election passage — membership changes stamp a set-level
     `lastActHeight`, and suspend/unsuspend guards read
     max(flag, membership)) refuse execution: the state changed hands and
     wants a fresh vote. An executed verdict stamps `executedAt`; the
     respondent may not re-transition that bit for one `votingBlocks`
     (post-execution re-hide war closed; text is frozen post-stake, so no
     new content grounds can arise; meta's own bit is the escape hatch).
  4. **No phantom targets**: target court and claim must strictly predate the
     meta claim's `openedAt`.
- **Asymmetric supremacy (owner flag §13.2)**: meta overrides court
  moderators in both directions; meta never clears the global bit, never
  reverses purge, and the global DAO can clear meta's bits and suspensions
  (recovery). The deployer's legal backstop is not appealable on-chain.
- Who moderates the meta court? Its own §3.1 set + the global DAO, like any
  court. `mod:suspend:meta` is self-referentially sound (it suspends the mod
  *set*, never the verdict machinery). No fourth layer.

## 4. Moderation state — `REVISED (round 2)`

Per claim: hide word (3 bits + purge flags per row), `lastActHeight` per bit,
`executedAt` per bit, the append-only act log. Per court: mod set +
set-level `lastActHeight`, suspension flag + `lastActHeight`, folders, tier,
election latch/bond state, **the per-court policing index**. Realm-level:
**one global policing index** (key = entry height | slug | claimID) and a
courts-with-entries tree (for the directory strip's per-court sub-cap).
Indexes are written at exactly the **membership sites** (§5.3) — zero writes
at vote sites; per-row status (open vote / counter window / redaction) is
read live at render, bounded by the page cap. Storage: one small row + one
event per act (the `enqueueSenior` idiom), paid by the actor's storage
deposit.

Render routes (carved out before the numeric-ID parse): `<slug>/mod` (the
court's moderation log, paged) and the strips. A paginated **read
entrypoint** (query function, not Render) exposes strip pages beyond the
first, so the guarantee never bottoms out at 50 rows.

## 5. Hiding: exact render semantics — `REVISED (rounds 1–2)`

### 5.1 Discovery surfaces (bits apply)

Court-page listings, folder listings, featured strips, the directory.

### 5.2 Non-discovery surfaces

Deep links (`<slug>/<id>`, `<slug>/<id>/<addr>`) always render with a banner
under courtMod/meta bits. Under the **global** bit they render redacted
(§3.2): banner + IDs + state + deadlines + money figures, no user text.
Purged rows render tombstones. Money state renders everywhere, always.

### 5.3 The policing strips — the load-bearing guarantee — `REVISED (round 2)`

Two strips — per-court and directory (realm-wide) — showing every claim in
its **policeable span**, immune to burial:

- **Membership** (round 2: v0.2's "six vote sites" never captured the
  undisputed path — the exact target — because vote sites all presuppose an
  answer; membership is lifecycle, status is render-time):
  - enter at `PostAnswer` (`frozenAt` set) — every answered claim, hidden or
    not; and at **birth** for schema-valid `mod:` appeals (round 2: pre-answer
    appeals were embargo-able by the meta court's own mods, falsifying
    "force-visible");
  - exit at `Crystallize` (`crystallized = true`), `provCloseClaim`, and
    `CloseDeadClaim` (round 2: "until crystallization completes" stranded
    provClosed/swept rows forever — span is
    `frozenAt != 0 && !crystallized && !provClose && !closed`);
  - **seeded claims**: birth-to-answer they live on a separate per-court
    **seeded list** (no deadline — round 2: parking unanswered seeds on the
    urgency strip was the cheapest flood primitive); from answer they are
    ordinary strip rows; they exit via the same three sites.
- **Ordering: ascending entry height — oldest first.** This one choice does
  three jobs (round-2 synthesis): it is the anti-flood property (an entry
  height in the past cannot be manufactured — burying a target needs 50
  *earlier*-answered claims, which can't be created after the fact); it is
  the urgency sort for the dominant path (settle deadline =
  answerHeight + 72h, monotone in entry height — the oldest answered claims
  are the ones about to mint); and it is one monotone index key with no
  re-keying. The page cap stays `renderPageSize`; "…and N more" reports the
  index remainder; the §4 read entrypoint serves deeper pages.
- **Directory strip**: reads the realm-level index with a **per-court
  sub-cap** (first pass: the oldest row per court across courts-with-entries,
  then fill by age) — one court cannot occupy the page. Court creation is
  **priced** (burned GNOT fee, §2 table) so court-count attacks cost like
  claim-count attacks.
- **Bits**: strips ignore courtMod and meta bits. The **global** bit redacts
  the row's text; for schema-valid `mod:` appeals the redacted row still
  renders the persisted **parse** (verb + target — realm-validated strings,
  the same speech class as category codes; round 2: full redaction of an
  appeal blinded its own electorate for zero legal-hold value). Tier-hidden
  courts' rows appear on the directory strip (redacted iff global).
- Hide bits set on strip-resident claims apply to ordinary discovery surfaces
  immediately; strips are unaffected. Nothing defers the global DAO.

## 6. Text: immutable after first stake; annotations after — `VETTING`

- **Author edit window**: title editable while `now < openedAt + delay`.
  (The `stake == 0` conjunct is provably redundant — staking is closed
  in-window and Stake is the only inflow — and stays as defense in depth.)
  First stake / window close freezes text forever. Edits are evented
  (hash-only per §2) and re-run the `mod:` parser on the meta court.
- **After freeze**: annotations — attributed, sanitized, ≤ 200 chars,
  append-only, above the untouched original — and at most one relabel per
  authority, "mod label:" alongside, never instead. **Purge rows (§3.2) are
  the sole text-mutation exception** (I4 carve-out).
- **Mod-copy rule** (first-party speech, no §230 shield — and round 2
  extends it to **seeded claim titles**, which are also moderator-authored):
  category codes and claim-about-the-claim phrasing, never assertions of
  fact about persons; token-promotion/APR language in any mod string is a
  removal-grade offense (§7.4 hygiene extends to runtime mod copy).

## 7. Folders: curation metadata, zero on-chain coupling — `VETTING`

As v0.2: membership gates nothing; the flat newest-first list always remains
(folders add, never bury); names/descriptions sanitized, length-capped,
purgeable as rows (§3.2); moderator-writable; suspension refuses writes.
"Zero economic weight" means zero on-chain coupling, not zero EV — PLAN's
tripwire applies verbatim: ordered visibility sold for consideration is the
value-coupling event demanding a full vet cycle.

## 8. Seeding: deposit-waived, provenance-marked, discovery-guaranteed — `REVISED`

The fee waiver is a bootstrap convenience; **the discovery guarantee (§5.3)
is the anti-farm mechanism** (an answered seeded claim is strip-resident and
oldest-first — visible junk gets flagged); the author-slice zero is
provenance, proving seeding is uncompensated work (securities-relevant, I5),
not farm-proofing — the winner (80/93) and answerer (5/93) slices still mint
on seeded claims like any others.

- `OpenClaimSeeded`: mod-only (reads set + suspension — a §2 carve-out),
  waives CC deposit and fee; GNOT storage deposit still paid; "seeded" badge
  + seeder address rendered; polish window applies (the mod is an ordinary
  author of its own seed).
- **I5 lands in crystallize.gno twice**: the author draw AND `AuthorBonus`.
- **`settleSlash` fix** (§2 table): the claim records its actual burned dust
  at `ResolveFlag`; `settleSlash` reads that, not `c.params` (on a seeded
  claim the phantom params base under-paid the flagger's slash bounty ~44%).
  Zero-deposit is otherwise tolerated end-to-end (all four terminal sites
  are `> 0`-guarded — verified; "sweep" = `CloseDeadClaim`).
- Everything else about a seeded claim is an ordinary claim.

## 9. The polish window — `REVISED (round 2)`

`Params.stakeOpenDelayBlocks`, `mustSane` [0, 17_280]. Staking closed for the
window; claim visible; author edits; mods annotate/hide/folder. Auto-opens —
no sign-off exists.

- **`StartCourt` grows the delay parameter** (round 2: "default 720 +
  unchanged signature + SkipHeights" was internally inconsistent — the txtar
  can't skip heights around a fixed default). Courts choose at creation,
  bounded by `mustSane`; `defaultParams()` keeps 720 for the meta court and
  doc examples; fixtures pass 0 except the window tests (28 unit sites + the
  txtar verified).
- **Priority re-anchor**: the 24h answer-priority window anchors at
  `openedAt + stakeOpenDelayBlocks + answerWindow` (answer.gno:51 today
  anchors without the delay; at max delay the priority phase would vanish —
  it equals `priorityWindowBlocks` exactly).
- **`openBlocks` re-anchor**: crystallize's F9 cap divides by
  `frozenAt − (openedAt + delay)`, floor 1 (dead window-time over-tightened
  payouts).

## 10. Invariants (deploy/test gate)

- **I1** — hidden/redacted/purged lifecycle equivalence: identical money
  outputs; votes proceed on tombstones; refunds reach purged claims' authors.
- **I2** — no moderation entrypoint reaches a money write; the three read
  gates (§8 seeding, purged-court OpenClaim, §5.3 strips) are enumerated and
  read-only.
- **I3** — deep links + positions render under courtMod/meta bits (banner);
  global bit renders redaction (IDs, state, deadlines, money — no user
  text); purged rows render tombstones; money state renders everywhere.
- **I4** — title writes revert after window close; annotations append-only;
  purge rows are the sole text mutation.
- **I5** — seeded claims: author draw = 0 AND AuthorBonus = 0, always.
- **I6** — every act appends a log row + an event carrying **no user text**
  (reason hash only); `VoteWithReason` is never exposed.
- **I7** — `stakeOpenDelayBlocks ∈ [0, 17_280]` in `mustSane`.
- **I8** — `ExecuteMetaVerdict`: persisted-parse only; final-verdict field
  (`Verdict()==YES`, non-provClose); voted-route gate on hide/suspend/
  **unsuspend**; actor-scoped staleness + membership-aware for suspend
  verbs + `executedAt` cooldown; targets strictly predate the appeal;
  idempotent-by-state; refuses nonexistent targets.
- **I9** — strips: the undisputed, unflagged, all-bits-set claim appears
  (the round-1 centerpiece, now the named fixture); provClosed and swept
  claims exit; a tier-hidden court's rows appear on the directory strip;
  ordering is ascending entry height; the directory sub-cap holds; seeded
  unanswered claims appear on the seeded list, not the strip.
- **I10** — suspension: masks bits, refuses all set writes except clearing
  own bits; unsuspend (voted) restores bit-for-bit; election passage clears
  the flag; global clear-any reaches the flag.
- **I11** — purge: m-of-n; row-level over the §2 inventory; category codes
  parse; unrecoverable through any realm read; whole-court purge tombstones
  future rows and gates OpenClaim.
- **I12** — election: one open per court; bond doubles to 4× + cooldown;
  quorum floor nets escrow; weight epoch pinned at open.

## 11. Attack ledger

| # | Attack | Disposition | Status |
|---|---|---|---|
| M-A1 | Hide-as-turnout-suppression on open votes | §5.3 strips (membership-site indexed) | REVISED |
| M-A2 | Meta-court capture | Render-only blast radius; **global clear-any incl. suspension**; full reversibility; deployer vote-dominance (§13.4) | REVISED |
| M-A3 | Global-DAO key compromise | Hide single-key but reversible + logged; purge m-of-n; custody flagged | ACCEPTED |
| M-A4 | Seeding mill | §5.3 oldest-first residency; I5 as provenance | REVISED |
| M-A5 | Edit-window bait-and-switch | Boundary pinned; edits evented; parser re-runs | VETTING |
| M-A6 | Moderator extortion | Log + meta appeal + election (escrow-netted quorum, escalating bond) | REVISED |
| M-A7 | Annotation spam / defamation | Sanitizer + caps + first-party mod-copy rules (incl. seeded titles) | REVISED |
| M-A8 | Folder burial | Flat list survives; tripwire on sold placement | VETTING |
| M-A9 | Hide to grief refunds/sweeps | I1 | ACCEPTED |
| M-A10 | Appeal spam / slot exhaustion on meta | Ordinary claim costs + **per-target appeal latch**; challenger-asymmetry noted, deployer capital +EV while dominant | REVISED |
| M-A11 | Suspension abuse | Masks + write-refusal + voted unsuspend + global recovery + election clears | REVISED |
| M-A12 | Force-display of illegal content via strips | Global bit redacts everywhere, never deferred | REVISED |
| M-A13 | Policing-window embargo | §5.3 membership sites incl. the undisputed path (the I9 fixture) | REVISED |
| M-A14 | Court-tier hide as discovery lever | Directory strip off the realm index, sub-capped | REVISED |
| M-A15 | Unopposed meta overrides via silence | Voted route for hide/suspend/unsuspend; silence only restores items | REVISED |
| M-A16 | Stale/banked verdict replay & phantom targets | Actor-scoped staleness + membership stamps + executedAt cooldown + predate guards | REVISED |
| M-A17 | Election spam as dispute DoS | Court-local tally (no slots) + latch + doubling bond + cooldown | REVISED |
| M-A18 | Seed-then-hide | Strip/seeded-list residency from birth | REVISED |
| M-A19 | Polish-window front-run | Strip residency + regime-limited EV — watch item | VETTING |
| M-A20 | **Strip flooding** (newest-first burial; seeded/court spam) | Ascending entry height + seeded-list segregation + per-court sub-cap + priced StartCourt + paginated reads | NEW |
| M-A21 | Staleness livelock (free bit re-toggle refuses every appeal) | Actor-scoped guard + executedAt cooldown | NEW |
| M-A22 | Mass-suspend unrecoverable under captured meta | Global clear-any covers the suspension flag | NEW |
| M-A23 | Unsuspend-by-silence re-imposes mass-hide | Voted route | NEW |
| M-A24 | Purge-as-appeal-veto (tombstoned title unparseable) | Binding parse persisted at PostAnswer | NEW |
| M-A25 | Pre-answer appeal embargo | `mod:` claims strip-resident from birth; redacted rows show the parse | NEW |
| M-A26 | Election lockout (bond-flat latch camping; escrow-inflated quorum) | Doubling bond + cooldown; escrow-netted floor | NEW |
| M-A27 | Voted-route forgery by self-dispute | Named honestly; defense = deployer dominance + reversibility; optional min-opposed-weight hardening | NEW |
| M-A28 | Illegal court names / whole-court themes | Row-level + whole-court purge; name length cap; slug aliasing; OpenClaim gate | NEW |
| M-A29 | Queued masked hides during suspension | Write-refusal (clear-own-bits only) | NEW |

## 12. Build plan (sequencing decision first — §13.1)

1. `moderation.gno` — bits + per-bit `lastActHeight`/`executedAt`, act log
   (hash-only events), mod sets + set-level `lastActHeight`, suspension
   (mask + write-refusal), global DAO migration, global redaction flag,
   row-level + whole-court purge, clear-any. Tests: I1–I3, I6, I10, I11.
2. `claim.gno` + `stake.gno` + `court.gno` — polish window (I7),
   `StartCourt` delay param + burned creation fee + `meta` slug refusal,
   title edits (I4), `OpenClaimSeeded`, purged-court gate, claim-lane
   events; fixture sweep (28 unit sites + txtar). Tests: I4, I7.
3. `answer.gno` + `crystallize.gno` + `quality.gno` + `dispute.gno` —
   strip-index entry/exit writes at the five membership sites; I5 both
   gates; `settleSlash` actual-burn base; `openBlocks` + priority
   re-anchors. Tests: I5, I9-core, §8/§9 regressions.
4. `folders.gno` — curation metadata. Tests: render goldens + purge rows.
5. `modvote.gno` — the election (latch, doubling bond + cooldown,
   escrow-netted quorum, addresses-only). Tests: I12.
6. `render.gno` — discovery filtering, banners, redaction, tombstones,
   `<slug>/mod` route, both strips off the indexes (ascending, sub-capped,
   "…and N more"), seeded list, paginated read entrypoint, badges, meta
   header line ("platform content decisions, not legal process"); §7.4
   hygiene. Tests: I3, I9-full, goldens.
7. Meta court — `startCourt` extraction + init deploy, parser (open +
   PostAnswer persistence + re-parse on edit), per-target latch,
   `ExecuteMetaVerdict` with the I8 guards. txtar: full appeal round-trip
   incl. an overturn, a refused stale execution, and a purged-title
   execution.
8. Integration (§15) + full audit pass, by the active build session, after
   this document converges.

## 13. Owner flags

1. **Sequencing — realms are write-once.** Moderation ships inside the
   courtv2 realm (hold launch) or as a new realm whose moderation never
   attaches to live-V2 courts. No additive patch path exists. Draft assumes
   hold-launch — owner call.
2. **Asymmetric supremacy**: meta never clears the global bit nor reverses
   purge; global can clear meta's bits/suspensions. Recommend keeping.
3. **Global DAO custody**: hide/redaction = single admin key (speed);
   purge = m-of-n. Which keys at launch — owner call. V3 DAO-ifies.
4. **Meta-court genesis (the real security parameter)**: the deployer's
   genesis buy must stay **vote-dominant** vs any plausible curve position
   (the voted-route gate is forgeable by self-dispute at ~4%·X̄ per act;
   dominance + reversibility is the actual defense, and disputing junk
   appeals is +EV while dominant). Related owner calls: meta-CC
   **non-transferable at launch** (recommended; spec: peer transfers
   restricted, escrow legs and curve mints exempt — else every bond/stake
   bricks; conspicuous pre-buy disclosure that meta-CC can never be sold,
   transferred, or redeemed) and **near-zero meta emission** (simplification
   worth considering; orphaned unsellable rewards are a UDAP disclosure
   burden and legally helpful but economically pointless). The deployer's
   address is the visible sole policer of the appeals layer during
   bootstrap — recorded (Ooki-cohort attribution).
5. **StartCourt creation fee** (burned GNOT, frozen constant): amount is an
   owner call — large enough that court-count floods price like claim
   floods, small enough not to kill permissionless court creation.
6. **Terminology**: "supreme" never in render/public copy; prefer "review"
   over "appeal" in user copy.

## 14. Changelog

- **v0.1** — initial draft (constitution, three authorities, union-of-bits,
  open-votes carve-out, edit freeze, folders, seeding, polish window, meta
  court as verdict-driven appeals).
- **v0.2** — round 1 ingested: policing-window clause; purge exception;
  audited-file diff; strips replacing the open-votes carve-out; `mod:clear`;
  global clear-any-bit; voted-route gate; staleness/predate guards;
  suspension masking; court-local election; write-once-realm sequencing;
  seeding relabeled honestly; priority/openBlocks re-anchors; legal ledger.
- **v0.3** — round 2 ingested (the round-1 fixes attacked; 1 CRITICAL,
  8 HIGH):
  - *Strips rebuilt* (the CRITICAL + three broken dispositions): membership
    at lifecycle sites — PostAnswer/Crystallize/provClose/CloseDeadClaim —
    not vote sites (the undisputed path never entered v0.2's index);
    **ascending entry-height ordering** (anti-flood: past heights can't be
    manufactured; urgency: oldest answered ≈ nearest minting; one monotone
    key); span excludes provClosed/closed (v0.2 stranded them forever);
    seeded-unanswered segregated off the urgency page; realm-level index +
    per-court sub-cap for the directory strip; priced StartCourt; paginated
    reads; `mod:` appeals resident from birth with parse-visible redacted
    rows.
  - *Suspension overhauled*: global recovery covers the flag (captured-meta
    mass-suspend was unrecoverable — econ+mech independently); unsuspend →
    voted route (legal+mech+econ independently); write-refusal except
    clear-own-bits; election passage clears the flag; membership stamps.
  - *Staleness guard actor-scoped* (v0.2's was livelock-able by free
    re-toggles): respondent transitions never refuse, third-party
    transitions do; executedAt cooldown; idempotent-by-state.
  - *Election hardened*: escrow-netted quorum (raw supply was unpassable on
    active courts); doubling bond + cooldown (flat bond was a 1-CC/week
    latch camp); epoch pinned at open; addresses-only.
  - *Purge restructured row-level* over the full user-text inventory (court
    names uncapped + ledger copy + folders + log rows were unreachable);
    whole-court purge + OpenClaim gate (constitution carve-out #2); global
    bit redefined as all-surface text redaction (deep-link full-render was
    internally inconsistent and under-complied with "disable access");
    DMCA verb mapping + operating rules + runbook; binding parse persisted
    at PostAnswer (purge-as-veto closed).
  - *Honesty items*: voted-route forgery named (deployer dominance is the
    real parameter; policing +EV while dominant); events carry no user
    text; claim-lane events added; StartCourt delay param (fixture story
    was inconsistent); Unstake gate documented as redundant; §2 table
    corrected (answer.gno, directory.gno added; records.gno removed);
    28-site fixture count; "sweep" → CloseDeadClaim.
- Rounds 1–2 tallies: r1 ~40 findings (1 CRITICAL-legal), r2 24 findings
  (1 CRITICAL-econ, 8 HIGH). Round 3 re-attacks v0.3.

## 15. Integration items (deferred edits to other docs)

- REGULATIONS.md — new **content/platform-liability axis**: CDA 230 contours
  (incl. the recorded non-waiver point: moderating third-party content does
  not forfeit §230; moderator-authored strings and seeded titles are
  unshielded first-party speech); purge rationale; **DMCA operational trio —
  registered designated agent (no agent, no §512 safe harbor), §512(i)
  repeat-infringer policy (address-level render-layer analog — design item),
  §512(g) counter-notice/put-back procedure** (the global-bit manual
  put-back); NCMEC §2258A duty; the purge **category-code table** (which
  statutes get codes — counsel drafts); whole-court-purge facilitation
  question (§3.2).
- REGULATIONS.md exposure map — row 6: **meta-CC** (founder-deployed,
  platform-wide adjudication authority; mitigations: non-transferability,
  near-zero emission option, functional-only copy); row 2 amendment
  (curation/seeding strengthens Howey prongs 3/4; counter-facts: render-only,
  electorate-removable mods, I5 uncompensated seeding); row 3 Ooki wording
  ("…or formulaic render-layer moderation acts"); DUNA correction — the
  **meta electorate** is the DUNA-cohort candidate; the global DAO and mod
  sets are **operator/agent exposure**, not member liability.
- PLAN.md §7.4 additions: seeding never marketed with curve-cheapness;
  "featured" criteria content-based, never price/volume; meta-CC copy
  strictly functional; mod-string and seeded-title hygiene is
  removal-grade.
- PLAN.md §7.5 counsel checkpoints: DMCA agent registration; NCMEC
  reporting; category-code table sign-off; whole-court lifecycle question.
- PLAN.md §12: owner-flag rows for §13.1 (sequencing), §13.4 (meta genesis
  sizing + transferability + emission), §13.5 (creation fee), and the
  compliance-uses-global-bit-only operating rule.
