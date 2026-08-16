# MODERATION.md — render-layer moderation, the meta court, and seeding

> **STATUS: v0.4 — round-3 vet ingested (3 lenses re-attacked the v0.3 fixes;
> 0 CRITICAL, 4 HIGH, all breaking a v0.3 disposition with a clean fix; the
> rest MED/LOW). VETTING continues; round 4 re-attacks the deltas only.**
> Statuses: `DRAFT` → `VETTING` → `ACCEPTED` / `REVISED`. Additive to
> launch-cleared V2 (now PLAN v0.40 — see §13.1 sequencing and the drift note
> below). PLAN/REGULATIONS edits deferred to integration (§15) to avoid racing
> the active build session.

> **Drift note (other session, PLAN v0.40):** the live branch adopted a
> **draw-proportional anti-mill slash** — `slash = min(bond, max(4.5%·X̄,
> 1.6·midGross))` — and a fix so `SettleUndisputed` no longer resets a
> conclusive-low tier to mid. Both touch files this plan edits (`quality.gno`
> `settleSlash`, `session.gno`). §8's settleSlash fix must be re-expressed
> against the v0.40 slash shape at build time, and every "settleSlash reads
> params" reference re-read against HEAD first.

## 0. Posture

Owner-directed scope (2026-08-16): a global moderator DAO that can hide courts
from the front page; per-court moderator sets that can hide items; a META court
deployed by default that overrides any court's moderators; cheap moderator
seeding; an edit story for claim text. Owner position overridden with consent:
**staked-on text is never rewritten** — edits close at first stake; after,
moderators annotate.

Three understandings anchor the design (rounds 1–3):

1. **Discovery is economics.** Money paths never read moderation state
   (I1/I2), and that is insufficient — hiding shapes who polices, and V2's
   junk defense is discovery-driven. Hence the policing strips (§5.3).
2. **Visibility dies by flooding, and the flood has three doors.** Ordering
   by ascending entry height shuts the "manufacture an older row" door;
   **per-actor sub-caps** shut the "own the target, pre-position blockers"
   door (round 3); **routing unanswered rows to a separate pending list**
   shuts the "cheap never-answered row" door (round 3). All three are needed.
3. **The constitution bends in exactly two places, both legal-hold**: row-level
   **purge** and the **OpenClaim gate on purged courts** (§3.2). Else
   discovery only.

## 1. The change in one paragraph

V2 already has the germ: `directory.gno` curates courts into
hidden/listed/featured tiers under a single `directoryAdmin`, "a hidden court
still works for anyone holding its address; moderation, not custody." This plan
generalizes that into a constitution and extends it downward (per-court item
moderation), upward (a meta court as the appeals layer, built from the court
machinery), and sideways (folders, seeding, a polish window). Moderation gains
one power — controlling *discovery* — plus two legally-forced exceptions, and
zero power over money.

## 2. The constitution — `REVISED (rounds 1–3)`

> **Moderation authority is render-layer authority. No moderation state is
> ever read by a money path, no moderation entrypoint ever writes one — and no
> moderation act may remove a claim from ALL discovery surfaces while it is
> still policeable.**

- Hidden ≠ voided: full lifecycle byte-identical (**I1**). Purge and global
  redaction touch *text*, never lifecycle: votes proceed on tombstones,
  refunds and draws run unchanged.
- Moderation entrypoints never write money state (**I2**), with the enumerated
  read-side gates and the **one money carve-out**: the election's proposer-bond
  legs move the *poster's own* CC to escrow and burn it on failure (round 3 —
  the tally is court-local like the flag lane, whose bond legs are the same
  shape). Read-only gates: `OpenClaimSeeded` reads set+suspension;
  `OpenClaim`/`OpenClaimSeeded` refuse on a **purged court** (touching nothing
  existing); the strips read moderation state to *include*, never exclude.
  **Build guardrail (round 3):** the purged-court gate touches ONLY
  `OpenClaim`/`OpenClaimSeeded` — never `PostAnswer`/`Stake`/withdraw, or
  answered-claim stakers strand (no dead-close exists for answered claims).
- Reachability (**I3**): deep links + per-claim positions render under
  courtMod/meta bits (banner). The **global** bit is stronger — all-surface
  text redaction (§3.2) — but money state, IDs, and deadlines render
  everywhere. No on-chain "all my claims" index exists or is added; clients
  enumerate via claim-lane events (which carry **no user text**).
- Every act is attributed, **category-coded** (global-bit and purge acts) or
  reasoned (≤ 200 chars, sanitized; courtMod/meta editorial acts), evented,
  and rendered in the per-court log (**I6**). Events carry actor, act code,
  target, height, and a reason **hash** — never reason/annotation/title text
  (events are unpurgeable; verified no current courtv2 event carries user
  text; `VoteWithReason` is never exposed).
- **User-text inventory** (purge must reach every row): claim titles;
  annotations; relabels; mod-log reasons; folder names/descriptions; **court
  names** (length-capped at StartCourt; the grc20votes ledger name copy is
  render-dead — names render only from the Court struct). Replacement-vote
  proposals are **addresses-only, no free text**. Court **slugs** are
  `[a-z0-9-]` routing keys, unpurgeable by construction — whole-court purge
  aliases them at render.

**Exhaustive audited-file diff** (corrected round 3; none change money math):

| audited file | edit |
|---|---|
| `stake.gno` | polish-window gate on Stake (Unstake needs none — stake is provably 0 in-window; belt-and-braces gate kept, documented redundant) |
| `court.gno` | `Params.stakeOpenDelayBlocks` + `mustSane` (I7); `StartCourt` grows the delay param + a **burned-GNOT creation fee** (paid via `IsUserCall`+`OriginSend`+refund, sent to the keyless burn sink `…courtv2:burned` — makes StartCourt **direct-user-call only**, a composability change to flag) + reserved-slug `meta` refusal; `startCourt(admin, slug, name)` extraction takes **no payment** (init cannot attach coins) |
| `answer.gno` | priority re-anchor (§9); **`PostAnswer` writes: strip-index entry, seeded-list→strip move, and the persisted meta-parse** (§3.3/§5.3) |
| `crystallize.gno` | seeded gate on author draw AND `AuthorBonus` (I5); `openBlocks` re-anchor (§9); strip-index exit in `Crystallize` |
| `quality.gno` | `settleSlash` bounty base = the claim's actual recorded burns, **reconciled with the v0.40 draw-proportional slash shape** (§8) |
| `dispute.gno` | strip-index exit in `provCloseClaim` |
| `claim.gno` | `OpenClaimSeeded` + seeded-list entry; **new title-edit entrypoint** running the full parser+latch+membership acquire/release/refuse block (I4); seeded-list drop in `CloseDeadClaim`; purged-court gate on OpenClaim; claim-lane events |
| `directory.gno` | `directoryAdmin` → global-DAO set migration; `SetTier` logged + evented (I6) |
| `moderation.gno` / `modvote.gno` / `folders.gno` / `meta.gno` | new modules (state homes named in §4) |
| `session.gno` | none (verified: `SettleUndisputed` changes no strip membership, tolerates zero-deposit/seeded/window claims; re-verify against the v0.40 tier-reset fix) |

## 3. The three authorities — `REVISED (rounds 1–3)`

Hiding composes as a union of independent bits (courtMod / meta / global) plus
the per-court suspension flag and purge rows. Each authority sets/clears its
own bits. Cross-authority: meta clears the courtMod bit by verdict; **the
global DAO clears any bit AND the per-court suspension flag** (round 2).
Nobody clears the global bit but the global DAO; nobody reverses a purge.

### 3.1 Court moderators (per court)

- Per-court address set. Render-layer powers: hide/unhide (own bit), annotate/
  relabel (§6), folders (§7), seeding (§8), polish-window acts (§9).
- **Appointment**: the creator (`Court.admin`) bootstraps and manages the set
  until a **replacement election** passes; passage installs the elected set,
  permanently unseats the creator's appointment power, **clears the suspension
  flag** (new set starts armed), and **resets the election bond ladder**. Dark
  elected set → another election (viable because the quorum nets escrow).
- **The election** (court-local sealed tally in `modvote.gno`; no governor
  slots; the quality-vote idiom):
  - proposal: **addresses only**, no free text; **proposer = any address**
    posting the bond (holder-priced by construction);
  - weights: `coin.PastVotes` at the epoch **pinned at vote open** (the
    governor's propose-time pin, not the answer-time qualityEpoch pin);
    threshold 5001 bps; length `votingBlocks`;
  - quorum floor: **max(1, 5%·(PastTotal(at) − PastVotes(escrow, at)))** on this
    court's ledger (escrow = the realm address; netting it is the election's
    own rule — the dispute floor nets escrow only in its `votable/3` arm, so
    this is analogous in spirit, not a copy);
  - bond: `flagMinCC`, **doubling per failed election, frozen at 4×**
    (per-court ladder, the `flagCycles` idiom; reset only by a passed
    election); **failed bond half-burned/half-returned** (the dispute
    failed-quorum disposition — full return would make the ladder lockup-only
    and the camp free); a passed election returns it; no withdrawal path
    (quorum-miss and sub-threshold both count as failed);
  - **anti-camp (round 3):** the per-court ladder is sybil-proof against
    *challenger* spam, but lets an **incumbent self-fail** elections to ratchet
    the bond and hold the latch. So the **latch and cooldown are
    per-proposer-address**: a proposer that just failed cannot re-take the
    latch until a guaranteed challenger-open window (`flagCooldownBlocks`)
    elapses **at the current, not-yet-re-doubled bond** — a fresh challenger
    always finds an open latch at the standing bond. Honest residual: a failed
    junk election still delays an honest one by one cooldown at half-bond cost,
    accepted, mirroring the flag lane.
- Meta may **suspend** a set: bits masked at render (kept); **all set
  write-entrypoints refuse except clearing own bits** (de-escalatory — no
  queued masked hides, no poisoned staleness); elections stay proposable;
  `unsuspend` **requires the voted route** (round 2, three lenses).

### 3.2 The global moderator DAO (realm-wide)

Generalizes `directoryAdmin` into a small set; admin-managed membership. Verbs:

- **court tiers** (existing `SetTier`, now logged/evented);
- **global hide = all-surface text redaction**: every surface — strips, deep
  links, positions — renders banner + IDs + state + deadlines + money, **no
  user text**. Single-key to *set* (legal speed). Reversal is an explicit
  logged global act — **never silence/timer/meta**. **Re-setting a redaction
  that a global act recently cleared requires m-of-n (or a cooldown)** (round
  3: a rogue single-key insider otherwise wins the reversal race and camps a
  competitor's healthy claim redacted). This is the DMCA disable-access verb;
  put-back is the manual clear after a counter-notice window; purge is never
  the DMCA verb. **Global-hide reason strings are category codes only** (round
  3: a free-text hide banner republishes the noticed characterization).
- **clear-any** (recovery): any bit, any suspension flag.
- **purge — row-level, m-of-n**: tombstone any single row of the §2 inventory,
  addressed (scope, id); reason = statutory category code; irreversible;
  unappealable on-chain; never touches an open vote or lifecycle (I1/I2).
- **whole-court purge**: every text render tombstones (incl. future rows), name
  tombstoned, slug aliased `court-<n>`, routes serve money state — plus the
  second constitution carve-out: **`OpenClaim`/`OpenClaimSeeded` refuse on a
  purged court** (no new content accretes; existing lifecycle completes; verified
  unwind stays intact — unanswered stakers `Unstake` anytime, answered claims
  reach a verdict via permissionless settle/finalize/provClose then withdraw).

**Operating rules** (rendered policy copy): (1) legal-compliance takedowns use
the global bit or purge exclusively — courtMod/meta hides are editorial;
(2) runbook: on notice/knowledge — single-key global hide immediately +
evidence snapshot; hosting-is-offense → m-of-n purge within 72h + NCMEC per
counsel; DMCA stops at hide; (3) any courtMod hide citing illegality escalates
to global review within the runbook window; (4) global bit and purge are never
editorial.

### 3.3 The meta court (the appeals layer)

- **A court** — own CC, own electorate, own governor instance (its 56-slot
  pool is its own; appeal-dispute pressure is meta-local, never spills to other
  courts), created at realm init under reserved slug `meta` (refused to
  `StartCourt`), undeletable (no court-deletion path exists — verified), listed
  by default. Init calls the extracted `startCourt(admin, slug, name)` with the
  deployer (`unsafe.OriginCaller()`, the r/govern/token.gno pattern) as admin.
- **Bootstrap truth**: zero supply → fully inert (no CC, no claim opens); one
  buyer → appeals pass by **silence**. Dispositions: deployer genesis buy sized
  to stay **vote-dominant** (the real security parameter — see the forgery
  note), earmarked to dispute junk appeals (**+EV while dominant**: overturn
  returns the bond and mints comp while the attacker's answer bond burns —
  **but see §13.4: near-zero meta emission would neutralize this incentive and
  simultaneously raise the forgery price to the full 20%·X̄**), appeals visible
  from birth on the pending list (§5.3).
- Reserved title schemas (strict parse; near-miss → rendered "not a valid
  appeal" badge): `mod:unhide:<court>/<claimID>` (clear courtMod bit) ·
  `mod:clear:<court>/<claimID>` (clear meta bit) ·
  `mod:hide:<court>/<claimID>` (set meta bit) · `mod:suspend:<court>` /
  `mod:unsuspend:<court>`.
  - **Parse is stored structured state** (round 3: a render-time re-parse of a
    tombstoned title is unrecoverable and would orphan the latch): written at
    open, rewritten on each title edit, **surviving purge**. Redacted/purged
    `mod:` rows render the *current stored parse* (verb + target — realm-
    validated, category-code-class speech), never the raw title — closing the
    pre-answer-redaction blind spot on both the pending list and the strip.
  - **The binding parse persists at `PostAnswer`** (title frozen by then).
    `ExecuteMetaVerdict` reads only the persisted binding parse.
  - **Per-target appeal latch binds at `PostAnswer`, not open** (round 3: an
    open-bound latch let a never-answered 0.1-CC junk appeal camp a target for
    12 weeks). Pre-answer: the pending-list banner shows "appeal pending"
    without an exclusive lock; **first-to-answer takes the latch** — forcing a
    latch-holder onto the bonded, deployer-disputable path. Latch residency =
    answer → Crystallize/provClose/CloseDeadClaim (a passed-but-unexecuted
    appeal holds it through its `executedAt` window). The title-edit entrypoint
    runs the same acquire/release/refuse block (schema→non-schema releases;
    target-change releases+acquires, refusing if the new target's latch is
    held) — no latch bypass via an in-window edit.
- **Execution** (`ExecuteMetaVerdict(metaClaimID)`, permissionless):
  1. **Order of checks**: idempotence-by-state **first** (same-direction →
     no-op success, still stamps `executedAt`), staleness only for
     direction-changing executions.
  2. **Final verdict**: `Verdict() == YES` (the `provisional` field, never
     `cs.answer`); provClose/NO/non-final/nonexistent execute nothing. **A
     title purged *before* the PostAnswer persistence (no binding parse
     exists) executes nothing; a post-persistence purge never blocks execution**
     — the persisted parse is what makes it robust (round 3: guard 1's v0.3
     wording wrongly listed "purged-title" as a blanket refusal, reopening
     M-A24).
  3. **Aggressive verbs need the voted route** (`route == "vote"`):
     `mod:hide`, `mod:suspend`, `mod:unsuspend`. Restorative (`unhide`,
     `clear`) may execute from the undisputed route — silence may restore item
     visibility, never remove it, disarm, or re-arm. Honesty note: the route
     gate stops only the *silent* factory — a meta-CC majority forges
     `route == "vote"` by self-disputing (~4%·X̄ per act at default emission,
     up to 20%·X̄ if emission is near-zero); against capture the defense is
     deployer dominance + global clear-any + reversibility. Optional hardening
     if capture is observed: require minimum genuinely-opposed weight.
  4. **Staleness, actor-scoped — corrected (round 3)**: the verdict **binds
     the authority, not the individuals; it executes against the *current*
     set.** Only **election passages** (and any future global act touching
     membership) write the refusing stamp `lastElectionAt`; a respondent's own
     transitions — the courtMod set's re-hides, the creator's member shuffles,
     the set's suspend-lane self-acts — **never refuse** (v0.3's "membership
     changes stamp unconditionally" re-opened the M-A21 livelock in the suspend
     lane). Execution refuses iff a *third-party* transition postdates the
     appeal's `openedAt`: `max(bitLastAct_by_others, lastElectionAt) < openedAt`
     required. Per-verb respondents: `unhide` → courtMod bit (respondent
     set+creator); `hide`/`clear` → meta bit (respondent ∅; refusers = global
     clear + later meta executions); `suspend`/`unsuspend` → flag (respondent
     set+creator; refusers = elections/global/other verdicts).
  5. **`executedAt` cooldown, pinned (round 3)**: the respondent may not
     re-transition the bit **in the direction the verdict reversed** for one
     `votingBlocks` (in practice: re-hide blocked after a `mod:unhide`;
     clearing own bit stays allowed). Enforced at the courtMod hide entrypoint
     reading `executedAt[bit]` (a mod-entrypoint-reads-mod-state check — no I2
     carve-out needed). Global-DAO verbs and subsequent meta executions are
     exempt. **No-op executions still stamp `executedAt`** (else a mod clears
     one block early and re-hides free).
  6. **No phantom targets**: target court and claim strictly predate the
     appeal's `openedAt`.
- **Asymmetric supremacy (owner flag §13.2)**: meta overrides court moderators
  both ways; meta never clears the global bit nor reverses purge; global clears
  meta's bits/suspensions.
- Meta is moderated by its own §3.1 set + the global DAO. `mod:suspend:meta`
  suspends the *set*, never the verdict machinery. No fourth layer.

## 4. Moderation state — `REVISED (round 3)`

Per claim (`moderation.gno`, keyed by claimID): hide word (3 bits + per-row
purge flags), per-bit `lastActHeight` (split by actor class so respondent acts
don't set the refusing stamp) + `executedAt`, the append-only act log **with a
monotone row id per entry** (so purge can address a single row), and
`stripEnteredAt` (round 3: the index key must be idempotent — entry sites write
only if it is zero; exits delete the stored key; no double-entry when an
answered `mod:` row moves list→strip). Meta-side (`meta.gno`, keyed by claimID —
**not** on the shared `claimState`, to avoid bloating every court's claims):
the stored parse (open + persisted binding) and the per-target latch. Per court:
mod set + set-level `lastActHeight`, `lastElectionAt`, suspension flag +
`lastActHeight`, folders, tier, election ladder/latch/cooldown state, the
per-court policing index and pending list. Realm-level: one global policing
index (key = entry height | slug | claimID) + a courts-with-entries structure
for the directory strip.

Indexes write at the **membership sites only** (§5.3), never at vote sites;
per-row status (open vote / counter window / redaction) reads live at render.
Storage: one small row + one hash-only event per act. Render routes carved out
before the numeric-ID parse: `<slug>/mod` (paged log); the strips; a paginated
**read entrypoint** (query, not Render) for strip pages beyond the first.

## 5. Hiding: exact render semantics — `REVISED (rounds 1–3)`

### 5.1 Discovery surfaces (bits apply)
Court-page listings, folder listings, featured strips, the directory.

### 5.2 Non-discovery surfaces
Deep links + positions always render under courtMod/meta bits (banner); under
the **global** bit, redacted (IDs/state/deadlines/money, no user text); purged
rows render tombstones. Money renders everywhere.

### 5.3 The policing surfaces — the load-bearing guarantee — `REVISED (round 3)`

Two indexed strips (per-court + realm-wide directory) plus a per-court
**pending list**. The strip shows every claim in its **policeable span**; the
pending list shows unanswered `mod:` appeals (force-visible, so a pre-answer
appeal can't be embargoed — M-A25) and unanswered seeded claims.

- **Membership**:
  - **strip entry is uniformly `PostAnswer`** (round 3: v0.3 birth-entered
    `mod:` rows, which are unanswerable/unflaggable/undisputable and so a
    12-week 0.1-CC flood primitive on the one strip that must stay clean —
    they go on the pending list instead);
  - **pending list**: unanswered `mod:` appeals and unanswered seeded claims
    enter at open; each **moves to the strip at `PostAnswer`** and **drops at
    `CloseDeadClaim`** (its only two transitions — Crystallize/provClose
    require an answer, so v0.3's "same three exits" was impossible for the
    list);
  - **strip exit**: `Crystallize`, `provCloseClaim`, `CloseDeadClaim`; span
    `frozenAt != 0 && !crystallized && !provClose && !closed`.
- **Ordering: ascending entry height (oldest first)** — anti-flood (a past
  entry height can't be manufactured), urgency (settle deadline =
  answerHeight + 72h, monotone in entry height on the dominant undisputed path;
  it *approximates* urgency off that path — flags/escrow/counter windows
  restamp crystallize-eligibility, the named exception), one monotone key.
- **Per-actor sub-caps — the durable anti-blockade lever (round 3)**: both
  strips cap the rows any single **answerer** and any single **author** may
  occupy on a page (mirroring the directory's per-court sub-cap). This defeats
  the pre-position blockade *without touching money paths*: a mill that
  pre-answers 50 blockers before opening its target still gets only its
  small per-actor allotment, so honest rows stay on page 1. The guarantee is
  stated honestly as "**oldest N per actor** on page 1, with a paginated read
  entrypoint behind it," not "un-buryable."
  - *Optional courtv2 coordination item (touches the other session's
    `crystallize.gno`)*: the blockade's remaining teeth are the participant-only
    `Crystallize` grace (1 week) that stops defenders evicting blockers as fast
    as the mill mints. Reducing that grace for **verdict-final, flag-quiet**
    claims closes it fully but is a change to existing V2 behavior — flagged,
    not assumed. The per-actor sub-cap alone is sufficient and render-only.
- **Directory strip**: reads the realm index; **per-court sub-cap selects**,
  and the per-court representative is the court's **nearest-to-mint** row, not
  its oldest (round 3: oldest-representative let a mill's junk blocker
  represent its court; and with ≥50 courts, pass-1 alone fills the page, so
  selection must prefer urgency). **Selection and display are separate**: the
  sub-cap governs *which* rows are chosen; the chosen page *renders* ascending
  by entry height. Court creation is priced (§2), so court-count floods cost
  like claim-count floods.
- **Bits on strips/pending**: ignore courtMod and meta bits; the **global**
  bit redacts the row's text but still renders the stored parse for `mod:`
  rows. Tier-hidden courts' rows appear on the directory strip (redacted iff
  global).
- **Residency honesty (round 3)**: an answered-but-never-crystallized claim is
  *correctly* strip-resident (still flaggable = still policeable); do not add
  an exit timer. Every path terminates or is permissionlessly terminable
  (`SettleUndisputed`/`ResolveDispute`/`Finalize`/`provCloseClaim` all
  permissionless; Crystallize permissionless after the 1-week grace), but the
  cranks **pay the caller nothing** — mods/deployer are the implied janitors;
  state that.

## 6. Text: immutable after first stake; annotations after — `VETTING`

- **Edit window**: title editable while `now < openedAt + delay` (the
  `stake == 0` conjunct is provably redundant — staking is closed in-window and
  Stake is the only inflow — kept as defense). First stake / window close
  freezes text forever. Edits are evented (hash-only) and **re-run the `mod:`
  parser + latch/membership block** on the meta court (§3.3).
- **After freeze**: annotations (attributed, sanitized, ≤ 200 chars,
  append-only with row ids, above the original) and ≤ 1 relabel per authority.
  Purge rows are the sole text-mutation exception (I4).
- **Mod-copy rule** (first-party speech, no §230 shield — incl. **seeded claim
  titles** and mod reasons/relabels/folder names): category codes and
  claim-about-the-claim phrasing, never assertions of fact about persons;
  token/APR language in any mod string is removal-grade.

## 7. Folders: curation metadata, zero on-chain coupling — `VETTING`
Membership gates nothing; the flat list always remains; names/descriptions
sanitized, length-capped, purgeable as rows; moderator-writable; suspension
refuses writes. "Zero economic weight" = zero on-chain coupling, not zero EV —
PLAN's tripwire (ordered visibility sold for consideration) applies verbatim.

## 8. Seeding: deposit-waived, provenance-marked, discovery-guaranteed — `REVISED`
Fee waiver = bootstrap convenience; **the discovery guarantee (§5.3) is the
anti-farm mechanism** (an answered seeded claim is strip-resident, oldest-first,
per-actor-capped — visible junk gets flagged); the author-slice zero is
provenance (I5), not protection (winner 80/93 + answerer 5/93 still mint).
- `OpenClaimSeeded`: mod-only (reads set + suspension), waives CC deposit+fee;
  GNOT storage still paid; "seeded" badge + seeder address; polish window
  applies; unanswered seeds sit on the **pending list**, not the strip.
- **I5 lands twice** in crystallize.gno (author draw AND `AuthorBonus`).
- **`settleSlash` fix**: record the claim's actual burns at `ResolveFlag`;
  `settleSlash` reads them, not `c.params` — **re-expressed against v0.40's
  draw-proportional slash** `min(bond, max(4.5%·X̄, 1.6·midGross))` at build
  (the phantom-params under-pay is the same class of bug in either shape;
  re-derive the top-up arithmetic against HEAD).
- Zero-deposit tolerated end-to-end (four terminal sites `> 0`-guarded).

## 9. The polish window — `REVISED (rounds 2–3)`
`Params.stakeOpenDelayBlocks`, `mustSane` [0, 17_280]. Staking closed
in-window; visible; author edits; mods annotate/hide/folder; auto-opens.
- **`StartCourt` grows the delay parameter** (round 2). Meta + doc examples use
  720 (≈1h); fixtures pass 0 except window tests. **Fixture sweep count is
  re-derived at build** (the "28" figure was wrong — real: ~6 direct StartCourt
  sites + a `testCourt` helper at ~41 call sites + 1 txtar; absorbing delay=0
  into the helper is the cheap path).
- **Priority re-anchor**: 24h answer-priority anchors at
  `openedAt + stakeOpenDelayBlocks + answerWindow` (else it shrinks; at max
  delay it equals `priorityWindowBlocks` and vanishes).
- **`openBlocks` re-anchor**: crystallize's F9 cap divides by
  `frozenAt − (openedAt + delay)`, floor 1.

## 10. Invariants (deploy/test gate)
- **I1** — hidden/redacted/purged lifecycle equivalence: identical money
  outputs; **votes proceed on tombstones across all lanes {dispute rounds incl.
  meta appeals, quality flag/ride/counter tallies, elections}**; purged claims'
  authors still refund.
- **I2** — no moderation entrypoint writes money **except the election
  proposer-bond legs (poster's own CC only)**; the three read gates enumerated.
- **I3** — deep links + positions render under courtMod/meta (banner); global
  redacts (money/IDs/deadlines, no text); purged → tombstones.
- **I4** — title writes revert after window close/first stake; annotations
  append-only; edit entrypoint runs the parser+latch block; purge rows sole
  text mutation.
- **I5** — seeded: author draw = 0 AND AuthorBonus = 0, always.
- **I6** — every act logs a row + a **no-user-text** event; `VoteWithReason`
  never exposed.
- **I7** — `stakeOpenDelayBlocks ∈ [0, 17_280]`.
- **I8** — `ExecuteMetaVerdict`: idempotence-first; persisted-binding-parse
  only (pre-persistence-purge refuses, post-persistence-purge doesn't block);
  final-verdict field; voted-route gate on hide/suspend/unsuspend; actor-scoped
  staleness (only elections/global stamp the refusing field); direction-scoped
  `executedAt` cooldown with no-op stamping; strict predate.
- **I9** — strips: the undisputed/unflagged/all-bits-set claim appears (named
  fixture); unanswered `mod:`/seeded rows are on the **pending list, not the
  strip**; provClosed/swept exit; ordering ascending entry height; **per-actor
  and per-court sub-caps hold** (selection vs display separated; the directory
  representative is nearest-to-mint); birth-entered pending rows key on
  `openedAt`.
- **I10** — suspension masks + refuses all set writes except clearing own
  bits; unsuspend (voted) restores bit-for-bit; election passage clears the
  flag + resets the bond ladder; global clear-any reaches the flag.
- **I11** — purge m-of-n; row-level over the §2 inventory with stable row ids;
  category codes parse (the on-chain code set is **final or shape-extensible
  before the write-once deploy**, §13.1); unrecoverable through any realm read;
  whole-court purge tombstones future rows + gates OpenClaim.
- **I12** — election: per-proposer latch + cooldown; per-court bond doubling to
  4× reset by passage; failed bond half-burned; escrow-netted quorum floor;
  epoch pinned at open; no withdrawal path.

## 11. Attack ledger
(rounds 1–2 rows retained; round-3 additions and status changes below)

| # | Attack | Disposition | Status |
|---|---|---|---|
| M-A20 | Strip flooding (newest-first burial) | Ascending entry height + **per-actor sub-caps** + pending-list segregation + priced StartCourt + paginated reads | REVISED r3 |
| M-A21 | Staleness livelock (free re-toggle) | Actor-scoped: only elections/global stamp the refusing field; respondent self-acts never refuse; `executedAt` cooldown | REVISED r3 |
| M-A24 | Purge-as-appeal-veto | Stored structured parse persisted at PostAnswer; guard 1 refuses only pre-persistence purge | REVISED r3 |
| M-A25 | Pre-answer appeal embargo | `mod:` on pending list from birth; redacted rows render the stored parse | REVISED r3 |
| M-A30 | **Pre-position blockade** (own the target, pre-answer 50 blockers) | Per-actor sub-caps (render-only); optional crystallize-grace reduction flagged | NEW r3 |
| M-A31 | **Unanswered-`mod:` strip flood** (birth-entry, 12wk, 0.1 CC) | Pending list, not strip; strip entry uniformly PostAnswer | NEW r3 |
| M-A32 | **Appeal-latch camp** (never-answered junk holds a target's latch 12wk) | Latch binds at PostAnswer; first-to-answer takes it | NEW r3 |
| M-A33 | **Election incumbent self-fail ratchet + latch camp** | Per-proposer latch/cooldown at standing bond; per-court ladder only for anti-sybil | NEW r3 |
| M-A34 | **Single-key insider re-redaction sabotage** | m-of-n/cooldown to re-set a recently-cleared redaction | NEW r3 |
| M-A35 | **Title-edit latch bypass** (non-schema → schema in-window) | Edit entrypoint runs the full parser+latch+membership block | NEW r3 |
| M-A36 | **Strip index double-entry** (birth height ≠ answer height) | `stripEnteredAt` idempotency guard; pending→strip is a move, not a 2nd entry | NEW r3 |
| M-A37 | **Directory representative gaming** (junk blocker as court's face) | Representative = nearest-to-mint; selection vs display separated | NEW r3 |
(M-A1–A19, A22–A29 unchanged from v0.3; all REVISED/ACCEPTED.)

## 12. Build plan (sequencing decision first — §13.1)
1. `moderation.gno` — bits + split `lastActHeight`/`executedAt`, log with row
   ids (hash-only events), sets + `lastElectionAt`, suspension (mask +
   write-refusal), global DAO migration, redaction + re-set guard, row-level +
   whole-court purge, clear-any, `stripEnteredAt`. Tests I1–I3, I6, I10, I11.
2. `claim.gno`+`stake.gno`+`court.gno` — polish window (I7), StartCourt delay
   param + burned creation fee (user-call-only) + `meta` refusal, title-edit
   entrypoint (I4), `OpenClaimSeeded`, purged-court gate (OpenClaim only),
   claim-lane events; fixture sweep. Tests I4, I7.
3. `answer.gno`+`crystallize.gno`+`quality.gno`+`dispute.gno` — strip/pending
   index writes at the membership sites (idempotent); I5 both gates;
   `settleSlash` actual-burn base (v0.40-reconciled); openBlocks + priority
   re-anchors. Tests I5, I9-core.
4. `folders.gno` — curation metadata (purgeable rows). Tests: goldens + purge.
5. `modvote.gno` — election (per-proposer latch/cooldown, per-court doubling
   bond half-burn, escrow-netted quorum, addresses-only). Tests I12.
6. `render.gno` — filtering, banners, redaction (stored-parse for `mod:` rows),
   tombstones, `<slug>/mod`, both strips + pending list (ascending, per-actor +
   per-court sub-caps, nearest-to-mint representative, paginated reads), badges,
   meta header, §7.4 hygiene. Tests I3, I9-full, goldens.
7. `meta.gno` — `startCourt` extraction + init deploy, parser (stored parse at
   open, binding at PostAnswer, re-parse on edit), per-target latch (PostAnswer-
   bound), `ExecuteMetaVerdict` (I8 guards). txtar: appeal round-trip incl.
   overturn, refused stale execution (third-party transition), latch pass by
   first-to-answer, post-persistence-purge execution.
8. Integration (§15) + full audit pass, by the active build session, after
   convergence.

## 13. Owner flags
1. **Sequencing — realms are write-once.** Moderation ships inside courtv2
   (hold launch) or as a new realm never attaching to live-V2 courts. No
   additive patch path. Draft assumes hold-launch. **The purge category-code
   set must be final or shape-extensible before deploy** (else a later statute
   category has no code).
2. **Asymmetric supremacy**: keep (meta never clears global / reverses purge).
3. **Global DAO custody**: hide single-key (speed); **re-set + purge m-of-n**;
   keys at launch — owner call.
4. **Meta-court genesis + emission (coupled — round 3)**: the genesis buy must
   stay **vote-dominant** (the route gate is forgery-able; dominance +
   reversibility is the real defense; disputing junk appeals is +EV *only while
   dominant*). Meta-CC **non-transferable at launch** recommended (escrow legs
   + curve mints exempt or every bond/stake bricks; conspicuous no-exit
   disclosure). **Near-zero meta emission** is a real fork with a two-sided
   consequence to weigh: it *neutralizes* the deployer's +EV junk-appeal
   policing (comp is emission) **and** *raises* the forgery price from ~4%·X̄ to
   the full 20%·X̄. Owner call.
5. **StartCourt creation fee** (burned GNOT, frozen constant; makes StartCourt
   user-call-only) — amount an owner call.
6. **Terminology**: "supreme" never in render/public copy; prefer "review".

## 14. Changelog
- **v0.1–v0.3**: see prior entries (constitution; policing strips; purge;
  meta court; suspension; election; write-once sequencing; r1 ~40 findings /
  1 CRITICAL-legal, r2 24 / 1 CRITICAL-econ + 8 HIGH).
- **v0.4** — round 3 ingested (0 CRITICAL, 4 HIGH, all breaking a v0.3
  disposition):
  - *Strip flooding closed on three doors* (HIGH ×2, econ+mech): per-actor
    sub-caps (pre-position blockade M-A30); pending-list segregation so
    unanswered `mod:` rows never touch the strip (M-A31); latch bound at
    PostAnswer (camp M-A32); idempotent `stripEnteredAt` (M-A36);
    nearest-to-mint directory representative (M-A37); optional crystallize-grace
    reduction flagged as a courtv2 coordination item, not assumed.
  - *Execution guards corrected* (HIGH, mech+legal): guard 3 actor-scoping
    contradiction fixed — only elections/global stamp the refusing field,
    respondent self-acts never refuse (M-A21 livelock reclosed in the suspend
    lane); guard 1 purged-title contradiction fixed (M-A24); `executedAt`
    direction/site/exemption/no-op pinned; idempotence-first ordering; parse is
    stored structured state surviving purge (M-A25 pre-answer redaction).
  - *Title-edit state-machine row added* (mech): the edit entrypoint runs the
    full parser+latch+membership block (bypass M-A35).
  - *Election fully specified* (mech): per-proposer latch/cooldown at standing
    bond vs incumbent self-fail ratchet (M-A33); failed-bond half-burn; ladder
    reset by passage; no withdrawal; I2 proposer-bond carve-out.
  - *Redaction* (econ): m-of-n/cooldown to re-set a recently-cleared redaction
    (insider sabotage M-A34); global-hide reasons category-code only.
  - *Owner economics* (legal): §13.4 now states the near-zero-emission fork's
    two-sided consequence (kills policing +EV, raises forgery price 5×).
  - *Code-truth corrections*: §2 table adds the PostAnswer parse/seeded-move
    writes, directory.gno, and the four new-module homes; StartCourt
    burn-sink + user-call-only mechanics; escrow = realm address; epoch pinned
    at open (governor idiom, not qualityEpoch); meta has its *own* 56-slot
    pool; fixture count de-pinned; parse/index state homes named
    (`meta.gno`/`moderation.gno`, not shared `claimState`); v0.40 drift note +
    settleSlash reconciliation.
  - *Legal nits*: §230(e)(2) IP carve-out named; category-code set finalized
    pre-deploy; I1/I9 enumerate lanes and separate selection/display.

## 15. Integration items (deferred — do not race the build session)
- REGULATIONS.md — content/platform-liability axis: CDA 230 contours **incl.
  the §230(e)(2) IP carve-out** (ROP outside §230 in the 3d Cir., Hepp) and the
  moderating-does-not-waive-§230 point; purge rationale; **DMCA operational
  trio** (registered agent; §512(i) repeat-infringer policy as an address-level
  render analog; §512(g) put-back); NCMEC §2258A; the purge **category-code
  table**; whole-court facilitation question.
- REGULATIONS.md exposure map — row 6 meta-CC (non-transferable, near-zero-
  emission option, functional-only copy); row 2 curation/seeding prong-3/4
  strengthening + counter-facts; row 3 Ooki wording; DUNA correction (**meta
  electorate** = DUNA-cohort candidate; global DAO + mod sets = operator/agent
  exposure, not member liability).
- PLAN.md §7.4: seeding never marketed with curve-cheapness; featured
  content-based; meta-CC functional-only; mod-string + seeded-title hygiene
  removal-grade. §7.5 counsel: DMCA agent, NCMEC, category-code sign-off,
  whole-court lifecycle. §12: owner rows for §13.1/§13.4/§13.5 + the
  compliance-uses-global-bit-only rule.
