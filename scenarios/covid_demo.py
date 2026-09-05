"""A populated COVID-19 court: five years, sixteen participants, a filed docket.

WHAT THIS IS FOR, and how it differs from covid.py beside it. That one is a
narrative: eleven claims chosen to demonstrate one rule — a claim nobody answers
within twelve weeks CLOSES rather than resolving — and it is a CI scenario with a
generated txtar. This one is the fixture you point a browser at: THIRTEEN
claims in SIX folders, sixteen accounts, and fourteen relations between claims,
so every surface the overlay has is looking at something.

Those numbers used to read "thirty-eight claims in twenty-four folders", and the
sentence after them promised they were "the counts the file actually produces".
They were not — the docket was trimmed to thirteen for the hourly-window reason
KEEP explains below, and the tree was cut from twenty-four folders to six because
thirty boxes on a map is a filing cabinet, not a docket. A count that describes
itself as measured has to be measured.

TWO ARTIFACTS, AND THE CHAIN CAN ONLY HOLD ONE OF THEM. This was the first thing
worth finding out and it shapes the whole file:

  * the realm's `folder` struct had an id, a name, a description and a list of
    claim ids, and NO PARENT — on-chain folders were flat, and a subfolder did
    not exist on this chain.
  * relations between claims were not on the chain at all. The overlay said so on
    every screen that drew one: "the chain stores no relations".

**BOTH OF THOSE ARE NOW FALSE, and this file used to be built around them.**
`folder.parent` shipped with `CreateFolderIn`/`MoveFolder`/`OrderFolders`
(maxFolderDepth 4, maxFolders 100), and §5's argument edge shipped as this
realm's ASSOCIATION (`AddAssociation`, and the bond that prices a stranger's).
So the tree and the argument graph go ON CHAIN here, out of the same table that
used to write them to a browser file.

What is still curation, and it is now one thing rather than two: claim-to-claim
CONTAINMENT (`part`). §5 allows a containment parent to be a *section* only, §6
defers sections, and folders are the containment this realm chose — so a
claim→claim `part` edge is the one shape §5 forbids, and it stays in the file the
reader keeps. The curation file is still written in full, because demo mode has
no chain to read and needs a tree of its own.

Both come out of ONE table below. The scenario knows each claim's id because ids
are `c.nextID`, per court, sequential from 1 — so the curation it writes cannot
reference a claim that does not exist, which is the failure the overlay warns
about ("N claim ids are not on this chain"). covid.py tracks its ids as
hand-written constants (`FUNDING = 2`); insert one claim above and every later
constant is silently wrong. This one counts them.

THE CALENDAR IS REAL. THE HEIGHT CANNOT BE, AND THAT IS THE REALM'S DECISION.
The first version of this file walked clock and height together at the chain's
five seconds a block, so the dates the overlay derives from `now:<unix>:<height>`
would match the dates the timeline reports. The realm refused it, correctly:

    kourtv2: the test height moves forward, by at most two emission periods a step

`maxHeightTotal` is ten emission periods — about ten weeks of blocks, ever. It is
capped that low on purpose and the reasoning is in testclock.gno: `touch()` walks
emission periods ONE AT A TIME, so the gas of the next transaction into a court
grows with the periods elapsed. Measured there: ~520k gas steady state, 713
MILLION after one legal step at an earlier 1e9 cap. Past the per-transaction gas
ceiling the touch reverts, `lastAccrual` is never written, and every entrypoint
that touches first is dead in that court FOR EVER — sealing included. One legal
call, irreversible. Five years of height is 33 million blocks. It is not a limit
to work around; it is a guard against bricking the court.

So the clock walks five years (maxAdvanceTotal is a hundred) and the height
advances only where a gate actually needs it — 2,160 blocks for answerability.
The consequence is worth stating because it is visible in the product: a claim's
TIMELINE dates are the real 2020-2025 stamps, while the CHART's x-axis is block
heights and the overlay dates those by extrapolating from `now:(t,h)` at five
seconds a block. On this fixture those two disagree, and they must — no fixture
can have a five-year clock and consistent heights on a realm that caps height
skew at ten weeks. Disputes are therefore left OPEN rather than voted through:
closing one costs votingBlocks + graceBlocks = 138,240 blocks, and six of them
would spend most of the ten-week budget to reach a state a reader can already see
from the docket.

WHAT THE CLAIMS SAY. A court adjudicates propositions, so each is written as
something a tribunal could find true or false on evidence, and nothing here
asserts a finding the world has not made. Where the record is genuinely split —
the origin question, the laboratory hypothesis — the claim stays OPEN, which is
the honest state for it. Where a matter of record has been established — what was
funded, what a document says, what an agency published — the claim resolves. An
unadjudicated allegation on the docket is not an accusation; pricing a question
is the thing this product does.

    python3 scripts/scenario.py scenarios/covid_demo.py --emit plan
    sh scripts/seed-node.sh scenarios/covid_demo.py
"""

import datetime
import os
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import Scenario, Addr, YES, NO, DEPLOYER  # noqa: E402

# Never a txtar. It writes a curation file as a side effect, walks five years of
# calendar, and exists to be looked at rather than asserted on.
CI = False

SLUG = "covid"
BASE = "2020-01-15"
# THE FIXTURE'S "NOW" IS TODAY, computed rather than written down. A literal END
# drifts the moment the calendar passes it: this said 2026-12-15 while the real
# date was 2026-09-03, so every seeded claim sat three months in the future and a
# vote closing five days after the fixture's now read as "closes in December" to
# somebody looking at it in September. The graph is where that shows, because a
# reader compares its x-axis against the date on their own wall.
#
# SEED_END pins it, for a run that wants a fixed dataset to diff.
END = os.environ.get("SEED_END") or datetime.date.today().isoformat()


def before_end(days):
    """A date `days` before the fixture's now, as an ISO string.

    The live disputes use this for the same reason END is computed: a dispute is
    interesting only while its vote is open, and fixed dates put them in the
    future once and in the distant past soon after. The offsets leave room for
    each arc to finish before END — short_grind runs about six days past its
    filing, and a date past END is what the guard at the bottom of this file
    refuses.
    """
    return (datetime.date.fromisoformat(END)
            - datetime.timedelta(days=days)).isoformat()
EPOCH_BLOCKS = 720       # the twap bucket width, and the height a calendar step moves
PERIOD_BLOCKS = 120_960  # one emission period = 168 buckets = the trailing window
# HOW MANY CLAIMS CARRY A TREND. A window is crossed inside each of these
# claims' lives — between two of its own moves — because that is the only thing
# that matures a trailing average: 168 buckets have to pass between two
# observations OF THE SAME CLAIM. A single window crossed at one date matured
# exactly one claim on the first attempt, since claims here live about
# twenty-six days and only one was mid-life on any given date.
# Four, spread across the calendar, at 120,960 blocks each — see the budget note
# where they are spent.
TREND_CLAIMS = 4
TWAP_BUCKETS = 3         # answerWindow / epochBlocks: distinct buckets needed to answer
# Beside the scenario, not in web/: the web root is what deploy.sh ships, and
# this is a local fixture the reader imports by hand.
CURATION = pathlib.Path(__file__).resolve().parent / "covid-curation.json"


def epoch(iso):
    return int(datetime.datetime.strptime(iso, "%Y-%m-%d")
               .replace(tzinfo=datetime.timezone.utc).timestamp())


s = Scenario("covid_demo", __doc__.split("\n\n")[0])
_at = {"iso": BASE}


def goto(iso, why):
    """Walk the wall clock to a real date. Forward only, like the chain's.

    Deliberately does NOT move the height with it — see the header. The height
    budget is ten weeks of blocks for the whole run and it is spent on gates.
    """
    delta = epoch(iso) - epoch(_at["iso"])
    if delta <= 0:
        raise ValueError(f"the calendar only moves forward: {_at['iso']} -> {iso}")
    s.advance(delta, why=f"{iso} — {why}")
    # ONE BUCKET PER CALENDAR STEP. answerability reads a trailing average over
    # answerWindow blocks and demands it MATURE, which twap.Average defines as
    # observations in `window / bucketWidth` = 3 DISTINCT buckets. It is not
    # 2,160 mined blocks — "not enough stake history to answer yet" was the ring
    # holding one sample, not the height being short. Moving 720 a step makes
    # consecutive calendar steps consecutive buckets, so a claim staked on three
    # different dates is answerable and one staked all at once is not.
    s.advance_height(EPOCH_BLOCKS, why=f"{iso} — one twap bucket")
    _at["iso"] = iso


# ------------------------------------------------------------------ the room
#
# Sixteen accounts. Who takes which side, and in which week, is what makes a
# docket read as used rather than dressed.
#
# The funding looks extravagant and the buy fraction small; both are load-bearing.
# Staked coin cannot also back a deposit or a bond — the chain says so in as many
# words — AND every write locks a GNOT storage deposit that is not the coin at
# all. Spending 92% of the balance on Buy passed the coin budget and then failed
# with "lockStorageDeposit failed ... insufficient coins": the accounts had bought
# themselves out of being able to file. A minority into coin, the rest kept for
# deposits.
ACTORS = [
    ("virology", 3_024_000_000, "coronavirus researcher; doubts a laboratory origin"),
    ("biosafety", 2_880_000_000, "containment engineer; thinks a leak likely"),
    ("epi", 2_736_000_000, "field epidemiology; the market-origin case"),
    ("genomics", 2_592_000_000, "sequence analysis; reads the phylogenies"),
    ("foia", 2_160_000_000, "reads the released documents, takes no side beyond them"),
    ("oversight", 2_448_000_000, "follows the congressional record"),
    ("journo", 2_016_000_000, "reporting the funding trail"),
    ("clinician", 2_304_000_000, "hospital medicine; the treatment claims"),
    ("modeller", 2_160_000_000, "built forecasts and grades his own"),
    ("statistician", 2_448_000_000, "excess mortality; distrusts every case count"),
    ("teacher", 1_584_000_000, "school closures, from inside one"),
    ("vaxsafety", 2_160_000_000, "pharmacovigilance; reads the safety signals"),
    ("skeptic", 1_872_000_000, "sceptical of every side, his own included"),
    ("trader", 3_024_000_000, "no view; takes the other side of crowds"),
    ("arbiter", 2_016_000_000, "answers claims; holds no position"),
    ("arbiter2", 1_872_000_000, "the second answerer, so one account is not the court"),
]

# --------------------------------------------------------------- the shapes
#
# WHY THIS EXISTS AT ALL: the first version of this fixture gave every claim four
# or five stakes, all in the filing week and all one way, and the charts were
# flat. ClaimSeries is CHANGE-ONLY and bucketed per 720-block epoch, and `goto`
# moves exactly one epoch a step, so a claim's chart has as many points as it has
# DATES with movement. Five dates, five points, no shape.
#
# So a claim carries a position HISTORY: eight to eighteen moves over its life,
# both sides, with unstakes. Unstakes are not decoration — they free committed
# coin, which is what keeps sixteen accounts inside their budgets while trading
# this much, and a book where nobody ever leaves is not a book.
#
# Each shape returns (day-offset, actor-slot, side, delta) with delta<0 meaning
# unstake. Slots are filled per claim from its own cast, so the same shape reads
# differently in different hands.
def tug(a, b, c, d):
    """Both sides keep answering each other. Swings, no resolution."""
    return [(0, b, NO, 6), (0, a, YES, 8), (2, b, NO, 7), (5, a, YES, 6), (8, b, NO, 9),
            (12, c, YES, 5), (16, b, NO, 6), (20, a, YES, -4), (24, d, NO, 4),
            (29, c, YES, 9), (34, b, NO, -5), (40, a, YES, 5), (46, d, NO, 7),
            (53, c, YES, -3), (60, b, NO, 4), (68, a, YES, 6), (76, d, NO, -4)]


def drift(a, b, c, d):
    """One side accumulates. The interesting part is that it never reverses."""
    return [(0, b, NO, 6), (0, a, YES, 5), (3, b, NO, 8), (7, a, YES, 6), (11, a, YES, 4),
            (15, b, NO, -3), (19, c, YES, 5), (25, a, YES, 7), (31, b, NO, 3),
            (38, c, YES, 6), (45, d, YES, 5), (52, b, NO, -4), (60, a, YES, 4),
            (70, c, YES, 5)]


def reversal(a, b, c, d):
    """A lead built early and given back. The shape a market is for."""
    return [(0, b, NO, 5), (0, a, YES, 12), (2, a, YES, 6), (4, b, NO, 3), (9, c, YES, 4),
            (14, b, NO, 8), (18, a, YES, -8), (23, d, NO, 7), (28, b, NO, 6),
            (33, a, YES, -6), (39, d, NO, 5), (47, c, YES, -3), (56, b, NO, 4),
            (65, d, NO, 3), (74, a, YES, 3)]


def capitulate(a, b, c, d):
    """Heavy conviction, then the holder leaves in stages."""
    return [(0, b, NO, 6), (0, a, YES, 16), (3, b, NO, 4), (6, c, YES, 3), (10, b, NO, 6),
            (15, a, YES, -5), (21, b, NO, 5), (27, a, YES, -6), (34, d, NO, 4),
            (42, c, YES, -2), (50, b, NO, 3), (59, a, YES, -4), (69, d, NO, 3)]


def late(a, b, c, d):
    """Quiet, then it becomes the question of the week."""
    return [(0, b, NO, 3), (0, a, YES, 4), (6, b, NO, 3), (14, a, YES, 2), (28, b, NO, 2),
            (44, c, YES, 3), (56, a, YES, 9), (60, b, NO, 11), (64, c, YES, 8),
            (68, d, NO, 7), (71, a, YES, 6), (74, b, NO, -5), (77, c, YES, 5),
            (80, d, NO, 6)]


def short(a, b, c, d):
    """For a claim that will be ANSWERED, so its whole life is three weeks."""
    return [(0, a, YES, 7), (0, b, NO, 5), (3, a, YES, 4), (5, c, YES, 3),
            (7, b, NO, 8), (9, a, YES, -3), (11, d, NO, 4), (13, c, YES, 6),
            (15, b, NO, -4), (17, a, YES, 5), (19, d, NO, 3), (21, b, NO, 4)]


def short_lopsided(a, b, c, d):
    """Answered because it was never really in doubt — but somebody tried."""
    return [(0, a, YES, 9), (0, b, NO, 4), (2, a, YES, 5), (4, b, NO, 6),
            (6, b, NO, 5), (8, a, YES, 7), (10, b, NO, -6), (12, c, YES, 6),
            (14, d, NO, 3), (16, a, YES, 6), (18, c, YES, 4), (20, b, NO, -3)]


def short_flip(a, b, c, d):
    """Led one way for a fortnight, then the evidence landed."""
    return [(0, b, NO, 8), (0, a, YES, 5), (3, b, NO, 5), (6, a, YES, 3),
            (8, b, NO, 4), (11, a, YES, 9), (13, a, YES, 7), (15, b, NO, -7),
            (17, c, YES, 6), (19, b, NO, 3), (21, d, YES, 5)]


def sparse(a, b, c, d):
    """A claim somebody filed and few traded. Three moves, and that is the point:
    a docket where every record is a battle is not a docket, and the height budget
    below does not stretch to thirteen battles."""
    return [(0, a, YES, 5), (0, b, NO, 4), (9, a, YES, 3), (18, b, NO, 5)]


def short_grind(a, b, c, d):
    """Nobody moves much, and that is itself the story."""
    return [(0, a, YES, 6), (0, b, NO, 5), (4, a, YES, 2), (6, b, NO, 3),
            (9, c, YES, 2), (12, b, NO, 2), (14, a, YES, 3), (16, d, NO, 2),
            (18, c, YES, 2), (20, b, NO, 3), (22, a, YES, 2)]


# THE CADENCE IS NOT THE VERDICT OF THE ROOM, and until now it was.
#
# A shape fixed both how often a claim traded AND where it ended up, so every
# claim sharing a shape shared its final split: nine claims on `sparse` all read
# 47.1% staked YES, eight on `short_grind` all read 53.1%, and the docket showed
# TWO numbers across nineteen claims. Read off the chain, not guessed. Reported
# as not looking plausibly real, which is exactly what two numbers look like.
#
# So the weights come out. The factories below keep each parent's cadence to the
# day — same offsets, same actor slots, same number of dated moves, so the height
# budget above is untouched — and take what each side puts in. The chart is the
# cadence; the number under it is the claim.
#
# THE TOTAL PER CLAIM IS HELD AT ITS PARENT'S, seventeen units for a thin claim
# and thirty-two for a grinding one. Staked coin is bought coin and the accounts
# are sized against a measured budget; redistributing between the sides costs
# nothing, while adding volume is how a seed run dies four hundred transactions
# in with a balance it cannot cover.
def sparse_at(y0, n0, y1, n1):
    """`sparse`'s cadence — four moves, two dated — at the caller's weights."""
    def shape(a, b, c, d):
        return [(0, a, YES, y0), (0, b, NO, n0), (9, a, YES, y1), (18, b, NO, n1)]
    # four moves is the point of a thin claim, so the flat-chart guard skips it.
    # A FLAG, NOT `is sparse`: that identity test was the only thing marking a
    # claim thin, and every claim built here is its own function object.
    shape.thin = True
    return shape


def grind_at(y, n):
    """`short_grind`'s cadence — eleven moves to day 22 — at the caller's weights.

    y is the six YES moves, n the five NO ones, in the order they land.
    """
    def shape(a, b, c, d):
        return [(0, a, YES, y[0]), (0, b, NO, n[0]), (4, a, YES, y[1]), (6, b, NO, n[1]),
                (9, c, YES, y[2]), (12, b, NO, n[2]), (14, a, YES, y[3]), (16, d, NO, n[3]),
                (18, c, YES, y[4]), (20, b, NO, n[4]), (22, a, YES, y[5])]
    return shape


# THE BUDGET THAT DECIDES HOW BIG THIS CAN BE, and it is not the one I expected.
#
# ClaimSeries keeps HOURLY points for `hourlyKeep` = 168 epochs of 720 blocks and
# trims them past that; below the horizon it answers from a DAILY grain of 17,280
# blocks — 24 hourly epochs. `goto` moves 720 blocks a step, one hourly epoch.
#
# So a claim whose twelve moves fall on twelve calendar steps spans 8,640 blocks:
# twelve distinct HOURLY epochs, but a single DAILY one. Drawn from the chain, its
# chart was ONE point. Measured, not assumed — the first dense version of this
# docket produced charts with 1 to 3 points against the 11 to 17 its own move
# table promised, because the points had been trimmed and the daily grain could
# not tell them apart.
#
# The whole docket therefore has to fit inside the hourly window: at most 168
# dates with movement, across every claim. 27 claims x ~12 moves is 331, so the
# docket is FIFTEEN claims — which is also the "too many items" complaint, and the
# two constraints happen to want the same thing. The tree keeps its depth.
KEEP = {"lab23", "defuse", "furin", "bioweapon", "yanrep", "baric", "baricout",
        "gof", "p3co", "perjury", "prompted", "divergence", "lancet",
        "mctext", "concealed", "nochain", "misc82", "denom", "miscrisk"}

# ----------------------------------------------------------------- the docket
#
# NOT A DOCKET OF TRUE CLAIMS, and that is the whole point. A court seeded only
# with things that are so demonstrates nothing: the product is a mechanism for
# REVEALING which claims hold, and a fixture where every claim settles YES shows
# a mechanism with nothing to do. So the claims here are the ones that actually
# circulate — compiled from 345 posts in ~/gopath/src/github.com/jaekwon/covid,
# with counts, citations and my own assessment in CLAIMS.md beside them — and
# their `arc` is what the record says happens to each one:
#
#   yes      the evidence carried it
#   no       it was answered against — the false ones live here, and watching
#            them settle NO is the demonstration
#   dispute  answered, then challenged; a sealed vote is still running
#   answered answered and nothing else yet — the settle clock is still running
#            at the story's now. Every other arc reaches a resting state, so a
#            docket built only from them shows a court where nothing is in
#            flight; this is the one row a reader refreshes
#   dead     nobody could answer it inside twelve weeks, so it closed unresolved
#            — which is the honest outcome for a question the evidence cannot
#            yet reach, and there is no shame in it
#
# COUNTER-CLAIMS ARE CLAIMS. Four entries below (`yanrep`, `baricout`, `nochain`,
# `denom`) are mine rather than the corpus's: each states the specific fact that
# undercuts a popular claim, and each is filed as its own proposition to be
# staked and answered like any other. That is how a court disagrees — not by
# refusing the first claim a hearing, but by filing the one that beats it. The
# association edges in REL point each counter at what it contests.
#
# Every title is a statement of fact with a settlement condition in its body.
# That test is what admits "a laboratory origin is more likely" and excludes
# "it was a cover-up": motive does not settle, and a claim that cannot settle
# only clogs the docket.
D = [
  # ------------------------------------------------------------------ origins
  dict(key="lab23", on="2023-04-10", arc="dead", shape=tug,
       path=("Origins",),
       cast=("biosafety", "virology", "oversight", "epi"),
       body='Settles on a finding by a body with subpoena power, or a published determination the relevant experts do not contest.\n\nDeliberately asks about the balance of evidence PUBLIC IN 2023, not the eventual truth: a claim whose answer depends on documents nobody has is unanswerable, and this docket already carries two that died that way.',
       title="A laboratory-associated origin is the more likely explanation, on the evidence public in 2023."),
  dict(key="defuse", on="2021-09-22", arc="yes", shape=sparse_at(10, 3, 3, 1),
       path=("Origins",),
       cast=("foia", "virology", "journo", "epi"),
       body='Settles on the document. DRASTIC published the 2018 DARPA proposal in September 2021; the text either describes the insertion or it does not.\n\nAsks ONLY what the proposal says. Whether the work was carried out is a different claim, and DARPA did not fund this one.',
       title="The 2018 DEFUSE proposal describes inserting a furin cleavage site into a SARS-related bat coronavirus."),
  dict(key="furin", on="2020-06-10", arc="dead", shape=reversal,
       path=("Origins",),
       cast=("genomics", "virology", "biosafety", "epi"),
       body='Settles on an identified natural progenitor carrying the motif, or on documentary evidence of insertion. Neither exists, which is why this one is expected to close unanswered.',
       title="The furin cleavage site in SARS-CoV-2 has no close analogue in the sampled sarbecovirus record."),
  dict(key="bioweapon", on="2020-09-15", arc="no", shape=grind_at((8, 4, 4, 3, 2, 2), (3, 2, 2, 1, 1)),
       path=("Origins",),
       cast=("skeptic", "genomics", "trader", "virology"),
       # ONE PROPOSITION, NOT TWO. This read "deliberately engineered AND
       # released as a Chinese state bioweapon", which is a conjunction, and a
       # conjunction cannot be answered YES or NO honestly: the docket settled
       # it NO on the release, and the title made that verdict look like a
       # finding against engineering as well. Engineering is separately docketed
       # in this very folder -- lab23, defuse, furin, baric -- and two of those
       # run YES, so the compound title had this court contradicting itself.
       # The overlay strikes a settled-NO title through now, which is what
       # surfaced it: a strike across the conjunction reads as a strike across
       # each half. Asks ONLY about deliberate release, the way defuse asks only
       # what the proposal says.
       body='Settles on evidence of deliberate release as a weapon. The published case rests on the Yan Li-Meng reports; no review has sustained them.\n\nAsks ONLY about deliberate release. Whether the virus was engineered is a different claim and is docketed separately in this folder, some of it running the other way — a NO here rejects the weapon story, not the laboratory one.\n\nFiled because it is one of the most circulated claims about this pandemic, and a docket that will not hear the popular claim is not a court.',
       title="SARS-CoV-2 was released deliberately as a Chinese state bioweapon."),
  dict(key="yanrep", on="2020-10-05", arc="yes", shape=sparse_at(2, 9, 3, 3),
       path=("Origins",),
       cast=("genomics", "skeptic", "virology", "trader"),
       body='Settles on the citation record: every published version of the bioweapon claim traces to the two Zenodo preprints, and on whether any peer-reviewed venue has sustained them.\n\nFiled against the claim above rather than in place of it.',
       title="Every published version of the bioweapon claim traces to the Yan Li-Meng preprints, which no peer review has sustained."),
  dict(key="baric", on="2022-03-12", arc="no", shape=grind_at((7, 4, 3, 3, 2, 1), (4, 3, 2, 2, 1)),
       path=("Origins",),
       cast=("biosafety", "virology", "journo", "genomics"),
       body='Settles on documentary or sequence evidence tying a construct made at that laboratory to SARS-CoV-2. Raised as a question by Sachs and others; nobody has evidenced it.',
       title="Ralph Baric's laboratory constructed the virus that became SARS-CoV-2."),
  dict(key="baricout", on="2024-05-20", arc="yes", shape=sparse_at(6, 5, 3, 3),
       path=("Origins",),
       cast=("foia", "oversight", "journo", "virology"),
       body="Settles on the authors' own testimony to congressional investigators, which is on the record.\n\nFiled because it cuts against the claim above from the same body of evidence that is usually cited FOR it: the party closest to the construction work was kept off the paper, deliberately, and said so.",
       title="Ralph Baric was excluded from the Proximal Origin author list on the ground that he was too close to the Wuhan Institute of Virology."),

  # ------------------------------------------- Fauci / gain-of-function funding
  dict(key="gof", on="2021-05-11", arc="yes", shape=sparse_at(11, 2, 3, 1),
       path=("Fauci", "Gain-of-function funding"),
       cast=("journo", "foia", "oversight", "virology"),
       body='Settles on the grant record: the subawards from EcoHealth Alliance to the Wuhan Institute of Virology, and the NIH acknowledgements of them.',
       title="US federal grants funded coronavirus research at the Wuhan Institute of Virology."),
  # A LIVE DISPUTE HAS TO BE RECENT, and these three are the only claims that end
# with one running. The scenario compresses 2,379 narrative days into a clock
# budget of 1,209,600 blocks — 70 days of block time, a 34x squeeze — so a date
# and a block deadline can never both be right across the whole story. They can
# be right NEAR THE END, where the two clocks have not had time to diverge: a
# dispute opened four days before the story's now has a vote closing ~7 days out
# by block count, which is what a reader is told and what the chain enforces.
# Dated in 2021 the same claim showed an answer from five years ago beside a
# vote closing next week, which is the state that was reported as nonsense.
# The subjects are unchanged — a court files a claim about a 2021 event whenever
# somebody raises it, and the filing date is when it was raised.
dict(key="p3co", on=before_end(28), arc="dispute", shape=grind_at((6, 3, 3, 2, 1, 1), (5, 4, 3, 2, 2)),
       path=("Fauci", "Gain-of-function funding"),
       cast=("biosafety", "virology", "oversight", "epi"),
       body='Settles on a determination by HHS or another authorised body that the funded work did or did not meet the P3CO definition.\n\nThe sharpest claim in this folder, because it is the one thing everybody is actually arguing about: nobody disputes that the money reached the work. NIH conceded in 2021 that a limited experiment met some criteria while rejecting the label.',
       title="The NIAID-funded work at the Wuhan Institute of Virology met the federal P3CO definition of gain-of-function research."),
  dict(key="perjury", on=before_end(24), arc="dispute", shape=grind_at((8, 4, 4, 3, 2, 1), (4, 2, 2, 1, 1)),
       path=("Fauci", "Gain-of-function funding"),
       cast=("oversight", "virology", "skeptic", "foia"),
       body='Settles on a perjury referral producing a finding, or an authoritative determination by a body with subpoena power. An accusation attached to a document release is not a finding.',
       title="Testimony given to Congress in 2024 denying participation in intelligence discussions about Wuhan research was false."),

  # ------------------------------------------------- Fauci / Proximal Origin
  dict(key="prompted", on=before_end(26), arc="dispute", shape=grind_at((3, 2, 2, 2, 2, 1), (7, 5, 3, 3, 2)),
       path=("Fauci", "Proximal Origin"),
       cast=("foia", "virology", "oversight", "epi"),
       body='Settles on the correspondence together with sworn testimony from the participants. The 1 February 2020 teleconference and the drafting timeline are documented; whether they amount to prompting is what is contested.',
       title="The Proximal Origin paper was drafted at the prompting of the director of NIAID."),
  dict(key="divergence", on="2023-01-15", arc="yes", shape=sparse_at(7, 5, 3, 2),
       path=("Fauci", "Proximal Origin"),
       cast=("foia", "genomics", "journo", "virology"),
       body='Settles on the released correspondence, which is public and unredacted.\n\nThe best-evidenced claim in this folder, and the one the corpus most often garbles into something larger.',
       title="The Proximal Origin authors privately assessed the genome as showing engineered features in the week they drafted the paper rejecting that."),
  dict(key="lancet", on="2021-06-21", arc="yes", shape=sparse_at(9, 4, 3, 1),
       path=("Fauci", "Proximal Origin"),
       cast=("journo", "foia", "epi", "oversight"),
       body="Settles on the statement's own published correction and the signatory record.",
       title="The organiser of the February 2020 Lancet statement concealed his institute's funding relationship with the Wuhan Institute of Virology."),

  # -------------------------------------------------- Fauci / the iPhone texts
  dict(key="mctext", on=before_end(50), arc="yes", shape=sparse_at(5, 6, 3, 3),
       path=("Fauci", "The iPhone texts"),
       cast=("foia", "vaxsafety", "clinician", "oversight"),
       body='Settles on the message itself, released 10 August 2026 from a government device produced to a Senate subcommittee.\n\nAsks only whether the message says what it is quoted as saying. What follows from it is the two claims after this one.',
       title="In January 2021 the director of NIAID privately raised first-trimester miscarriage as a theoretical risk of the second vaccine dose."),
  dict(key="concealed", on=before_end(49), arc="no", shape=grind_at((4, 3, 2, 2, 1, 1), (7, 4, 3, 3, 2)),
       path=("Fauci", "The iPhone texts"),
       cast=("oversight", "clinician", "skeptic", "vaxsafety"),
       body='Settles on comparing the private chain with the public statements over the same period.\n\nThe same message chain, one day later, weighs risks against benefits and records ten thousand vaccinated pregnancies with no signal — so the private position and the public one have to be compared whole, not by their first line.',
       title="The January 2021 miscarriage concern was withheld from the public while the same officials recommended vaccination in pregnancy."),
  # ANSWERED YESTERDAY, SETTLING TOMORROW. Its two siblings above are dated by
  # the release they read; this one is dated by what it is here to show, the same
  # licence the three live disputes take. A claim whose answer is still inside its
  # settle window is the only row on this docket with a clock a reader can watch,
  # and there was not one.
  dict(key="nochain", on=before_end(23), arc="answered", shape=sparse_at(8, 4, 3, 2),
       path=("Fauci", "The iPhone texts"),
       cast=("foia", "clinician", "vaxsafety", "oversight"),
       body='Settles on the same released chain that carries the quoted line.\n\nFiled because a quotation with its reply removed is a different claim from the quotation, and the docket should hold both.',
       title="The same message chain records, one day later, more than ten thousand vaccinated pregnancies with no adverse signal."),

  # ----------------------------------------------------- vaccine safety claims
  dict(key="misc82", on="2021-06-01", arc="no", shape=grind_at((9, 4, 4, 3, 2, 2), (3, 2, 1, 1, 1)),
       path=("Vaccine safety claims",),
       cast=("vaxsafety", "clinician", "skeptic", "statistician"),
       body='Settles on the arithmetic in the source table.\n\nOne of the most-repeated numbers of the pandemic and one of the easiest to check, which is why it is here: a docket that cannot dispose of a checkable false number is not worth running.',
       title="Vaccination in the first or second trimester was followed by miscarriage in 82% of completed pregnancies."),
  dict(key="denom", on="2021-06-15", arc="yes", shape=sparse_at(2, 10, 2, 3),
       path=("Vaccine safety claims",),
       cast=("statistician", "vaxsafety", "clinician", "modeller"),
       body='Settles on the published table: 104 losses against a denominator of 127 counts only those vaccinated in the first or second trimester, most of whom had not finished their pregnancies.',
       title="The 82% figure divides completed-pregnancy losses by a denominator that excludes pregnancies still ongoing."),
  dict(key="miscrisk", on="2021-08-10", arc="no", shape=short_grind,
       path=("Vaccine safety claims",),
       cast=("vaxsafety", "clinician", "statistician", "modeller"),
       body='Settles on cohort data against a population baseline. The final CDC analysis reports 10.79% across 12,097 vaccinated pregnancies, with no elevated risk week by week to twenty weeks; baseline is roughly 10 to 20%.',
       title="COVID-19 vaccination during pregnancy increases the risk of miscarriage."),
]

# ------------------------------------------------------------------ relations
#
# THE COUNTER-CLAIMS ARE THE INTERESTING EDGES. Four of these run from a claim I
# filed to the popular claim it undercuts, and they are `contradicts` on purpose:
# the court's own record should show that the thing beating a claim is another
# CLAIM, staked and answered, not an editorial note. `supports` edges run the
# other way — a document claim propping up the inference drawn from it.
#
# `supersedes` is the docket's own history: a claim re-filed after an earlier one
# died unanswered. The realm verifies it rather than taking the filer's word.
REL = [
  # counter-claims, each pointed at what it contests
  ("yanrep",   "bioweapon",  "bears", "contradicts"),
  ("baricout", "baric",      "bears", "contradicts"),
  ("nochain",  "concealed",  "bears", "contradicts"),
  ("denom",    "misc82",     "bears", "contradicts"),
  # the documentary claims that prop up the inferences drawn from them
  ("defuse",   "furin",      "bears", "supports"),
  ("defuse",   "lab23",      "bears", "supports"),
  ("gof",      "p3co",       "bears", "supports"),
  ("gof",      "lab23",      "bears", "supports"),
  ("divergence", "prompted", "bears", "supports"),
  ("lancet",   "prompted",   "bears", "supports"),
  ("mctext",   "concealed",  "bears", "supports"),
  ("divergence", "perjury",  "bears", "supports"),
  # and the ones that cut across
  ("baricout", "prompted",   "bears", "supports"),
  ("miscrisk", "concealed",  "bears", "contradicts"),
  ("denom",    "miscrisk",   "bears", "contradicts"),
  ("furin",    "bioweapon",  "bears", "supports"),
  # a re-filing: the 2023 question put again is not the 2020 one
  ("lab23",    "furin",      "bears", "supports"),
]

D = [c for c in D if c["key"] in KEEP]
REL = [r for r in REL if r[0] in KEEP and r[1] in KEEP]

# ------------------------------------------------------- is the shape any good?
#
# "Interesting" is measurable, so it is measured rather than hoped for. Every
# claim's YES-share path is walked here from its own moves, and a claim whose
# share barely moves or barely changes is a defect in the fixture — that was the
# whole complaint about the first version.
MOVES = {}
for _c in D:
    _cast = _c["cast"]
    MOVES[_c["key"]] = [(_d, _cast[_slot] if isinstance(_slot, int) else _slot, _side, _amt)
                        for _d, _slot, _side, _amt in
                        _c["shape"](0, 1, 2, 3)]

_report = []
for _c in D:
    _y = _n = 0
    _path = []
    for _d, _who, _side, _amt in MOVES[_c["key"]]:
        if _side == YES:
            _y = max(0, _y + _amt)
        else:
            _n = max(0, _n + _amt)
        if _y + _n:
            _path.append(round(_y * 100 / (_y + _n)))
    _spread = max(_path) - min(_path)
    _turns = sum(1 for i in range(2, len(_path))
                 if (_path[i] - _path[i-1] > 0) != (_path[i-1] - _path[i-2] > 0))
    _report.append((_c["key"], len(_path), min(_path), max(_path), _spread, _turns))
    _thin = _c["shape"] is sparse or getattr(_c["shape"], "thin", False)
    if not _thin and len(_path) < 8:
        raise ValueError(f"{_c['key']}: only {len(_path)} points, and it is not a "
                         f"`sparse` claim — a flat chart where a busy one was meant")
    if not _thin and _spread < 18:
        raise ValueError(f"{_c['key']}: share moves only {_spread} points — flat")
    # AND THE UNSTAKES HAVE TO BE COVERED. A shape asking an actor to withdraw
    # more than it holds on that side is not a flat chart, it is a transaction
    # the chain refuses — 300 calls into a seed run, with the node already up.
    # Per (actor, side), the running total may never go negative.
    _held = {}
    for _d, _who, _side, _amt in MOVES[_c["key"]]:
        _k = (_who, _side)
        _held[_k] = _held.get(_k, 0) + _amt
        if _held[_k] < 0:
            raise ValueError(f"{_c['key']}: {_who} unstakes {_side} below zero on day "
                             f"{_d} — the chain refuses that, mid-run")

def _dt(iso, n):
    return (datetime.datetime.strptime(iso, "%Y-%m-%d")
            + datetime.timedelta(days=n)).strftime("%Y-%m-%d")


# A STAKE IS COMMITTED COIN, and the budget is PEAK concurrent commitment rather
# than the sum — an unstake hands the coin back, which is what lets sixteen
# accounts trade a thousand transactions inside their holdings.
#
# BY ABSOLUTE DATE. An earlier version of this guard walked moves in
# (claim's opening, day-offset) order, which is not the order they happen in: a
# move is dated open + offset, so claims opened months apart interleave and every
# actor's real concurrent commitment is higher than that ordering shows. It passed,
# and the chain refused a stake 700 calls into the run — "not enough unstaked CC".
_spend = {n: int(f * 0.35) for n, f, _ in ACTORS}
_live, _peak = {}, {}
for _when, _who, _amt in sorted(
        ((_dt(c["on"], off), who, amt)
         for c in D for off, who, _sd, amt in MOVES[c["key"]]), key=lambda x: x[0]):
    _live[_who] = max(0, _live.get(_who, 0) + _amt * 1_000_000)
    _peak[_who] = max(_peak.get(_who, 0), _live[_who])
for _who, _units in sorted(_peak.items(), key=lambda kv: -kv[1] / _spend[kv[0]]):
    _ratio = _units / _spend[_who]
    if _ratio > 0.35:
        raise ValueError(
            f"{_who} holds {_units:,} units committed at its peak against "
            f"{_spend[_who]:,} ugnot bought (ratio {_ratio:.2f}). Over ~0.35 the "
            f"chain refuses the stake for want of unstaked coin — lower the shape "
            f"amounts, spread the cast wider, or raise the funding.")

# THE HOURLY WINDOW IS THE HARD CAP. Every dated move is one 720-block epoch, and
# points older than 168 of them are trimmed — after which the daily grain, 24
# epochs wide, cannot separate moves that were days apart on the wall clock. A
# docket wider than the window silently loses its own charts.
_dates = {_dt(c["on"], off) for c in D for off, _w, _s2, _a in MOVES[c["key"]]}
if len(_dates) > 168:
    raise ValueError(f"{len(_dates)} dates with movement, against a 168-epoch hourly "
                     f"window — the oldest charts will be trimmed to the daily grain "
                     f"and flatten. Drop claims or moves.")

# Anything ANSWERED still needs its positions in three distinct 720-block
# buckets, and one calendar step is one bucket — so a claim with an answer arc
# must move on at least three separate dates before the answer.
for _c in D:
    if _c["arc"] in ("yes", "no", "dispute", "answered"):
        _dates = {_off for _off, _w, _s2, _a in MOVES[_c["key"]] if _off <= 22}
        if len(_dates) < 3:
            raise ValueError(f"{_c['key']}: moves on {len(_dates)} date(s) before its "
                             f"answer; the answerability gate wants three buckets")

# ================================================================== the run
s.note("arm clock and height together, before any court exists — the overlay reads "
       "dates off the ratio between them, so a fixture that moves one alone lies "
       "to the tool it exists to exercise")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=epoch(BASE))
s.expect("TestClockActive", [], "true")

accounts = {name: s.account(name, funds) for name, funds, _ in ACTORS}

# THE OVERLAY'S DOMAIN, so every gnoweb page carries a link to its counterpart.
# Without it siteBanner renders nothing and the two surfaces have no way to reach
# each other — which is how a seeded node looked until somebody asked where the
# link was.
s.note("point every gnoweb page at the overlay")
s.call(DEPLOYER, "SetSiteDomain", ["kourt.xyz"])
s.expect("SiteDomain", [], r"kourt\.xyz", final=True)

s.note("the court, and real GNOT burned into its coin by sixteen participants")
s.court(DEPLOYER, SLUG, "COVID-19 Origins & Response Court")
# ONE BUY PER EPOCH, SMALLEST FIRST.
#
# These buys used to land in a single epoch. That is correct on chain and
# useless to look at: the court page charts burn, price and supply as CHANGE
# POINTS, and one epoch is one point, so sixteen purchases drew a flat line.
#
# Spreading them changes no balance and no total — the same actors spend the
# same 35% — and costs 11,520 blocks of a clock budget that is ten weeks wide
# and barely a tenth used. Smallest first, so cumulative burn comes out convex
# rather than a straight ramp.
for name, funds, _ in sorted(ACTORS, key=lambda a: a[1]):
    s.advance_height(EPOCH_BLOCKS, why="a buying epoch, so the curve has a point")
    s.buy(accounts[name], SLUG, int(funds * 0.35))
s.expect("CoinSupply", [SLUG], r"int64")

# ------------------------------------------------------- the filing system
#
# THE WHOLE TREE, ON CHAIN: three roots, and one of them carries the only
# subfolders. Built from the same `path` tuples the curation file uses, so the two
# can never disagree about the shape of the docket — the failure the old split
# invited.
#
# THREE, AND NOT THE TWENTY-FOUR IT HAD. The first version put every claim at the
# bottom of a three-level chain of its own — Origins → Natural spillover → The
# market cluster → one claim — which on a map is thirty boxes and six straight
# threads out of the middle, and reads as a filing cabinet rather than a docket.
# Depth costs a reader something and buys nothing when the leaf holds one claim.
# So the branching lives where the docket actually has a sub-structure worth
# naming, and everywhere else a claim sits in its root.
#
# Parents strictly before children, and not by sorting: ensure_folder recurses up
# the path and creates what is missing, so a parentID is always a folder the
# chain has already acknowledged. `mustNestable` would refuse otherwise, and it
# counts depth against maxFolderDepth = 4 — this tree is two, with room to spare.
#
# The ids are TRACKED rather than read back. CreateFolder/CreateFolderIn return
# the id, but a scenario step is a broadcast and not a value, so the plan cannot
# capture it. folderSeq increments by one per create and starts at 0, so counting
# creates in this process gives the same numbers the realm assigns. Any drift
# would show up immediately as an AddToFolder into the wrong folder — which is
# why the placements are asserted at the end.
#
# THE FAUCI FOLDER IS A ROOT NOW, not a cross-cut hung off a fifth branch. It was
# one: four claims filed elsewhere by evidence type, with a folder crossing those
# branches to read them together. That works — AddToFolder checks membership
# within one folder only, so a claim may sit in several, and the map draws the
# extra membership as an "also filed here" spoke. But it made the folder's own
# contents invisible next to its subject, and the subject is what a reader came
# for. As a root with the evidence types BELOW it, the same four claims are one
# click from the thing they are about. The cross-cut path stays exercised by
# map_test.js and folders_test.js, which is where that behaviour belongs.
#
# NAMED FOR THE RECORD AND NOT FOR THE PERSON. Every claim under it is about a
# document or a proceeding with a stated settlement condition; the folder is a
# reading order, and it asserts nothing its claims do not.
FOLDER_DESC = {
    ("Origins",):
        "Where the virus came from, and who built what. Each hypothesis is its own "
        "claim, so none is settled by another one losing.",
    ("Fauci",):
        "What NIAID funded under his direction, what his office wrote, and what he "
        "said in private and in public. Sorted below by the kind of record each "
        "claim settles on.",
    ("Fauci", "Gain-of-function funding"):
        "The grant record, and the definitional fight over what it was.",
    ("Fauci", "Proximal Origin"):
        "The 2020 paper: who prompted it, what its authors thought while writing "
        "it, and who else was organising at the same time.",
    ("Fauci", "The iPhone texts"):
        "34,000 messages off a government device, released August 2026 — and the "
        "claims made about them, which are not all the same claim.",
    ("Vaccine safety claims",):
        "What the shots did in pregnancy. Two of these are false and are here to be "
        "answered — the only way a docket disposes of a number.",
}


# SHAPE AND ARC HAVE TO AGREE, and nothing said so until a seed run died 400
# transactions in with "staking is frozen — this claim has an answer". An answer
# lands on day 22 and freezes staking; `reversal` and `tug` keep trading to day
# 74 and 76. They are DEAD-CLAIM shapes — the long argument nobody ever resolves —
# and pairing one with an answered arc files a stake into a frozen claim.
for _c in D:
    _mx = max(off for off, _w, _s2, _a in MOVES[_c["key"]])
    if _c["arc"] != "dead" and _mx > 22:
        raise ValueError(
            f"{_c['key']}: arc {_c['arc']!r} is answered on day 22 but its shape "
            f"trades to day {_mx}. Use sparse or short_grind for answered claims, "
            f"reversal or tug only for arc='dead'.")

for _pth, _dsc in FOLDER_DESC.items():
    if len(_dsc) > 200 or not (1 <= len(_pth[-1]) <= 200):
        raise ValueError(f"{_pth[-1]!r}: name {len(_pth[-1])} chars, description "
                         f"{len(_dsc)} — the realm caps both at 200 and refuses the "
                         f"CreateFolder outright, which a seed run learns 400 "
                         f"transactions in.")

# EVERY SET IS BORN OF A CLAIM. Not one CreateFolder in the docket's filing
# system: each heading is filed as an ordinary claim whose title opens with the
# wedjat, staked and answered and settled like any other, and only then carried
# into a set by AffirmSet. That is the whole point of the mark — the court
# decides its own filing system rather than being handed one.
#
# BATCHED IN PHASES, and the arithmetic is why. A set-claim needs its open
# interest matured (three stakes across two epochs, 1,440 blocks) and then the
# 51,840-block settle delay. Done one set at a time that is ~53,280 blocks each
# and seven of them would be 373,000 — three emission periods spent on filing.
# Done in phases, every set shares the same two waits: 53,280 blocks TOTAL,
# under half a period, against a 1,209,600 budget already 598,320 spent.
#
# THE CLAIM IDS COME FIRST, deliberately. These have to exist and be affirmed
# before any docket claim can be filed into them, so they take 1..N and the
# docket starts after — see `ids`, whose enumeration begins at len(SET_PATHS)+1
# for exactly this reason. Any hardcoded #/c/covid/<n> from before this change
# names a different claim now.
#
# THE DESCRIPTION BECOMES THE CLAIM'S BODY rather than the folder's desc field.
# AffirmSet creates the set with an empty description on purpose: the claim
# behind it has a body, a stake history and a verdict, which is a better account
# of what belongs in the set than a line anybody could have written, and it means
# the text lives in exactly one place.
s.note("the filing system on chain: every set is BORN — a wedjat claim, staked, "
       "answered and settled, then carried by AffirmSet. No CreateFolder here.")

SET_MARK = "\U00013080"   # U+13080 EGYPTIAN HIEROGLYPH D010, the exact codepoint

# Parents before children: a child is MoveFolder'd under its parent after both
# exist, so the parent's id has to be known first.
SET_PATHS = []
for _c in D:
    for _i in range(1, len(_c["path"]) + 1):
        if _c["path"][:_i] not in SET_PATHS:
            SET_PATHS.append(_c["path"][:_i])
SET_PATHS.sort(key=len)

SET_CID = {}      # path -> the claim that asks for it
FOLDER_ID = {}    # path -> the set it became
STAKER = "foia"   # takes no side beyond the documents; a fitting filer of headings
# unit() is defined further down, with the docket it serves; spelled out here
# rather than moved, because moving a definition the whole file already reads
# from is a bigger change than one multiplication.
SET_STAKE = 40 * 1_000_000   # whole coin, in the realm's smallest unit

# Phase 1 — file every heading as a claim, and open its position.
for _n, _path in enumerate(SET_PATHS, start=1):
    SET_CID[_path] = _n
    s.claim(accounts[STAKER], SLUG, SET_MARK + " " + _path[-1],
            FOLDER_DESC.get(_path, "") or None)
    s.stake(accounts[STAKER], SLUG, _n, YES, SET_STAKE)

# Phase 2 — two more rounds across two epochs, which is what matures the
# trailing average an answer is sized against. Shared by every set at once.
for _round in range(2):
    s.advance_height(EPOCH_BLOCKS, why="an epoch, so the headings' open interest matures")
    for _path in SET_PATHS:
        s.stake(accounts[STAKER], SLUG, SET_CID[_path], YES, SET_STAKE)

# Phase 3 — answered YES, then ONE settle delay for all of them.
for _path in SET_PATHS:
    s.answer(accounts["arbiter"], SLUG, SET_CID[_path], YES)
s.advance_height(int(51_840), why="the 72h undisputed window, once, for every heading")

# Phase 4 — settled, then carried. AffirmSet is permissionless: the verdict is
# the authority, so the staker calls it rather than a moderator.
_folder_seq = 0
for _path in SET_PATHS:
    s.settle(accounts["arbiter"], SLUG, SET_CID[_path])
    s.call(accounts[STAKER], "AffirmSet", [SLUG, str(SET_CID[_path])])
    _folder_seq += 1
    FOLDER_ID[_path] = _folder_seq

# Phase 5 — the nesting. AffirmSet creates at the root because the title is spent
# on the name, so the tree is assembled afterwards by the same moderator
# authority that could have retired any of these anyway.
for _path in SET_PATHS:
    if len(_path) > 1:
        s.call(DEPLOYER, "MoveFolder",
               [SLUG, str(FOLDER_ID[_path]), str(FOLDER_ID[_path[:-1]])])
FAUCI = ("Fauci",)

def unit(n):
    """Whole coin, in the realm's smallest unit."""
    return n * 1_000_000


# ids are c.nextID, per court, sequential from 1 — so they must be assigned in the
# order the claims are actually OPENED, which is the calendar's order and not the
# table's. Assigning them in table order produced ids that no claim had:
#
#   kourtv2: no such claim
#
# The table is grouped by subject because that is how it is read; the chain
# numbers by filing date. Both, from one list, is the whole point of counting them
# here rather than writing them down.
# AFTER THE HEADINGS. The set-claims take 1..len(SET_PATHS) because they must be
# affirmed before anything can be filed into them, so the docket begins past
# them. Derived rather than written as a literal: a set added to the tree moves
# every docket id, and a constant here would be wrong the first time that
# happened and silently — the ids would still be contiguous, just off by one,
# which shows up as a claim filed in the wrong folder rather than as an error.
ids = {}
for _n, _c in enumerate(sorted(D, key=lambda c: (c["on"], D.index(c))),
                        start=len(SET_PATHS) + 1):
    ids[_c["key"]] = _n

# ------------------------------------------------------------ one timeline
#
# A CLAIM IS RESOLVED IN ITS OWN ERA, not in a batch at the end. The first
# version opened the whole docket across five years and then answered everything
# at 2025-05, and the chain refused it:
#
#   kourtv2: this claim is past the dead-claim timeout; it closes, it is not answered
#
# deadClaimSecs is twelve weeks. A claim older than that has ALREADY expired —
# the only verb left for it is CloseDeadClaim. That is the rule covid.py exists to
# demonstrate and this fixture had to learn it the same way. So every arc's later
# steps are scheduled relative to the claim's own opening, the whole lot is sorted
# by date, and the calendar is walked once.
def days(iso, n):
    d = datetime.datetime.strptime(iso, "%Y-%m-%d") + datetime.timedelta(days=n)
    return d.strftime("%Y-%m-%d")


# The claims that will carry a trend: spread across the calendar by taking every
# fourth one in date order, so the docket shows old-with-trend beside
# new-without rather than a run of them together.
_by_date = sorted(D, key=lambda c: (c["on"], D.index(c)))
TREND_IDS = {ids[c["key"]] for c in _by_date[1::max(1, len(_by_date)//TREND_CLAIMS)][:TREND_CLAIMS]}

events = []
for c in D:
    cid, on, arc = ids[c["key"]], c["on"], c["arc"]
    events.append((on, 0, "open", cid, c))
    # every move on its own date: that is what makes the chart a chart, since
    # ClaimSeries is change-only and one calendar step is one 720-block epoch
    for k, (off, who, side, amt) in enumerate(MOVES[c["key"]]):
        if off:
            events.append((days(on, off), 0, ("move", k), cid, c))
    if arc in ("yes", "no", "dispute", "answered"):
        events.append((days(on, 22), 1, "answer", cid, c))
    # "answered" stops here on purpose: no settle, no dispute. Filed late enough
    # that day 22 lands just before the story's now, it is still inside its settle
    # window when a reader arrives — the state the docket otherwise never holds.
    if arc in ("yes", "no"):
        events.append((days(on, 26), 2, "settle", cid, c))
    if arc == "dispute":
        events.append((days(on, 23), 2, "dispute", cid, c))
    if arc == "dead":
        events.append((days(on, 91), 3, "dead", cid, c))

_trend = set()
for iso, _, kind, cid, c in sorted(events, key=lambda e: (e[0], e[1], e[3])):
    if iso > END:
        raise ValueError(f"#{cid} {c['key']}: {kind} falls at {iso}, past {END}")
    # A WHOLE TRAILING WINDOW, INSIDE A CLAIM'S OWN LIFE.
    #
    # twap maturity is not a count of observations, it is a count of BUCKETS
    # ADVANCED: Ring.Observe carries `last` into every bucket it skips, so
    # `filled` reaches 168 only when 168 buckets have gone by between two
    # observations of the SAME claim. Staking a claim ten times in a day leaves
    # filled at 1, which is why every row on this fixture read "no trend yet" —
    # the whole five-year narrative fits inside one window, by design, since a
    # calendar step moves 720 blocks.
    #
    # SO THE WINDOW IS CROSSED BETWEEN A CLAIM'S FIRST AND SECOND MOVE. Crossing
    # it once at a fixed date matured exactly one claim: these claims live about
    # twenty-six days each and are spread over five years, so on any date only
    # one is mid-life. Doing it per claim is what makes the number of trends
    # something this file decides rather than something the calendar decides.
    #
    # BETWEEN THE FIRST AND SECOND MOVE, not later: stake history is trimmed to
    # the last 168 epochs on a claim's next WRITE, so a claim jumped over late
    # loses the chart it had already built, while one jumped over on its second
    # move loses only its opening point and builds the rest afterwards.
    #
    # Each costs one of the ten emission periods the realm allows. The cap is low
    # because touch() walks periods one at a time and a court that runs out of
    # gas mid-touch is bricked for ever — so these are counted, not sprinkled:
    # four here, plus the 118,080 blocks the gates need, against 1,209,600.
    # The claim's FIRST DATED move, whatever its index. Moves at offset zero are
    # staked at open and never become events, so the first tuple here is index 2
    # on this fixture — keying on a literal index matched nothing and emitted no
    # jumps at all, which the height total said plainly: 118,080, unchanged.
    if isinstance(kind, tuple) and cid in TREND_IDS and cid not in _trend:
        _trend.add(cid)
        s.note(f"#{cid} has been open a full trailing window — its next move "
               f"matures the average behind the docket's trend line")
        s.advance_height(PERIOD_BLOCKS, why=f"#{cid}: one emission period, so twap matures")
    if iso != _at["iso"]:
        goto(iso, "positions move" if isinstance(kind, tuple) else
             {"open": "filed", "answer": "answered", "settle": "settles",
              "dispute": "disputed", "dead": "expires unanswered"}[kind])
    if kind == "open":
        s.note(f"#{cid} {c['key']} — {c['arc']}, {len(MOVES[c['key']])} moves")
        s.claim(accounts[MOVES[c["key"]][0][1]], SLUG, c["title"], c.get("body"))
        s.folder_add(DEPLOYER, SLUG, FOLDER_ID[c["path"]], cid)
        for off, who, side, amt in MOVES[c["key"]]:
            if off == 0:
                s.stake(accounts[who], SLUG, cid, side, unit(amt))
    elif isinstance(kind, tuple):
        _, k = kind
        off, who, side, amt = MOVES[c["key"]][k]
        if amt >= 0:
            s.stake(accounts[who], SLUG, cid, side, unit(amt))
        else:
            s.unstake(accounts[who], SLUG, cid, side, unit(-amt))
    elif kind == "answer":
        who = "arbiter" if c["arc"] != "dispute" else "arbiter2"
        s.answer(accounts[who], SLUG, cid, YES if c["arc"] in ("yes", "dispute", "answered") else NO)
    elif kind == "settle":
        s.settle(accounts["arbiter"], SLUG, cid)
    elif kind == "dispute":
        s.note(f"#{cid} is disputed — a sealed vote is left running")
        s.dispute(accounts["skeptic"], SLUG, cid)
    elif kind == "dead":
        s.note(f"#{cid} died unanswered — twelve weeks passed and nobody could answer it")
        s.call(accounts["skeptic"], "CloseDeadClaim", [SLUG, str(cid)])

goto(END, "the court as a reader finds it")
s.expect("ClaimCount", [SLUG], r"int64")

# ---------------------------------------------- the argument graph, on chain
#
# §5's ARGUMENT EDGE, which this realm calls an ASSOCIATION. Filed last, after
# every claim exists, because AddAssociation refuses an edge whose either end is
# missing — and filing them as the claims appeared would need the graph sorted
# into calendar order for no gain.
#
# WHO SIGNS EACH ONE IS THE POINT, and it is the whole bond design in eleven
# transactions:
#
#   * the asserting claim's OWN AUTHOR pays nothing. That is most of this graph,
#     because "my claim #7 bears on your claim #3" is normally said by the person
#     who filed #7.
#   * a MODERATOR pays nothing either. One edge here is filed by the court's own
#     moderator, which is what curation looks like.
#   * a STRANGER posts a refundable bond. Three do: one returned by a moderator
#     who agreed, one BURNED by a moderator who did not, and one nobody judged.
#
# THE THIRD ONE'S WINDOW IS ALREADY CLOSED, AND NO BACK-DATED FIXTURE CAN DO
# BETTER. A bond's window is fourteen days of BLOCK TIME from the write
# (clock.gno: a deadline a user plans around gates on time, not height). These
# associations are written at the fabricated present — 2025-06-01 — and then
# SealTestClock hands the chain back to its real clock, which is well past
# 2025-06-15. So the moment the seal lands, the unjudged bond is reclaimable and
# `ClaimAssociationBond` succeeds rather than refusing.
#
# That is worth stating because the first version of this comment claimed the
# third bond was "still HELD because nobody has looked yet", and a probe against
# the seeded node disproved it in one transaction. A PENDING bond needs a write
# at real time: scenarios/assoc_demo.py never arms the clock, so its bonds have
# live windows, and the demo note there says so.
STANCE = {"supports": "supports", "contradicts": "contests"}
author_of = {c["key"]: MOVES[c["key"]][0][1] for c in D}

# The three edges filed by somebody with no claim of their own at the FROM end.
# `epi` and `oversight` are participants in this docket who did not file the
# claim they are connecting, which is exactly the case the bond prices.
BONDED = {("defuse", "lab23"): "epi", ("furin", "bioweapon"): "oversight",
          ("gof", "lab23"): "epi"}

s.note("associations: the claim's own author pays nothing, a stranger posts a bond")
for a, b, kind, stance in REL:
    if kind != "bears":
        continue
    fro, to = ids[a], ids[b]
    if (a, b) in BONDED:
        who = BONDED[(a, b)]
        s.note(f"#{fro} -> #{to}: filed by {who}, who wrote neither — 1 CC bonded")
        s.call(accounts[who], "AddAssociation",
               [SLUG, str(fro), str(to), STANCE[stance]])
    elif a == "excess":
        # One by the court's moderator, to show the other free case.
        s.call(DEPLOYER, "AddAssociation", [SLUG, str(fro), str(to), STANCE[stance]])
    else:
        s.call(accounts[author_of[a]], "AddAssociation",
               [SLUG, str(fro), str(to), STANCE[stance]])

s.note("a moderator judges two of the three bonds and leaves the third pending")
# Approved: a document claim propping up an inference is what the bond is for.
s.call(DEPLOYER, "ApproveAssociation",
       [SLUG, str(ids["defuse"]), str(ids["lab23"])])
# Disapproved and BURNED: "the furin site is unusual, therefore bioweapon" is the
# leap this docket exists to price. The claims both stand; the EDGE between them
# is what a moderator struck.
s.call(DEPLOYER, "DisapproveAssociation",
       [SLUG, str(ids["furin"]), str(ids["bioweapon"])])
# gof -> lab23 is deliberately left unjudged, which on this fixture means its
# author may reclaim the bond immediately once the clock is sealed — see the note
# above on why a back-dated docket cannot hold an open window. The rule it stands
# for is the important half: unjudged means approved, never forfeit.

s.note("re-filings, on chain too — the realm checks the older claim really died")
for a, b, kind, _ in REL:
    if kind == "supersedes":
        s.call(accounts[author_of[a]], "SupersedeClaim",
               [SLUG, str(ids[a]), str(ids[b])])

# --------------------------------------------------- one claim, two folders
#
# THE CROSS-CUT, which nothing else in this docket exercises. AddToFolder
# de-duplicates only within the folder it is adding to and never consults the
# others — "folder membership couples nothing", folders.gno — so a claim may sit
# in several at once, and ClaimFolders returns a slice for exactly that reason.
#
# The overlay has been built for this and had nothing to draw. mapTree gives a
# shared claim ONE node with a lighter "also filed here" spoke to every folder
# past the first, and that legend row stayed hidden on a docket where every claim
# sat in exactly one drawer — so the feature was only ever visible to somebody who
# ran AddToFolder by hand. Twice, here, it was: both writes were lost to a re-seed,
# which is the argument for it living in the scenario instead.
#
# gof rather than a contrived pair. The grant record is the subject of
# "Gain-of-function funding" and it is also part of the origins story the first
# folder collects, which is what a cross-cut IS: a reading order, not a second
# copy. The claim is decided once either way — folders carry no economic weight.
#
# NOT IN THE DEMO TREE BELOW, and that is the documented split rather than an
# oversight: tree() is built from each claim's single `path`, because local
# curation enforces one folder per claim while the chain is flat and allows
# several. A merged view of the two has no honest caption.
s.note("one claim filed in two folders — a cross-cut, not a move")
s.call(DEPLOYER, "AddToFolder",
       [SLUG, str(FOLDER_ID[("Origins",)]), str(ids["gof"])])

# ------------------------------------------------------------- the boards
#
# COMMENTS, ON THE TWO CLAIMS THAT CAN STILL TAKE THEM. boardOpen is
# `verdictAt == 0 && !closed`, so every `yes`/`no` claim here settled and closed
# its board, and every `dead` one was closed outright. The `dispute` arcs are the
# only claims in this docket that are ANSWERED — so both parties exist — and
# still open. That is not a limitation of the fixture, it is the rule: a board
# stops taking comments the moment the claim has a verdict.
#
# ROW IDS ARE COUNTED HERE, NOT READ BACK. `cs.boardNextID++` is per claim and
# sequential from 1 (board.gno), so the same discipline this file already uses
# for claim ids applies: count them, never hand-write them. `row()` is the
# counter, and a reply or an upvote that named a hand-written constant would go
# silently wrong the moment a comment is inserted above it.
#
# EVERY COMMENTER BUYS A PASS FIRST. Most of these actors have STAKED, not
# earned standing, and postLevel reads standing — so without a pass PostComment
# refuses at level 0 and this whole section would emit transactions that all
# revert, producing an empty board and a green run.
# FOUR WITHDRAWALS, AND THEY ARE HERE TO BUY STANDING RATHER THAN COIN.
#
# UpvoteComment is weighted by standing and refuses an address with none
# (board.gno). Nobody in this fixture had any, and the reason is not the ladder
# or the tier — it is that conviction standing is credited inside WithdrawBonus
# (openrewards.gno), so a staker earns it by coming back to COLLECT, and this
# docket never collected. Measured on a seeded node before it was believed:
# every one of the sixteen actors read `score:0` from StandingBreakdown, and the
# credit rates were non-zero, so it was not a rounding story.
#
# The winners are DERIVED from MOVES, not listed: a winner is an address whose
# NET position on the side the claim settled is positive. Hand-listing them
# worked only until somebody edited a stake, at which point the withdrawal would
# refuse and the upvotes below would fail again.
#
# Deliberately only four, on three claims. Every settled claim in this docket has
# winners who could collect, and having them all do so would change what a dozen
# claim pages show for the sake of one board.
_winners = {}
for _c in D:
    if _c["arc"] not in ("yes", "no"):
        continue
    _win = YES if _c["arc"] == "yes" else NO
    _net = {}
    for _off, _w, _side, _amt in MOVES[_c["key"]]:
        if _side == _win:
            _net[_w] = _net.get(_w, 0) + _amt
    for _w, _v in _net.items():
        if _v > 0:
            _winners.setdefault(_w, (ids[_c["key"]], _win))

# OPEN THE REWARDS FIRST, and it is not a formality: WithdrawBonus refuses with "the
# draw has not rewardsOpened" until it has run. Once per CLAIM, not once per
# winner — a second call panics with "already rewardsOpened" — and called by a
# participant, because OpenRewards is participant-only for the first week after
# the verdict and these winners staked on the claim they are collecting from.
#
# It advances three of nineteen claims one step further along their lifecycle,
# which is a real change to what those pages show. That is the price of a fixture
# where anybody has standing at all, and three is the fewest that buys it.
s.note("four winners collect, which is how an address earns standing at all")
UPVOTERS = ["virology", "genomics", "clinician", "foia"]
_cryst = set()
for _w in UPVOTERS:
    if _w not in _winners:
        raise ValueError(f"{_w} holds no winning position — the upvotes below cannot work")
    _cid, _side = _winners[_w]
    if _cid not in _cryst:
        s.call(accounts[_w], "OpenRewards", [SLUG, str(_cid)])
        _cryst.add(_cid)
    s.call(accounts[_w], "WithdrawBonus", [SLUG, str(_cid), str(_side)])
    # Standing is what the upvote needs, so standing is what is asserted — not
    # the coin the withdrawal also paid. Pinned to a NONZERO value: `int64`
    # alone matches every int64 reply this realm can give, including 0.
    s.expect("Standing", [SLUG, Addr(_w)], r"[(][1-9][0-9]* int64[)]", final=True)

s.note("the boards: comments on the two claims a verdict has not closed")

_row = {}
def row(cid):
    """The id the NEXT comment on this claim will get."""
    _row[cid] = _row.get(cid, 0) + 1
    return _row[cid]

# A pass each, for everybody who is about to write. Bought once per address:
# BuyCommentPass panics on a second buy, by design.
BOARD_ACTORS = ["virology", "epi", "genomics", "foia", "journo", "statistician",
                "oversight", "clinician", "skeptic", "arbiter2"]
# The claim's own author is DERIVED, not listed. Naming them by hand here worked
# only while p3co's first mover happened to be somebody already on the list —
# change one row of MOVES and the author writes two comments with no pass, both
# revert, and the parties block loses the half that makes it an argument.
for _who in ("p3co", "perjury"):
    if author_of[_who] not in BOARD_ACTORS:
        BOARD_ACTORS.append(author_of[_who])
for _who in BOARD_ACTORS:
    s.comment_pass(accounts[_who], SLUG)

# ---- p3co: both parties argue, and the thread has everything a reader meets --
P3 = ids["p3co"]
_author = author_of["p3co"]

r_auth = row(P3)
s.comment(accounts[_author], SLUG, P3,
          "The P3CO framework is the standard the claim names, so the question is "
          "not whether the work was risky but whether it met that definition. The "
          "2017 guidance is the text to read.")
r_ansr = row(P3)
s.comment(accounts["arbiter2"], SLUG, P3,
          "I answered YES on the reading that the enhanced-transmissibility clause "
          "is met. The bond is on that reading, not on the wider question.")
r_skep = row(P3)
s.comment(accounts["skeptic"], SLUG, P3,
          "The grant text and the framework use different words for the same "
          "thing in two places. Which one governs is the whole dispute.")

# Replies. Depth stops at one, so neither of these can itself be answered here.
s.comment(accounts["epi"], SLUG, P3,
          "The 2017 guidance also carves out surveillance work, and that carve-out "
          "is what the department leaned on at the time.", parent=r_auth)
row(P3)
s.comment(accounts[_author], SLUG, P3,
          "Agreed that it is the dispute. The grant text is the later document, "
          "which is why I filed it that way.", parent=r_skep)
row(P3)

# An UPVOTED row, so Top is not Newest. Cold start puts every un-upvoted row in
# the score index at zero and the two orderings are byte-identical; without this
# the overlay's ranked view would have nothing to rank and would not be offered.
s.note("upvotes, so the ranked ordering differs from the newest one at all")
# Cold start puts every un-upvoted row in the score index at zero, so Top is
# byte-for-byte Newest on a board nobody has upvoted — the overlay probes for a
# nonzero score before it offers the ranked view at all, and without these the
# toggle would correctly never appear.
# Cold start puts every un-upvoted row in the score index at zero, so Top is
# byte-for-byte Newest on a board nobody has upvoted — the overlay probes for a
# nonzero score before it offers the ranked view at all, and without these the
# toggle would correctly never appear.
for _who in UPVOTERS[:3]:
    s.upvote(accounts[_who], SLUG, P3, r_ansr)
s.upvote(accounts[UPVOTERS[3]], SLUG, P3, r_skep)
s.expect("CommentScore", [SLUG, P3, r_ansr], r"[(][1-9][0-9]* int64[)]", final=True)


# ---- the two tombstones, which are different acts by different authorities ---
# The overlay collapses both to `h` because boardMark does — the wire does not
# say which, deliberately — so a fixture needs BOTH to prove the page never
# attributes one to the other.
r_withdrawn = row(P3)
s.comment(accounts["journo"], SLUG, P3,
          "Posting a working link to the grant PDF here; I will replace it if the "
          "host moves it.")
s.note("the author withdraws their own row — a discovery bit, not a delete")
s.withdraw_comment(accounts["journo"], SLUG, P3, r_withdrawn)

r_modhidden = row(P3)
s.comment(accounts["statistician"], SLUG, P3,
          "This has nothing to do with the claim and everything to do with a "
          "different argument three claims over.")
s.note("and a MODERATOR hides a different row, for a different reason")
s.hide_comment(DEPLOYER, SLUG, P3, r_modhidden, "off-topic")

# ---- perjury: only ONE party has spoken -------------------------------------
# The chip's copy branches on which parties replied, and "the answerer has
# replied" is reachable without the author's — the realm returns one party row
# and it may be either of them. This claim exercises that branch.
PJ = ids["perjury"]
r_pj = row(PJ)
s.comment(accounts["arbiter2"], SLUG, PJ,
          "The answer rests on the transcript as published, not on the summary "
          "that was reported from it.")
s.comment(accounts["foia"], SLUG, PJ,
          "The published transcript and the released recording differ in one line, "
          "and it is the line the claim turns on.", parent=r_pj)
row(PJ)

# ASSERTED AGAINST THE CHAIN, because every row id above is a number this
# process COUNTED and never read back. If boardNextID ever stopped being
# sequential-from-1, the replies would hang off the wrong parents and the hides
# would land on the wrong rows, and the fixture would look fine.
#
# The role patterns are DELIMITED. Bare `author` also matches the word inside
# somebody's comment text, which is on the same line — the role is field 3, and
# the pipes are what say so.
# The count comes from the COUNTER, not from a number typed here. Written by
# hand it was 9 against a board of 7, and it still passed — `grep -Eq 9`
# matches any 9 anywhere in the reply, so a wrong count asserted nothing.
# Pinned to the whole typed value for the same reason.
s.expect("BoardSize", [SLUG, P3], r"[(]%d int[)]" % _row[P3], final=True)
s.expect("BoardSize", [SLUG, PJ], r"[(]%d int[)]" % _row[PJ], final=True)
s.expect("BoardOpen", [SLUG, P3], r"true", final=True)
s.expect("BoardPartyRows", [SLUG, P3], r"[|]author[|]", final=True)
s.expect("BoardPartyRows", [SLUG, P3], r"[|]answerer[|]", final=True)
# perjury: the answerer spoke and the author did not, so ONE row comes back and
# it is not the author's — the case the role field exists for.
s.expect("BoardPartyRows", [SLUG, PJ], r"[|]answerer[|]", final=True)
# Both tombstones, and they are indistinguishable on the wire by design: the
# mark is `h` for either authority, so this asserts two `h` rows exist rather
# than which is which.
s.expect("BoardNewest", [SLUG, P3, 0, 25], r"[|]h[|]", final=True)

# ------------------------------------------------------------ what it built
#
# Asserted, not described. A folder id tracked in this process rather than read
# back from the chain is a guess until something checks it, and these reads are
# the check: the tree's shape, one leaf's contents, the cross-cut folder, and the
# graph around the claim the most edges point at.
# THE WHOLE TREE IN ONE READ. FolderTree answers `id:parent:flags` per row in
# creation order, and creation order is deterministic — so this asserts the exact
# shape rather than that something exists: three roots (parent 0), and folders
# 3, 4 and 5 all hanging off folder 2, which is the Fauci one.
# UNANCHORED, and it has to be: an expect greps the whole `gnokey query` output
# line, which begins `data: ("`, so a pattern anchored with ^ can never match.
# The full comma sequence pins the shape without needing them.
s.expect("FolderTree", [SLUG], r"1:0:-,2:0:-,3:2:-,4:2:-,5:2:-,6:0:-", final=True)
s.expect("FolderCount", [SLUG], r"6", final=True)
s.expect("FolderName", [SLUG, FOLDER_ID[FAUCI]], r"Fauci", final=True)
# The description, and it is asserted on a phrase from its END: a folder desc is
# capped at 200 characters, so a check on the first few words would pass on a
# string the realm had silently truncated.
s.expect("FolderDesc", [SLUG, FOLDER_ID[FAUCI]], r"kind of record each claim settles on", final=True)
s.expect("ClaimAssociations", [SLUG, ids["lab23"]], r"in:", final=True)
s.expect("AssociationBond", [SLUG], r"1000000", final=True)

# ------------------------------------------------------------- the curation
#
# The half the chain cannot hold. Written from the SAME table, with the ids the
# scenario just counted, so it can never reference a claim that is not there.
def tree():
    """Any depth the schema allows, from the `path` tuples. Was two levels
    hard-coded; the ask was more structure, and cleanFolder permits four."""
    roots, index = [], {}
    for c in D:
        node, key = None, ()
        for name in c["path"]:
            key = key + (name,)
            nxt = index.get(key)
            if nxt is None:
                nxt = index[key] = {"name": name, "claims": [], "folders": [], }
                (roots if node is None else node["folders"]).append(nxt)
            node = nxt
        node["claims"].append(ids[c["key"]])
    return roots


relations = []
for a, b, kind, stance in REL:
    r = {"from": ids[a], "to": ids[b], "type": kind}
    if stance:
        r["stance"] = stance
    relations.append(r)

CURATION.write_text(json.dumps({
    "kourtCuration": 1,
    "court": SLUG,
    "chain": "dev",
    "note": "local curation — held in a browser, recorded on no chain",
    "desc": ("A docket on the origins and handling of COVID-19. The folders and "
             "the argument graph are ON CHAIN now; this file carries the same "
             "shape for demo mode, which has no chain to read, plus the one "
             "relation the chain cannot hold: claim-to-claim containment."),
    "folders": tree(),
    "relations": relations,
}, indent=1) + "\n", encoding="utf-8")

SCENARIO = s
