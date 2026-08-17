# MODERATION.md — render-layer moderation, the meta court, and seeding

> **STATUS: v0.44 — CONVERGED + BUILDING. Design converged at round 7; v0.9
> added the meta/local peer install (owner), v0.10 folded in its three-way vet
> consensus (§3.3). Modules 1–5 are BUILT AND GREEN on branch
> `courtv2-moderation`; modules 6 (render) and 7 (meta court) remain.**
>
> Historical status (round 7): The election's approval-voting re-spec
> held on the 5th check; round 7's residuals (β ceiling, turnout definition +
> churn-dual, m-of-n set rule, canonical sets, window timing, two-pass
> resolution) are all folded in-doc/as-build-notes — none was a mechanical
> break.** 7 rounds, ~24 adversarial passes; severity CRITICAL(r1/r2)→HIGH
> (r3–r6, all in the election)→resolved(r7). The election reached textbook
> approval voting; everything else converged by round 5. **Two standing owner
> calls before/at build: §13.1 sequencing (hold-launch vs new realm) and §13.7
> election human-review (the m-of-n parameter + the irreducible UI-dependent
> decoy residual).** Build proceeds on branch `courtv2-moderation`; the election
> module (`modvote.gno`, step 5) is built last and carries the heaviest tests.
> Additive to launch-cleared V2 (PLAN v0.40; drift note + §13.1). PLAN/
> REGULATIONS edits deferred to integration (§15).

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
| `court.gno` | `Params.stakeOpenDelayBlocks` + `mustSane` (I7); `StartCourt` grows the delay param + **name length-cap** + reserved-slug `meta` refusal; `startCourt(admin,slug,name)` extraction for init. **No GNOT creation fee** (owner decision v0.8.2): a fixed GNOT fee can't be sized without a USD oracle, so court-count floods are priced by the **per-byte storage deposit** the Court/coin/governor/curve state already incurs (protocol-set, self-repricing, no oracle) — which also keeps `StartCourt` **realm-callable** (no `OriginSend`, no user-call-only restriction) |
| `answer.gno` | priority re-anchor (§9); **`PostAnswer` writes (non-panicking): strip entry, seeded/pending move, persisted binding parse; and reads the per-target latch (refuse-if-held)** |
| `crystallize.gno` | seeded gate on author draw AND `AuthorBonus` (I5); `openBlocks` re-anchor; strip exit |
| `quality.gno` | `settleSlash` bounty base = actual recorded burns, re-expressed vs v0.40 `slashSizeFor` (§8) |
| `dispute.gno` | strip exit in `provCloseClaim` |
| `claim.gno` | `OpenClaimSeeded` + pending entry; **title-edit entrypoint** (rewrites stored parse + pending enter/exit — **no latch op**, round 4 F4); pending drop in `CloseDeadClaim`; purged-court gate on OpenClaim; claim-lane events |
| `directory.gno` | `directoryAdmin`→global-DAO migration; `SetTier` logged/evented; burn-descending + creation-newest secondary indexes for the front-page sort (§3.2) |
| `buy.gno` | maintain the per-court GNOT-burn total + its burn-ordered directory index entry on each `Buy` (write-only, additive) |
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
- **Set decision rule = m-of-n** (round 7 R3; recommended over any-one-member):
  a moderation act requires m of the n set members. This bounds the blast
  radius of a single captured or decoy member (the election's residual
  decoy-puppet risk, §3.1 tie-break) far more than any render change can — a
  lone puppet installed into a set can act on nothing. m/n are per-court,
  set at appointment/election. (Owner-flagged §13.7 as the one place a human
  should confirm the parameter.)
- **Appointment**: the creator (`Court.admin`) bootstraps the set until a
  **replacement election** installs a new one; installation unseats the
  creator's appointment power and clears the suspension flag. Dark/captured set
  → another election (quorum nets escrow, and the ballot is uncapped +
  price-not-veto, so a turnout majority is always able to install — that is the
  recovery this whole subsection must deliver).
- **The election** (court-local sealed multi-select tally, `modvote.gno`; no
  governor slots — but **NOT** the quality-vote 3-bucket idiom; a purpose-built
  accumulator, see below). Rebuilt four times (r3 latch-camp → r4 per-proposer-
  sybil → r5 auction ballot-veto → r6 majority-gate + cap); v0.6/v0.7 stops
  inventing and specifies **standard approval voting done correctly** — every
  prior break was a scarce excludable slot, and the r6 break was two of them
  (an absolute majority gate that made abstention a vote for the incumbent, and
  an undefined candidate *cap*). The correct mechanism has neither.
  - **latch = per-court (one open election window)** — pinned; a per-proposer
    latch splits quorum across concurrent elections.
  - **The ballot is every bonded candidate-set PLUS an explicit approvable
    "retain the current set" line — no candidate cap** (round 6 F2: a cap is a
    scarce excludable slot; a griefer front-fills it to keep a challenger off,
    reintroducing exactly the veto v0.5 removed). The ballot is **priced and
    paginated, not capped**; **at most one nomination per address** (sybil-
    priced by the bond, so no actor exhausts a global pool). **Nomination
    window ≥1 day (a load-bearing duration, round 7 R4)**: the per-court latch
    makes the window a temporal-griefing surface (miss it → ~15-day retry:
    ~8-day election + 7-day cooldown), but the defender always eventually wins
    (the ballot is *inclusive* — they nominate *into* the griefer's open
    election) and the griefer pays ½-bond per cycle, so it is bounded friction,
    not denial.
  - **Install by most-approvals-over-retain — no absolute threshold** (round 6
    F1: "5001 bps of approving weight" was copied from the two-sided dispute
    vote, which only means something because it has a yes+no denominator;
    approval has none, so an absolute gate + retain-as-silent-default makes a
    31% captured minority beat a 69% honest majority, or a motivated 5%
    capture). Each voter **approves any number of lines including retain**. The
    winner is `argmax` approving-weight over {all candidate-sets, retain}. A
    challenger installs **iff** it is the winner **AND** its approval exceeds
    retain's by ≥ the **margin floor** (= the quorum floor) **AND** turnout ≥
    the quorum floor; otherwise the current set is retained. Retain being a
    real ballot line judged by approvals (not a zero-approval fail-through) is
    what makes approval's anti-split property actually hold — adding an honest
    candidate cannot hand the seat to the incumbent.
  - **Turnout is distinct-voter weight** (round 7 R2 — not Σ approving-weight,
    which double-counts multi-approvers): keep a global per-voter set beside the
    per-(candidate, voter) dedup. **The accepted trade-off, stated:** because
    retain must now be *affirmatively* approved, a motivated ≥quorum minority
    can install over an *apathetic* majority (retain≈0). This churn-ease is the
    deliberate and correct side of the recovery/stability tension — an easy-to-
    unseat mod set is render-layer-only, reversible, and money-isolated (I2),
    and the residual is bounded by meta **suspension** and global **clear-any**,
    not by a mechanical incumbent floor (which would re-open the v0.6 lock).
  - **Tie / near-tie is deterministic and capital-stable**: within the margin
    floor, earliest nomination height wins, else retain (round 6 F5 — stops a
    whale installing a one-address-swapped **decoy** of an honest set by adding
    free approving weight). This backstops any decoy whose lead is ≤ the margin;
    a decoy from a **>quorum whale** can exceed the margin, so two more guards
    (round 7 R3): candidate-sets are stored **canonically (sorted)** so a mere
    reordering is not a distinct candidate, and render **diffs every differing
    address** of each near-duplicate against the earliest one it resembles — not
    just a "similar" flag. The irreducible residual (a large whale + a voter who
    ignores the diff) is UI-dependent and **bounded** — one puppet in an
    otherwise-honest set, reversible — and is the §13.7 human-review item.
  - weights: `PastVotes` at the epoch **pinned at nomination-window open**;
    quorum/margin floor **max(1, 5%·(PastTotal(at) − PastVotes(escrow, at)))**
    (escrow = the realm address); length `votingBlocks`.
  - **per-candidate bond scales with court size**: `min(quorumFloor,
    max(flagMinCC, β·votable(at)))` — measured on **votable weight, the same
    base as the floor**, then clamped to the floor. **β is FROZEN with a
    two-sided deploy invariant** (round 6 F4 — not an owner knob): a floor
    keeping the bond ≥ `flagMinCC`, and a **ceiling pinning β below the 5%
    quorum floor** (round 7 R1 — concretely β ≤ ~1% ), so "can you afford the
    bond" is never tighter than "can you win the vote": any coalition that can
    clear quorum can trivially field one nominator, and refund-on-install means
    a winner pays zero — so the ceiling can sit well under the floor without
    enabling spam.
    **The two runtime clamps are load-bearing, not belt-and-braces** (v0.14): a
    constant deploy gate can only police the RATIO, and two terms escape it.
    (i) The bond was quoted on **raw supply** while the floor nets the escrow,
    making the true ratio `(β/q)·(supply/votable)` — so the invariant *inverted*
    on any court holding >90% of its CC as stake and bonds, i.e. precisely the
    mature courts whose electorate most needs the remedy, and only those.
    (ii) `flagMinCC` is absolute, so below ~20 CC votable it is the binding term
    and exceeds 5% of votable outright. The floor wins: a ballot priced above
    winning the vote *is* incumbency-lock-by-price, and the spam bar is not
    needed there anyway — filling all 64 lines at 5% of votable each costs 3.2×
    the court's entire votable weight.
    **Bond refunds ONLY on install; every non-installed candidate half-burns**
    (round 6 F3: "refund if above the quorum floor" was self-approvable — a ≥5%
    holder approves its own junk to reach the floor and spams the ballot for
    free, then loops the cooldown to lock a captured court indefinitely). No
    withdrawal path; a fully-failed election (retain wins)
    starts a per-court cooldown of `flagCooldownBlocks`' **duration** — but in
    its **own** per-court election-cooldown slot (round 6 code-truth: the
    existing `flagCooldownBlocks` field is per-*claim* flag-lane state; reuse
    the constant, not the field).
  - **Tally structure**: a `candidateID→approvingWeight` accumulator + a
    per-(candidate, voter) dedup set (a voter may approve many lines, unlike
    the quality tally's single bucket), in the bptree idiom; the `argmax`
    winner scan is O(candidates) and **bounded/paginated** (the priced,
    uncapped ballot means candidate count is bounded by bond spend, but the
    scan must not assume a small set).
  - **I2 carve-out**: candidate-bond legs move the poster's *own* CC to escrow
    and burn on failure — the one money write a moderation-adjacent entrypoint
    makes (the flag lane's bond legs are identical).
- Meta may **suspend** a set: bits masked at render (kept); **all set writes
  refuse except clearing own bits**; elections stay proposable; `unsuspend`
  requires the voted route.

### 3.2 The global moderator DAO (realm-wide)

Generalizes `directoryAdmin` into an admin-managed set. Verbs:
- **court tiers** (existing `SetTier`, logged/evented). **Front-page sort
  within the listed tier (owner decision, v0.8.2)**: two paginated orderings,
  both served from monotone secondary indexes so render stays O(page) — (a)
  **GNOT-burn descending** (the default): cumulative GNOT burned into a court's
  curve is a real, un-sybil-able capital signal (you cannot fake burning real
  money), so it ranks courts by genuine commitment without any gameable
  activity/vote score — index keyed by `burned|slug`, updated on `Buy`; and
  (b) **creation order, newest first** — index by a monotone creation seq,
  reverse-iterated. Featured tier renders above both. This deliberately avoids
  an auto-ranking on any address-keyed or vote-keyed signal (a capture surface);
  the only rank is curation (tier) + burned capital + age.
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
  `mod:suspend:<c>` / `mod:unsuspend:<c>` · **`mod:setmods:<c>/<candidateID>`**
  (owner addition v0.9 — see the peer rule below).
- **Meta and the local electorate are PEERS over a court's moderator set
  (owner decision v0.9)**: the meta court can not only *disarm* a rogue set
  (suspend) but *install* one (`mod:setmods`), because suspend is the wrong
  tool for the case that motivates this — **negligent/absent moderators**,
  where disarming an already-idle set only deepens the gap; installing a
  working set is what that needs. Rules that keep it from flapping:
  - **Both peers act only through their own bonded/voted process**: meta via a
    `mod:setmods` appeal verdict (answer bond → dispute → sealed vote), the
    court via its coin-holder election. Neither can re-set for free; each
    override costs a bond or an election cycle, so an override-war is slow and
    self-limiting.
  - **Last-writer-wins by height stamp**: the most recent valid install (from
    *either* peer) is authoritative; whoever acted last holds until the other
    runs its full process again. Both installs stamp the set's `setActHeight`
    (already the meta staleness field) so the guards compose.
  - **The candidate set (addresses + m-of-n) is pre-registered by ID**
    (`RegisterModCandidate` → id) so the title stays short and any set size is
    allowed, mirroring the election's addresses-only candidate.
  - **Why safe:** installing is render-layer only (no meta act ever touches a
    coin), so a captured meta seating puppets can at worst censor discovery —
    reversed by the local electorate and backstopped by the global DAO. This is
    also a genuine mutual check: a court whose *local* coin is captured (a whale
    seats bad mods) can be corrected by meta, and a court meta wrongly targets
    is defended by its own electorate. Suspend remains the *fast* lever (freeze
    now, before a replacement set is known); `setmods` is the *corrective* one.
  - **Vet status: DONE (v0.10) — three identical adversarial passes, all three
    returned HOLD WITH FIXES.** The consensus, and what it forces:
    - **The safety claim was false as written and is now true in code**: no
      global verb reached set MEMBERSHIP (`ClearAnyBit` is per-claim), so a
      hostile install was globally irreversible while a suspension was a
      one-call cure. Added **`ResetModSet`** (m-of-n, disarms without
      appointing — global gets a cure, never the power to pick moderators) and
      **`GlobalSuspendSet`** (global could previously only *clear* the flag).
    - **The local electorate beats meta in any flap war** — ~8 days and 0 CC
      (the winner's bond refunds) against meta's ~14–28 days and 4–10 CC. So
      **the claim that setmods "corrects a whale-captured local coin" is
      withdrawn**: an attentive local majority is supreme over its own set,
      before and after this verb. `setmods` genuinely bites only on *quiet*
      courts — which is the negligent/absent case that motivated it.
    - **`route == "vote"` is forgeable for ~10%·X̄ with ZERO voters**: it is
      stamped for any once-disputed claim, including one whose only round
      FAILED QUORUM. Seating a principal on someone else's court must not
      execute on silence, so `setmods` additionally requires
      **`cs.decidedRounds > 0`** (a quorate round actually classified it) and
      a genuine contest (`credEligible`, the same test the credential already
      uses), not merely a self-dispute.
    - **Staleness must NOT anchor on `openedAt`** (2/3 explicit): the local side
      is always faster, so an `openedAt` anchor hands it a free mid-flight veto
      and meta's duty cycle goes to zero. Anchor after the vote concludes —
      **refuse if `cm.setActHeight > cs.verdictAt`** — plus an **execution
      expiry of one `votingBlocks` after verdict-final**, so bindings cannot be
      banked and discharged one block after each local election (the
      "K banked shots" inversion, which would have let meta win the war).
    - **The setmods latch is keyed per COURT**, not per (court, candidate), or
      unlimited parallel appeals run on one court.
    - **A meta install must not stamp `lastElectionAt`** (it would poison every
      other in-flight appeal on that court, reintroducing M-A40 through the
      shared primitive) **nor burn `creatorUnseated`** (one cheap appeal would
      permanently destroy a never-elected court's free repair path). Both are
      election-only effects now.
    - **Install clears the suspension only if the installed set DIFFERS from
      the judged one** — always-clearing made suspension escapable at zero cost
      by re-seating the same addresses; never-clearing delivered a pre-disarmed
      remedy. A one-address swap still escapes: the accepted M-A48 decoy
      residual, now costing a real membership change.
    - **`AppointMods` is refused outright while suspended** (it is creator-only
      and free, so it must not undo a bonded, voted disarm), and installs are
      never gated by `requireActiveMod` (or meta's own setmods would deadlock
      against meta's own suspend).
    - **"Render-layer only" is qualified**: install grants `OpenClaimSeeded`,
      which waives the deposit AND fee while winner/answerer slices still mint
      — an economic privilege. So **a meta-installed set may not seed**;
      creator-appointed and election-installed sets seed normally.
    - *Accepted, owner-decided:* meta-CC stays transferable, so ~5% of meta
      supply is purchasable and is the security parameter for every court at
      once (all three vets flagged it; §13.4 records the owner's call).
      ~~The meta court's `minAnswerX` is the explicit forgery-price dial — the
      forge costs ~10% of it.~~ **CORRECTED v0.15 (3/3 unanimous):** that was
      true of the code this section was written against and is false now. The
      `decidedRounds > 0` guard below means no aggressive verb executes without
      a QUORATE round, so the ~10%·X̄ zero-voter forge cannot run at all. The
      live price of a hostile aggressive execution is **5% of meta supply held
      as votable weight** (12.5% where `credEligible` applies) — already
      supply-relative, and 100× the term `minAnswerX` contributes. `minAnswerX`
      is not the forgery dial and no value of it makes it one; the dials are
      `quorumSupplyBps`, `compOfBurnBps`, and `credEligible`'s scope. What
      `minAnswerX` *does* price is OCCUPANCY — the review latch, the pending
      list, and the restorative silence route — which is why v0.15 makes it
      supply-relative anyway.
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
  here); (4) aggressive verbs (`hide`/`suspend`/`unsuspend`/`setmods`) require
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
  ~~Because meta-CC is one-way GNOT-sunk and non-transferable,~~ **meta-CC is
  TRANSFERABLE (§3.3, §13.4 owner call) — this paragraph was written against the
  wrong premise (caught v0.15).** Set the deposit high enough to make a 50-row
  flood park real capital for 12 weeks without pricing out a single appeal —
  a nuisance-cost ceiling, not a flood *gate*. **v0.15 makes the sizing rule
  explicit and deploy-checked** rather than left to judgement: a 50-row flood
  must cost at least one self-answer escape, `50·metaDepositBps ≥
  1.5·metaAnswerXBps`. The old `effMinAnswerX/100` peg failed this
  arithmetically — 50 rows parked half of ONE escape — so the deposit now
  carries its own fraction of supply.
  **The load-bearing escape, stated (round 6 F1):** a buried pre-answer
  appellant is not stuck — they **self-answer their own appeal** (`PostAnswer`
  has no author≠answerer ban), which moves the row **pending → strip**, where
  the sybil-proof deadline spine makes it discoverable-for-policing for its
  whole settle window and the deployer's junk-appeal-policing sees it. Cost
  ≈ `minAnswerX` (100 CC) + a 50%·X̄ answer bond (~50 CC) ≈ 150 meta-CC, all
  recoverable. *That* — not pagination — is what bounds pending-list burial to
  friction rather than denial; pagination merely preserves enumeration until the
  appellant escapes. (A floor-deposit appellant sorts to the bottom under
  deposit-descending order, so the escape, not the render key, is the real
  guarantee.)
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

## 7. Folders and argument edges — `VETTING`
**Folders**: membership gates nothing; flat list always remains;
names/descriptions sanitized, length-capped, purgeable rows; moderator-writable;
suspension refuses writes. "Zero economic weight" = zero on-chain coupling; the
tripwire (ordered visibility sold for consideration) applies verbatim.

**Argument edges (support/counter links between claims)**: permissionless to
*create* (anyone links, priced only by the chain-level storage deposit, zero
economic weight — no vote, no emission, no verdict effect), but **moderators may
hide an individual edge** (owner add, v0.8): a per-edge courtMod hide bit,
m-of-n like any mod act, suspension-disabled, so a spammy or abusive edge can be
pulled from a claim page without hiding either endpoint claim. This sits
trivially inside the constitution and needs **no re-vet**: an edge carries zero
economic weight and (as a typed link) no free text, so hiding one is strictly
weaker than the already-audited claim hide — it can affect nothing a money path
reads, and the audit's whole threat model is about hiding *claims*. If an edge
ever carries a label, that label is a sanitized, purgeable user string like any
other (the §7 tripwire on value-coupling still applies to edges verbatim).
Edges themselves are a curation feature that may ship after this moderation
pass; the hide primitive attaches to them when they land (same courtMod bit,
keyed by edgeID).

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
  candidate-bond legs (poster's own CC → escrow; refunded on install, else
  half-burned)**; money→moderation write-calls never panic; the four read gates
  enumerated; PostAnswer's latch read touches no bit/money value.
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
  voted unsuspend restores bit-for-bit; election installation clears the flag;
  global clear-any reaches the flag.
- **I11** — purge m-of-n, row-level with stable row ids; category codes parse
  (code set **final/shape-extensible before deploy**); unrecoverable; whole-
  court purge tombstones future rows + gates OpenClaim.
- **I12** — election: per-court latch; **approval ballot with retain as an
  explicit approvable line, no candidate cap, one nomination/address; install =
  argmax-approval over {candidates, retain} iff a challenger wins by ≥ the
  margin floor AND turnout ≥ quorum, else retain**; deterministic earliest-
  nomination tie-break within the margin; court-size-scaled per-candidate bond
  **refunded only on install, else half-burned**; **β frozen by two-sided
  deploy invariant** (bond ≥ flagMinCC floor, bearable-coalition ceiling);
  escrow-netted quorum/margin floor; epoch at nomination-window open;
  fully-failed election starts a cooldown; no withdrawal; O(candidates) winner
  scan bounded.

## 11. Attack ledger
(rounds 1–3 rows retained; round-4 additions/status below; M-A1–A29 as v0.4
except where noted)

| # | Attack | Disposition | Status |
|---|---|---|---|
| M-A30 | Pre-position blockade | **Deadline ordering (sybil-proof, strips)** + per-actor caps (contended pages) + priced doors; spine delivers discovery not self-financing slash (r5 prose) | REVISED r4/r5 |
| M-A33 | Election incumbent camp / ballot-veto | **Standard approval voting, correctly specified**: uncapped priced ballot + retain-as-explicit-line + most-approvals-over-retain (no absolute gate) + refund-on-install-only + frozen β | REVISED r4/r5/**r6** |
| M-A46 | **Approval majority-gate incumbency-lock** (absolute 5001-bps gate + retain-as-default → abstention favors incumbent; 31% minority beats 69% majority) | Retain is an approvable ballot line; install by argmax-over-retain + margin, no absolute threshold | NEW r6 |
| M-A47 | **Candidate-cap exclusion + free self-approved spam** (fill the cap to keep a challenger off; ≥5% holder self-approves to refund junk bonds, loops cooldowns) | No cap (price + paginate, one nomination/address); refund only on install | NEW r6 |
| M-A48 | **Decoy near-duplicate set** (whale installs a one-address-swapped clone of an honest set) | Deterministic earliest-nomination tie-break within margin; render diffs candidates vs incumbent | NEW r6 |
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
   name-cap + `meta` refusal (no GNOT fee — storage-deposit-priced, realm-
   callable), title-edit entrypoint (no latch), `OpenClaimSeeded`, purged-court
   gate (OpenClaim only), events; fixture sweep. Tests I4, I7.
3. `answer.gno`+`crystallize.gno`+`quality.gno`+`dispute.gno` — membership-site
   index writes (non-panicking, idempotent) + PostAnswer latch read + binding
   persist; I5 both gates; `settleSlash` actual-burn base (v0.40); openBlocks +
   priority re-anchors. Tests I5, I9-core.
4. `folders.gno`. 5. `modvote.gno` — election (per-court latch, multi-candidate
   approval ballot, court-scaled bond refunded-on-install, escrow-netted quorum,
   addresses-only, m-of-n set rule). **Implementation duties (round 7 R5):
   two-pass resolution** (pass 1 find max + retain; pass 2 earliest nomination
   within margin — a single-pass running argmax gets the tie-break wrong), the
   O(candidates) scan **paginated**, and a **separate per-court election-cooldown
   slot** (reuse the `flagCooldownBlocks` constant, not the per-claim field).
   Heaviest test coverage here per §13.7. Tests I12.
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
   meta-CC transferable per the owner's v0.9 call; **near-zero meta emission**
   is a two-sided fork (kills the deployer's +EV junk-appeal policing AND
   raises the forgery price). Owner call. **Superseded in part by §13.8.**

### 13.8 The meta franchise — owner proposal, three-way vet, UNANIMOUS ADOPT WITH FIXES

**The proposal (owner):** stop selling meta-CC on its own curve as the primary
channel. Instead, whenever anyone burns GNOT into ANY court, they receive
meta-CC pro-rata to the GNOT burned — so the appeals franchise belongs to the
platform's paying participants, weighted by unfakeable sunk capital.

**Why it is right (all three vets):** today meta's security budget is *one
actor's one-time purchase and never grows*. The binding threshold is not 50%
but **5%** (`quorumFloor`'s supply arm), so a 5% pivot costs ~0.108× the
deployer's genesis spend — on the order of **~54–108 GNOT, forever, at any
platform size**. Pro-rata makes the parameter **endogenous**: ~0.053×
cumulative platform burn, i.e. ~49× better at 100k GNOT burned and rising with
adoption. It also fixes the selection problem — a franchise sold at the door
selects for *appetite for the lever*, the worst possible filter for a review
body; burned capital selects for diversified exposure to the platform's
credibility.

**Six fixes, unanimous, without which it is a REGRESSION:**

1. **Mint on `spent` µGNOT — never on `delta`/CC minted.** A fresh curve sells
   CC ~44,721× cheaper per GNOT, and `StartCourt` is free, so per-CC minting is
   an unbounded **√N free-mint** of the platform's master governance token
   (10,000 shell courts ⇒ 100× the meta-CC for the same GNOT). Per-GNOT makes
   the court you burn into irrelevant — and this is safe *only because the GNOT
   is genuinely burned to a keyless sink with no redemption anywhere*. **Record
   that as a tripwire: it breaks instantly if a treasury or redemption is ever
   reintroduced.** Corollary: per-court caps and age/tier weighting are BOTH
   sybil-defeated by free court creation, so uniform-linear-per-µGNOT is the
   only defensible form.
2. **Meta's own curve must not stay a cheap side door.** `c.minted` advances
   only on curve buys, so a franchise channel that leaves it parked lets meta's
   curve sell a capture bloc at genesis prices forever (~45× cheaper). Either
   close meta's `Buy`, or advance meta's `minted` with every franchise mint —
   routing the franchise *through meta's own curve* additionally preserves the
   quadratic escalator (5% costs 0.108·B instead of 0.053·B) and keeps
   `mustInvariants` true **unchanged**, with ~4 orders of magnitude of headroom.
3. **Clamp at the cap, silently — NEVER panic.** `grc20votes.Mint` panics past
   `MaxSupply`, and the franchise mint lives inside `Buy`, the platform's only
   GNOT on-ramp: an unclamped mint means the day meta fills, **every `Buy` on
   every court reverts forever.** Same discipline as `reindexBurn` (never
   panics, never reads money state back).
4. **Fix the quorum denominator FIRST — this is the one that decides win vs
   regression.** Meta supply would inflate with platform burn while turnout does
   not, and `quorumFloor`/`electionFloor` take 5% of **raw** supply, so the bar
   rises ~158× and legitimate appeals go **quorum-dead** — while the zero-voter
   `route=="vote"` forge keeps working. Unfixed, the change *starves the honest
   path and leaves the forgery path operational*.
5. **Claim-on-demand is the fix, and it was derived independently by all
   three.** Accrue an address-keyed entitlement at `Buy`; mint only when the
   holder affirmatively claims. One mechanism solves four problems: supply then
   equals the *engaged* electorate so quorum stays reachable; the cheap-float
   capture route evaporates (an attacker must pay people to claim and sell —
   visible vote-buying); the unsolicited distribution becomes an opt-in
   membership act (the securities fix); and the unclaimed overhang becomes a
   **standing defensive reserve** — dormant burners can claim and dilute an
   attacker next cycle. Honest debit: the security base is *claimed* burn, not
   total burn.
6. **New deploy invariant + meta emission.** `mustInvariants` becomes a false
   certificate (it proves a bound only the curve enforces): restate as
   `metaGenesis + metaFranchiseCap + metaEmissionLifetimeBound ≤ MaxInt64/Bps`
   with an explicit frozen cap and counter. Meta emission must not be
   `S_live × bps` (it would size meta's budget off platform-scale supply):
   zero, or senior-lane-only on a fixed absolute stepped-down budget.

**Honest accounting (all three):** the headline capture-cost win is **~3–10×
smaller than gross**, because transferable coins let an attacker resell the
court-CC collateral and keep the meta weight, and because an airdropped
transferable franchise creates a large weak-handed float that is cheaper to buy
out than to out-burn. Fix 5 recovers most of it.

**OWNER RE-CHECK (surfaced, not overridden):** all three vets note the §13.4
transferability call was made about a *bought* coin. This proposal changes the
premise — **nobody pays for franchise-minted meta-CC, so locking it takes
nothing from anyone**, and transferability is precisely what enables the
cheap-float capture route. Keeping it transferable is the owner's standing
decision; the vets' unanimous recommendation is to re-take that one call on the
changed input.

**Also flagged — RESOLVED in v0.15:** meta's `minAnswerX` /
`minClaimDepositCC` were absolute CC constants frozen at StartCourt with no
retune path, so they decayed to nothing as meta supply grew and took §5.3's
flood-deposit argument with them. Now supply-relative (§14 v0.15). The panel
also found the constants were wrong in the OTHER direction at launch scale, and
that "the forge price does not scale, so `minAnswerX` stops being the forgery
dial" mis-states the position: it was never the dial once `decidedRounds > 0`
landed. See the correction in §3.3.
5. **StartCourt creation fee — RESOLVED (v0.8.2): no GNOT fee.** A fixed GNOT
   fee can't be sized without a USD oracle; court-count floods are priced by the
   per-byte storage deposit court creation already incurs (protocol-set, no
   oracle), and `StartCourt` stays realm-callable. (β is **no longer an owner
   knob** — round 6 froze it
   with a two-sided deploy invariant; the owner sets only the invariant's
   floor/ceiling shape, not a live value.)
6. **Terminology**: "supreme" never in render/public copy; prefer "review".
7. **The election is the highest-iteration, highest-risk module — recommend
   human review before it goes live.** The moderator-replacement election broke
   in four consecutive audit rounds (latch-camp → per-proposer-sybil → auction
   ballot-veto → majority-gate + cap); v0.7 settles on textbook approval voting
   (retain as an explicit line, most-approvals-over-retain, no absolute gate, no
   cap, refund-on-install, frozen β), which is a solved problem when specified
   correctly — but four breaks on one mechanism is a signal that a human should
   sanity-check the final election spec before build, and that the build should
   carry the heaviest test coverage here (the r6 fix set A–F maps to concrete
   test cases). Everything *else* in the doc converged cleanly by round 5.

### 13.9 Naming — "Pleadger", ticker PLEA, and a live symbol bug (3/3 unanimous)

> **SUPERSEDED (2026-08-16).** The owner rejected *Pleadger* on the trademark
> flag raised in this very section, and the project is now **Kourt** —
> **kourt.xyz**, ticker **KOURT**, canonical display **`KOURT:SLUG`**. Read
> everything below as the method and the evidence, not the answer: the
> per-court `uppercase(slug)` symbol rule, the reserved deny-list, and the live
> `"COURT"`-symbol phishing bug it uncovered all still stand and are all
> implemented. Substitute KOURT for PLEA throughout.

**Project name (owner):** ~~Pleadger — *plead* + *ledger*.~~ **Kourt.**

**Ticker: `PLEA`, not PLGR.** Three independent researchers reached this
unanimously, and the reasoning is not aesthetic:

- **PLGR is taken** by a defunct BEP-20 literally named **"Pledge"**; its dead
  pages persist on CoinMarketCap, Coinbase, Crypto.com, LiveCoinWatch,
  CryptoCompare and Yahoo (`PLGR-USD`). Adopting it means the top result for
  your own ticker is the exact word people already mishear the brand as.
- **PLGR reads "plugger"** — the established nickname for the AN/PSN-11
  Precision Lightweight GPS Receiver (Smithsonian-catalogued).
- **PLGR's consonant skeleton spells PLeDGeR**, the wrong word; Pleadger's is
  P-L-D-G-R. The ticker would actively cement the misreading.
- **PLGR is one character from PLTR** (Palantir) — a mega-cap in an adjacent
  surveillance/legal space, with six tokenised-PLTR assets already listed.
- **PLEA is genuinely unclaimed**: zero exact matches across 18,438 active
  CoinGecko coins, Dexscreener, CoinMarketCap and US equities. It is the literal
  first four letters of Pleadger, one syllable, spellable from hearing, and
  on-narrative — *entering a plea* is the product's core action.

**Per-court coin symbols — and a REAL BUG shipping today.** `court.gno` mints
every court's ledger with the literal symbol `"COURT"`:

    coin := grc20votes.NewLedger(name, "COURT", coinDecimals, epochBlocks)

Wallets, explorers and indexers key their display on **symbol**, not package
path, so every court's coin renders identically while having genuinely
different backing and zero fungibility (each is its own one-way curve with no
redemption). That is a live phishing vector — a malicious court's coin is
pixel-identical to the flagship's — and presenting distinct assets with
distinct risk under one label is a consumer-protection problem independent of
any securities question. **Fix before a second court exists.**

The scheme (2/3 preferred, and it needs no new registry):

- **symbol = `uppercase(slug)`, hyphens preserved.** A bijection with the slug,
  so uniqueness and the paid-deposit anti-squat property are inherited from the
  slug registry that already exists. Do NOT truncate or strip hyphens — both
  break injectivity (`ab-c` and `abc` would collide).
- **Cap slugs at 11 characters** at registration, so the symbol always satisfies
  GRC20's `MaxSymbolLen`.
- **Canonical display is namespaced: `PLEA:OREM`.** A bare court symbol appears
  only inside that court's own page, so a court coin can never read as "the
  Pleadger token".
- **Reserved deny-list enforced at slug registration**: `plea`, `pleadger`,
  `gno`, `gnot`, `ugnot`, `btc`, `eth`, `usdc`, `usdt` — otherwise someone
  registers the slug `plea` and mints a coin that impersonates the platform.

**Owner red flags (all three raised these independently):**

1. **"Pleadger" is a homophone of "Pledger"**, which is a LIVE fintech in an
   adjacent sector (pledger.fr, and pledger.finance in Palo Alto), plus a US
   `PLEDGER, LLC` mark and a "Pledger Charitable" app. "Plead" is also a Seoul
   legal-tech company. Sight/sound/meaning is exactly the trademark confusion
   test. **Commission a real clearance search in classes 9/36/42, US and EU,
   before spending on brand.** PLEA mitigates this (it anchors the *plead*
   vowel); PLGR would amplify it.
2. **Publish the pronunciation** (PLEE-jer) in the first line of every doc —
   the ticker is the cheapest, most-repeated enforcement of it.
3. `pleadger.com` is registered; `.io`, `.xyz`, `.org` and the social handles
   were still free at research time. Claim them before any public post — a
   coined misspelling with zero prior web results is trivially squatted the hour
   it is announced.
4. Defensively mint `PLEA` on other chains at launch: clean four-letter
   English-word tickers get squatted by memecoins within days, and a squatter
   with volume outranks you on every aggregator.

**Sequencing:** the rename is cross-cutting (docs, realm paths, README, PLAN,
this file) and touches the other session's files, so it lands LAST, after the
code audit, with a coordinated merge. **Realm import paths are write-once** —
`gno.land/r/kourt/kourtv2` cannot be renamed after deploy, so the path
decision must be made before launch, not after.

## 14. Changelog
- **v0.1–v0.4**: see prior entries (constitution; policing strips; purge; meta
  court; suspension; election; write-once sequencing). r1 ~40/1 CRITICAL-legal;
  r2 24/1 CRITICAL-econ+8 HIGH; r3 ~19/4 HIGH.
- **v0.8 — CONVERGED (round 7)**: the election's approval-voting re-spec held on
  the 5th check; round 7 confirmed all four r6 breaks closed and gave the reason
  the chain terminates (the prior versions chased an impossible gate; approval
  voting stops building gates and offloads the residual to the supervisory
  layers — meta suspension, global clear-any, reversibility, money-isolation).
  Residuals folded in, none a mechanical break: β ceiling pinned below the
  quorum floor (R1); turnout = distinct-voter weight + the churn-dual documented
  (R2); m-of-n set decision rule to bound a decoy puppet + canonical sorted sets
  + full-address render-diff (R3); nomination window ≥1d flagged load-bearing
  (R4); two-pass paginated resolution + own cooldown slot as build notes (R5).
  Owner flags standing: §13.1 sequencing, §13.7 election review (m-of-n +
  UI-dependent decoy residual).
- **v0.8.1 — owner addition (edges hideable)**: moderators may hide an
  individual argument edge (§7), not just a node/claim. Constitution-consistent
  and no re-vet needed (an edge is zero-weight, text-free, so an edge hide is
  strictly weaker than the audited claim hide). Build hooks it when edges land.
- **v0.8.2 — owner decisions (front-page sort + StartCourt fee)**: the listed
  tier sorts by **GNOT-burn descending** (default; an un-sybil-able capital
  signal) or **creation newest-first**, both paginated from monotone secondary
  indexes (§3.2). And **no GNOT creation fee** — a fixed fee can't be sized
  without a USD oracle, so court-count floods are storage-deposit-priced (no
  oracle) and `StartCourt` stays realm-callable (§2, §13.5).
- **v0.44 — `folders.gno` had folder tests and pinned none of its rules. All six
  now caught; batch 242.** Curation is the shallow end of the moderation
  constitution, which is presumably why it was never measured: four folder tests
  exist, and **every one of the file's six distinct guards could be deleted without
  any of them noticing** — both text-length bounds, the not-in-the-folder guard, the
  purged-text latch, and the purge's authority and category-code requirements.
  - **Every refusal is paired with a success**, and here that pairing is doing real
    work rather than ceremony: curation is m-of-n and needs an active moderator, so
    without the paired call each refusal would pass just as well if the caller
    simply lacked authority — a different guard entirely.
  - Two of the six needed **disambiguated anchors**: `CreateFolder` and
    `RenameFolder` share one length message verbatim, so a line-level anchor matched
    twice and `mutate.py` reported *bad anchor* rather than a survivor. Widened by
    the line that follows each — the sequence bump versus the folder lookup.
  - **The fixture passed alone and failed in company, and the cause was worth
    fixing properly.** `PurgeFolder` is m-of-n on the global DAO's `purgeM`, which
    is package-global and outlives any test that moves it, so a lone approval
    **banks instead of firing** if a neighbour left it above one. The fix is for the
    fixture to *establish* the threshold rather than assume it. **A TEST THAT
    DEPENDS ON PACKAGE-GLOBAL STATE MUST ESTABLISH IT, NOT INHERIT IT** — the
    companion to the rule that a test which grows such state owes the next one a
    tidy body.
  - I skipped my own duplicate-slug check before adding the court and got away with
    it; the scan afterwards was clean. Noted because the rule exists precisely
    because that collision is invisible test-by-test.
  - **And the new parallelism produced its own false failure, which is now guarded.**
    Per-runner GNOROOT made the gates safe to run together, so I ran five at once —
    and `make check` came back with two citation errors naming files nobody had
    touched: `NoProseSaysThis` and `nobody_cited_this.gno`. Both are **selftest's own
    controls**, read mid-mutation. Shadows made *staging* parallel-safe and did
    nothing for the one runner that rewrites the **working tree**: selftest's whole
    job is to break a guard and watch it complain, and the guards read the repo's own
    sources, so it edits them in place.
    - **A FALSE FAILURE IN A DIFFERENT GATE IS THE WORST KIND** — it names a file you
      did not touch, for a reason that is not true, and the natural response is to go
      fix a citation that was never wrong. So `repolock.py` has the mutating runner
      announce itself and the four source-reading guards refuse rather than report.
      A refusal costs one re-run; a phantom citation error costs a diagnosis.
    - Three controls, all firing, all institutionalised rather than run once by
      hand: a reader refuses while the tree is being rewritten; **the owner's own
      children are not locked out** (selftest invokes those readers *as* its
      controls, so without re-entrancy it could not test anything at all); and a
      **dead holder clears instead of wedging**, because a lock left behind by a
      crashed run would refuse every reader forever — worse than the race it
      prevents.
    - Corrected rule: check, isolation, txtar and the mutation batch are parallel-
      safe; **`make selftest` must run alone.** `mutate.py` is safe because their
      merge made it mutate the staged copy and it says so in the code.
    - **Adding the lock broke two guards, and their controls are what caught it.**
      The scripted edit inserted the sibling import after `import sys`, which in two
      of the four files sits *above* `from pathlib import Path` — so the guards
      crashed on a name that did not exist yet instead of running. Both showed up as
      **SILENT** controls in the selftest: the arms were watching for a complaint and
      got a traceback. **A SCRIPTED IMPORT MUST LAND AFTER THE NAMES IT USES ARE
      DEFINED** — placing it after the *last* top-level import is the rule that has
      no exceptions. Worth noting which way the evidence ran: the guards I had just
      written were broken, and the guards I had written earlier are what said so.
    - The lock is released on **any** exit, including a failing run. Registering that
      was not cosmetic: without it the lockfile outlives the process, and every later
      reader has to notice the pid is dead before proceeding — correct, but it makes
      a stale lock the normal case rather than the exception.
- **v0.43 — merged the other branch's 23 commits: it had been building the same
  mutation harness in parallel, and its infrastructure is better than mine, so I
  took it wholesale.** Their 199-row batch plus my 93 gives **236 rows**, every
  anchor verified. **WHEN TWO SESSIONS BUILD THE SAME HARNESS, TAKE THE BETTER
  INFRA WHOLESALE AND RE-APPLY YOUR OWN ADDITIONS ON TOP** — resolving line by
  line would have preserved my slower, lock-based staging out of nothing but
  authorship.
  - **`gnoroot.py`: every runner gets its own GNOROOT shadow.** This retires the
    shared staging lock and with it the *never two gates at once* rule I had been
    working under for the whole session. **Verified rather than assumed**: two
    `make check` runs exited 0 while the 236-row batch held its own root, with
    exactly one live shadow visible under the shared temp base. The base is
    deliberately shared across worktrees so the reaper can find roots abandoned by
    runs that died.
  - **`mutate.py` got two real fixes**: it mutates the *staged copy* rather than
    the repo's sources, and it consults an **importer graph** so only the suites
    that could plausibly object to a mutation run — the package's own tests plus
    its importers. Nine suites down to one in the common case, which is the entire
    reason my 93-row batch took 55 minutes. Their corrected graph also drops
    `cshares` and `tickbook`, which only V1 imports.
  - **Five rounds of fixes, every one found by a gate rather than by reading.**
    Worth stating plainly, because the same 23 commits looked clean on inspection
    each time.
    1. Nineteen of their anchors quote `panic("courtv2: …")` against my `kourtv2:`
       source, and six `dispute.gno` anchors needed my v0.34 `mustSpendable` line
       threaded in — their anchor spans exactly that region.
    2. **My keep-both conflict resolution dropped closing braces** in two test
       files, because the conflict region began before my functions' `}`. gno
       reports *"expected '(', found TestX"* when the parser is inside an unclosed
       function reading `func` as a literal. **`gofmt` IS THE CHEAP PARSE CHECK
       AFTER ANY CONFLICT RESOLUTION.**
    3. **Their fixtures are calibrated to their constants.**
       `TestAnswerBondCapBindsWhenTheFloorIsBelowIt` staked for X̄ = 400 CC, below
       my v0.27 answer floor of 500. The fixture needs X̄ in a **window** — above my
       floor but below ~1111 CC, or 4.5%·X̄ exceeds their 50 CC cap and the *floor*
       binds instead of the cap, defeating the test's own purpose. Recalibrated by
       measurement, with the window documented. (My first measurement read the
       *dust* arm, because `effMinAnswerX` only switches to the supply arm once the
       first epoch seals.)
    4. A test counting the old link target exposed a **production** defect the
       merge carried in: `quality.gno` panicked with `"courtv2: the dispute vote
       has closed"` while every other message in the realm says `kourtv2:`.
    5. `TestClaimListIsPageBounded` rendered 51 against a cap of 50, and the cause
       was **mine**: the court page emits one other link under the prefix their
       test counts — the moderation log at `:<slug>/mod`, from v0.19. **A PREFIX
       COUNT IDENTIFIES A ROUTE, NOT A LIST**; when a page grows a second link
       under the same prefix, a substring-counting test silently changes meaning.
  - **My own verification was broken twice, in ways worth naming.** The post-merge
    name grep reported *clean* because I piped a completeness check through `head`
    and read a truncated list. The corrected grep *also* reported clean, because
    `grep -rn … | grep -v kourtv2` filters on the **path**, and every file under
    `realm/r/kourtv2/` carries that token in its path — so it silently excluded the
    one directory most in need of checking. A python content-only scan with a
    negative lookbehind found all four hits at once. **NEVER PIPE A COMPLETENESS
    CHECK THROUGH `head`, AND NEVER FILTER `grep -rn` OUTPUT ON A TOKEN THAT
    APPEARS IN THE PATH.**
- **v0.42 — all 13 of `meta.gno`'s measured guards are pinned. Batch 93, gaps
  empty.** The last four closed as §13–§16 of `TestMetaLifecycleGuards`, and three
  of them taught something about the fixture rather than the code.
  - **§13, a claim with no binding appeal.** The binding is written at
    `PostAnswer` and only for a title that parses as a `mod:` instruction, so an
    ordinary claim filed on the review court reaches execution with nothing bound.
    Deleting the guard does not let a no-op through — the next line dereferences the
    binding, so the refusal becomes a **nil dereference**. A clean error and a VM
    panic are different behaviours and only one is a refusal.
  - **§14, a NO verdict.** Nothing else blocks it: the verdict is read from
    `provisional`, the field a dispute overturns, so without this guard losing an
    appeal and winning it do the same thing. The fixture needed a block inserted
    between the target claim and the appeal — **predate is strict, and check 2 runs
    before check 3**, so the claim guard fired first and the test was measuring the
    wrong refusal until the gap was widened.
  - **§15, a local install between verdict and execution.** `setmods` anchors
    staleness on `verdictAt` rather than `openedAt` deliberately — the local
    electorate is always faster than a meta appeal, so an `openedAt` anchor would
    hand it a permanent free veto and meta's duty cycle would be zero. But an
    install landing *after* the verdict must still refuse, which is the one window
    that anchor leaves open. Two fixture faults, both measured rather than guessed:
    alice had run out of **spendable** CC (15 sections of stakes are still locked
    and nothing withdraws), and the install shared the verdict's block, so a strict
    `>` read equal. Topping up converges because the floor is basis points of
    supply — adding S raises the requirement by a small fraction of S — and carol
    was topped up in the same proportion because `credEligible` needs her overturn
    weight above a quarter of a floor that also moves with supply.
  - **§16, a provisionally closed claim is not a verdict.** `verdictAt == 0 ||
    provClose` looks like one guard and is two. The first arm is **masked** — an
    undecided claim still carries `provisional == -1`, so the YES check refuses it
    anyway. The `provClose` arm stands alone: three failed rounds close a claim
    *without* deciding it, leaving `provisional` on the posted answer, and if that
    answer was YES then only this arm refuses. The state is set directly rather
    than driven through three failed rounds, because the **path** there is already
    covered by `TestDisputeFailedRoundsToProvClose` and what is under test here is
    the guard's reaction to it. Reusing §15's decided appeal also pins the **check
    order**: the verdict test is step 3 and the staleness test is step 7, so the
    message must change from the one §15 asserts to this one.
- **v0.41 — `meta.gno` measured for the first time: `TestMetaLifecycleGuards`
  earns its name on 7 of 13 guards, and the two predate arms it was missing guard a
  named attack.** The biggest zero-coverage surface, and the home of I8. Thirteen
  mutations written against `ExecuteMetaVerdict`'s check order and exactly-once
  machinery.
  - **The ten-section scenario is a real test, not a vacuous one.** It caught
    `credEligible` (the manufactured contest, v0.15), exactly-once execution, the
    execution expiry, the silence refusal, the target-claim predate and the global
    DAO's suspension interlock. That was worth establishing rather than assuming —
    exactly this shape, a test named after a guard, is what failed to pin the v0.25
    fix.
  - **Six survived, and the two now closed were the security-relevant pair.**
    §5 covered the target *claim* predate; the **court** and **candidate** arms were
    both deletable with nothing noticing, and they are not the same guard — each
    names a different thing that had to exist when voters judged the appeal.
    - The court arm: the parse is stored at open and existence is only checked at
      execution, so an appeal can name a court that does not exist yet. Without the
      guard an attacker files against a name, wins a vote on a court nobody could
      inspect because it was not there, then creates it.
    - The candidate arm guards an attack the code comment already described:
      registration is permissionless with a **predictable per-court counter**, so an
      attacker opens `setmods` against an unallocated id, wins the vote on a
      candidate set nobody could inspect, and only then registers their own puppet
      set at exactly that id. The new §12 performs it — puppet registered after the
      appeal, at id 1, the first and therefore predictable allocation — and requires
      the refusal.
    - **Asserted on the specific message, not the shared substring.** All three arms
      contain *"does not predate"*, so asserting that loosely would let the claim
      guard stand in for the other two. §11 and §12 name `target court` and
      `candidate set`.
  - **Four still unpinned, recorded rather than implied**: a claim with no binding
    appeal (deleting the guard turns a clean refusal into a nil dereference), an
    undecided verdict, a **NO** verdict, and a mod set changed between verdict and
    execution. The undecided one is *partly* masked — an undecided claim has
    `provisional == -1`, so the YES check fires anyway — but `provClose` with
    `provisional == YES` distinguishes them, so it is a genuine gap rather than an
    unpinnable one. Batch at **89**; gaps at **four**.
- **v0.40 — the last four moderation gaps are closed; the known-gaps list is
  empty and the batch stands at 80, all caught.** The global DAO discards its
  banked approvals whenever *who may act* changes, or *how many must agree*:
  `AddGlobalMod`, `RemoveGlobalMod`, `TransferGlobalAdmin` and
  `SetPurgeThreshold`. All four share one body, all four were deletable without a
  test noticing, and all four are now pinned — **verified separately**, because one
  fixture claimed to catch four and catching one is the trap.
  - **The assertion is the pending count, not the behaviour.** Bank one approval,
    make the change, require the count to be **zero**. Driving it through
    fire/no-fire would need a third approver per case and would have to fire
    irreversible actions to prove a negative. The control is what makes a zero mean
    anything: **with no membership change the approval survives**, asserted first,
    so every subsequent zero is the clear working rather than banking never having
    worked at all.
  - **A wrong premise of mine, caught by the fixture rather than by reading.** My
    first attempt transferred the admin seat to an **existing** member and the
    approval survived — which looked like a fifth bug and is not one. The clear sits
    inside the branch that *adds* the new admin, and that conditionality is correct:
    if the seat moves between existing members, membership is unchanged, so every
    banked signature still belongs to a current member and no consent has gone
    stale. The admin's own extra powers are unilateral and were never approved by
    m-of-n. The exploit the code comment describes — *seat a fresh key without
    resetting the banked signatures* — needs a **non-member**, which does clear.
    - Both branches are now pinned, including the deliberate non-clear, so nobody
      "fixes" the conditional into an unconditional wipe and thereby makes a stuck
      purge un-completable by rotating a key.
  - The fixture **restores the DAO** it grew — threshold back to 1, added members
    removed — because the global DAO is package-global and never reset between
    tests, so a test that grows it owes the next one a tidy body.
  - **What an empty gaps list does and does not mean.** It means every guard this
    audit found unpinned is now pinned or structurally enforced. It does **not**
    mean there are no unpinned guards: `meta.gno`, `folders.gno`, `strips.gno`,
    `modrender.gno` and `records.gno` still have **no mutation coverage at all**, and
    the only reason no gaps are listed there is that nobody has looked yet. The
    80-entry main batch is the signal; the empty file is a bookmark.
- **v0.39 — `AppointMods` pinned, and one guard proved UNPINNABLE BY ANY TEST, so
  it got a structural check instead.** Two more of the six closed, by opposite
  means, and the second is the interesting one.
  - **`AppointMods` discards the outgoing set's approvals** — the same v0.25 class
    reached by the other route, since a creator holds the appointment power until an
    election spends it and can therefore swap the set directly. Pinned, and
    mutation-verified. Observable where `ResetModSet` is not: the incoming set can
    act immediately, with no other clear in between. The fixture carries the same
    two premise assertions the repaired v0.25 one does (one banked approval before
    the swap; the TTL not yet elapsed when the new set acts) **plus** a closing
    control — the incoming set fires on its *own* 2-of-2, so the refusal is the
    stale approval being discarded and not simply a broken set.
  - **`ResetModSet`'s clear cannot be pinned by any test, and that is a fact about
    the design rather than a gap.** It empties the set, so nobody can act until
    `AppointMods` or `installModSet` re-installs one — and **both of those clear on
    the way in.** Its effect is therefore always superseded, a mutation deleting it
    survives every possible test, and always will. Verified exhaustively rather
    than argued: only three functions in the realm write `cm.members` or `cm.n`,
    and all three clear.
    - So it is defence in depth, it stays, and the thing that could make it
      load-bearing — **a fourth install path that forgets to clear** — is drift a
      test cannot see. That gets `scripts/check-membership-clears.py`: every
      function changing a set's membership must discard its pending approvals, or
      the build fails. Two controls, both firing: a fourth path with no clear trips
      it, and a write pattern that stops matching the code **fails closed** rather
      than scanning nothing and reporting clean. Six guards in `scripts/` now, all
      controlled.
    - Its mutation is removed from **both** batches. Keeping it in the main one
      would leave a standing survivor; keeping it in known-gaps would assert a gap
      that no test can ever close. **WHEN A GUARD IS UNPINNABLE BY CONSTRUCTION,
      SAY SO AND ENFORCE THE CONSTRUCTION** — the reasoning lives in the check
      script, where the next person to add an install path will read it.
  - Main batch **76, all caught**; known gaps down to **four**, all of them the
    global-DAO clears (`AddGlobalMod`, `RemoveGlobalMod`, `SetPurgeThreshold`,
    `TransferGlobalAdmin`), which share one body and need a second DAO member plus
    a raised threshold before any approval can be banked at all.
- **v0.38 — three of the nine unpinned moderation guards are now pinned; six
  remain, and they are all the same shape.** `TestModerationRangeAndAuthorityGates`
  closes the cheap three: `AppointMods`' m-of-n range (0 and n+1 both refused),
  `SetPurgeThreshold`'s authority gate (a stranger refused), and its range gate
  (0 and 9999 refused). Verified by mutation, not by passing — all three come back
  **caught**, and they have graduated from the known-gaps file into the main batch,
  which now stands at **75, all caught**.
  - **Every refusal is paired with a success.** A 2-of-2 install and a threshold of
    1 sit beside the six refusals, because without them all six would pass equally
    well if those functions were refusing *everything* for some unrelated reason —
    a stale realm, a spent appointment power, a missing court. **PAIR EVERY REFUSAL
    WITH A SUCCESS, OR A BLANKET REFUSAL PASSES AS A RANGE CHECK.**
  - The range test uses **9999 rather than n+1** deliberately: other tests add
    global DAO members, so `n` is order-dependent at the point this test runs, and
    **a bound you have to compute is a bound you can compute wrong.** An obviously
    out-of-range literal cannot drift.
  - **The six that remain are every other `clearPendingOnMembershipChange` call
    site** — `AppointMods`, `ResetModSet`, `AddGlobalMod`, `RemoveGlobalMod`,
    `SetPurgeThreshold`, `TransferGlobalAdmin`. Each needs the same choreography
    v0.25's fixture needed: bank an approval, change WHO may act, then have the new
    body try to fire on the old signature. And each must conclude **inside**
    `pendingTTLBlocks`, or it goes vacuous exactly the way v0.25's did. Note the
    four global-DAO sites share one body, so a single fixture may cover several —
    but **one test catching four mutations is fine; one test *claimed* to catch
    four and catching one is the trap**, so each is verified separately.
- **v0.37 — THE v0.25 DEPOSED-SIGNATURE FIX WAS NOT PINNED BY THE TEST NAMED
  AFTER IT, and the moderation constitution has no mutation coverage at all.**
  Measuring mutation coverage per file — rather than recalling what had been
  tested — showed the batch weighted almost entirely to the money path:
  `quality.gno` 15 mutations, `crystallize.gno` 10, `dispute.gno` 8, and
  **`moderation.gno` zero across 1063 lines and 51 guards**, plus nothing at all
  on `meta.gno`, `folders.gno`, `strips.gno`, `modrender.gno` or `records.gno`.
  **MUTATION COVERAGE FOLLOWS ATTENTION, NOT RISK.** Ten mutations were written
  for the moderation path and **all ten survived.**
  - **The one that matters.** `TestInstallModSetDiscardsTheDeposedSetsApprovals`
    exists, exercises the right attack, and did **not** fail when the fix it is
    named after was deleted. The cause is a second mechanism doing the work: the
    election takes `nominationWindow + votingBlocks` = 138,240 blocks to conclude,
    while `pendingTTLBlocks` is 120,960 — so the outgoing set's banked signature
    **expired by rule** before the incoming set ever acted, and the test passed
    with or without `clearPendingOnMembershipChange`. A guard and a clock were both
    sufficient, so neither was necessary, and the test could not tell them apart.
  - **The vulnerability is real, which is why this matters rather than merely
    being untidy.** A court sets its own voting window, and any court with one
    shorter than about six days leaves the deposed set's signature live. The
    default is simply longer than the TTL — so the *default* court is safe by
    accident, and every faster court is exposed. Fixed by giving the fixture a
    200-block voting window so the election concludes well inside the TTL, and the
    mutation is now **caught**.
  - **The premise is asserted, not assumed, both ways.** The fixture now checks
    that the outgoing set really banked one approval (`PendingApproval` = 1) before
    the election, and that the election has **not** outlived the TTL at the moment
    the new set acts. If a future change lengthens the window past the TTL again,
    that assertion fires instead of the test quietly going vacuous a second time.
    **WHEN TWO MECHANISMS WOULD EACH SUFFICE, A TEST PROVES NEITHER — PIN THE ONE
    YOU MEAN.**
  - Also corrected: my first batch was **mislabelled**. It aimed at "installModSet"
    but `installModSet` lives in `modvote.gno`, so the mutation deleted
    `AppointMods`' clear in `moderation.gno` instead and I nearly recorded the
    wrong conclusion. All seven `clearPendingOnMembershipChange` call sites are now
    labelled with the function they are actually in.
  - **Nine survivors remain, each a real gap and none yet closed**: the clears in
    `AppointMods`, `ResetModSet`, `AddGlobalMod`, `RemoveGlobalMod`,
    `SetPurgeThreshold` and `TransferGlobalAdmin`; the `m-of-n must be in 1..n`
    range gate; the `only the global DAO admin sets the purge threshold` authority
    gate; and the `purge threshold must be in 1..n` range gate. Every one can be
    deleted today without a single test noticing. Recorded here rather than left
    implicit, because a survivor list nobody wrote down is a survivor list nobody
    closes.
    - They live in `scripts/mutations-kourtv2-KNOWN-GAPS.json`, **not** in the main
      batch. The main batch is all-caught and has to stay that way: a batch with a
      standing survivor is a batch whose output people learn to skim, which is the
      same failure this document keeps finding in other guards. Every entry in the
      gaps file survives on purpose, the file shrinks as tests are written, and a
      CAUGHT result there means an entry graduates to the main batch.
- **v0.36 — the positions page shows what you hold, what is committed, and what is
  free, because after v0.34 the balance alone is misleading.** Locked CC stays in
  the holder's balance and keeps voting, so a client that shows only the balance
  tells someone they have coins to bond when those coins are already committed —
  and the refusal then reads as a bug in the realm rather than as the arithmetic
  it is. The positions route (`…/<slug>/<id>/<addr>`) is the only per-address
  surface, so it is where this belongs.
  - Labelled **court-wide, "all claims"**, deliberately: the stake and conviction
    figures directly above it are *this claim's*, and two adjacent sets of numbers
    at different scopes with no label is worse than showing neither. Locked spans
    every claim in the court.
  - **The partition is the assertion, not the three numbers.** `held` must equal
    `committed + free`; checking each figure separately would pass just as well if
    the page printed the balance three times under different labels. Asserted both
    in the rendered text and against the reads.
  - Four mutations added, because a render path with no mutation coverage is
    exactly how §7.4 came to be enforced on one word on one page: drop the section,
    print the raw balance as *free to commit*, print committed as zero, and drop
    the court-wide label. All four caught. One first came back **INVALID rather
    than caught** — zeroing the figure left the local unused, so the mutant did not
    build, and `mutate.py` correctly refuses to score a non-building mutant as
    caught. Rewritten to keep the variable live, so it tests the assertion instead
    of the compiler.
  - Nothing added to the claim page: it already links to this route, and
    duplicating a court-wide figure onto a claim-scoped page would reintroduce the
    scope confusion the label exists to prevent.
  - **I1–I12 audited against the code after five rounds of change, and the finding
    is traceability rather than coverage.** Four — **I2, I3, I8, I12** — were named
    in no test at all. That is not the same as untested, and checking before
    claiming it mattered: each is in fact enforced. I2's money-neutrality is
    asserted as *"hiding must not move escrow"*; I3 by the deep-link, tombstone and
    global-redact render tests; I8 by the ten-section meta lifecycle scenario; I12
    by the install-rule, turnout and bond tests. So the invariants hold — but you
    could not get from an invariant to its test, or back, for a third of them.
    Every one now cites the invariant it enforces. **AN ENFORCED INVARIANT NOBODY
    CAN FIND IS HARD TO KEEP ENFORCED** — the converse of this document's own rule
    that naming an invariant is not enforcing it.
    - Checked specifically for rot from v0.34, and none: I2's carve-out is still
      exactly the candidate-bond legs (the new `mustSpendable` is a read, not a
      money write); I1's *"purged authors still refund"* draws on the deposit,
      which is still custodial; and no invariant mentions where stake is held.
- **v0.35 — the mutation batch found that v0.34's own test walked five of six
  paths, and the isolation guard was reporting a success it had never checked.**
  `lock.gno` shipped as a new money-path file with **zero mutation coverage**,
  which is exactly the gap that batch exists to close. Eleven mutations were added
  — deleting each of the six spendable guards, making `spendable` ignore the lock,
  dropping the lock on stake, dropping the release on both unstake paths, and
  removing the over-release panic. Two survived on the first run, and both were
  real.
  - **The test said FIVE and there were SIX.** `TestLockedStakeCannotBeSpentTwice`
    enumerated another stake, the claim deposit, the answer bond, the flag bond
    and the dispute bond — and never the **election bond**, which `addNomination`
    posts out of the nominator's own CC. Deleting that guard survived. The comment
    claiming completeness is the thing that made it invisible: enumerating is only
    worth something if the enumeration is complete, and nothing short of a mutation
    run was ever going to say otherwise. **AN ENUMERATION THAT CLAIMS TO BE
    COMPLETE IS A CLAIM, NOT A FACT.**
  - `releaseStake`'s over-release panic also survived, because nothing exercised
    it. It is unreachable through any public path — it fires only if `p.stake` and
    the lock tree have already diverged — but an unreachable assertion nobody has
    watched fire is indistinguishable from a comment, and a refactor can drop it
    silently. Now pinned directly, along with the lock being unchanged by the
    refusal. All eleven caught, none surviving.
  - **And the isolation guard was claiming something it had not tested.** Its
    success line says tests "pass alone as well as together", but the together-run
    only happened for packages that had *already* failed alone — so when
    everything passed alone it printed that claim having never once run a suite
    together. A slug collision proved it: my new test reused `rl1`, which
    `render_test.gno` already owns, and slugs are package-global and never reset.
    Each test passed alone; the package died instantly with *"that slug is taken"*;
    the guard reported **success**. The together-run is unconditional now — one run
    per package against N per package for the sweep itself, so free — and a suite
    that dies with no attributable test gets its own `SUITE` label, because that
    shape prints no per-test marker to blame. Verified by reintroducing the
    collision: the guard now fails, with exit code 1 so `make check` gates on it,
    and all three labels have controls.
  - Worth naming as its own lesson, because it recurred twice in one change:
    **a test that passes alone and fails in company is the mirror of an isolation
    bug, and the sweep as written could not see it.** The other instance was
    `effMinDeposit` returning the dust arm until the first epoch seals and the
    supply arm afterwards, so a court funded just enough to run alone cannot
    afford its own claim once neighbours have advanced the clock.
- **v0.34 — STAKE IS A LOCK IN PLACE, NOT A TRANSFER. Staking no longer costs the
  staker their vote.** The last backlog item, endorsed 3/3 by two independent
  panels. `Stake` used to `Transfer(who, escrow, amount)`; it now records a claim
  against the holder's own balance (`lock.gno`) and the coins never move. Custody
  secured nothing — stake principal is never slashed and never burned, and
  `WithdrawStake` returns it 1× whichever way the verdict went — while it removed
  the staker's vote **court-wide**, on every election and every quality poll in
  that court, for as long as they were staked. The design only ever wanted a
  claim-scoped exclusion, and it already had one that works by rule rather than by
  custody (`isParticipant`). The deposit and the five bonds are **not** locks and
  still transfer: the realm has to be able to burn or redirect those on a loss, so
  it must actually hold them. That is the line between the two — custodial means
  *the realm may have to take it*.
  - **What custody was silently enforcing, and the reason this is the risky part.**
    Custody made double-commitment arithmetically impossible: the coins had left
    the balance, so the **ledger** refused a second spend, automatically, on every
    path, including paths nobody had thought about. A lock does not. The coins are
    still sitting there and the ledger will happily let them be spent again — and
    the second spend is one the realm cannot honour. Stake 100, post a 100 bond
    against the same 100, and at unstake the realm owes CC it does not hold and
    would have to **mint** to return, breaking supply conservation, which is the
    one invariant a token cannot lose. So a total, automatic check moved out of the
    ledger and into this realm, where it is a *list* — and a list can be one entry
    short. Every path that moves a user's CC into the escrow now sizes itself
    against `spendable(c, who) = BalanceOf − locked`, never `BalanceOf`, and
    `TestLockedStakeCannotBeSpentTwice` walks **all five** of them (another stake,
    the claim deposit, the answer bond, the flag bond, the dispute bond) with a
    fully-locked balance, then asserts no coin moved and the lock is intact. A new
    spend path belongs in that test. **WHEN REMOVING A MECHANISM THAT BUYS
    NOTHING, ASK WHAT IT WAS ENFORCING FOR FREE.**
  - Scoping was worth more than the edit. Conviction accrual reads
    `stakePos.stake`, the per-claim record, and **never** the escrow balance, so
    accrual is untouched. And — the assumption I had backwards — **no formula
    changes** in `votableAt`, `electionFloor`, `quorumFloor` or `qualityBars`:
    they keep netting the escrow, and the escrow simply stops containing stake.
    The expressions were already right for the world after the change. Exactly
    three sites move `stakePos.stake` (`Stake`, `Unstake`, the settlement
    withdrawal), which is what made the paired lock/release safe to reason about.
  - **A real behaviour change, in the direction the v0.31 ruling wanted.** Votable
    is now larger, so all three turnout bars sit higher in absolute CC. That is
    correct rather than incidental: the bar is a fraction of the people who *can
    turn out*, and stakers now can. Every coin added to the base is a coin that
    can also vote, which is precisely the property the netting-vs-clamp argument
    turned on. It also **retires item 17 outright** — votable now differs from
    supply only by bonds and deposits, so `q·votable` and `min(q·raw, votable/3)`
    converge, as the panel predicted they would.
  - `LockedOf` and `SpendableOf` are the new reads, because a balance that is
    partly committed and partly not is unusable to a client that can only see the
    total. `TestStakingDoesNotDisenfranchise` asserts the point of the whole
    change: a staker's `PastVotes` and the court's votable base are both unmoved
    across a stake, and the escrow's votes equal the deposit and fee alone.
  - **Exercised through a real transaction, not only in process.** The money txtar
    asserted that staking grows the escrow; it no longer does, so that section now
    pins the opposite on a real ledger — escrow unchanged across stake *and*
    unstake, the position recorded as a lock, and `LockedOf` + `SpendableOf`
    partitioning the balance exactly. Both halves are asserted deliberately: a
    lock that recorded nothing would leave spendable whole, and one that
    double-counted would leave it short. The figures were **measured, not
    guessed** — my first pass invented two plausible balances and both were wrong,
    which is the standing rule about fixtures earning its keep again.
  - **Blast radius: one test in 437.** `TestSettleUndisputedAndWithdraw` asserted
    that withdrawal *increases* the balance. It no longer does and should not: a
    withdrawal is a lock RELEASE, so it reports the full principal while the
    balance stays exactly where it was. The rewritten assertion requires the
    balance to be **unmoved**, which is the one that would catch a release path
    that also paid out — i.e. that minted principal from nothing.
  - **And the isolation guard was giving the wrong diagnosis.** It reported that
    test as *"passes only in company"* when it in fact failed **both** alone and
    with its package, because running each test alone was the only thing the guard
    ever did: with no together-baseline it could not distinguish a test that needs
    its neighbours from one that is simply broken, and it labelled both as the
    former — sending the reader to hunt for cross-test state that was never there.
    It now runs the suite once per affected package (only when something already
    failed) and classifies **per test**, scanning that run for the test's own
    failure marker. Per-package would have been too coarse: one unrelated red test
    would relabel every genuine isolation failure beside it as ordinary.
    - Both labels have a control now, and getting them took three wrong turns
      worth recording. My first `BROKEN` control inserted a function **above the
      import block**, so the package would not parse — it was measuring the parser,
      not the classifier. My second used `panic` instead of `t.Error`, which aborts
      before the per-test marker prints.
    - And **the pre-existing `ALONE` control's premise was dead.** It deleted a
      kind registration from `TestAMalformedRulesPayloadIsRefusedAtTheDoor` to
      reproduce a test that passed only in company. That test now fails *both*
      ways, verified by running it, because `resetLedger` builds a **whole new
      governor** — so the kind registry does not survive a reset and the leak it
      reproduced cannot happen any more. The in-code comment still asserted the
      opposite and has been corrected. The control is replaced by a real one:
      kourtv2's package-global `courts` tree genuinely is never reset, so a test
      reading a court a neighbour created panics alone and passes in company.
      **A CONTROL HAS TO FAIL FOR THE REASON IT NAMES** — the file already said so
      about a different arm; this is the second arm it was true of.
- **v0.33 — the merge brought back a bug I had already fixed once, and item 18
  turns out to be a fifth the size it was filed as, for a reason that also
  sharpens what it is actually buying.**
  - **The second staging lock came back.** `scripts/mutate.py` arrived from the
    other branch taking `.cryptocourt-stage.lock` while every other stager takes
    `.kourt-stage.lock` — the *exact* failure already found and fixed this
    session: two differently-named locks exclude nothing while looking protected,
    so a mutation run and a gate can stage into the same tree and delete each
    other's files mid-run, which this harness would score as a mutation it could
    not judge. All four stagers now agree on one name, verified by grep rather
    than by assumption. **A merge can reintroduce a fixed bug under a name the
    conflict resolver never shows you** — the file merged *cleanly*; nothing
    conflicted, because their line and my line were never the same line.
  - Their saved mutation batch needed retargeting, and five of its 56 anchors no
    longer matched. Four were the §7.4 comms-hygiene mutations — the ones that
    prove the render layer never prints a backing figure, an APR, the inflation
    ceiling or the word *redeem* — and one was the `SetTier` guard, stale because
    v0.24 moved that power from the lone `directoryAdmin` key to the global DAO.
    An anchor that matches nothing is reported as BAD ANCHOR rather than as a
    survivor, so this failed loudly instead of silently claiming coverage; but the
    coverage claim in the commit that added them was false against this tree until
    retargeted. Anchors now verified to match exactly once, **and then verified to
    be CAUGHT**, because an anchor that applies is not a guard that fires.
  - One incoming comment had gone from stale to wrong: it described `render.gno`
    writing `](/r/cryptocourt/courtv2:` at two line numbers, where the code writes
    `](/r/kourt/kourtv2:` at four sites. Rewritten against function anchors, which
    is what this repo requires anyway and is why the line numbers rotted.
  - **ITEM 18 IS SMALLER THAN FILED, AND CUSTODY IS BUYING ONE THING AFTER ALL.**
    Scoping found the separation that matters: conviction accrual reads
    `stakePos.stake`, the per-claim record, and **never** the escrow balance. The
    only escrow reads in the realm are four `PastVotes(c.escrow, at)` calls
    computing `votable` for the turnout bars. So a lock in place does not touch
    accrual, and — the assumption I had backwards — it needs **no formula change
    to `votableAt`, `electionFloor`, `quorumFloor` or `qualityBars` either.** They
    keep netting the escrow; the escrow simply stops containing stake. The
    expressions are already correct for the world after the change.
    - The stake transfer is redundant bookkeeping: `p.stake` and the escrow
      balance move in lockstep, and bonuses are **minted**, never paid out of
      escrow, so no payout depends on the staked CC being held there. That is
      item 18's claim — custody buys nothing — confirmed in code.
    - **But custody is buying sufficiency enforcement, for free.** Today the
      *ledger* makes double-committing impossible, because staked coins physically
      left the balance. Under a lock they do not, so a staker with 100 CC could
      stake 100 and then post a 100 bond against the same coins: the transfer to
      escrow succeeds, and at unstake the realm owes 100 it does not hold and
      would have to mint to honour — breaking supply conservation, the one
      invariant a token cannot lose. So the lock does not merely delete a
      transfer; it **moves a sufficiency check out of the ledger, where it was
      automatic and total, into this realm, where it must be written once per
      spend path and cannot miss one.** That is the whole risk of the item, and
      the reason it is worth a plan rather than an edit.
    - Plan: a per-court per-address locked total, one `spendable(c, who) =
      BalanceOf(who) − locked(c, who)` helper, and every one of the six sites that
      spends from a user balance routed through it — `Stake`, the answer bond, the
      claim deposit, the dispute bond, the flag bond, the election bond. The
      test that must exist before it ships: stake the full balance, then try to
      bond the same coins, and require the refusal — plus the conservation
      assertion that total supply is unchanged across a stake/unstake cycle.
- **v0.32 — THE SPEC AND THE CODE DISAGREE ABOUT WHETHER CC IS TRANSFERABLE, AND
  THE CODE HAS NEVER IMPLEMENTED IT. Owner decision needed; deliberately not
  built.** Scoping item 18 required knowing whether a lock in place is
  *enforceable*, which meant asking who can move a balance. The answer is nobody
  outside this realm: **CC cannot be transferred between two user addresses, in
  V1 or V2, and never could.** Every one of the 27 `coin.Transfer` call sites has
  the escrow account as its source or its destination; the exported write surface
  contains no `Transfer`, `Approve`, `TransferFrom`, `Delegate` or `Sell`; the
  curve is one-way so there is no burn-for-GNOT exit; and `r/offerer` is a
  governor fixture that never touches CC. A court coin is therefore mint-only,
  escrow-only, burn-only — **effectively soulbound**.
  - **This contradicts a recorded owner decision and several load-bearing
    passages of this document.** §"meta-CC stays transferable" is written as an
    owner call from v0.9, and the capture analysis reasons explicitly that
    *"transferable coins let an attacker resell the franchise"* and that
    *"transferability is precisely what enables the cheap-float capture route."*
    That entire route is currently foreclosed by the implementation. One stale row
    in the REGULATIONS.md exposure map still says non-transferable, which is the
    only place the code's actual behaviour is described.
  - **Two readings, and it is not my call which is right.** Either the decision
    was never implemented, or non-transferability is the real design and the
    decision was reversed without the document catching up. A soulbound court coin
    is a defensible and even strong design — it is the most complete
    anti-vote-buying property available, and unlike an address-keyed guard it
    cannot be sybilled around, because the capital itself cannot move. So this is
    flagged, not fixed. Adding user-to-user transfer is a large,
    security-critical behaviour change that needs its own design round, and
    implementing an owner decision this consequential from a changelog line would
    be the wrong kind of initiative.
  - **The divergence errs in the SAFE direction, which is why it has survived.**
    Every parameter was chosen assuming a resale/cheap-float threat the code does
    not actually expose, so the shipped constants are conservative against the
    real surface. The danger is the reverse: **if transfer is ever added, a large
    amount of already-settled reasoning silently becomes load-bearing again.**
  - **Concretely, it adds a fourth precondition to the v0.31 `electionFloor`
    ruling.** Panel C's refutation of the park-to-cheapen vector assumed the
    attacker must "buy existing float from existing holders on a secondary
    market." There is no secondary market, so they cannot acquire float at all —
    only park their own, which is monotonically self-defeating (`A ≥ q·V +
    (1−q)·S`). The 3/3 KEEP NETTING verdict is therefore safer than the panel
    knew, and **non-transferability is now one of the things it rests on.** If CC
    becomes transferable, re-open item 17 along with the three preconditions
    already listed.
  - Item 18's premise (b) is answered and **satisfied**: a lock in place needs no
    coin hook, because `grc20votes.Ledger` has none and needs none — this realm
    controls 100% of balance movement. A lock reduces to tracking a per-address
    locked amount and checking it at the six sites that spend from a user balance
    (stake, the answer/dispute/quality/election bonds, the claim deposit). That is
    tractable, and it is the next item.
- **v0.31 — the two moderation powers that had never run on a node, and a
  vacuous refusal caught by insisting on the message**. `SetTier` and
  `PurgeModLogRow` were the last two moderation entrypoints with no on-chain
  coverage: both were unit-tested in-process, but neither had ever been reached
  through a real transaction, a real signer and a real render. Both now are, in
  `kourtv2_moderation.txtar` — tier moves and comes back, a hide writes a log row
  that renders with the row id `PurgeModLogRow` addresses it by, the purge takes
  the moderator's free-text reason out of the rendered log, and the row survives
  with its height, actor and act code so the audit trail still shows that
  something happened and who did it. The hide itself is untouched: a text purge
  is not an unhide.
  - **The interesting part is a test that was passing for the wrong reason.** The
    non-DAO refusal leg asserted `! gnokey ... SetTier ... test2`, and the
    harness ships only `test1` — so the call did fail, but with `Key test2 not
    found`, never reaching the authorization check it claimed to prove. The
    negation passed on a missing key. What exposed it was asserting the *message*
    as well as the failure; a bare `!` would have shipped green forever. Fixed by
    declaring a funded `stranger` key via `adduser` (which must precede `gnoland
    start`), so the refusal is now the guard's own.
  - Auditing the rest of the file for the same shape found exactly one more bare
    `!`: the suspended-set hide refusal, which had a following state read proving
    the hide did not land but nothing proving *why*. It now asserts the
    suspension message too. **A NEGATION IS ONLY AS STRONG AS THE REASON IT
    PINS** — a `!` with no message is a test that the command failed, not a test
    that your guard fired.
  - The purge assertions were verified by positive control rather than assumed:
    with the `PurgeModLogRow` call deleted the script fails on the `! stdout`
    line, so the negative genuinely measures the purge. The negatives are also
    bracketed by positives on the same render output (`row 1`, `hide`), so a
    render that broke outright could not read as a successful purge.
  - **Also closed, without a code change: the meta-only deposit fee.** A standing
    backlog item wanted `depositFeeBps` split so the meta court could charge a
    higher flood fee than an ordinary court. Checking the premise first killed
    it: the fee is `dep · depositFeeBps`, and `dep` is `effMinDeposit(c)`, which
    has branched meta (`depositFloorBps` = 2) against ordinary
    (`ordDepositFloorBps` = 1) **since v0.27**. The fee is therefore already both
    meta-scaled and supply-scaled *through its base*; a second `metaDepositFeeBps`
    would stack a second meta multiplier on an already-differentiated base and
    double-count. The other half of the premise was right and needs nothing: the
    fee burns only on the dead-claim paths (expiry, conclusive low quality) and
    refunds on the live ones (settlement, crystallization), so a flooder always
    pays it and an answered honest claim never does. `depositFeeBps` stays global
    because, riding a differentiated base, it is a pure *what share of the filing
    cost is at risk* dial, and that share has no reason to vary per court. Second
    backlog item this round whose premise did not survive being read.
  - **And the recorded v0.29 dissent on `electionFloor` is resolved: 3/3 KEEP
    NETTING.** One v0.29 reviewer wanted `electionFloor`'s netted base
    (`q·votable`, shipped v0.14) replaced by `min(q·raw, votable/3)` — uniformly
    stricter, equal only at zero escrow. A fresh panel of three rejected it
    unanimously. The doctrine *franchise-scoped authority prices on supply* is
    sound but was being applied to the wrong instrument: supply is a **proxy** for
    the franchise, and under transfer-based staking escrowed coins are
    disenfranchised by construction, so `votable` **is** the franchise. A turnout
    floor is not a price — it is a quorum, and a quorum denominated in units that
    cannot participate is a disenfranchisement multiplier on everyone else
    (`q·raw/votable`: 10% at half escrow, 25% at 80%, pinned at 33% by the
    reachability arm — bars a dispersed token electorate does not clear). It would
    also have made removal hardest exactly when the docket is busiest, which is
    when moderator abuse is most likely, and handed a captured set a free
    near-1:1 voter-suppression lever (escrow instead of voting: abstain *and*
    raise the bar). Note the convergence that settles it: if item 18 ships,
    `votable == raw` and `min(q·raw, raw/3) = q·raw = q·votable` — NETTING and
    CLAMP become the same formula, so netting today already reaches the dissent's
    own end state without an intervening period of harder-than-intended elections
    and without an irreversible two-armed formula.
  - **The vector that prompted the review is real in sign and dominated in
    magnitude — 20:1.** Because `Stake` is a `Transfer`, raw is unchanged by
    staking and only `votable` falls, so parking stake *lowers* the election floor
    and cheapens deposing a set. But `∂floor/∂escrow = −q = −0.05`: parking a coin
    removes 0.05 from the requirement while **voting** that same coin adds 1.0. Any
    coin is 20× more useful held and voted, so the attack is strictly dominated by
    honest participation, and for a self-funded attacker parking is monotonically
    self-defeating (`A ≥ q·V + (1−q)·S`). Two panelists caught an error in the
    prompt's own framing, since verified in code: buying CC **mints** to the buyer
    (`Buy`), so raw and escrow both rise by the same delta and `votable` is
    *unchanged* — the bonding curve is not an attack surface here at all. Moving
    `votable` requires buying existing float on a secondary market, one-way, then
    handing the position to the defender as a hostage, because any bystander can
    freeze it by posting an answer.
  - **Three mechanical preconditions the verdict rests on, each verified in code
    rather than assumed** — a future reader re-proposing CLAMP should re-check
    these first, because if any fails the panel said its answer flips:
    1. **The base is pinned, not live.** The `election` record stores `floor` and
       `bond` at open and the resolve path reads the stored values, never
       recomputing. The snapshot height is `Epoch()-1`, a previous-epoch read that
       predates the election, and `votableAt` reads total and escrow at that *same*
       height. Both panels named live recomputation as the one thing that would
       turn a dominated attack into a purchasable option — an attacker who could
       watch the turnout shortfall and *then* park exactly enough to erase it.
       Invariant: **the floor of a live election never decreases** — and because
       naming an invariant is not enforcing it, this one is now *asserted* by
       `TestElectionFloorIsPinnedAtOpenAndNeverFalls`, which opens a ballot, parks
       80% of supply into the escrow afterwards, and requires the pinned floor to
       be unmoved **while a live recomputation at the current epoch comes back
       strictly lower**. That second half is the positive control: asserting only
       that the pinned floor held would pass equally well if the parking had done
       nothing. It also surfaced a detail worth knowing — the votable base after
       opening is 195 CC, not 200, because the nomination bond is itself a transfer
       into the escrow, which is precondition 2 visible in miniature.
    2. **Escrow cannot grow without a 1:1 lockup by the party that benefits.**
       This is what the 20:1 tax rests on. Every `Mint` in the realm targets a
       *user*; none mints into the escrow account. Every path that grows escrow is
       a transfer of the payer's own CC (stake, the answer/dispute/quality/election
       bonds, the claim deposit). Protocol-side escrow accrual, or fees routed to
       escrow, would break the tax and was named as the flip condition.
    3. **The floor is not the only gate.** Installation also requires a margin,
       `maxW − retainW ≥ floor`, so clearing turnout alone cannot remove a set —
       and both gates read the pinned value.
  - Residual, recorded and not acted on: *mint and abstain* raises the floor under
    netting (raw and votable rise together), so capital can buy a higher removal
    bar. It is dominated by the same factor in the defender's direction — minting
    `M` and abstaining raises the bar by `0.05M`, while voting `M` to retain raises
    the margin requirement by `M` — so it is 20× cheaper to defend a set by voting
    than by buying immunity. Symmetric and self-correcting; no guard added.
- **v0.30 — nobody votes on their own verdict, and a note on exactly what that
  is worth**. `VoteQuality` has refused participants since V2 — quality moves
  their own payout multiplier, and nobody votes their own multiplier.
  `VoteDispute` had **no such check**, so a claim's author, answerer or any
  staker could vote their own liquid weight on their own claim's verdict, and the
  only thing preventing it was the *accident* of custodial escrow. Two of the
  three v0.29 reviewers flagged it independently; verified in code, and now
  fixed.
  - **Deliberately NOT sold as a security fix.** `isParticipant` is
    **address-keyed**, and this document's own root principle — earned over four
    audit rounds and stated at the top — is that *address-keyed defenses fall to
    sybils; only capital-keyed, deadline-keyed or residency-keyed defenses hold.*
    A participant who wants to vote simply votes from a second address that never
    staked, at the cost of one transaction. So the guard closes the naive case and
    the conflict of interest; it does **not** close the manufactured contest. What
    closes that is capital-keyed and already shipped in v0.15: `credEligible`
    demands weight voted AGAINST the claim before an aggressive meta verb will
    execute, so a contest with no real adversary buys nothing however many
    addresses staged it. The limitation is written beside the guard in code, and
    **asserted in the test** — the last leg of
    `TestParticipantsCannotVoteTheirOwnVerdict` votes successfully from a sock
    address, so nobody can later mistake the guard for more than it is.
  - **The fixture fix improved the fixtures.** Exactly one test broke — the two
    places in `TestMetaLifecycleGuards` where alice self-answers and then votes
    her own weight to uphold. Substituting the confederate who opened the dispute
    (bob, who never staked) is not a workaround: it is how the attack is actually
    performed, so §9's manufactured-contest fixture now models the real shape
    **and still succeeds in reaching a decided round with zero adversarial
    weight** — which is the live demonstration that the guard does not stop it and
    `credEligible` must.
  - Noted in passing: `stakeAnswerDispute` stakes and answers but does *not* open
    the dispute its name promises; callers do. Left alone, recorded here.
- **v0.29 — the reachability clamp both bars already implied and then threw
  away (3 identical mechanism reviewers)**. Asked whether `quorumFloor` and
  `qualityBars` should net the escrow on their 5% arm, as `electionFloor` was
  changed to in v0.14. **Answer: no — and the fix was already in the code.**
  - **All three found the same thing independently.** Each bar computes
    `min(X̄, votable/3)` — its own statement of how high a turnout bar may go and
    still be decidable — and then `max()`es past that ceiling with 5% of RAW
    supply. `5%·S` exceeds `votable/3` **exactly when escrow passes 85%**, so the
    supply arm breaks the reachability rule in precisely, and only, the regime
    where the lane is already dying. Above 95% the bar exceeds all votable weight
    and no set of votes can clear it.
  - **Totalling the clamp is bit-identical below 85% escrow** — it weakens
    nothing in the normal range, and no fixture changed. Above it, "a third of the
    float" replaces "impossible". Netting would instead have divided the bar by
    (1−E) at *every* level — 20× at 95% escrow — buying nothing at 50%, where the
    bar was already fine. **2/3 preferred the clamp; the third named it as its own
    fallback**, so all three found it acceptable.
  - **My panel prompt contained a false premise, and all three corrected it.** I
    offered "the jam may be the intended conservative failure". It is not. The
    failed-quorum branch sets `provisional = answer`, burns *half* the disputer's
    bond, and returns the answer bond whole. So an unreachable bar **hands the
    decision to the party it exists to police**, and challenging costs ~70%·X̄
    across three doubling rounds to deny a draw worth ≤31%. A bar whose
    non-satisfaction means the policed party wins cannot be made safer by raising
    it.
  - **And v0.27's own reasoning reverses in sign here.** "Votable is deflatable
    for free" is true of a PRICE the attacker pays and false of a BAR he must
    clear: parking coins to shrink the denominator is ~19:1 counterproductive,
    because the deflating resource and the measured resource are the same coins.
    Recorded so nobody unifies the lanes on it. **General rule: check the
    direction of an argument before reusing it one lane over.**
  - The quality lane's case is sharper than the verdict lane's, which is why the
    clamp matters there most: `fullBar` gates the **slash**, and `qualityEpoch` is
    pinned at `PostAnswer`, so nobody can buy fresh weight in afterwards. A mill's
    own answered claims fill the escrow that makes the mill **permanently
    unslashable, per claim, for that claim's whole life** — while `demotionBar`
    has no supply arm and gets *easier* as escrow grows. So the lane kept its one
    free destructive action and lost the priced one: positive feedback on the
    single deterrent the draw-proportional slash exists to provide. The clamp also
    now enforces `fullBar ≥ demotionBar`, since the tier ladder reads them
    together.
  - **`court.gno`'s escrow comment was the source of the misreading.** It claimed
    the escrow "never votes (the quorum floor nets it out)". The quorum floor does
    **not** net it out on the arm that decides the value. Corrected, along with
    what custody does and does not buy: stake principal is never slashed and never
    burned, so custody buys only disenfranchisement — and it disenfranchises
    COURT-WIDE where the design wants CLAIM-SCOPED, which the `isParticipant` rule
    beside it already does properly.
  - **New reads: `VotableSupply`, `QuorumFloorOf`, `QualityBarsOf`.**
    `ElectionFloorOf` had existed since the election lane shipped; the verdict and
    quality lanes had none, so the one ratio that distinguishes a paralysed court
    from a quiet one was unobservable — escrow's *address* was readable, its
    *share* never was. All non-allocating and covered by the read filetest.

  **Recorded dissent, not acted on.** One reviewer argued for netting both bars
  outright, on the ground that `fullBar` guards no extractable prize
  (`isParticipant` makes promotion unprofitable; the slash is a burn with the
  bounty capped at the flagger's own bond). Another argued for replacing
  `electionFloor`'s v0.14 netting with the same clamp — `min(5%·raw, votable/3)`,
  uniformly stricter than today and equal only at zero escrow. That is 1/3 and
  would change shipped behaviour, so it needs its own panel.

  **Two items split out rather than bundled.** (1) `VoteDispute` has **no
  `isParticipant` guard** while `VoteQuality` does, so an answerer can vote their
  own liquid weight to uphold their own answer and the only thing preventing it is
  the *accident* of custodial escrow. Two reviewers flagged it; I verified it and
  measured the guard — it has real fixture blast radius, unlike the clamp, so it
  ships on its own rather than under an inert-clamp headline. (2) **3/3 name the
  root fix: make `Stake` a lock in place rather than a transfer.** `votable` would
  equal `supply` identically and this entire question would retire. V3-scale —
  needs a lock primitive in grc20votes and the `VoteDispute` guard first.
- **v0.28 — a set can see what it has half-approved, minus the part it has not
  agreed to**. v0.25 gave every unfired approval a 7-day expiry and
  `PendingApproval(court, key)` to read one; that still required knowing the key.
  The moderation log now lists in-flight proposals with their tallies and
  deadlines. An m-of-n set that cannot see what it has half-approved coordinates
  by rumour, and an unseen clock is a trap for a set six days into gathering
  signatures.
  **The stored `reason` is deliberately withheld until the act carries.** It is
  free text ONE moderator wrote, which no m-of-n has approved — rendering it
  would hand any single member of the set a publication channel on the court's
  own page without the set's consent, which is the same
  authority-without-agreement the threshold exists to prevent. The key, the
  count and the deadline are enough to coordinate on; the prose waits for the
  agreement.
  Bounded on entries VISITED as well as rows emitted, because this is the only
  place in the realm that walks `pending` and an unbounded walk here would undo
  v0.21's lesson one function from where it was learned. Expired proposals do not
  render, so the page agrees with what `approveAction` will actually do.
  Regression asserts all four: the tally shows, the deadline shows, the
  unapproved reason does NOT, and it appears once the set really agreed.
- **v0.27 — ordinary courts get the supply-relative floor, at a TENTH of
  meta's fraction (3 identical economists; unanimous on shape, 2/3 on the
  number)**. v0.26 established the bug; the panel established that my intended
  fix was wrong in a way I had not seen.
  - **The asymmetry is real, 3/3, and by a mechanism I had half wrong.** `Stake`
    transfers coins into escrow, so CC backing claim A genuinely cannot back
    claim B — per-claim floors SUM. Each answered claim locks **1.5×** the floor
    (stake plus the 50%·X̄ bond), and the lock outlives the answer: `Unstake`
    panics once frozen, so principal returns only at settlement, weeks later.
    Aggregate demand is `N × 1.5 × bps` — **a pure number, independent of
    supply** — so the fraction decides how many claims a court may run at once.
    Meta never feels it because its claim count is O(1) forever; an ordinary
    court's N grows with its own success. **At 50 bps a court supports ~40
    concurrent answered claims, and the dispute machine jams near 127**, because
    escrowed CC cannot vote while `quorumFloor`'s dominant arm reads RAW supply.
  - **The number that settles it (agent A): 50 bps overtakes a flat 100 CC at
    only 20,000 CC of supply.** Applying meta's fraction to ordinary courts would
    have been *more expensive than the constant v0.26 condemned*, for every court
    above that. My failing fixture was the proof and I had misread it: 80,050 CC
    × 50 bps = 400.25 CC against X̄ = exactly 400 CC — it failed by a quarter of a
    coin, against a floor four times the one being removed.
  - **So: `ordAnswerXFloorBps = 10`, `ordDepositFloorBps = 1`; meta keeps 50/2.**
    Two lanes, deliberately not unified. The panel's doctrine, which is v0.15's
    own words turned on their point: *on meta the claim IS a franchise-scoped act
    — an appeal installs or suspends moderator sets — so pinning it to the
    franchise is dimensionally right. On an ordinary court the verdict binds one
    claim, the market prices it, and the floor's only job is to exclude dust.* A
    bridge set at franchise scale on a docket court is the bridge doing the
    pricing.
  - **Raw supply, 2/3** — votable was rejected for the reason v0.15 gave and the
    panel sharpened: it is deflatable for free by the very activity it meters,
    and it is *seductive* precisely because it self-limits, which is the griefing
    vector rather than a fix. (Agent A dissented, arguing the deflation attack
    costs 100× compliance; recorded, not taken.)
  - **Too high is far worse than too low, 3/3 — and it is the asymmetry that
    justifies erring low.** A too-high floor panics at `PostAnswer` *after* the
    author paid and stakers locked, is **correlated with success** (a court that
    raises capital walls off its own small claims), **jams the dispute and
    quality quorums** via escrow starvation, reads from outside as "nobody
    answered" rather than as a parameter bug, and is **unfixable by anyone** —
    params freeze at `StartCourt`. A floor is a floor: the market can always
    exceed it and can never get under it.
  - **`answerDustCC` deleted; `params.minAnswerX` is now the dust arm**, exactly
    as `minClaimDepositCC` already serves `effMinDeposit`. That keeps the param
    alive and meaningful instead of leaving it read only by `mustSane` — the
    same no-dead-state rule this changelog has been enforcing since v0.16.
  - **`mustInvariants` now runs BOTH pairs through all three checks.** A gate
    that certifies one of two constant pairs certifies nothing about the other,
    and the ordinary pair is the one every court uses.
  - **A lid off-by-one, found by agent B.** `supplyFloor`'s clamp made filing
    cost *exactly* the quorum bar at every supply — the runtime clamp admitted
    the equality the deploy invariant rejects on the constants. One bps of slack
    restores the strict inequality, and it matters precisely where the lid binds:
    the low-supply case the dust arm reaches.
  - **And the correction to my own method.** I had "fixed" the 17 failing tests
    by shrinking their courts 10× so a 600 CC claim became 7.5% of the coin, and
    reported that the fixtures were unrealistic. Two agents rejected that
    independently: *rewriting the court sizes encodes the assumption this change
    exists to remove* — the judgment "unrealistic fixture" was downstream of the
    number I had already chosen, and it only holds if a court may never have more
    than ~13 concurrent claims. **The parameter was dictating what a court is
    allowed to look like.** Reverted. At 10 bps not one court needed resizing;
    only **four** genuine floor-probes needed adapting, and all four now DERIVE
    their stake from `effMinAnswerX` instead of restating it as a literal:
    `TestAnswerBelowFloorRefused`, `TestF9CapHeadroomAtTheExtreme`, and the two
    drain probes. v0.26's "blast radius is ONE test" was wrong; it is four.
- **v0.26 — ORDINARY courts have meta's decayed-constant bug too, and worse.
  Premise corrected, quantified, NOT YET FIXED.** The backlog carried this as
  low-priority on the grounds that "unlike meta, an ordinary court's params ARE
  settable at StartCourt". **That is false.** `StartCourt` lets a creator set
  `stakeOpenDelayBlocks` and *nothing else*; every other param, `minAnswerX`
  included, comes from `defaultParams()` frozen with no retune path — exactly
  meta's situation before v0.15.
  And the launch-side inversion is **worse** here. Filing an appeal costs
  1.5×X̄ while deciding one costs 5% of supply, so a fixed 100 CC floor makes
  **filing cost more than deciding for every court under ~3,000 CC of supply**
  — and every court starts at zero and grows through that band (~4,500 GNOT of
  burn to leave it). At 200 CC of supply the floor is **50% of the court's
  entire supply**. Meta was one court in the inverted regime; this is all of
  them, always, at birth.
  **Status: reverted, not shipped.** The fix is the v0.15 shape applied to every
  court (demote `defaultParams().minAnswerX` to a 1 CC dust arm, let the
  fraction carry policy). Blast radius is ONE test —
  `TestF9CapHeadroomAtTheExtreme`, which deliberately stakes big and unstakes to
  a sliver to probe the F9 cap's worst case. That shape is **no longer legal**
  under a supply-relative floor, which is itself the finding: *the floor bounds
  how far a position can diverge and still answer, so the F9 cap has MORE
  headroom than the test currently asserts.* Rewriting that fixture needs a
  careful run rather than the three guesses it got; backed out so the branch
  stays green, with the analysis kept.
  Method note: the first blast-radius measurement reported "zero failures" and
  was **vacuous** — the edit had silently no-op'd. Verified-applied, it is one.
  Same lesson as everything else this session: a check that measures nothing
  reports success.
- **v0.25 — pending approvals: a live m-of-n bypass, and consent that never
  went stale (3 identical reviewers)**. The question put to the panel was
  storage: nothing prunes `pending`, so a moderator can leave unfired proposals
  outstanding forever. **All three came back saying the storage framing is the
  weak half — and all three independently found the same live authorization
  bug instead.**
  - **THE BUG (3/3, verified here, exploit test written and confirmed by
    reverting the fix). `installModSet` did not clear `cm.pending`.** Approvals
    record ADDRESSES and are never re-validated at fire time, so any surviving
    entry lets a deposed moderator's signature still count. `installModSet` is
    the shared install primitive for *both* peers that replace a set — the
    court's own election and the meta court's `mod:setmods` verdict — and it was
    the only membership change that left approvals standing. Old set banks m-1
    on a hide, the electorate throws them out, one member of the incoming set
    fires it on the deposed signatures. That breaks §3.1's "a lone puppet
    installed into a set can act on nothing" **in the exact scenario the
    election is the remedy for**, and `ResolveElection` is permissionless.
  - Two more of the same family: **`TransferGlobalAdmin`** adds a member without
    wiping (making it the strictly better route than `AddGlobalMod` for an admin
    wanting to complete a stuck purge — seat a key without resetting the banked
    signatures), and **`SetPurgeThreshold`** lowers `purgeM` without wiping, so
    signatures gathered under 7-of-7 become executable at 5 on the admin's word.
    The threshold is half of "who must agree".
  - **Root cause, and the fix that matters more than the three lines.**
    `moderation.gno` referenced a helper `clearPendingOnMembershipChange` that
    **did not exist** — the invariant was named in a comment and implemented as
    four hand-written copies of one line, and every membership path added later
    forgot it. The helper is now real and all six sites call it. *Naming an
    invariant is not enforcing it.*
  - **The expiry itself (3/3 on shape, 2/3 on the two splits).** Framed as
    **consent freshness**, not garbage collection: the panel showed the storage
    case is thin — entries are self-paid by the proposer's own storage deposit,
    the key space is *derived* (every key needs a pre-existing claim, folder or
    row, each a larger separately-paid object), and nothing in the realm ever
    walks `pending`. What is real is that m-of-n meant "m members agreed at some
    point in history" rather than "m members agree now".
    `pendingTTLBlocks = flagCooldownBlocks` (7 days) — the realm's existing unit
    for "a body gets this long to decide", and 2.3× §3.2's own 72h purge
    runbook. **Not** `reSetWindowBlocks`: that is the statutory §512(g) clock and
    must stay independently tunable.
    **Lazy eviction only, no sweep entrypoint (2/3)** — and the dissenting
    design is why. A permissionless sweep *is* a front-runnable veto: watch for
    the m-th signature, snipe the entry, and moderation fails — profitably,
    since the storage refund pays the caller. Lazy eviction has no such surface:
    the predicate is only ever evaluated by a member already authorised for that
    key, and eviction is a **replacement, not a deletion**, so the evictor's own
    signature seeds the fresh entry and they cannot leave the key empty. It is
    also the reclaim — the overwriting `Set` frees the old object in the same
    transaction.
    **Fixed deadline from the first approval, not sliding (2/3)**: sliding gives
    an entry up to n×TTL (32 × 7 days ≈ 224 days) and makes the death height
    depend on other members' behaviour, which a coordinated pair can steer. A
    fixed height is public and identical for attacker and defender.
    **Silent (3/3)** — no cooldown, no cap, no event. Punishing a lapse taxes the
    honest first mover, and an m-of-n set whose members fear signing first never
    acts. Only `openedAt` came back from v0.16; **`actor0` stays deleted**, still
    having no reader.
    Per-member caps rejected 3/3: address-keyed, which this project's root
    principle rejects by name, and a liveness footgun that locks honest
    moderators out during the spam wave that needs them.
  - `PendingApproval(court, key)` ships with it: a deadline nobody can see is a
    trap for a set six days into gathering signatures. Non-allocating, and it
    reports an expired entry as absent — the same answer the write path acts on,
    per the v0.19 rule.
- **v0.24 — the unimplemented spec, two built and one handed back**.
  - **I11, row-level mod-log purge — BUILT.** `modAct.rowID` and `modAct.purged`
    both existed and `renderModLog` had honoured `purged` since it was written,
    but **nothing ever set it**: the inverse of the v0.16 complaint, and the same
    hazard. State that looks load-bearing and is never *written* misleads exactly
    as much as state that is never *read*.
    Why it matters beyond spec-compliance: **the moderation log is itself a text
    surface**, and the one power that removes text could not reach it. A row's
    `reason` is free text a moderator wrote, so it can carry the very thing the
    purge was called in to remove — a name, a slur, a link — and "we removed the
    claim" is no answer when the removal notice repeats what it removed.
    `PurgeModLogRow(court, claimID, rowID, code)` is global-DAO m-of-n on the
    same terms as `PurgeClaim`. The row SURVIVES with its height, actor and act
    code, so the audit trail still shows that something happened and who did it;
    only the prose goes — **and it goes from state, not merely from the render**,
    since a purge that only stops printing leaves the text on chain for anyone
    reading the tree. The row is resolved *before* the vote, so an unreachable id
    is refused on the first approval rather than after m-of-n has been spent.
    `renderModLog` now prints row ids, because a power addressed by an id nobody
    can see is a power nobody can use.
  - **`SetTier` → global DAO, and evented (I6) — BUILT.** It was gated on the
    bare `directoryAdmin`, so the realm had *two* unrelated moderation
    authorities: a lone key with no m-of-n, no membership management and no
    handover, beside a DAO that had all three. Tier is moderation — hiding a
    court from the front page is the first power the global DAO was ever
    described as having. The DAO's founding member *is* `directoryAdmin`, so this
    widens who may act without changing who can act today. Single-key like
    `GlobalHide` rather than m-of-n like purge: a tier change moves nothing,
    removes no text, and reverses in one call, so speed beats ceremony. The event
    carries the tier code only, never user text, because events are unpurgeable
    history. No log row — the moderation log is per-claim by construction and a
    tier change is court-level, exactly like suspension, which emits with claim
    id 0 for the same reason.
  - **§6 annotations / title relabels — NOT BUILT, returned to the owner.** The
    owner's original framing was *"possibly (and you can override me on this)
    re-wording claim titles or bodies"*, and §6 still carries a **VETTING** tag.
    That is an open design question, not an unimplemented decision, and building
    it silently would convert one into the other. The tension worth deciding on:
    letting moderators rewrite a claim's text is in real friction with §6's own
    "immutable after first stake" rule and with I1 — people staked on the words
    that were there. An annotation (an appended, attributed note that leaves the
    original intact) has none of that problem; a relabel has all of it.
  **The isolation sweep caught one of these tests, and it is worth recording
  which.** `TestPurgeReachesTheModerationLog` asserted that a non-member is
  refused — using **alice**, the court's creator. The global DAO bootstraps from
  whoever creates the FIRST court in the process, so run alone alice *is* the
  sole member and the refusal arm asserted nothing. That is exactly the
  kourtv1 `TestDirectoryTiers` trap from v0.17, written again by the same hand
  an hour later, in a test *about* moderation authority. Two lessons kept: the
  bootstrap-from-first-court rule is a standing trap for any test that needs a
  non-authority, so **name a distinct outsider and assert it is not the admin**;
  and this is the second time the widened sweep has paid for itself on work that
  had already passed the ordinary suite.
- **v0.23 — the review court's escrow is a string constant, now checked**.
  `init()` has no `cur` to ask for the realm's own address, so meta's escrow is
  derived from the **`metaRealmPath` constant**. Every other court gets
  `cur.Address()`, straight from the crossing frame. The two derivations must
  agree, and *comparing them is the whole check* — no address literal to pin,
  no oracle needed.
  If that constant ever drifts from the deploy path — a rename, a fork, a v3
  deployed beside this one — meta's escrow silently becomes an address nobody
  holds the key to. Every appeal bond and deposit routed through the review
  court is paid into it, and **a realm is write-once**, so there is no version
  of this that gets repaired afterwards. The cheapest possible assertion against
  the most expensive possible typo.
  Checked in two places: `TestMetaEscrowIsThisRealm` (unit, so it runs in the
  isolation sweep too) and the moderation txtar, which asserts both derivations
  resolve to the realm address on a real node.
  **The guard was verified by breaking it**: pointing `metaRealmPath` at
  `.../kourtv3` makes the test fail with both addresses in the message. A guard
  nobody has watched fail is not yet a guard — the same standard `make selftest`
  already holds the script checks to.
  **Deliberately a test, not a runtime assert.** The only way to make this false
  is to edit the constant or move the realm, and both happen in the repository,
  where a test catches them. A per-call runtime check would charge every user
  gas forever to guard against a mistake no user can make. Also worth recording:
  the existing money txtar pins `CourtEscrow("orem")`, which looked like it
  already covered this and does not — ordinary courts never touch the constant.
- **v0.22 — the rest of the lazily-created reads**. A sweep for the v0.19 bug
  class: every read with a *not-yet-materialised* branch must answer what the
  WRITE path would do, not what is currently stored. Nine reads audited, one
  wrong, and the wrongness was an inconsistency rather than a plain error.
  - **`FolderPurged` returned `false` for a folder that does not exist**, while
    its two siblings `FolderName` and `FolderItems` panic `"no such folder"` —
    and `FolderPurged` itself panics once the court holds any moderation state,
    because it then routes through the shared `mustFolder`. So the same bad id
    answered two different ways depending on whether the court had ever been
    moderated, and a caller probing an unvalidated id would only meet the
    discrepancy on the second kind of court. Now panics, consistently.
  - Confirmed CORRECT, and listed so the sweep is not repeated: `FolderCount`
    (0 — folders only exist via moderation), `FolderName`/`FolderItems` (panic —
    matches `mustFolder`), `claimTitleFor` (no mod ⇒ nothing purged or withheld
    ⇒ the sanitized title), `hideBanner` and the `courtPurged` check (no mod ⇒
    no banner, not purged), and `writeAppeal`'s candidate lookup (no mod ⇒ no
    candidates ⇒ "this candidate set does not exist yet", which is exactly the
    bait-and-switch warning it should print).
  - Regression: `TestFolderReadsAgreeOnAMissingFolder` probes all three reads on
    a court with **no** moderation state and on one **with** it, and requires the
    same answer from both.

  Testing note worth keeping: these are plain reads, not crossing calls, so they
  panic rather than abort a cross-realm frame — `uassert.PanicsContains`, not
  `AbortsContains`, which does not catch them and lets the panic escape the test.
- **v0.21 — bounded reads (audit-N3), and what the backlog got wrong about
  them**. Checked before changing, and two of the three suspects were already
  fine: `writeStrip` and `writePending` both page at `renderPageSize` **and**
  already print "…and N more". `StripPage`/`PendingPage` stop the iteration when
  the page fills, so they are O(offset+limit) rather than O(index). The item was
  overstated; recorded here so the next reader does not re-litigate it.
  - **`renderModLog` was the real one, and for a subtler reason than "unbounded".**
    It stopped once ROWS filled a page — a bound on *output*, not on *work*. A
    `claimMod` carrying few or no acts costs a step and buys no row, so a court
    with many lightly-moderated claims walks all of them. Nothing mints an
    act-less row today (v0.16 moved `ensureClaimMod` after the m-of-n fires), but
    that is an invariant in a different file, and a render should not silently
    depend on one. The walk is now bounded on **two** terms: rows *and* claims
    visited.
  - **It also truncated silently, which for a moderation log is the worse half.**
    The log is an accountability record; a page of it presented as the whole
    thing invites the reader to conclude nothing else happened. It now says how
    many acts it is showing and how many claims the court has moderated. The
    exact remaining act count is deliberately *not* computed — that would re-walk
    everything the bound exists to avoid — while `claims.Size()` is O(1) and
    tells a reader how much history is behind the page.
  - `PendingPage` now skips with `IterateByOffset` (O(log n)) instead of stepping
    over the offset. `StripPage` deliberately keeps the linear skip: its
    per-actor cap counts across the whole prefix **on purpose**, so that a deep
    page stays consistent with the pages before it, and an offset descent would
    silently change that rule.

  Regression: `TestModLogReportsItsOwnTruncation` asserts both directions — a
  long log says it is truncated and renders exactly one page, and a short one
  does not claim truncation, so the notice carries information instead of
  decorating every page.
- **v0.20 — the rename's survivors, and one ticker question for the owner**.
  The 2026-08-16 cryptocourt→Kourt rename moved directories and import paths but
  left five *strings* behind, three of them user-visible. Found by grepping the
  whole tree rather than the realm being worked on:
  - `realm/r/govern/token.gno` — the governance token's live **name** was
    `"Cryptocourt Governance"`. Now `"Kourt Governance"`. govern is not part of
    the V1 freeze, and the comment above those constants explicitly invites
    changing them pre-deploy. `z_use_filetest.gno`'s expected output updated
    with it, since the filetest asserts the name.
  - `realm/r/kourtv1/render.gno` — V1's front page still headed
    **`# CryptoCourt`**. Now `# Kourt`, matching kourtv2's `platformName`.
    **Flagged as revertible**: the owner froze V1 *behaviourally, including its
    internal `COURT` coin symbol*, and this is render copy rather than
    behaviour — but it is exactly the branding "no more cryptocourt" targets,
    and no test asserts it.
  - `realm/p/grc20votes/grc20votes.gno` package-doc example, `web/README.md`
    heading, and two `REGULATIONS.md` headings.

  **RESOLVED by the owner (v0.21): govern's `tokenSymbol` is `KOURT`.** It had
  still been `"COURT"`, and since `tokenID` is
  `"gno.land/r/kourt/govern." + tokenSymbol` the symbol is wire identity — free
  to choose before deploy, unfixable after, because a realm cannot be redeployed
  at its path. The decisive argument was not the three-way confusability with
  the platform ticker, the per-court `KOURT:SLUG` coins and kourtv1's exempted
  internal `COURT`; it was that **kourtv2's own slug deny-list reserves `court`
  precisely so no user can mint a coin displaying as COURT beside KOURT**, so
  shipping the governance token as COURT would have had the platform doing the
  exact thing it forbids its users. No collision is possible the other way
  either: `kourt` is itself a reserved slug, so no court coin can carry the
  symbol. The scheme now reads whole — **KOURT** is the platform token, a court
  coin is `uppercase(slug)` rendered `KOURT:SLUG`, and the review court is
  `KOURT:META`.
- **v0.19 — moderation on a real node, and the read that contradicted its own
  write path**. `kourtv2_moderation.txtar` asserts the §2 constitution through
  the surface a reader actually meets — a node's `qrender` over RPC, not
  `Render()`'s return value in-process. Covered: a hidden claim leaves the court
  listing while its **deep link still renders with the banner naming the
  authority**; the `/<slug>/mod` log is a real sub-route (carved out before the
  numeric-id parse); unhide restores discovery; `GlobalHide` withholds text
  while IDs, state and money keep answering; and a purge reaches **all four**
  surfaces — `ClaimTitle`, the claim page, the court listing, and the
  `/<slug>/<id>/<addr>` positions route, which was once the single render path
  that skipped the text gate. Throughout, the lifecycle reads keep answering:
  a moderator must never be able to strand a position. The appeal lifecycle is
  **not** covered (answer → 72h → execute needs thousands of blocks; it lives in
  `meta_test.gno`), and the file says so rather than implying coverage.

  **Writing it immediately found a bug no unit test could have.** `IsCourtMod`
  returned **false** for the creator of a court that had never been moderated —
  while `HideItem(creator)` on that same court **succeeds**. Moderation state is
  created lazily (`ensureMod` bootstraps the admin as a 1-of-1 on the first
  act), so before any act there is no object to read, and the query answered
  "no" where the write path answers "yes". Wrong in the direction that misleads:
  a UI would tell the one person who can moderate that they cannot. `IsCourtMod`
  and `ModThreshold` now report the set the write path will act on, and the mod
  log page names the bootstrap moderator instead of only saying "no acts yet".
  The unit suite never asked, because every unit test moderates first and
  queries after; the txtar asked in the natural order a real user would.
  **The general form:** lazily-created state gives every read a second branch —
  *not yet materialised* — and that branch must answer what the write path will
  do, not what is currently stored.

  One small true thing recorded in the file: category codes come back
  markdown-escaped (`CSAM\\-2258A`), because they go through `sanitize.InlineText`
  like every other rendered string.
- **v0.18 — kourtv2 had no filetest, so nothing guarded "a read that writes"**.
  Following v0.17's drift into the sibling guards. Two turned out fine and one
  did not:
  - `check-docnumbers.py` is **correctly** govern-scoped — it pins govern's
    `doc.gno` table against `governor.gno`'s init, and kourtv2 has no such
    table. No change.
  - `check-citations.py` had the **same drift**: `SRC` listed govern, its
    packages and offerer, but not kourtv1, kourtv2, or p/twap, p/cshares,
    p/tickbook, p/curve. Extended on that file's own stated principle —
    *"listed so that the first one somebody adds is watched rather than
    discovered"* — and it is pure prevention: those six packages contain **zero**
    line-number citations today, and the widened run reports "34 citations still
    hold".
  - `check-storage.py` could not have covered kourtv2 even if listed, because
    **kourtv2 had no filetests at all**. govern has had a read-must-write-nothing
    filetest since the beginning; kourtv2's read surface was unguarded, and that
    is exactly the defect found by hand TWICE this session — five election reads
    calling `ensureMod` (v0.13 pass) and `ensureClaimMod` running ahead of the
    m-of-n gating it (v0.16). Both are the shape govern's guard was written for:
    the work is thrown away with the query, so the only symptom is storage that
    grows on reads, months later, under load.

  So kourtv2 gets its first filetest, `z_read_filetest.gno`: the read surface
  walked from OUTSIDE the package — directory, coin, curve, moderation,
  election, strips, franchise, and both render routes — using the meta court
  (created at realm init) as a fixture needing no setup. **It writes zero
  bytes**, so it earns the strictest budget, `None`. `GlobalModCount` was
  suspected of allocating through `ensureGlobalDAO` and does not: it already
  returns 0 on a nil DAO. One honest observable recorded rather than hidden —
  `DirectoryAdmin()` is empty in a filetest, because the meta court is created
  at init from `unsafe.OriginCaller()` and a filetest has no deployer to be;
  on chain `MsgAddPackage` supplies one, and govern's filetest records the same
  condition about its minter.

  `check-storage.py` was single-realm by construction (`REALM`/`DEST`/`BUDGETS`),
  which is *how* the gap existed, so it is now a `TARGETS` list — and it
  cross-checks itself: **`realms_with_filetests()` walks `realm/r/*` and fails on
  any realm that has filetests without a budget entry.** Verified it fires. That
  is the v0.17 lesson applied one level up: the fix for a hand-maintained scope
  list is not a longer list, it is a list that is checked against the tree.
- **v0.17 — the isolation gate had never run on this code**. Noticed from a
  number that did not move: `make isolation-test` printed "151 tests" both
  before and after kourtv2 gained two test functions. `scripts/check-isolation.py`
  keeps its scope in a hand-maintained `REALMS` list, and that list had drifted
  from the Makefile's: it swept **151 of the 388 tests `realm-test` compiles**,
  and every one of the 237 it skipped was the newer half of the tree —
  **kourtv1, kourtv2, and p/twap, p/cshares, p/tickbook, p/curve**. So the whole
  moderation layer, all 110 kourtv2 tests, had never been isolation-checked,
  while three green gates were being cited on every commit.
  The script's own docstring already forbade this — *"Everything `make
  realm-test` compiles, not just the realm most likely to have the problem.
  Covering where somebody has already looked is opt-in coverage, and opt-in
  coverage is how a citation goes unregistered."* The list had simply not kept
  up with the tree. `REALMS` now mirrors the Makefile's two lists exactly: 11
  packages, 388 tests.
  **What widening it found:** exactly one real failure, and not in the new code
  — **`TestDirectoryTiers` (kourtv1)**. Its own line 1 admitted the dependency:
  `admin := DirectoryAdmin() // the first court's creator, set across the suite`.
  The directory admin is whoever created the first court in the process, so run
  ALONE the test's own `dir-court` was that first court and its supposed
  non-admin *was* the admin — the "a non-admin cannot curate" assertion passed
  in company and asserted nothing by itself. Fixed by seeding a court from a
  separate address so an admin exists either way, then reading it back. All 110
  kourtv2 tests passed alone unchanged.
  **Lesson, and it generalises past this repo:** a gate whose scope is a
  hand-maintained list drifts silently, because a passing run looks identical
  either way. The only symptom is a count that stops moving — so print the
  count, and watch it. Backlog: derive `REALMS` from the Makefile, or assert the
  two agree, so the drift cannot recur.
- **v0.16 — the moderation layer's dead state, and what it was hiding**. A
  sweep for written-but-never-read fields, on the principle that state which
  *looks* load-bearing is worse than no state at all — a future reader trusts it.
  - **`courtActByOthers` / `metaActByOthers` / `globalActHeight` DELETED.** Their
    comment said the meta staleness guard read them "(§3.3 g4)". Nothing did.
    They are residue of a per-claim third-party refusal that was **deliberately
    removed** — see the `verbUnhide` comment in `meta.gno`: refusing on a
    same-direction third-party clear let a moderator re-hide for free. Kept as
    written-only stamps, they advertised a guard that did not exist. The mod log
    already carries the same who/when for render.
  - **`stripEnteredAt` DELETED** — the strip key already encodes the deadline it
    would have duplicated.
  - **`approval.actor0` / `.height` DELETED**, with the reason recorded at the
    struct: re-add them *together with a sweep* when pending entries get an
    expiry. **Noted as a real gap:** today a member can leave unfired proposals
    outstanding forever and nothing prunes `pending`.
  - **`suspendedAt` WIRED** (it is the only record of when a suspension began),
    and a new **`suspendActByGlobal`** stamped by the two global-DAO suspension
    verbs — `ClearCourtSuspension` and `GlobalSuspendSet` **stamped nothing at
    all**, so a meta verdict filed *before* a global decision could execute
    after it and silently undo the legal backstop. The meta staleness guard now
    reads it, refusing only **opposite-direction** acts, which is the rule
    `verbUnhide` already settled on: refusing on a same-direction act buys
    nothing (the verdict's goal is already achieved) and costs a re-appeal.
  - **`maxModSetSize = 32`**, enforced at `canonicalMembers` — the one chokepoint
    `AppointMods` and `RegisterModCandidate` share. `currentSetID` concatenates
    every member into one string, so it is O(n²), **and it sits on the suspend
    path**: uncapped, a set could be grown until the global DAO's and the meta
    court's emergency hammer no longer fit in a transaction — a set making
    itself too big to suspend.
  - **`ensureClaimMod` moved AFTER `approveAction`** in `HideItem`, `GlobalHide`
    and `PurgeClaim`. Allocating on the *first* approval let one member of an
    m>1 set mint an empty `claimMod` per claim — rows carrying no act, costing
    storage, that `renderModLog` and every claims-tree walk must step over. Pure
    griefing of a set the griefer cannot otherwise act for. The pre-vote reads
    (the I8 re-hide cooldown, the §512(g) re-set window) now go through
    `lookupClaimMod`, and `mustClaim` still runs first so a nonexistent claim
    is refused whether or not the act fires.

  Tests: `TestModSetSizeIsCapped`, `TestUnfiredApprovalAllocatesNothing`, and
  `TestMetaLifecycleGuards` §10 (the global DAO suspends then clears while an
  appeal is in flight; the stale `suspend` verdict must refuse).
- **v0.15 — meta's supply floors, re-derived (3 identical adversarial
  economists; the SAME bug class as v0.14, one lane over)**. The panel was asked
  only to re-size `metaFloorBps`, and found instead that the fixed constants
  behind it were wrong at *both* ends. **Unanimous 3/3:**
  - `metaFloorBps = 1` (0.01%) needed ~**5e8 GNOT of CLAIMED burn** to overtake
    the 100 CC constant — 10⁶× the deployer's genesis spend. Unreachable, not
    slack; both floors were fixed in practice. Deleted.
  - **The launch-side inversion, which nobody had looked for.** A ~500–1,000
    GNOT genesis buy puts launch meta supply near 1,000 CC, where a 100 CC
    answerability floor is ~10% of supply and the full filing cost (stake +
    50%·X̄ bond) is ~15% — against a 5% turnout bar. **Filing an appeal cost 2–3×
    more than deciding one**, for the platform's entire early life. This is
    exactly the incumbency-lock-by-price `mustElectionInvariants` has long
    forbidden in the election lane; the appeals lane simply never had the gate.
    Worse, it fed back: `quorumFloor = max(5%·S, min(X̄, votable/3))`, so an X̄
    pinned at 10% of supply DOUBLED the turnout bar it was sized against.
  - §3.3's "`minAnswerX` is the explicit forgery-price dial — the forge costs
    ~10% of it" is **stale**: `meta.gno`'s `decidedRounds > 0` guard already
    closed the zero-voter forge. Corrected in place.
  - Do **not** price the answer bond off supply. Doctrine, now stated: **X̄
    prices claim-scoped risk; supply prices franchise-scoped authority; the
    floor on X̄ is the only bridge between them** — so make the floor
    supply-relative and change nothing else. Pricing the bond off supply would
    falsify `mustInvariants`' collateralization identity (an X̄-relative
    statement) and add friction only to honest answerers: the forger's bond
    returns in full on the uphold path.
  - Base is RAW supply, not votable — votable is deflatable for free by parking
    no-loss stake, so a votable base lets an attacker lower the appeals bar at
    zero cost and makes each appeal cheapen the next.
  - Unpeg the deposit from `effMinAnswerX/100`; add deploy invariants.

  **Majority 2/3:** fraction **50 bps** (A,C; B argued 25) · **sealed
  `PastTotal(Epoch()-1)`** rather than live `TotalSupply()` (B,C) · **1 CC dust
  arm replacing the 100 CC policy arm** entirely (B,C; A wanted to keep a
  lowered 10 CC arm — but `max(100 CC, bps)` merely moves the dead zone one
  order down, to ~40,000 CC) · extend `credEligible` beyond `setmods` to
  suspend/unsuspend **but not `hide`** (B's carve-out, the only reasoned one:
  requiring an adversary would mean a correct but UNCONTESTED hide could never
  execute, and hide is the one aggressive verb that is low-harm, moves no money,
  and is globally reversible).

  **The sealed-epoch read closes a live griefing vector B found and C
  independently confirmed:** `effMinAnswerX` read live `TotalSupply()`,
  `PostAnswer` reads that floor, and `ClaimMetaFranchise` mints into supply — so
  a whale sitting on an unclaimed entitlement could front-run an honest answer
  **in the same block**, push the floor above that appellant's X̄, and revert it.
  Repeatably, for free, keeping coins they were owed anyway. Regressed in
  `TestMetaLifecycleGuards` §8.

  **Where the panel split 1/1/1: the deposit fraction** (A 10 bps, B 1, C 2).
  Resolved on the *rule* rather than the number — B and C derived from the same
  constraint (`50·d ≥ 1.5·f`: a 50-row flood must cost at least one self-answer
  escape), which is 2/3, and at the majority `f = 50` that yields **d = 2 bps**.
  A's stricter rule (a flood must park the whole quorum floor, `55·d ≥ 500`)
  would give 10 bps and is **not** satisfied at 2 — recorded here as the one
  place a reasoned minority was overruled, so it can be revisited if
  pending-list abuse ever appears. Noted for that day: the **fee**, not the
  deposit, is the flood-specific dial — it is burned only on the dead-claim
  path, so a flooder always pays it and an answered honest appeal never does.

  **Out of scope, worth recording:** every ORDINARY court has the same
  decayed-constant problem (`defaultParams` hands them all a fixed 100 CC with
  no retune path). Meta only needed it first because its supply tracks
  platform-wide burn rather than its own.
- **v0.14 — polish pass: the election bond's two unpoliced arms (§3.1)**. The
  round-7 R1 deploy invariant certifies that affording the ballot is never
  harder than winning the vote, but it is a **constant ratio check**, and two
  runtime terms sat outside it — one of which inverted the guarantee on exactly
  the courts it was written for. (i) **Base mismatch**: the bond was quoted on
  `PastTotal` while the floor nets the escrow, so the real ratio was
  `(β/q)·(supply/votable)`; at β/q = 1/10 the bond overtakes the floor once
  escrow passes 90% of supply — the normal state of a busy court, where most CC
  is stake and bonds. Fixed by measuring the bond on **votable weight, the same
  base as the floor**. (ii) **Absolute-floor arm**: `flagMinCC` = 1 CC binds
  below ~20 CC votable and exceeds 5% of votable outright; fixed by **clamping
  the bond to the floor**, which is safe because 64 lines at 5% of votable each
  already costs 3.2× the court's whole votable weight. Regression:
  `TestElectionBondNeverExceedsTheFloor` covers both arms separately (ARM 2 is
  sized well above `flagMinCC` so it tests the base, not the clamp). Lesson for
  future invariants: **a constant-only gate is valid only if every term it
  compares shares a denominator, and only above the absolute floors.**
- **v0.13 — the final CODE audit (3 identical adversarial auditors; one ran
  executed exploit probes against a staged realm). Verdicts: 2× "MUST FIX
  BEFORE MERGE (5 critical/high)", 1× "(1 critical / 4 high)". ALL fixed, all
  three gates re-run green.** The consensus findings, and what each cost:
  - **CRITICAL, 3/3, probe-verified — the meta latch leaked forever.**
    `releaseMetaLatch` had exactly ONE call site: the tail of a *successful*
    execution. So every appeal that was refused, expired, or voted down held its
    target's review slot permanently — bricking that target's appeals lane and
    permanently reverting `PostAnswer` for it, for the price of a refundable
    bond. Worse, it fired on the ORDINARY path: this doc's own "aggressive verb
    refused on silence" test was silently leaking a latch. Fixed by releasing at
    every terminal transition (Crystallize / provClose / CloseDeadClaim), with a
    regression test asserting the slot frees.
  - **CRITICAL, 1/3 — a zero-approval candidate could win the election.** The
    two-pass tie-break filtered on `weight >= maxW - floor`, so whenever the
    winning approval sat near the floor the band reached down to ZERO — and the
    election opener is always the earliest line, so a griefer's puppet beat a
    genuinely-approved challenger for free (permanently unseating the creator
    and gaining the seeding privilege). The selected line now re-tests the
    install condition itself. Regression test added.
  - **HIGH, 3/3, probe-verified — the re-hide cooldown was never read.**
    `executedAt` was written twice and read nowhere, so a moderator who LOST an
    unhide appeal re-hid in the next block, free, forever: the restorative half
    of the appeals layer was a no-op. Now enforced in `HideItem`.
  - **HIGH, 3/3, probe-verified — m-of-n was bypassable with banked approvals.**
    Pending approvals were never re-validated and never cleared on a membership
    change, so a deposed moderator's signature still counted — including toward
    an irreversible purge. Pending now clears on every membership/threshold
    change.
  - **HIGH, 2/3 — `setmods` never checked its candidate.** Registration is
    permissionless with a predictable per-court counter, so an attacker could
    win a vote on an unallocated candidate id and only *then* register their own
    puppet set at it. The candidate must now exist and predate the appeal.
  - **HIGH, 3/3, probe-verified — purge did not reach every surface.** Both
    `ClaimTitle` (a one-call qeval) and the `…/<id>/<addr>` positions page
    rendered raw titles, defeating the legal-compliance power outright. Both now
    go through the same text gate; a whole-court purge also tombstones the court
    NAME (it was still rendering on the directory and every court page).
  - **Also fixed:** `AppointMods` validated `m` against the pre-dedup list (so
    `{A,A,B}, m=3` produced an unsatisfiable 3-of-2 in which even `UnhideItem`
    could never fire); a title edit could drop a SEEDED claim off the pending
    list (M-A18) or clear the purge poison; and `ResolveElection` was an
    unpaginated O(N) transaction whose N an attacker controlled — exceeding the
    gas cap would have left `resolved == false`, permanently killing that
    court's elections and stranding every bond, so the ballot is now bounded.
  - **Confirmed clean by all three:** I1 (no hide/purge/suspension state gates
    any money write), I2 (money→moderation writes are total; the only refusal is
    the sanctioned latch read), I5 (both seeded gates), the §13.8 franchise
    economics (court-independent per-µGNOT, no double accrual, no over-claim,
    cannot panic inside `Buy`), determinism (no range-over-map), borrow rule #2,
    and access control on every exported crossing function.
- **v0.12 — naming (3/3 unanimous)** — *SUPERSEDED: the owner rejected Pleadger
  on the trademark flag this very entry raised, and the project is now **Kourt**
  (kourt.xyz, ticker **KOURT**, per-court display `KOURT:SLUG`). Kept for the
  method and for the live bug it caught.* Ticker **PLEA**, not PLGR (PLGR is a dead
  token named "Pledge", reads "plugger", spells PLeDGeR, and is one char from
  PLTR; PLEA is unclaimed across 18,438 CoinGecko coins + Dexscreener + CMC +
  US equities). Per-court symbol = `uppercase(slug)` displayed `PLEA:SLUG`,
  with a reserved deny-list at slug registration. **Live bug recorded** (CLOSED — `courtSymbol(slug) = uppercase(slug)`, slugs
  capped at 11 for GRC20's symbol bound, deny-list enforced; and as of v0.21
  govern's own symbol is KOURT): every
  court then minted its ledger with the literal symbol `"COURT"`
  (court.gno) — a phishing vector, since wallets key display on symbol not
  pkgpath. Trademark red flag: "Pleadger" is a homophone of "Pledger", a live
  fintech in an adjacent sector — clearance search recommended (§13.9).
- **v0.11 — the meta-franchise vet (owner proposal; 3 identical passes, all
  ADOPT WITH FIXES; §13.8 carries the full consensus)**. Distributing meta-CC
  pro-rata to GNOT burned on every court makes meta's security budget
  endogenous to platform adoption (~49× at 100k GNOT burned) instead of a fixed
  ~54–108 GNOT forever, and replaces an electorate self-selected for appetite
  for the lever with one selected by sunk capital. Six unanimous conditions:
  mint on `spent` µGNOT never on CC (an unbounded √N free-mint otherwise);
  don't leave meta's own curve a parked side door; clamp never panic (a mint
  panic inside `Buy` bricks the platform's only on-ramp); fix the raw-supply
  quorum arm FIRST or the change is a net regression; **claim-on-demand**
  (independently derived by all three — it fixes quorum, cheap-float capture,
  the securities posture, and creates a defensive reserve); and a restated
  supply invariant with meta emission off `S_live × bps`. Owner re-check
  surfaced on transferability, not overridden.
- **v0.10 — the setmods flap vet, resolved by three identical adversarial
  passes (all HOLD WITH FIXES; §3.3 carries the full list)**. Landed in code:
  `ResetModSet` + `GlobalSuspendSet` (global had NO reach over set membership —
  the "backstopped by the global DAO" claim was false for installs);
  `AppointMods` refused while suspended; meta installs no longer stamp
  `lastElectionAt` or burn `creatorUnseated`; install clears a suspension only
  if the set actually changed; a meta-installed set may not seed. Specified for
  the module-7 build: `decidedRounds > 0` + genuine-contest gating on setmods,
  staleness anchored at `verdictAt` (never `openedAt`) plus a one-`votingBlocks`
  execution expiry, and a per-COURT setmods latch. Doc corrections: the
  "corrects a locally-captured court" claim is withdrawn (local wins any war,
  8d/0 CC vs 14–28d/4–10 CC), and "render-layer only" is qualified for the
  seeding waiver.
- **v0.9 — owner decision (meta can INSTALL a mod set, not just suspend)**: the
  meta court and the local coin-holder electorate are **peers** over a court's
  moderator set (`mod:setmods`), because suspend-only deepens the gap in the
  motivating case (negligent/absent mods). Both act through their own
  bonded/voted process, last-writer-wins by height stamp; suspend stays as the
  fast disarm lever. Safe because it is render-layer only (no meta act touches
  a coin) and reversible by the local electorate + global DAO. Meta-CC decided
  **transferable, normal emission** (owner, risk-tolerant) — noted for counsel:
  meta-CC is then a tradeable securities-analysis unit tied to platform power,
  and forgery costs ~4%·X̄, so meta integrity rests on the deployer's genesis
  vote-dominance. **Flap/harassment vet PENDING** before the `setmods` build.
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
