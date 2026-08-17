<!-- Managed by the whitepaper iteration loop (influence session, cron 5cdddab6).
     State and round log: WHITEPAPER-ITERATION.md. Please don't hand-edit while
     the loop runs — leave notes in the iteration file instead and the loop will
     pick them up. This comment is stripped at publication. -->

# Kourt

**Courts for the internet's arguments — and the map they leave behind.**

*Draft. Kourt runs today on gno.land's sapphire testnet. Nothing in this
document is an offer to sell anything or a promise that anything will be worth
anything. Section 7 says plainly what these coins are and are not; read it
before buying anything.*

---

## 1. Every big argument on the internet is undefeated

In early 2021, the largest social platforms removed posts arguing that
SARS-CoV-2 might have come out of a laboratory. Two years later, the director
of the FBI said a lab origin was the bureau's assessment. The claim had not
changed. The evidence had barely changed. What changed was *permission*.

That sequence should bother you no matter where you think the virus came from,
because it reveals what public argument actually runs on. Not evidence —
permission. And permission has no memory: nobody who shouted "conspiracy
theory" in 2021 paid anything in 2023, and nobody who was right early was owed
anything either. There is no scoreboard. There is no ledger of who claimed
what, against what resistance, at what price.

The deeper problem is structural. Assertion is free, so it never stops.
Rebuttal is unpaid, so it never sticks. A thread about a contested question in
2020 and a thread about the same question in 2026 contain the same fight, the
same links, the same accusations — because nothing anyone said in between was
recorded anywhere it could *bind*. The internet has annotation (fact-checks,
community notes), and it has summary (the encyclopedia written by whoever
outlasted the edit war). It has never had the argument itself: as a structure,
with positions, with costs, with a record of who was where before it was safe
to be there.

Kourt is that record.

Kourt is a network of small courts, one per topic or community, where claims
are filed in exact, unchangeable words; argued by people who put money behind
their positions; and decided by a vote whose weights were fixed *before the
fight was visible*. Win or lose, everything stays: every claim, every stake,
every verdict, every dissent, linked into a public graph of the whole dispute.

The verdicts are useful. The graph is the point.

## 2. How a claim lives

Walk one claim through the machine.

**Filed.** Someone posts a claim in a court: one sentence, plus a body of
evidence. The sentence is immutable — a claim's identity *is* its wording, and
a different question is a different claim. The body is append-only: the author
may add timestamped notes below, and may never revise or remove what is
already there. Once anyone stakes on the claim, even the polish window closes.
There is no version of this where a claim quietly becomes a different claim
after it starts winning. Moving the goalposts is not against the rules; it is
against the data structure.

**Staked.** Holders of the court's coin stake it on the claim — for or
against. Staking is how a question becomes a question the court must answer,
and a position accrues *conviction* over time: coins staked for months count
for more than the same coins parked yesterday. Under the deployed rules, a
losing position forfeits rewards, never principal. You may unstake freely
until an answer is posted; an answer freezes the claim's stakes until
settlement, and at settlement principal returns in full, whichever way the
verdict went. The court is trying to find out what you actually believe, and
people stake honestly when a wrong position can't ruin them.

**Answered.** An answerer posts a resolution — TRUE, FALSE, with reasoning —
and bonds it. The bond is sized so that posting junk answers costs more than
it can ever pay.

**Disputed.** Anyone who thinks the answer is wrong can dispute it, which
sends the claim to a vote.

**Voted.** Voting weight is the court's coin as of an *epoch* — an hourly
snapshot of holdings — sealed **before the dispute opened**. This is the
mechanism the whole design leans on: by the time a fight is visible, the
electorate that will decide it is already fixed. You cannot buy your way into
a verdict you can already see coming — coins acquired today vote only in
tomorrow's fights.

**Crystallized.** The verdict is recorded permanently and the claim takes its
place in the graph: TRUE, FALSE, or, often and honestly, still OPEN, with the
live stakes on each side visible to anyone. Accuracy rewards are paid from the
court's own bounded emission — to the answerer, to the stakers who were right,
and to the voters of the deciding round. Forfeited bonds and deposits are
burned. Nobody in Kourt is ever paid from anyone else's loss.

One thing a verdict is not: the truth. A verdict is the recorded conclusion of
a particular electorate, with a particular amount of money behind it, at a
particular time. That is exactly as much authority as any human institution's
conclusion carries — a journal's, an agency's, an encyclopedia's. The
difference is that this one shows its work, prices its convictions, and keeps
its dissents on the record.

Won't people just vote their side? Sometimes they will. The design's honest
answer has four parts. Accuracy rewards pay the voters who sided with the
eventual verdict — a pull toward expected consensus, not an oracle. The sealed
epoch keeps a mob from flooding into a fight it can already see. The dissent
is permanent, so a court that votes tribally signs its own record in public,
claim after claim. And founding a rival court is permissionless: a court's
product is its credibility, and credibility is the one thing a captured court
cannot mint. If a court rots, the topic is not trapped — the record of which
court called what, and when, is how the next reader knows which one earned
the authority.

## 3. The by-product that outlives the verdicts

Claims in a court do not float free. They form two structures at once.

The first is a **tree**: every claim has exactly one home — a section, a
parent question — so paths mean something and the same sentence cannot be
filed twice in the same place. The second is a **graph** laid over it:
argument edges, added by anyone, at any time, marking that one claim
*supports* or *counters* another. A piece of evidence genuinely bears on many
questions; the edges are how the record says so.

The edges are deliberately inert. A supporting claim settling TRUE does not
mechanically drag its parent toward TRUE — no cascade, no inference engine, no
chain of dominoes an attacker could tip from one cheap corner of the graph.
People vote the parent too, seeing the children. Views may aggregate; the
chain does not infer.

Here is what that produces. The mockup below is illustrative — every number in
it is invented — but the *shape* is the product:

**KOURT:ORIGINS — "Origins of SARS-CoV-2"** (a court; month 14 of its life)

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
  ├─ ✓ #7  "US intelligence is split: FBI and DOE assess a    TRUE   settled month 2, undisputed
  │        lab origin as more likely; others lean zoonotic."
  ├─ ✗ #8  "mRNA vaccines contain tracking hardware."         FALSE  settled month 1; answerer
  │                                                                  compensated, disputer's bond burned
  └─ ⊘ #9  "Anthony Fauci declined to answer a Senate         OPEN   filed this week;
           committee's questions, invoking the Fifth (2026)."        answer window open
```

Read what the tree is doing, because no other artifact on the internet does
it.

Claims #2, #3 and #7 were, at various points, socially expensive to say out
loud. On the record, with money invited against them, they settled fast and
cheap — because each one reduces to documents, and staking against a published
document is expensive charity. Claim #5 settled FALSE: a favorite argument of
the lab-leak side, killed *in a lab-leak-curious court*, which is precisely
what makes the root claim's open 58/42 worth staring at. The graph separates
the strong version of a case from the weak version — on both sides, at once.
Claim #8 is the junk filter working as economics rather than moderation:
nobody had to delete it; it cost its supporters money and stands as a public
loss. And claim #9 is intake: a breaking, contested assertion enters the
record wordlocked, dated, and priced before the news cycle has settled on what
happened. However it resolves, the graph will remember who said what first,
and what it cost them to say it.

Policy claims work too, and differently. In a neighboring court:

**KOURT:MANDATES — "Pediatric COVID-19 vaccine mandates were justified."**
VERDICT: NO — month 14, 71/29, heavy stakes on both sides, dissent preserved.

A policy claim resolves to the court's *judgment*, and says so on its face.
This court's NO happens to land where several European health authorities
landed and against where several US states did. Unlike either, it shows you
exactly who backed which side, how hard, and what the minority said on the way
down — the dissent is as permanent as the verdict. And in the same court, the
claim *"COVID-19 vaccines substantially reduced severe disease and death in
adults"* settled TRUE early and was never seriously challenged. The same
electorate that rejected pediatric mandates settled adult efficacy TRUE.
Courts judge claims, not teams — and the graph is what proves it, either way,
to both audiences.

Now zoom out from COVID. The same machine runs for any dispute that generates
more heat than structure: a scientific controversy, a disputed election claim,
a corporate scandal, a historical argument, the safety record of a product.
What accumulates in each court is something that has never existed: **a map of
the argument** — what is claimed, what each claim rests on, what died and what
killed it, what is still live, and how much sustained conviction sits on each
side, denominated in the only unit the internet cannot counterfeit: money
someone chose to burn for a voice.

Wikipedia gives you the winner's summary. Threads give you the fight, with no
memory. Fact-checks give you one editor's verdict on one atom, with no
structure. Kourt gives you the argument itself — and gives it to everyone,
because the chain is public. Researchers, journalists, historians, and anyone
building AI systems that need to know *what the dispute actually is* — not
which side won the platform-moderation coin toss that week — can read the
whole graph, free, forever. That artifact is the reason this system deserves
to exist. The coins below are how it gets built.

## 4. Courts and coins

Every court has its own coin. This is deliberate fragmentation: one topic's
fate — legal, economic, social — must not couple to another's. A court about
drug policy and a court about a war zone should not share a token, a treasury,
or a failure mode. Capture of one court captures one court.

A court's coin is minted one way only: on its **bonding curve**, paid in GNOT,
gno.land's native token. The price starts near zero and rises linearly with
every coin minted. Voice in a small court is cheap because almost nobody has
claimed one; voice in a large, established court costs what established voices
cost. There is no premine, no allocation, no founder's stash — the founder
mints on the same curve as everyone else, starting at position zero because
nobody has minted yet, not because anyone reserved anything.

And the GNOT you pay is **burned** — destroyed, sent to a designated burn
address, auditable by anyone on-chain. Not held, not pooled, not managed by
anybody. This one fact clarifies the whole design, so it is worth being blunt
about what it buys and what it costs:

- **There is no treasury.** Nobody — not the founder, not a moderator, not a
  53%-of-supply attacker — holds a pool of contributed funds, because no such
  pool exists. There is nothing to rug, nothing to embezzle, nothing to freeze,
  and nothing whose custody you are trusting anyone with.
- **There is no redemption.** The curve only mints; nothing ever buys back.
  Your GNOT is spent the moment you spend it, in exchange for exactly one
  thing: a durable voice in one court's decisions, plus eligibility to earn
  its emission by working.

Coins are voice: staking weight, voting weight (at sealed epochs), the right
to answer and dispute. Coins also *flow to work*: each court runs a bounded
emission — 0.38% of live supply per week at genesis, stepping down a little
every week, shrinking to half its rate over each two-year span, with a hard
lifetime ceiling under +80% of everything ever minted on the curve. It decays
because a court needs its work funded hardest at the start; it is ceilinged so
that the worst case is arithmetic, not trust. Emission pays for answering
claims, disputing bad answers, voting in decided fights, and moderating well;
weeks with nothing worth paying for are skipped and forgone forever, never
banked and paid later. The coin concentrates, over time, in the hands of the
people doing the judging.

## 5. The Review Court, and what it costs to capture

Courts moderate themselves — and moderators, everywhere, eventually make
someone furious. So above all courts sits one more court, built out of the
same machinery: **KOURT:META, the Review Court**, the appeals layer.

An appeal is just a claim in the Review Court, in a reserved format naming a
verb and a target. Six verbs exist. Two are *restorative* — un-hide an item a
court's moderators hid, clear the Review Court's own mark — and these can pass
even from silence, because silence should be able to restore visibility. Four
are *aggressive* — hide, suspend a moderator set, re-arm one, install a new
moderator set on a court — and these execute only after a genuinely contested,
quorate vote in which a real adversary showed up. Silence can never seize a
court.

Who votes in the Review Court? The people who built the platform under it.
Every unit of GNOT burned in any court accrues, to the burner, a claimable
**franchise**: the right to mint KOURT:META through the Review Court's own
curve, at the same price a direct buyer would pay at that moment. Every
court's burn feeds that one curve, so the price of appellate voice reflects
the whole platform's history, not any one court's. Participation anywhere
earns appellate voice everywhere — automatically, at no discount and no
penalty. (You can also simply buy META. It accrues nothing further and costs
the same. Almost nobody should.)

The arithmetic of capturing the Review Court is public and brutal. To end
holding a given share of it, an attacker must irrecoverably burn a multiple of
**everything the entire platform has ever burned**:

| share of the Review Court | cost, as a multiple of all GNOT ever burned platform-wide |
|---:|---:|
| 5% | 0.11× |
| 20% | 0.56× |
| 50% | 3× |
| 90% | 99× |

And even that only counts if it was in place *before the epoch sealed* — the
weights for any given appeal were fixed before the appeal was visible.

Then the last line of defense, which is really the first: **the Review Court
cannot touch money.** Neither can anything else in the moderation system.

## 6. Moderation with a constitution

One rule governs every moderation power in Kourt, from a single court
moderator to the Review Court to the operator's own legal backstop:

> **Moderation is render-layer authority. No moderation state is ever read by
> a money path, and no moderation action ever writes one.**

Concretely: a hidden claim leaves the browse listings — and its full lifecycle
keeps running, byte-identically. Stakes, votes, settlement, withdrawals: all
of it. Deep links always render, with a banner naming exactly which authority
hid the item and under which category. Hiding is *discovery* control, never
custody, never confiscation. A fully captured moderator — a fully captured
*Review Court* — is harmless to funds, because the pipes it would need do not
connect.

Above the courts and the Review Court sits a small global moderator set: the
operator's legal backstop, for the things a token vote cannot lawfully decide
— court orders, DMCA notices, content that must actually come down. Its powers
are deliberately shaped as *cures, not commands*: it can clear any hide bit
(including the Review Court's — the recovery path if meta itself is ever
captured), disarm a rogue moderator set, and, by multiple keys, purge text for
legal compliance — a tombstone that removes words while every position stays
withdrawable. What it cannot do: appoint anyone's moderators (it can only
empty a set; the court's own electorate installs the next one), reverse a
verdict, or move a coin. Even the takedown machinery observes due-process
shapes — re-imposing a redaction that was cleared requires multiple keys
within a counter-notice window modeled on the DMCA's.

Every moderation act is an on-chain event carrying codes, never content — so
the history of who hid what is itself permanent and auditable, without
becoming a channel that defeats a legal purge.

## 7. What this is not

Read this section as written, because it is not boilerplate; it is the design.

**Kourt coins are not investments, and this document is not an offer of one.**
There is no treasury, no dividend, no buyback, no redemption, no revenue
share, and no pool of anyone's money anywhere in the system. The GNOT you
spend on a curve is burned: *treat it as spent.* What you receive is a
participation instrument — voice in one court's decisions and eligibility to
earn its emission by doing its work. If you do not intend to stake, vote,
answer, dispute, or moderate in that court, its coin is not for you.

**Nobody's future efforts stand behind these coins.** Once deployed, a gno
realm — gno.land's unit of deployed contract code — cannot be redeployed or
upgraded at its path, by the deployer or anyone else; a testnet reset starts a
fresh instance rather than changing a live one. The rules described here are
the rules, permanently, checkable in public source. The operator's remaining
roles are legal compliance and front-page curation, both constitutionally
fenced away from money. A thing whose value depended on our ongoing management
would be a different thing than this one. This is a machine that runs.

**Verdicts are conclusions, not facts.** A court can be wrong. A court can
stay wrong. The remedy is the record and the fork, not an oracle.

**Emission dilutes.** Holding without participating means a slow, bounded,
publicly scheduled dilution in favor of the people doing the work — that is
its purpose. Ceiling: under +80% of curve-minted supply, ever; half of all
emission lands in roughly the first two years of a court's life.

**This is early, on a young chain, with internal audit rounds only — no
external audit yet.** Testnet deployments will reset. Assume bugs exist.
Assume the coin you acquire may end up worth nothing, socially or otherwise,
and size your participation like the burn it literally is.

**Nothing here is legal, financial, or medical advice** — including the
contents of any court's graph, which are the recorded opinions of the people
who staked on them.

## 8. Starting

Kourt runs on gno.land, whose native token (GNOT) pays for transactions and
feeds the curves. Today that means the sapphire testnet, where GNOT is free
from a faucet — the entire system above is live to try at zero cost.

To participate: pick a court whose question you care about — or found one,
which is permissionless and costs only storage deposits. Mint voice on its
curve. File the claim you think the record is missing, in words you are
willing to be held to forever. Answer something. Dispute something that
deserves it. Vote when a fight lands in your court. Claim your franchise in
the Review Court when you've earned it.

The verdicts compensate the participants. The graph pays everyone else. Ten
years from now, most individual verdicts will read as period pieces — and the
map of how we argued, who stood where, what it cost and what died along the
way, will still be worth reading.

Bring a claim.

---

*Kourt — kourt.xyz · realm `gno.land/r/kourt/kourtv2` (sapphire testnet) ·
coins are denominated KOURT:SLUG; the Review Court's is KOURT:META. Design
sources: PLAN.md, MODERATION.md, and the realm source, which is public and
controlling — where this document and the code disagree, the code is the
whitepaper.*
