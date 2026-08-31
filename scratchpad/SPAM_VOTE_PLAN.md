# Abstain becomes "spam" — implementation plan

Owner's decision, settled over the preceding exchange. Abstain is removed as a
concept and its slot becomes a spam flag that discounts the reward and, past
half, deletes the claim.

## 0. The finding that sizes this job

**The governor's abstain slot already behaves exactly as the spam button must.**

    turnout(p)       = yes + no + abstain      counts toward QUORUM
    forAndAgainst(p) = yes + no                excluded from the VERDICT bar

(governor.gno, `turnout` and `forAndAgainst`.) So "spam counts toward quorum"
and "spam is excluded from the yes/no denominator" — both of which the owner
asked for — are the shipped behaviour of the bucket being renamed. And
`ResolveDispute` already destructures `yes, no, abstain, _ := c.gov.Tally(...)`.

This is not a new vote bucket. It is a relabel plus new dispositions.

## 1. The spec

**Ballot:** overturn / uphold / **spam**. Abstain is gone.

**Discard:** the claim is deleted iff

    spamW × 2 > totalW              (strictly more than half; integer, no division)

**Reward,** when it is not discarded — a DISCOUNT on the size multiplier, never a
replacement:

    multiplier = tierBpsFor(cs) × (totalW − 2×spamW) / totalW,  floored at 0

| spam share | pays, as a fraction of what size gave |
|---|---|
| 0% | 1.00× |
| 10% | 0.80× |
| 25% | 0.50× |
| 33% | 0.34× |
| 40% | 0.20× |
| 50% | 0 — the claim STANDS and draws nothing |
| >50% | discarded |

**Why a discount and not a replacement.** Size reaches 2× and spam caps at 1×,
so "replace" would mean a small self-staked claim (0.25× by size) that got
disputed and drew no spam jumps to 1.00× — a 4× promotion for being disputed,
bought for the price of a dispute bond by a second address. `OpenDispute` bars
only the answerer. Discounting makes a dispute able to lower a claim and never
to promote one.

**Money on a discard** (the author is the only party who loses, which is where
the spam came from):

| | < 67% spam | ≥ 67% spam |
|---|---|---|
| stakes, both sides | returned 1× | returned 1× |
| author's deposit | returned | **burned** |
| author's fee | burned | **burned** |
| answerer's bond | returned | returned |
| disputer's bond | returned | returned |

The answerer and the disputer are not the spammer: the answerer did the work,
and the disputer opened the round that surfaced it — punishing them would
discourage the only path that finds spam at all.

**The carrot pays spam voters when spam wins.** Without it the spam button is
dominated exactly as abstain was — same lock, same turnout contribution, no
upside — and nobody rationally presses it. This is what decides whether the
button is real.

## 2. The seam, named on purpose

At *exactly* half, the multiplier is 0 and the claim is NOT discarded: it stands,
principal returns, nothing is drawn. Reachable with integer weights. It reads
sensibly as a ladder — half the weight calls it spam and it earns nothing, past
half it is deleted — but it must be a deliberate line in the code with a test,
not something found later and mistaken for an off-by-one.

## 3. What changes

### 3a. The vote itself — dispute.gno

- `VoteDispute`'s choice set: `"yes" | "no" | "spam"`. **Reject the literal
  `"abstain"`** rather than aliasing it: two names for one bucket is how a
  client and a realm come to disagree about what was cast.
- The governor call still passes its own `"abstain"` — that is the p/ layer's
  vocabulary and is not ours to rename. One translation point, in one function.

### 3b. Resolution — dispute.gno `ResolveDispute`

`abstain` becomes `spamW`. Before the existing verdict switch:

- `if spamW*2 > cast` → the discard path (new terminal state, §3c).
- otherwise record the discount factor for crystallize.

**Where the factor lives.** Frozen on the claim at resolution: `cs.spamW` and
`cs.spamTotalW`, two int64s, with crystallize doing the division. Storing the
ratio pre-divided loses the denominator a reader needs to check it against.

CORRECTED FROM THE FIRST DRAFT, which said the tally might be gone by then
because `ReleaseRoll` is permissionless. It is not: ReleaseRoll sets
`p.voted = nil`, while `Tally` returns `p.yes, p.no, p.abstain, p.total` —
counters that survive. The real reason is better: `cs.proposalID` is
OVERWRITTEN by every new round (dispute.gno), so by crystallize it may name a
later round than the one that decided. That is precisely why `cs.decidedPID`
already exists, and the spam figures belong beside it, frozen at the same
moment and by the same argument.

### 3c. The discard — a new terminal state

`provCloseClaim` is the template and should be followed rather than paralleled:
it already sets `verdictAt`/`verdictAtTime`/`route`, refunds the answer bond and
refunds the deposit. The spam path differs only in its dispositions (fee always
burned; deposit burned at the 67% arm), so the two want to share a helper rather
than drift as two hand-written terminal paths.

On top of that shape: a `cs.spamClosed` marker, and the dispositions in §1. The
67% arm is a second threshold on the same number — `spamW*3 >= totalW*2` — and
burns the deposit as well as the fee.

`check-epoch-coherence` counts terminal writers (`TERMINAL_VERDICT_N`,
`TERMINAL_CLOSED_N`); a new terminal path moves those counts and they must be
**re-derived with the reason named**, not bumped.

### 3d. The draw — crystallize.gno

    want := mulDiv128(midGross, tierBpsFor(cs), tierParBps)          // today
    want  = mulDiv128(want, cs.spamTotalW-2*cs.spamW, cs.spamTotalW) // then, guarded

Guard `spamTotalW <= 0` (no dispute, or a pre-existing claim) as "no discount".
Floor at zero. `mulDiv128` because midGross is conviction and not supply-bounded.

### 3e. The carrot — crystallize.gno `PullCarrot`

On the discard path set `cs.carrotChoice = "spam"` and `cs.carrotDenom = spamW`,
so the existing with-verdict machinery pays the spam side. The `"d"+pid+addr`
record already stores each voter's choice string, so no new record is needed —
this is the trap T1 from QUALITY_REMOVAL_PLAN.md paying off, and the reason
`qVoted` must not be deleted with the quality lane.

### 3f. The overlay and gnoweb

- The third button becomes "Flag as spam" with what it does: below half it cuts
  the reward proportionally, above half it deletes the claim.
- The ballot's current sub-copy — "counts to turnout only, never to a side" —
  is still true and is now the *less* interesting half; lead with the effect.
- gnoweb's claim page: a disputed claim shows the spam share and the discount it
  implies, beside the size multiplier it is discounting.

## 4. What this does NOT change

The size multiplier stays as the undisputed case. An undisputed claim has no
voters and therefore no spam signal, so without it the mill's route — open,
self-answer, settle undisputed, collect — pays 1× again. Size is what reaches
that path: a self-staked claim is small against the court's typical claim and
earns 0.25×.

## 5. Risks

- **The 2× factor and the discard threshold must move together.** They meet at
  half by construction; changing one alone puts a gap or an overlap between
  "pays nothing" and "is deleted". Worth a deploy invariant in the same shape as
  the tier clamps: assert the discount hits zero exactly at the discard bar.
- **Nothing yet stops a spam-flag brigade** on a claim that is merely unpopular.
  The quorum bar and the participant exclusion are the only defences, and this
  plan adds no more. Worth stating in an ADR as accepted rather than discovered.
- **The 67% arm burns an author's deposit on a vote**, which is the harshest
  money consequence in the system reachable without a bond having been posted by
  the person who loses it. It deserves its own test naming the threshold.

## 6. Order

1. Rename the choice, reject `"abstain"`, keep the governor translation in one
   place. Green, commit.
2. Freeze `spamW`/`spamTotalW` at resolution. Green, commit.
3. The discount in crystallize, with the zero-floor and the no-dispute guard.
   Green, commit.
4. The discard terminal state and its two money arms; re-derive the
   `check-epoch-coherence` terminal counts. Green, commit.
5. The carrot for spam voters.
6. Overlay and gnoweb.
7. ADR recording the brigade risk and the deposit burn as accepted.
