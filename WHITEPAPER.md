<!-- Managed by the whitepaper iteration loop (influence session, cron 5cdddab6).
     State and round log: WHITEPAPER-ITERATION.md. Please don't hand-edit while
     the loop runs — leave notes in the iteration file instead and the loop will
     pick them up. This comment is stripped at publication. -->

# Kourt

**An on-chain court system for contested claims.**

**Abstract.** Kourt is a network of on-chain courts, one per topic. A claim is
filed in fixed wording and cannot be reworded afterward. Holders of the
court's coin stake on it, an answerer bonds a resolution, and anyone who
disagrees can force a vote. Voting weight is read from an hourly snapshot
sealed before the vote opened, so weight cannot be bought for a vote already
underway. Verdicts, stakes, and dissents are recorded permanently. The coin is
minted on a one-way curve and the payment is burned; no treasury exists, and
rewards are minted by a bounded, decaying emission that pays the people who do
the judging. Moderation, including the appeals court that oversees it, can
control what is listed but cannot touch a stake, a bond, a verdict, or a
withdrawal.
What accumulates is a public record of each dispute: what was claimed, what it
cost to claim it, and how each part fared. This record is the purpose of the
system.

*Draft. Kourt is not yet deployed to a public network. Nothing in this
document is an offer to sell anything or a promise that anything will be worth
anything. Section 7 states what the coins are and are not; read it before
acquiring any.*

## 1. Introduction

In February 2021, Facebook banned posts claiming the COVID-19 virus was
man-made. It reversed the ban that May. In February 2023, the director of the
FBI said the bureau assessed the pandemic most likely began with a lab
incident in Wuhan. The claim had not changed. The evidence had barely changed.
What changed was permission.

That sequence is a problem whatever the virus's true origin, because it shows
that public argument runs on permission rather than evidence. Permission has
no memory: no one who dismissed the claim in 2021 paid anything in 2023, and no
one who was right early was owed anything. There is no scoreboard. There is no
ledger of who claimed what, against what resistance, at what price.

The deeper problem is structural. Assertion is free, so it never stops.
Rebuttal is unpaid, so it never sticks. A thread about a contested question in
2020 and a thread about the same question in 2026 contain the same dispute and
the same links, because nothing said in between was recorded anywhere it could
bind. The internet has annotation, and it has summary. It has never had the
argument itself: as a structure, with positions, costs, and a record of who
was where before it was safe to be there.

Kourt is that record. Claims are filed in exact, unchangeable words, argued by
people who put money behind their positions, and decided by a vote whose
weights were fixed before the vote opened. Win or lose, everything stays:
every claim, every stake, every verdict, every dissent.

## 2. Claims

A claim moves through six states.

**Filed.** A claim is one sentence, at most 200 characters. The sentence is
permanent: a claim's identity is its wording, and a different question is a
different claim. A court may allow a short polish window at filing, up to a
day; staking cannot begin until the window ends, and the wording is fixed from
then on. A claim cannot become a different claim after it starts winning.

**Staked.** Holders of the court's coin stake it on the claim, for or against.
Stake accrues conviction over time: coins staked for months count for more
than coins parked yesterday. A losing position forfeits rewards, never
principal. Stakes move freely until an answer is posted; an answer freezes the
claim's stakes until settlement, and at settlement principal is released in full,
whichever way the verdict went. People stake their true position when a wrong one
cannot ruin them.

Nothing prevents one holder staking both sides of a claim, and it is worth being
exact about what that does, because two earlier drafts of this paragraph were
wrong. **It is mildly profitable.** Only the winning half earns, but both halves
tie up capital, so a hedger collects about half the reward while bearing the whole
holding cost — which leaves a thin positive margin rather than nothing. Measured
on an eleven-week claim, a hedger keeps roughly a twelfth of what someone who
took a side and was right keeps, and the hedger's edge depends entirely on what
that capital could have earned elsewhere: it grows if alternatives are poor and
vanishes if they are good.

This is a spread, not a leak. It is bounded twice over by mechanisms that exist
for other reasons — the payout cap means the bonus tier pays a hedger less than
double, and the per-period emission budget makes hedging *lose* money on a thin
court — and it is not risk-free in aggregate, since a claim voted junk or left
unanswered pays a hedger nothing at all. Closing it is possible only by charging
for staked capital-time, which prices a hedger and an honest 50/50 staker
*identically*, because they are arithmetically the same position. We would rather
pay the spread than tax genuine uncertainty.

Verdicts themselves are decided by coin votes, not by stakes, so hedged capital
buys no verdict power at all — but note that staked coins are **not** held in
custody and do keep their court-wide vote; an earlier draft claimed otherwise, and
that custody was deliberately removed. And equal stake on both sides moves a
claim's lean toward even; it cannot manufacture one. The lean measures net stake,
not headcount — though the lean is a *display* of sentiment and deliberately does
not drive the payout, because keying rewards to it would let anyone burn a claim's
whole prize by funding the losing side.

**Answered.** An answerer posts a side, TRUE or FALSE, and bonds it. The bond is
priced against what a wrong answer could destroy — the conviction standing on
the claim, measured on **both** sides rather than only the side being declared.
That distinction is the whole of it. Price it against the declared side alone and
someone can stake dust on their own side, declare it, and post almost nothing
against a large opposing pool; price it against the larger of the two and the
same person pays for the damage they are in a position to do. An answer that
contradicts a well-funded crowd is therefore expensive, and an early answer on a
thin claim is cheap, which is the correct way round.

**Disputed.** Anyone except the answerer can dispute the answer, posting a bond
of their own. The dispute sends the claim to a vote, and the side the vote
decides against loses its bond.

**Expired.** A claim nobody answers within twelve weeks closes rather than
resolving. Stakes return whole; no prize is paid. This is a real limit and worth
stating plainly: a court cannot hold a years-old open question. What a market on
an unresolved question does instead is ask again each time new evidence lands,
and let the earlier contract lapse — so a long-running dispute appears on the
docket as a series of claims rather than one, each priced by what was knowable
that month.

**Voted.** Voting weight is the court's coin as of an epoch: an hourly
snapshot of holdings, already sealed when the vote opened. By the time a vote
exists, the electorate that will decide it is already fixed. Coins bought after the seal
carry weight in later votes, not this one. The seal binds those who react to
a dispute, not those who plan one: a buyer can wait out the hour and open the
dispute himself. What it removes is the crowd that arrives once a dispute is
visible.

**Crystallized.** The verdict, TRUE or FALSE, is recorded and never revised.
A claim not yet carried to verdict stays OPEN, its live stakes visible. Accuracy rewards are
minted from the court's emission and paid to the prevailing bonder (answerer
or disputer), the stakers on the verdict's side, and the voters of the
deciding round. Forfeited bonds are
burned. No one in Kourt is paid from anyone else's loss.

Two things about that reward are worth being exact about, because a staker
commits before either is knowable. The **published rate is never reduced** — a
claim adjudicated as ordinary pays the rate it advertised, and nothing in the
settlement can cut it. What *is* discretionary is the bonus multiplier an
exceptional claim can earn on top, and that bonus is capped by what the answerer's
bond collateralized. The reason is unglamorous: the bonus is the one component a
false answer could inflate at someone else's expense, so it is bounded by the
money at risk behind the answer. A staker is promised the rate, not the bonus.

A verdict is not the truth. It is the recorded conclusion of a particular
electorate with a particular amount of money at stake at a particular time.
That is the same authority any human institution's conclusion carries. The
difference is that this one shows its work, prices its convictions, and keeps
its dissents on the record.

People will sometimes vote their side rather than the evidence. The design
accepts this and answers it five ways, and the first is the strongest: **a
participant cannot vote on their own claim at all.** Anyone holding stake on
either side of a claim, its author, and its answerer are refused outright — and a
stake record survives withdrawal, so the position cannot be shed to buy back the
franchise. A verdict is therefore decided by holders with no position on the
question, which is a stronger guarantee than any incentive: the conflicted party
is not paid to behave, they are excluded. It has a real cost, and it is the
reason the next paragraph matters — a claim needs turnout from people who have
nothing riding on it.

Beyond that: accuracy rewards pay the voters who sided with the eventual verdict,
a pull toward expected consensus rather than an oracle. The sealed epoch keeps a
crowd from buying into a dispute it can see. Dissent is permanent, so a court
that votes tribally signs its own record, claim after claim. And founding a rival
court is open to anyone, so a court that rots does not trap its topic: the record
of which court called what, and when, tells the next reader which one earned
authority.

## 3. The record

The version of Kourt described in this paper ships in layers, and it is worth
being exact about which layer does what. The court layer, specified above, is
built: wordlocked claims, stakes, bonds, votes, verdicts, dissents, all
permanent.

The bond pricing described in §2 is now **shipped**: the base fell from half a
claim's average stake to 6%, and — the part that does the work — it is priced
against the larger of the two sides rather than the side being declared. So is the
bonus cap. Both landed with their fixtures and were verified by deliberately
breaking them, and the reasoning, the measurements and the attacks run against
them are recorded in `GAMETHEORY.md` and `IMPLEMENTATION.md`.

Three structural fixes shipped alongside: a small claim's verdict is now reachable
at all (the turnout bar was keyed to the court's size rather than the claim's, so
below a threshold no proportional turnout could clear it — and an unreachable
quorum handed the decision to the party the bar exists to police); a claim whose
rounds all fail now closes at the ordinary rate instead of paying nothing; and a
vote that overturns an answer can no longer, in the same breath, declare the claim
worthless.

**Two things are open and named rather than papered over.** The cheapest way to
destroy a claim's reward is not the answer bond at all but a low-turnout quality
vote, which is a pending decision about how cheap a legitimate challenge should
be. And staking *both* sides of a claim is currently profitable — small, but
risk-free — which is a bug rather than a design choice. The structure layer arranges those claims and is specified for the
release after: each claim gets one home in a tree of sections, so paths mean
something and the same sentence cannot be filed twice in the same place, and
anyone may add argument edges marking that one claim supports or counters
another. Edges will be inert by design. A supporting claim settling TRUE will
not mechanically move its parent; people vote the parent too, seeing the
children. Views may aggregate; the chain does not infer, and no attacker can
tip a tree of verdicts from one cheap corner of it.

The mockup below shows a mature origins court under both layers.

**KOURT:ORIGINS — "Origins of SARS-CoV-2"** (month 14 of the court's life;
⊘ open · ✓ settled true · ✗ settled false. The stakes, leans, verdicts, and
settlement dates are invented; the claims themselves reference real documents
and events.)

```
⊘ #1  "SARS-CoV-2 originated in a laboratory."                OPEN   412k staked · leaning 58/42
  ├─ ✓ #2  "NIH funded coronavirus research at the Wuhan      TRUE   settled month 2, undisputed
  │        Institute of Virology via EcoHealth Alliance."
  ├─ ✓ #3  "The 2018 DEFUSE proposal described inserting      TRUE   settled month 3, disputed once
  │        furin cleavage sites into SARS-like viruses."
  ├─ ⊘ #4  "That research met the 2014 gain-of-function       OPEN   201k staked · 51/49
  │        moratorium's definition."
  ├─ ✗ #5  "The furin cleavage site cannot have arisen        FALSE  settled month 6, after a vote
  │        naturally."
  ├─ ⊘ #6  "The earliest cases cluster at the Huanan market   OPEN   97k staked · 47/53
  │        independent of where officials looked first."
  ├─ ✓ #7  "US intelligence agencies are split on the         TRUE   settled month 2, undisputed
  │        origin, with no consensus assessment."
  ├─ ✗ #8  "A SARS-CoV-2-infected animal was found at the     FALSE  settled month 8;
  │        Huanan market."                                            disputer's bond burned
  ├─ ✓ #9  "Anthony Fauci invoked the Fifth Amendment more    TRUE   filed and settled inside
  │        than 100 times before a Senate committee (2026)."          five days
  └─ ⊘ #10 "The January 2025 pardon defeats the Fifth         OPEN   freshly staked
           Amendment privilege for the pardoned conduct."
```

The tree separates the strong version of each case from the weak version, on
both sides at once. Claims #2, #3, #7 and #9 were, at various points,
expensive to say in public. On the record, with money invited against them,
they settled fast, because each reduces to documents, and staking against a
published document predictably loses. Claim #5 settled FALSE: a favorite argument of
the lab-leak side, retired in a court whose root leans lab-leak. Claim #8
settled FALSE the same way for the other side: the market samples were
environmental, and no infected animal was ever found, however widely the
opposite was reported. Each camp lost its weakest claim in public, which is
what makes the root's open 58/42 worth reading. Claims #9 and #10 show intake:
a breaking event decomposes on arrival into the part that reduces to public
record, which settles in days, and the contested residue, which
stays open with stakes accumulating.

Policy claims resolve to a court's judgment and say so on their face. In a
neighboring court:

**KOURT:MANDATES — "Pediatric COVID-19 vaccine mandates were justified."**
VERDICT: FALSE. Month 14, 71/29, heavy stakes on both sides, dissent
preserved.

That FALSE lands where several European health authorities landed, and
against the position hundreds of US universities took. Unlike either, it shows who backed
which side, at what weight, and that the minority held its ground to the end;
the dissenting weights are as permanent as the verdict. In the
same court, the claim "COVID-19 vaccines substantially reduced severe disease
and death in adults" settled TRUE early and was never seriously challenged.
The same electorate rejected pediatric mandates and settled adult efficacy
TRUE. Courts judge claims, not teams, and the record proves it to both
audiences.

The same machine runs for any dispute that generates more heat than structure:
a scientific controversy, an election claim, a corporate scandal, a historical
argument, a product's safety record. What accumulates in each court has not
existed before: a map of the argument. What is claimed, what each claim rests
on, what died and what killed it, what is still live. The weight on each side
is denominated in money someone
chose to burn for a voice.

Wikipedia records the winner's summary. Threads record the fight, without
memory. Fact-checks record one editor's verdict on one atom, without
structure. Kourt records the argument itself, and the chain is public, so it
records it for everyone: researchers, journalists, historians, and anyone
building systems that need to know what a dispute is rather than which side
was winning moderation that week. That artifact is the reason the
system exists. The coins are how it gets built.

## 4. Courts and coins

Every court has its own coin. This is deliberate fragmentation. One topic's
fate must not couple to another's, so courts share no coin, no treasury, and
no failure mode. Capture of one court captures one court.

A court's coin is minted one way: on its bonding curve, paid in GNOT, the
native token of the gno.land chain. The price starts near zero and rises
linearly with each coin minted, so the cost of the n-th coin is proportional
to n. Voice in a small court is cheap because almost no one has claimed one.
Voice in a large court costs what established voices cost. There is no premine
and no allocation. What a founder gets is the chance to mint first, on the
same curve, at its lowest positions; section 7 discloses that the designers
may hold such positions.

The GNOT paid is burned: sent to a designated burn address, auditable by
anyone on-chain. It is not held, pooled, or managed. This one fact clarifies
the design:

- **No treasury.** No one holds a pool of contributed funds, because no such
  pool exists. There is no fund to steal, freeze, or embezzle, and no
  custodian to trust.
- **No redemption.** The curve only mints; nothing buys back. GNOT spent is
  spent. What it bought is a durable voice in one court's decisions, and
  eligibility to earn that court's emission by working.

Coins are voice: staking weight, voting weight at sealed epochs, the right to
answer and dispute.

Coins also flow to work. Each court runs a bounded emission: 0.38% of live
supply per week at genesis, stepping down weekly, falling by half over each
two-year span. Over a court's whole life, emission adds less than 80% on top
of what its curve has minted. The rate decays because a court needs its work
funded hardest at the start. It is ceilinged so the worst case is arithmetic
rather than trust. Emission pays
for staking on the verdict's side, answering, disputing bad answers, voting in
deciding rounds, and policing junk. Beyond a four-week reservoir, unspent
budget is forgone, not banked. Over time the coin concentrates in the hands of
the people doing the judging. The Review Court, described next, runs a small
fixed weekly budget instead.

## 5. The Review Court

Courts moderate themselves, and moderation eventually faces challenge. One
further court therefore sits above the courts, built from the same machinery:
KOURT:META, the Review Court, the appeals layer.

An appeal is a claim in the Review Court, in a reserved format naming a verb
and a target. Six verbs exist. Two are restorative: un-hide an item a court's
moderators hid, and clear the Review Court's own mark. These can pass even
from silence, because silence should be able to restore visibility. Four are
aggressive: hide an item, suspend a moderator set, re-arm one, and install a
new set. These execute only after a decided, quorate vote, and the three verbs
that touch moderator sets further require that real opposing weight voted.
Silence can never seize a court.

The Review Court's electorate is the people who built the platform under it.
Burning GNOT in any court, other than the Review Court itself, earns
franchise: a claimable right to mint KOURT:META later. The franchise is not a
discount; the price is the same for everyone. What differs is which burn pays
it: GNOT already burned for a court's coin stands on record, and the Review
Court's curve accepts that record as payment, while a direct buyer burns new
GNOT. Claiming mints through
the Review Court's own curve at the price a direct buyer would pay at that
moment, and every court's claimed burn feeds that one curve, so the cost of
appellate voice reflects the platform's whole history rather than any one
court's. Direct purchase is also possible, accrues nothing further, and costs
the same.

Capturing the Review Court is a purchase whose price is public. To end up
holding a share of it, an attacker must irrecoverably burn a multiple of
everything ever claimed into its curve:

| share of the Review Court | cost, as a multiple of all burn ever claimed into it |
|---:|---:|
| 5% | 0.11× |
| 20% | 0.56× |
| 50% | 3× |
| 90% | 99× |

Weight counts only if it was in place before the appeal's vote opened.
Franchise not yet claimed is a standing reserve: every unclaimed unit, once
claimed, dilutes a captor.

## 6. Moderation

One rule governs every moderation power in Kourt, from a single court
moderator to the Review Court to the operator's legal backstop:

> Moderation controls what is found, never what is owed. No moderation power
> can touch a stake, a bond, a verdict, or a withdrawal.

A hidden claim leaves the browse listings, and its lifecycle keeps running,
byte for byte: stakes, votes, settlement, withdrawal. A direct link to a
hidden claim always renders, with a banner naming the authority that hid it and
the category invoked. Two narrow intake gates exist, both disclosed: a purged
court accepts no new claims, and while a review of a target is live, competing
appeals against that target cannot be answered. Funds in flight are never
gated. A fully captured moderator, or a fully
captured Review Court, is harmless to funds, because the pipes it would need
do not connect.

Above the courts sits the operator's legal backstop, for the things a coin
vote cannot lawfully decide: court orders, DMCA notices, content that must
come down. At genesis this is a single operator key; the code supports m-of-n
membership, and broadening it is deployment work, not a rule change. Its
powers are cures, not commands. It can clear any hide bit, including the Review Court's, which is
the recovery path if the Review Court itself is captured. It can disarm a
rogue moderator set, though it cannot appoint one: after a disarm, the court's
own electorate installs the next set, or its creator does if no election has
yet been held. A court's first moderator set is likewise its creator's
appointment; once an election installs a set, the creator's power to appoint
is spent. It can purge text for legal compliance, up to a whole court: a tombstone that
removes words while every position stays withdrawable. The purge threshold is
m-of-n keys, set by its own admin; at genesis it is one key. Re-imposing a redaction that was cleared
requires that same threshold inside a counter-notice window modeled on the
DMCA's.

Every moderation act emits an on-chain event carrying codes, never content.
The history of who hid what is itself durable, without becoming a channel
that defeats a legal purge.

## 7. What this is not

The limits below are design constraints, not disclaimers.

**The coins are not investments, and this document is not an offer of one.**
There is no treasury, no dividend, no buyback, no redemption, and no pool of
anyone's money anywhere in the system. GNOT spent on a curve is burned and
should be treated as spent. The coin is a participation instrument: voice in
one court's decisions, and eligibility to earn its emission by doing its
work. A coin in a court whose question holds no interest is a coin with no
use.

**No one's future efforts stand behind the coins.** A gno realm, the chain's
unit of deployed contract code, cannot be redeployed or changed at its path
once published; not even its deployer can change it. The rules described here
are
the rules, checkable in public source. The operator's remaining roles are
legal compliance and front-page curation, both fenced away from money by the
rule in section 6. A thing whose value depended on continuing management
would be a different thing than this one.

**Verdicts are conclusions, not facts.** A court can be wrong. A court can
stay wrong. The remedy is the record and the fork, not an oracle.

**Emission dilutes.** Holding without participating means a slow, scheduled
dilution in favor of the people doing the work. That is its purpose. The
lifetime ceiling adds less than 80% on top of curve-minted supply, and half of all
emission lands in roughly a court's first two years.

**This is early software on a young chain.** It has had internal audit rounds
only; there has been no external audit. Nothing is deployed to a public
network as of this draft, and test deployments reset. Assume bugs exist.
Assume a coin can end up worthless, and size participation like the burn it
is.

**Disclosure.** Kourt's designers hold GNOT, the token every curve burns,
and may hold positions in courts they have founded, minted on the same public
curve as anyone else's and visible on-chain like any others. Readers should weigh
this document accordingly.

**Nothing here is legal, financial, or medical advice.** That includes the
contents of every court's record, which are the staked opinions of the people
who put money on them.

## 8. Participation

Kourt is built for gno.land. At launch it will run on a public testnet, where
GNOT is free from a faucet, so trying the system will cost nothing. A burn of
faucet tokens is rehearsal; the record that matters starts where the money is
real.

Participation is three acts: founding or joining a court, filing the claims
its record lacks, and staking, answering, disputing, and voting as
disputes arise. The Review Court franchise accrues on its own.

Individual verdicts will age. The record of how each question was argued,
who stood where, and what it cost, will not.

---

*Kourt · kourt.xyz · target platform gno.land · coins denominated KOURT:SLUG;
the Review Court's coin is KOURT:META. Design sources: PLAN.md, MODERATION.md,
and the realm source. Where this document and the code disagree, the code
governs.*
