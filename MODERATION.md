# MODERATION.md — render-layer moderation, the meta court, and seeding

> **STATUS: v0.10 — CONVERGED + BUILDING. Design converged at round 7; v0.9
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
      once (all three vets flagged it; §13.4 records the owner's call). The
      meta court's `minAnswerX` is the explicit forgery-price dial — the forge
      costs ~10% of it — and is worth revisiting if abuse appears.
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
  Because meta-CC is one-way GNOT-sunk and non-transferable, set
  `minClaimDepositCC` high enough to make a 50-row flood park real capital 12
  weeks without pricing out a single appeal — accepting this is a nuisance-cost
  ceiling, not a flood *gate*.
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

**Also flagged:** meta's `minAnswerX` / `minClaimDepositCC` are absolute CC
constants frozen at StartCourt with no retune path — if meta supply grows 1000×
they decay to nothing, and §5.3's flood-deposit argument decays with them. Make
them supply-relative **before deploy**. And the forge price (~10%·X̄) does not
scale with supply, so `minAnswerX` stops being the forgery dial it is called.
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
  with a reserved deny-list at slug registration. **Live bug recorded**: every
  court currently mints its ledger with the literal symbol `"COURT"`
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
