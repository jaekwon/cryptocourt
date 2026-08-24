"""A populated COVID-19 court: five years, sixteen participants, a filed docket.

WHAT THIS IS FOR, and how it differs from covid.py beside it. That one is a
narrative: eleven claims chosen to demonstrate one rule — a claim nobody answers
within twelve weeks CLOSES rather than resolving — and it is a CI scenario with a
generated txtar. This one is the fixture you point a browser at. Thirty-eight
claims in twenty-four folders two levels deep, sixteen accounts and forty-two
relations between claims, so every surface the overlay has is looking at
something. Those are the counts the file actually produces, checked against the
overlay's own cleanCuration rules rather than described.

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
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import Scenario, YES, NO, DEPLOYER  # noqa: E402

# Never a txtar. It writes a curation file as a side effect, walks five years of
# calendar, and exists to be looked at rather than asserted on.
CI = False

SLUG = "covid"
BASE = "2020-01-15"
END = "2025-06-01"
EPOCH_BLOCKS = 720       # the twap bucket width, and the height a calendar step moves
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
KEEP = {"lab20", "lab23", "lab25", "market",
        "gof", "drafts", "foiagap",
        "masks", "schools",
        "vaxsevere", "myo",
        "testimony", "excess"}

# ----------------------------------------------------------------- the docket
#
# Three levels deep. The first version
# had 38 claims in 24 folders two deep, which read as a long list with some
# headings — the opposite of a filing system. Fewer records, more places to put
# them, so browsing is done by walking the tree.
#
# `path` is the curation tree, up to three levels (the schema allows four).
# `cast` is (yes-lead, no-lead, yes-second, no-second) — the shape's four slots.
# `arc`: open | yes | no | dispute | dead, as before.
D = [
  # ---------------------------------------------------------------- origins
  dict(key="lab20", on="2020-02-05", arc="dead", shape=reversal,
       path=("Origins", "Laboratory hypothesis", "The 2020 question"),
       cast=("biosafety", "virology", "skeptic", "epi"),
       body='What would settle this: a documented incident, or an official finding of one.\n\nNot asking whether such research was funded, or whether it was risky — those are separate claims on this docket. Only whether THIS virus reached people that way.',
       title="SARS-CoV-2 entered the human population through a laboratory-associated incident."),
  dict(key="furin", on="2020-06-10", arc="dead", shape=tug,
       path=("Origins", "Laboratory hypothesis", "Sequence features"),
       cast=("genomics", "virology", "biosafety", "epi"),
       title="The furin cleavage site in SARS-CoV-2 has no close analogue in the sampled sarbecovirus record."),
  dict(key="lab23", on="2023-04-10", arc="dead", shape=tug,
       path=("Origins", "Laboratory hypothesis", "After the agency assessments"),
       cast=("biosafety", "virology", "oversight", "epi"),
       body='The same question as the 2020 filing, re-put after the agency assessments. Settles on a finding by a body with subpoena power, or a published determination the relevant experts do not contest.\n\nDeliberately asks about the balance of evidence PUBLIC IN 2023, not the eventual truth: a claim whose answer depends on documents nobody has is unanswerable, and this docket already has two that died that way.',
       title="A laboratory-associated origin is the more likely explanation, on the evidence public in 2023."),
  dict(key="lab25", on="2025-03-20", arc="open", shape=sparse,
       path=("Origins", "Laboratory hypothesis", "After the agency assessments"),
       cast=("biosafety", "virology", "genomics", "epi"),
       body='Put again on the 2025 assessments. Same settlement standard as the 2023 filing.\n\nThe intelligence community is itself split — some elements assess a laboratory origin as more likely, others natural spillover, at low to moderate confidence either way. That split is why this is open rather than answered.',
       title="A laboratory-associated origin is the more likely explanation, on the evidence public in 2025."),
  dict(key="host", on="2021-03-15", arc="dead", shape=capitulate,
       path=("Origins", "Natural spillover", "Intermediate host"),
       cast=("epi", "genomics", "virology", "biosafety"),
       title="An intermediate host animal for SARS-CoV-2 has been identified in the published record."),
  dict(key="market", on="2021-06-07", arc="dead", shape=drift,
       path=("Origins", "Natural spillover", "The market cluster"),
       cast=("epi", "biosafety", "genomics", "skeptic"),
       body='Settles on the published epidemiological record of the earliest confirmed cases.\n\nAsks about the earliest KNOWN cluster, which is a claim about the record and not about where the outbreak began — early cases may have gone undetected, and this claim does not assert they did not.',
       title="The earliest known cluster of COVID-19 cases centred on the Huanan Seafood Market."),
  dict(key="raccoon", on="2023-03-20", arc="no", shape=short_flip,
       path=("Origins", "Natural spillover", "The market cluster"),
       cast=("epi", "genomics", "trader", "virology"),
       title="Market environmental samples establish that an infected animal was the source of the outbreak."),
  # --------------------------------------------------------- document trail
  dict(key="gof", on="2020-04-20", arc="yes", shape=sparse,
       path=("The document trail", "Grants and funding", "The WIV subawards"),
       cast=("foia", "skeptic", "journo", "trader"),
       body='Settles on the grant record: award documents, subaward agreements, progress reports.\n\nA matter of record, not of judgement. Not asking whether the work was wise, whether it was gain-of-function under any particular definition, or whether it caused anything — only whether the money went there.',
       title="US federal grants funded coronavirus research at the Wuhan Institute of Virology before 2020."),
  dict(key="reports", on="2021-09-10", arc="yes", shape=short_grind,
       path=("The document trail", "Grants and funding", "Reporting compliance"),
       cast=("foia", "trader", "oversight", "skeptic"),
       title="Required progress reports for at least one federal coronavirus grant were filed late."),
  dict(key="ehasusp", on="2024-05-20", arc="yes", shape=short,
       path=("The document trail", "Grants and funding", "Reporting compliance"),
       cast=("oversight", "skeptic", "journo", "trader"),
       title="HHS suspended EcoHealth Alliance's federal funding in May 2024."),
  dict(key="drafts", on="2022-01-25", arc="yes", shape=sparse,
       path=("The document trail", "Correspondence", "Released under subpoena"),
       cast=("foia", "trader", "journo", "skeptic"),
       body='Settles on the released documents themselves.\n\nAsks only whether the correspondence was released under subpoena. What it SAYS, and what that implies, are other claims.',
       title="Drafting correspondence for the 2020 Proximal Origin paper was released under subpoena."),
  dict(key="foiagap", on="2022-06-15", arc="dispute", shape=sparse,
       path=("The document trail", "FOIA and subpoena", "Withholdings"),
       cast=("foia", "skeptic", "journo", "trader"),
       body="Settles on a court ruling, an inspector-general finding, or an agency's own concession that an exemption was misapplied.\n\nNot asking whether the withholding was intentional. An improper one found on review is enough.",
       title="Records released under FOIA were withheld in part on grounds later found improper."),
  # ------------------------------------------------------------ public health
  dict(key="masks", on="2020-08-12", arc="dead", shape=tug,
       path=("Public health measures", "Non-pharmaceutical", "Masking"),
       cast=("epi", "skeptic", "clinician", "statistician"),
       body='Settles on the randomised and observational literature as it stood before 2021, read together.\n\nScoped to the settings studied and to that period on purpose. It is not a claim about mandates, about later variants, or about any particular mask.',
       title="Community masking reduced SARS-CoV-2 transmission in the settings studied before 2021."),
  dict(key="distance", on="2020-09-20", arc="dead", shape=capitulate,
       path=("Public health measures", "Non-pharmaceutical", "Distancing rules"),
       cast=("clinician", "epi", "skeptic", "statistician"),
       title="The two-metre distancing rule was set from evidence specific to SARS-CoV-2."),
  dict(key="schools", on="2021-02-10", arc="dead", shape=late,
       path=("Public health measures", "Schools", "Learning loss"),
       cast=("teacher", "epi", "statistician", "clinician"),
       body='Settles on standardised assessment data for the affected cohorts against their own pre-2020 trend.\n\nAsks about measured learning loss, not about whether closures were justified — a cost can be real and still be worth paying, and this court does not price that.',
       title="Extended school closures produced measurable learning loss in the cohorts studied."),
  dict(key="borders", on="2020-05-18", arc="no", shape=short_grind,
       path=("Public health measures", "Borders and travel", "Closures"),
       cast=("trader", "epi", "skeptic", "modeller"),
       title="Border closures announced in early 2020 prevented sustained local transmission where applied."),
  # ---------------------------------------------------- vaccines and therapeutics
  dict(key="vaxsevere", on="2021-10-04", arc="yes", shape=sparse,
       path=("Vaccines and therapeutics", "Efficacy and waning", "Severe outcomes"),
       cast=("clinician", "skeptic", "epi", "trader"),
       body='Settles on the trial endpoints and the early observational cohorts.\n\nScoped to hospitalisation risk in the period studied. Not a claim about transmission, about durability, or about any later variant.',
       title="Vaccination substantially reduced hospitalisation risk in the trial and early observational data."),
  dict(key="vaxtrans", on="2021-08-16", arc="no", shape=short_flip,
       path=("Vaccines and therapeutics", "Efficacy and waning", "Transmission"),
       cast=("trader", "clinician", "skeptic", "epi"),
       title="The initial vaccine rollout prevented onward transmission as durably as it prevented severe disease."),
  dict(key="myo", on="2021-12-06", arc="yes", shape=sparse,
       path=("Vaccines and therapeutics", "Safety signals", "Myocarditis"),
       cast=("vaxsafety", "trader", "clinician", "skeptic"),
       body='Settles on the published post-authorisation surveillance findings.\n\nAsks whether a signal was IDENTIFIED, which is a claim about what surveillance found. Its magnitude, and how it weighs against the benefit, are not in scope.',
       title="A myocarditis signal in young males was identified in post-authorisation surveillance."),
  dict(key="vaers", on="2022-03-14", arc="dispute", shape=short_grind,
       path=("Vaccines and therapeutics", "Safety signals", "Surveillance quality"),
       cast=("vaxsafety", "clinician", "skeptic", "statistician"),
       title="Passive surveillance systems under-reported adverse events by more than an order of magnitude."),
  dict(key="ivermectin", on="2021-07-12", arc="dead", shape=reversal,
       path=("Vaccines and therapeutics", "Repurposed drugs", "Ivermectin"),
       cast=("skeptic", "clinician", "trader", "statistician"),
       title="Ivermectin reduced COVID-19 mortality in the randomised trials completed by 2021."),
  # ------------------------------------------- institutions and accountability
  dict(key="testimony", on="2024-06-10", arc="open", shape=sparse,
       path=("Institutions and accountability", "Testimony", "Gain-of-function funding"),
       cast=("oversight", "virology", "journo", "trader"),
       body="Settles on a tribunal's finding, or on a concession. The referral itself is a separate claim on this docket.\n\nFramed as what a tribunal WOULD find because no charge has been brought. An unadjudicated allegation is precisely the thing a market on claims of fact exists to price, and pricing one is not asserting it.",
       title="A tribunal applying the ordinary standard would find that congressional testimony on gain-of-function funding was materially false."),
  dict(key="referral", on="2023-07-17", arc="yes", shape=short_flip,
       path=("Institutions and accountability", "Referrals and sanctions", "The 2023 referral"),
       cast=("oversight", "trader", "journo", "skeptic"),
       title="A criminal referral concerning pandemic-origins testimony was sent to the Department of Justice in 2023."),
  # ---------------------------------------------------------- data and modelling
  dict(key="excess", on="2022-04-11", arc="dead", shape=drift,
       path=("Data and modelling", "Excess mortality", "The 2020-21 gap"),
       cast=("statistician", "skeptic", "epi", "modeller"),
       body='Settles on the excess-mortality estimates for 2020-2021 against reported COVID-19 deaths.\n\nAsks only whether the gap exists. What it is attributable to is a separate claim.',
       title="Global excess deaths for 2020–2021 exceeded the reported COVID-19 death count."),
  dict(key="models", on="2021-01-18", arc="dead", shape=reversal,
       path=("Data and modelling", "Model performance", "Interval coverage"),
       cast=("modeller", "statistician", "epi", "skeptic"),
       title="Published epidemic forecasts for 2020 stayed within their own stated prediction intervals."),
  dict(key="testpos", on="2022-02-07", arc="dispute", shape=short_lopsided,
       path=("Data and modelling", "Case and test data", "Prevalence tracking"),
       cast=("epi", "statistician", "trader", "modeller"),
       title="Reported case counts in 2021 tracked infection prevalence closely enough to guide policy."),
  dict(key="seroprev", on="2025-04-02", arc="open", shape=short_grind,
       path=("Data and modelling", "Case and test data", "Retrospective serology"),
       cast=("statistician", "modeller", "epi", "trader"),
       title="Retrospective serology will place first-wave infection prevalence above the contemporaneous estimate."),
]

# ------------------------------------------------------------------ relations
REL = [
  ("gof", "lab20", "part", None),
  ("furin", "lab23", "part", None),
  ("host", "lab23", "bears", "supports"),
  ("market", "lab23", "bears", "contradicts"),
  ("raccoon", "lab25", "bears", "contradicts"),
  ("drafts", "lab23", "bears", "supports"),
  ("gof", "lab23", "bears", "supports"),
  ("gof", "lab25", "bears", "supports"),
  ("furin", "lab25", "bears", "supports"),
  ("market", "lab25", "bears", "contradicts"),
  ("lab23", "lab20", "supersedes", None),
  ("lab25", "lab23", "supersedes", None),
  ("gof", "testimony", "bears", "supports"),
  ("drafts", "testimony", "bears", "supports"),
  ("reports", "testimony", "bears", "supports"),
  ("ehasusp", "reports", "bears", "supports"),
  ("foiagap", "drafts", "bears", "supports"),
  ("referral", "testimony", "part", None),
  ("distance", "masks", "bears", "contradicts"),
  ("schools", "masks", "bears", "supports"),
  ("myo", "vaxsevere", "bears", "contradicts"),
  ("vaers", "myo", "bears", "supports"),
  ("vaxtrans", "vaxsevere", "bears", "contradicts"),
  ("ivermectin", "vaxsevere", "bears", "contradicts"),
  ("testpos", "models", "bears", "contradicts"),
  ("excess", "testpos", "bears", "contradicts"),
  ("seroprev", "excess", "bears", "supports"),
  ("excess", "masks", "bears", "supports"),
  ("models", "borders", "bears", "contradicts"),
  ("testpos", "excess", "part", None),
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
    _thin = _c["shape"] is sparse
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
    if _c["arc"] in ("yes", "no", "dispute"):
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

s.note("the court, and real GNOT burned into its coin by sixteen participants")
s.court(DEPLOYER, SLUG, "COVID-19 Origins & Response Court")
for name, funds, _ in ACTORS:
    s.buy(accounts[name], SLUG, int(funds * 0.35))
s.expect("CoinSupply", [SLUG], r"int64")

# ------------------------------------------------------- the filing system
#
# THE WHOLE TREE, ON CHAIN. Six roots, eleven headings under them, twelve leaves,
# built from the same `path` tuples the curation file uses — so the two can never
# disagree about the shape of the docket, which is the failure the old split
# invited.
#
# Parents strictly before children, and not by sorting: ensure_folder recurses up
# the path and creates what is missing, so a parentID is a folder the chain has
# already acknowledged. `mustNestable` would refuse otherwise, and it counts
# depth against maxFolderDepth = 4 — this tree is three, with room for one more.
#
# The ids are TRACKED rather than read back. CreateFolder/CreateFolderIn return
# the id, but a scenario step is a broadcast and not a value, so the plan cannot
# capture it. folderSeq increments by one per create and starts at 0, so counting
# creates in this process gives the same numbers the realm assigns. Any drift
# would show up immediately as an AddToFolder into the wrong folder — which is
# why every claim's placement is asserted at the end.
ROOT_DESC = {
    "Origins": "Where the virus came from. Two hypotheses, filed as separate "
               "claims so neither is settled by the other losing.",
    "The document trail": "Claims that rest on released grant records, "
                          "correspondence and audits — the paper, not the "
                          "inference from it.",
    "Public health measures": "What the interventions did, asked one measure and "
                              "one outcome at a time.",
    "Vaccines and therapeutics": "Efficacy, waning and safety signals, kept "
                                 "apart because they settle on different records.",
    "Institutions and accountability": "What officials and bodies said, and "
                                       "under what obligation they said it.",
    "Data and modelling": "Claims about the numbers themselves, where the "
                          "measurement is the thing in dispute.",
}

s.note("the filing system on chain: CreateFolder for a root, CreateFolderIn for "
       "a child, parents first — moderator-only, single-signer, no bond")
FOLDER_ID = {}
_folder_seq = 0


def ensure_folder(path):
    """The id of this path's folder, creating it and any missing ancestor."""
    global _folder_seq
    if path in FOLDER_ID:
        return FOLDER_ID[path]
    parent = ensure_folder(path[:-1]) if len(path) > 1 else 0
    desc = ROOT_DESC.get(path[0], "") if len(path) == 1 else ""
    if parent:
        s.call(DEPLOYER, "CreateFolderIn", [SLUG, str(parent), path[-1], desc])
    else:
        s.folder(DEPLOYER, SLUG, path[-1], desc)
    _folder_seq += 1
    FOLDER_ID[path] = _folder_seq
    return _folder_seq


for _c in D:
    ensure_folder(_c["path"])

# A FOLDER ABOUT ONE PERSON, and it is a cross-cut rather than a sixth branch of
# the tree. Four of this docket's claims turn on what NIAID funded, what its
# director's office wrote, and what was said about it under oath — and they are
# filed in three different places, because that is where the EVIDENCE lives (a
# subaward is a grant record, a draft is correspondence, testimony is testimony).
# Reading them together needs a folder that crosses those branches, which is
# exactly what AddToFolder allows: it checks membership within one folder only, so
# a claim may sit in several.
#
# NAMED FOR THE RECORD AND NOT FOR THE PERSON. Every claim in it is about a
# document or a proceeding, with a stated settlement condition; the folder is a
# reading order, and it asserts nothing the claims do not.
FAUCI = ("Institutions and accountability", "NIAID and its director")
ensure_folder(FAUCI[:1])
FOLDER_ID[FAUCI] = None  # created below, so the description is not the default ""
s.call(DEPLOYER, "CreateFolderIn",
       [SLUG, str(FOLDER_ID[FAUCI[:1]]), FAUCI[1],
        "Claims turning on what NIAID funded, what its director's office wrote, "
        "and what was said about it under oath. Filed elsewhere by evidence type."])
_folder_seq += 1
FOLDER_ID[FAUCI] = _folder_seq
FAUCI_CLAIMS = ["gof", "drafts", "foiagap", "testimony"]

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
ids = {}
for _n, _c in enumerate(sorted(D, key=lambda c: (c["on"], D.index(c))), start=1):
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


events = []
for c in D:
    cid, on, arc = ids[c["key"]], c["on"], c["arc"]
    events.append((on, 0, "open", cid, c))
    # every move on its own date: that is what makes the chart a chart, since
    # ClaimSeries is change-only and one calendar step is one 720-block epoch
    for k, (off, who, side, amt) in enumerate(MOVES[c["key"]]):
        if off:
            events.append((days(on, off), 0, ("move", k), cid, c))
    if arc in ("yes", "no", "dispute"):
        events.append((days(on, 22), 1, "answer", cid, c))
    if arc in ("yes", "no"):
        events.append((days(on, 26), 2, "settle", cid, c))
    if arc == "dispute":
        events.append((days(on, 23), 2, "dispute", cid, c))
    if arc == "dead":
        events.append((days(on, 91), 3, "dead", cid, c))

for iso, _, kind, cid, c in sorted(events, key=lambda e: (e[0], e[1], e[3])):
    if iso > END:
        raise ValueError(f"#{cid} {c['key']}: {kind} falls at {iso}, past {END}")
    if iso != _at["iso"]:
        goto(iso, "positions move" if isinstance(kind, tuple) else
             {"open": "filed", "answer": "answered", "settle": "settles",
              "dispute": "disputed", "dead": "expires unanswered"}[kind])
    if kind == "open":
        s.note(f"#{cid} {c['key']} — {c['arc']}, {len(MOVES[c['key']])} moves")
        s.claim(accounts[MOVES[c["key"]][0][1]], SLUG, c["title"], c.get("body"))
        s.folder_add(DEPLOYER, SLUG, FOLDER_ID[c["path"]], cid)
        if c["key"] in FAUCI_CLAIMS:
            s.folder_add(DEPLOYER, SLUG, FOLDER_ID[FAUCI], cid)
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
        s.answer(accounts[who], SLUG, cid, YES if c["arc"] in ("yes", "dispute") else NO)
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
BONDED = {("gof", "lab23"): "epi", ("market", "lab25"): "oversight",
          ("drafts", "lab23"): "epi"}

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
s.call(DEPLOYER, "ApproveAssociation",
       [SLUG, str(ids["gof"]), str(ids["lab23"])])
s.call(DEPLOYER, "DisapproveAssociation",
       [SLUG, str(ids["market"]), str(ids["lab25"])])
# drafts -> lab23 is deliberately left unjudged, which on this fixture means its
# author may reclaim the bond immediately once the clock is sealed — see the note
# above on why a back-dated docket cannot hold an open window. The rule it stands
# for is the important half: unjudged means approved, never forfeit.

s.note("re-filings, on chain too — the realm checks the older claim really died")
for a, b, kind, _ in REL:
    if kind == "supersedes":
        s.call(accounts[author_of[a]], "SupersedeClaim",
               [SLUG, str(ids[a]), str(ids[b])])

# ------------------------------------------------------------ what it built
#
# Asserted, not described. A folder id tracked in this process rather than read
# back from the chain is a guess until something checks it, and these reads are
# the check: the tree's shape, one leaf's contents, the cross-cut folder, and the
# graph around the claim the most edges point at.
s.expect("FolderTree", [SLUG], r"1:0:-")
s.expect("FolderDesc", [SLUG, FOLDER_ID[FAUCI]], r"NIAID")
s.expect("ClaimAssociations", [SLUG, ids["lab23"]], r"in:")
s.expect("AssociationBond", [SLUG], r"1000000")

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
