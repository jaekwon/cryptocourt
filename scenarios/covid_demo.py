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

  * the realm's `folder` struct has an id, a name, a description and a list of
    claim ids. No parent. **On-chain folders are flat** — there is no such thing
    as a subfolder on this chain.
  * relations between claims are not on the chain at all. The overlay says so on
    every screen that draws them: "the chain stores no relations".

So "many folders and subfolders with rich relations" is not one seeding job, it
is two: the claims, the stakes, the answers and the flat case files go on the
chain; the TREE and the RELATIONS are local curation — a JSON file the reader
imports into their own browser, held in localStorage and written to no chain.

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
    ("virology", 1_680_000_000, "coronavirus researcher; doubts a laboratory origin"),
    ("biosafety", 1_600_000_000, "containment engineer; thinks a leak likely"),
    ("epi", 1_520_000_000, "field epidemiology; the market-origin case"),
    ("genomics", 1_440_000_000, "sequence analysis; reads the phylogenies"),
    ("foia", 1_200_000_000, "reads the released documents, takes no side beyond them"),
    ("oversight", 1_360_000_000, "follows the congressional record"),
    ("journo", 1_120_000_000, "reporting the funding trail"),
    ("clinician", 1_280_000_000, "hospital medicine; the treatment claims"),
    ("modeller", 1_200_000_000, "built forecasts and grades his own"),
    ("statistician", 1_360_000_000, "excess mortality; distrusts every case count"),
    ("teacher", 880_000_000, "school closures, from inside one"),
    ("vaxsafety", 1_200_000_000, "pharmacovigilance; reads the safety signals"),
    ("skeptic", 1_040_000_000, "sceptical of every side, his own included"),
    ("trader", 1_680_000_000, "no view; takes the other side of crowds"),
    ("arbiter", 1_120_000_000, "answers claims; holds no position"),
    ("arbiter2", 1_040_000_000, "the second answerer, so one account is not the court"),
]

# ----------------------------------------------------------------- the docket
#
# One table, two artifacts. `path` is the curation TREE this claim is filed
# under; `case` is the flat on-chain folder, which is all the chain can hold.
# `arc` is what happens to it:
#
#   open      opened and staked, still live at the end of the calendar. Must be
#             opened inside the last twelve weeks — deadClaimSecs is twelve weeks
#             and a court cannot hold an older open question.
#   yes / no  answered and settled undisputed.
#   dispute   answered, disputed, voted.
#   dead      never answered; closed by anyone once twelve weeks have passed.
#
# `on` is the week the claim is opened, and it is the week the argument was
# actually being had.
D = [
  # ---------------------------------------------------------------- origins
  dict(key="lab20", on="2020-02-05", arc="dead", case=None,
       path=("Origins", "Laboratory hypothesis"),
       title="SARS-CoV-2 entered the human population through a laboratory-associated incident.",
       stakes=[("biosafety", YES, 8), ("virology", NO, 11), ("epi", NO, 6),
               ("skeptic", YES, 2), ("trader", NO, 4)]),
  dict(key="gof", on="2020-04-20", arc="yes", case="Document trail",
       path=("Origins", "Laboratory hypothesis"),
       title="US federal grants funded coronavirus research at the Wuhan Institute of Virology before 2020.",
       stakes=[("foia", YES, 9), ("journo", YES, 6), ("oversight", YES, 5),
               ("skeptic", NO, 2), ("trader", NO, 2)]),
  dict(key="furin", on="2020-06-10", arc="dead", case=None,
       path=("Origins", "Laboratory hypothesis"),
       title="The furin cleavage site in SARS-CoV-2 has no close analogue in the sampled sarbecovirus record.",
       stakes=[("genomics", YES, 6), ("virology", NO, 6), ("biosafety", YES, 4)]),
  dict(key="host", on="2021-03-15", arc="dead", case=None,
       path=("Origins", "Natural spillover"),
       title="An intermediate host animal for SARS-CoV-2 has been identified in the published record.",
       stakes=[("epi", NO, 7), ("virology", NO, 5), ("genomics", NO, 6),
               ("trader", YES, 3)]),
  dict(key="market", on="2021-06-07", arc="dead", case=None,
       path=("Origins", "The market"),
       title="The earliest known cluster of COVID-19 cases centred on the Huanan Seafood Market.",
       stakes=[("epi", YES, 8), ("genomics", YES, 4), ("biosafety", NO, 5),
               ("skeptic", NO, 2)]),
  dict(key="raccoon", on="2023-03-20", arc="no", case=None,
       path=("Origins", "The market"),
       title="Market environmental samples establish that an infected animal was the source of the outbreak.",
       stakes=[("epi", YES, 6), ("genomics", NO, 8), ("virology", NO, 4),
               ("biosafety", NO, 5), ("trader", YES, 3)]),
  dict(key="lab23", on="2023-04-10", arc="dead", case=None,
       path=("Origins", "Laboratory hypothesis"),
       title="A laboratory-associated origin is the more likely explanation, on the evidence public in 2023.",
       stakes=[("biosafety", YES, 9), ("virology", NO, 8), ("oversight", YES, 4),
               ("epi", NO, 6), ("skeptic", YES, 2), ("trader", NO, 4)]),
  dict(key="lab25", on="2025-03-20", arc="open", case=None,
       path=("Origins", "Laboratory hypothesis"),
       title="A laboratory-associated origin is the more likely explanation, on the evidence public in 2025.",
       stakes=[("biosafety", YES, 10), ("virology", NO, 8), ("genomics", YES, 5),
               ("epi", NO, 6), ("oversight", YES, 4), ("trader", NO, 4)]),
  # --------------------------------------------------------- document trail
  dict(key="drafts", on="2022-01-25", arc="yes", case="Document trail",
       path=("The document trail", "Correspondence"),
       title="Drafting correspondence for the 2020 Proximal Origin paper was released under subpoena.",
       stakes=[("foia", YES, 8), ("journo", YES, 5), ("oversight", YES, 4),
               ("trader", NO, 2)]),
  dict(key="proximal", on="2020-03-25", arc="yes", case="Document trail",
       path=("The document trail", "Correspondence"),
       title="\"The Proximal Origin of SARS-CoV-2\" was published in Nature Medicine in March 2020.",
       stakes=[("virology", YES, 6), ("foia", YES, 4), ("journo", YES, 3)]),
  dict(key="ehasusp", on="2024-05-20", arc="yes", case="Document trail",
       path=("The document trail", "Grants and funding"),
       title="HHS suspended EcoHealth Alliance's federal funding in May 2024.",
       stakes=[("oversight", YES, 6), ("journo", YES, 5), ("foia", YES, 4),
               ("skeptic", NO, 2)]),
  dict(key="reports", on="2021-09-10", arc="yes", case="Document trail",
       path=("The document trail", "Grants and funding"),
       title="Required progress reports for at least one federal coronavirus grant were filed late.",
       stakes=[("foia", YES, 6), ("oversight", YES, 4), ("journo", YES, 3),
               ("trader", NO, 2)]),
  dict(key="foiagap", on="2022-06-15", arc="dispute", case="Document trail",
       path=("The document trail", "FOIA and subpoena"),
       title="Records released under FOIA were withheld in part on grounds later found improper.",
       stakes=[("foia", YES, 7), ("journo", YES, 4), ("skeptic", NO, 4),
               ("trader", NO, 5), ("oversight", YES, 3)]),
  # ------------------------------------------------------ public health
  dict(key="masks", on="2020-08-12", arc="dispute", case=None,
       path=("Public health measures", "Non-pharmaceutical"),
       title="Community masking reduced SARS-CoV-2 transmission in the settings studied before 2021.",
       stakes=[("epi", YES, 8), ("clinician", YES, 6), ("skeptic", NO, 6),
               ("statistician", NO, 4), ("trader", NO, 4)]),
  dict(key="distance", on="2020-09-20", arc="dead", case=None,
       path=("Public health measures", "Non-pharmaceutical"),
       title="The two-metre distancing rule was set from evidence specific to SARS-CoV-2.",
       stakes=[("epi", NO, 5), ("clinician", NO, 4), ("skeptic", NO, 4)]),
  dict(key="schools", on="2021-02-10", arc="dispute", case=None,
       path=("Public health measures", "Schools"),
       title="Extended school closures produced measurable learning loss in the cohorts studied.",
       stakes=[("teacher", YES, 8), ("statistician", YES, 6), ("epi", NO, 4),
               ("clinician", YES, 3), ("trader", NO, 4)]),
  dict(key="schoolspread", on="2021-04-14", arc="dead", case=None,
       path=("Public health measures", "Schools"),
       title="Open schools were a principal driver of community transmission in early 2021.",
       stakes=[("teacher", NO, 6), ("epi", YES, 4), ("clinician", NO, 4)]),
  dict(key="borders", on="2020-05-18", arc="no", case=None,
       path=("Public health measures", "Borders and travel"),
       title="Border closures announced in early 2020 prevented sustained local transmission where applied.",
       stakes=[("epi", NO, 6), ("modeller", NO, 5), ("skeptic", NO, 3),
               ("trader", YES, 4)]),
  dict(key="quarantine", on="2021-11-08", arc="dead", case=None,
       path=("Public health measures", "Borders and travel"),
       title="Hotel quarantine programmes leaked infections at a rate above their stated design.",
       stakes=[("biosafety", YES, 5), ("epi", YES, 4), ("skeptic", YES, 2)]),
  # --------------------------------------------------- vaccines and therapeutics
  dict(key="vaxtrans", on="2021-08-16", arc="no", case=None,
       path=("Vaccines and therapeutics", "Efficacy and waning"),
       title="The initial vaccine rollout prevented onward transmission as durably as it prevented severe disease.",
       stakes=[("clinician", NO, 8), ("epi", NO, 6), ("vaxsafety", NO, 5),
               ("trader", YES, 4), ("skeptic", NO, 3)]),
  dict(key="vaxsevere", on="2021-10-04", arc="yes", case=None,
       path=("Vaccines and therapeutics", "Efficacy and waning"),
       title="Vaccination substantially reduced hospitalisation risk in the trial and early observational data.",
       stakes=[("clinician", YES, 8), ("epi", YES, 6), ("vaxsafety", YES, 4),
               ("skeptic", NO, 2), ("trader", NO, 3)]),
  dict(key="myo", on="2021-12-06", arc="yes", case=None,
       path=("Vaccines and therapeutics", "Safety signals"),
       title="A myocarditis signal in young males was identified in post-authorisation surveillance.",
       stakes=[("vaxsafety", YES, 7), ("clinician", YES, 5), ("epi", YES, 4),
               ("trader", NO, 2)]),
  dict(key="vaers", on="2022-03-14", arc="dispute", case=None,
       path=("Vaccines and therapeutics", "Safety signals"),
       title="Passive surveillance systems under-reported adverse events by more than an order of magnitude.",
       stakes=[("vaxsafety", YES, 6), ("skeptic", YES, 5), ("clinician", NO, 6),
               ("statistician", NO, 4), ("trader", NO, 3)]),
  dict(key="mandate", on="2022-09-19", arc="dead", case=None,
       path=("Vaccines and therapeutics", "Mandates"),
       title="Employment vaccine mandates raised uptake beyond what voluntary campaigns achieved.",
       stakes=[("statistician", YES, 5), ("skeptic", NO, 4), ("clinician", YES, 4),
               ("teacher", NO, 3)]),
  dict(key="ivermectin", on="2021-07-12", arc="no", case=None,
       path=("Vaccines and therapeutics", "Efficacy and waning"),
       title="Ivermectin reduced COVID-19 mortality in the randomised trials completed by 2021.",
       stakes=[("clinician", NO, 8), ("skeptic", NO, 4), ("statistician", NO, 5),
               ("trader", YES, 4)]),
  # ------------------------------------------- institutions and accountability
  dict(key="testimony", on="2024-06-10", arc="open", case=None,
       path=("Institutions and accountability", "Testimony"),
       title="A tribunal applying the ordinary standard would find that congressional testimony on gain-of-function funding was materially false.",
       stakes=[("oversight", YES, 8), ("journo", YES, 5), ("virology", NO, 6),
               ("skeptic", YES, 3), ("trader", NO, 4), ("foia", YES, 3)]),
  dict(key="referral", on="2023-07-17", arc="yes", case="Document trail",
       path=("Institutions and accountability", "Referrals and sanctions"),
       title="A criminal referral concerning pandemic-origins testimony was sent to the Department of Justice in 2023.",
       stakes=[("oversight", YES, 6), ("journo", YES, 4), ("foia", YES, 3),
               ("trader", NO, 2)]),
  dict(key="charge", on="2025-04-15", arc="open", case=None,
       path=("Institutions and accountability", "Referrals and sanctions"),
       title="A charge will be brought on the 2023 origins-testimony referral before 2027.",
       stakes=[("oversight", YES, 5), ("skeptic", NO, 6), ("journo", YES, 3),
               ("trader", NO, 5)]),
  dict(key="advisory", on="2022-11-14", arc="dead", case=None,
       path=("Institutions and accountability", "Advisory bodies"),
       title="At least one advisory committee recommendation in 2021 departed from its own stated evidence threshold.",
       stakes=[("vaxsafety", YES, 5), ("skeptic", YES, 4), ("clinician", NO, 4)]),
  dict(key="conflict", on="2023-01-23", arc="dispute", case="Document trail",
       path=("Institutions and accountability", "Advisory bodies"),
       title="A declarable conflict of interest went undeclared by at least one adviser on pandemic-origins questions.",
       stakes=[("foia", YES, 6), ("oversight", YES, 4), ("virology", NO, 5),
               ("skeptic", YES, 3), ("trader", NO, 4)]),
  # ------------------------------------------------------- data and modelling
  dict(key="excess", on="2022-04-11", arc="yes", case=None,
       path=("Data and modelling", "Excess mortality"),
       title="Global excess deaths for 2020–2021 exceeded the reported COVID-19 death count.",
       stakes=[("statistician", YES, 8), ("epi", YES, 5), ("modeller", YES, 4),
               ("skeptic", NO, 2)]),
  dict(key="excessattr", on="2022-08-08", arc="dead", case=None,
       path=("Data and modelling", "Excess mortality"),
       title="The excess-death gap for 2020–2021 is attributable mainly to undercounted infection deaths.",
       stakes=[("statistician", YES, 6), ("epi", YES, 4), ("skeptic", NO, 5)]),
  dict(key="ifr", on="2020-10-19", arc="dead", case=None,
       path=("Data and modelling", "Case and test data"),
       title="The infection fatality rate assumed in spring 2020 planning was within a factor of two of the later estimate.",
       stakes=[("modeller", YES, 5), ("statistician", NO, 6), ("epi", YES, 3)]),
  dict(key="models", on="2021-01-18", arc="no", case=None,
       path=("Data and modelling", "Model performance"),
       title="Published epidemic forecasts for 2020 stayed within their own stated prediction intervals.",
       stakes=[("modeller", NO, 6), ("statistician", NO, 6), ("skeptic", NO, 4),
               ("trader", YES, 4)]),
  dict(key="modelrev", on="2023-09-11", arc="dead", case=None,
       path=("Data and modelling", "Model performance"),
       title="Forecast accuracy improved measurably after the 2020 methodological revisions.",
       stakes=[("modeller", YES, 5), ("statistician", NO, 4), ("epi", YES, 3)]),
  dict(key="testpos", on="2022-02-07", arc="dispute", case=None,
       path=("Data and modelling", "Case and test data"),
       title="Reported case counts in 2021 tracked infection prevalence closely enough to guide policy.",
       stakes=[("statistician", NO, 7), ("modeller", NO, 5), ("epi", YES, 4),
               ("skeptic", NO, 4), ("trader", YES, 3)]),
  dict(key="cyclethresh", on="2021-05-24", arc="dead", case=None,
       path=("Data and modelling", "Case and test data"),
       title="PCR cycle-threshold reporting practice varied enough between laboratories to affect case comparability.",
       stakes=[("statistician", YES, 4), ("clinician", YES, 3), ("skeptic", YES, 2)]),
  dict(key="seroprev", on="2025-04-02", arc="open", case=None,
       path=("Data and modelling", "Case and test data"),
       title="Retrospective serology will place first-wave infection prevalence above the contemporaneous estimate.",
       stakes=[("statistician", YES, 6), ("epi", YES, 4), ("modeller", NO, 4),
               ("trader", NO, 3)]),
]

# ------------------------------------------------------------------ relations
#
# The argument, as edges. `part` is containment — a tree, at most one parent, and
# the overlay files it beside "Rests on"; `bears` is the argument graph with a
# stance; `supersedes` is a re-filing after a claim died unanswered, which is the
# shape this docket keeps producing because the question outlived the contract.
REL = [
  # the laboratory question rests on its evidence
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
  # the question was asked three times, each after new evidence
  ("lab23", "lab20", "supersedes", None),
  ("lab25", "lab23", "supersedes", None),
  # the document trail bears on the testimony claim
  ("gof", "testimony", "bears", "supports"),
  ("drafts", "testimony", "bears", "supports"),
  ("reports", "testimony", "bears", "supports"),
  ("proximal", "drafts", "part", None),
  ("ehasusp", "reports", "bears", "supports"),
  ("foiagap", "drafts", "bears", "supports"),
  ("conflict", "testimony", "bears", "supports"),
  ("referral", "testimony", "part", None),
  ("charge", "referral", "bears", "supports"),
  # public health: the parts of the closure question
  ("schoolspread", "schools", "bears", "contradicts"),
  ("distance", "masks", "bears", "contradicts"),
  ("quarantine", "borders", "bears", "contradicts"),
  # vaccines
  ("myo", "vaxsevere", "bears", "contradicts"),
  ("vaers", "myo", "bears", "supports"),
  ("vaxtrans", "mandate", "bears", "contradicts"),
  ("vaxsevere", "mandate", "bears", "supports"),
  ("advisory", "myo", "bears", "supports"),
  ("ivermectin", "vaxsevere", "bears", "contradicts"),
  # data
  ("excessattr", "excess", "part", None),
  ("ifr", "models", "bears", "contradicts"),
  ("modelrev", "models", "bears", "contradicts"),
  ("testpos", "models", "bears", "contradicts"),
  ("cyclethresh", "testpos", "bears", "supports"),
  ("seroprev", "excess", "bears", "supports"),
  ("excess", "ifr", "bears", "contradicts"),
  # and the cross-folder edges that make it an argument rather than six lists
  ("excess", "masks", "bears", "supports"),
  ("testpos", "masks", "bears", "contradicts"),
  ("excessattr", "testpos", "bears", "supports"),
  ("conflict", "proximal", "bears", "supports"),
  ("foiagap", "conflict", "bears", "supports"),
]

# A stake is committed coin. Every actor's total commitment has to fit inside what
# it actually bought, and the curve gives the sixteenth buyer less per ugnot than
# the first, so the budget is checked here rather than discovered mid-run.
_spend = {n: int(f * 0.35) for n, f, _ in ACTORS}
_staked = {}
for _c in D:
    for _who, _side, _amt in _c["stakes"]:
        _staked[_who] = _staked.get(_who, 0) + _amt * 1_000_000
    if _c["arc"] in ("yes", "no", "dispute"):
        for _i in (0, -1):
            _w, _, _a = _c["stakes"][_i]
            _staked[_w] = _staked.get(_w, 0) + max(2, _a // 3) * 1_000_000
for _who, _units in sorted(_staked.items(), key=lambda kv: -kv[1] / _spend[kv[0]]):
    _ratio = _units / _spend[_who]
    if _ratio > 0.35:
        raise ValueError(
            f"{_who} commits {_units:,} units against {_spend[_who]:,} ugnot bought "
            f"(ratio {_ratio:.2f}). Over ~0.35 the chain refuses the stake for want "
            f"of unstaked coin — lower the numbers in D or raise the funding.")

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

s.note("one flat case file on the chain — CreateFolder is moderator-only and the "
       "struct has no parent, so the TREE is curation and only this is chain")
s.folder(DEPLOYER, SLUG, "Document trail",
         "Claims resting on released grant records, correspondence and audits.")
CASE_FOLDER = 1

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
    if arc in ("yes", "no", "dispute"):
        # Positions arrive over three weeks rather than all in the filing block.
        # Required — three buckets or the claim cannot be answered — and it is
        # also how a real book fills: somebody adds after the first week.
        events.append((days(on, 7), 0, "topup", cid, c))
        events.append((days(on, 14), 0, "topup2", cid, c))
        events.append((days(on, 21), 1, "answer", cid, c))
    if arc in ("yes", "no"):
        events.append((days(on, 25), 2, "settle", cid, c))
    if arc == "dispute":
        events.append((days(on, 22), 2, "dispute", cid, c))
    if arc == "dead":
        events.append((days(on, 91), 3, "dead", cid, c))

for iso, _, kind, cid, c in sorted(events, key=lambda e: (e[0], e[1], e[3])):
    if iso > END:
        raise ValueError(f"#{cid} {c['key']}: {kind} falls at {iso}, past {END}")
    if iso != _at["iso"]:
        goto(iso, {"open": "filed", "answer": "answered", "settle": "settles",
                   "dispute": "disputed", "dead": "expires unanswered",
                   "topup": "positions added", "topup2": "and again"}[kind])
    if kind == "open":
        s.note(f"#{cid} {c['key']} — {c['arc']}")
        s.claim(accounts[c["stakes"][0][0]], SLUG, c["title"])
        if c["case"]:
            s.folder_add(DEPLOYER, SLUG, CASE_FOLDER, cid)
        for who, side, amount in c["stakes"]:
            s.stake(accounts[who], SLUG, cid, side, unit(amount))
    elif kind in ("topup", "topup2"):
        who, side, amount = c["stakes"][0 if kind == "topup" else -1]
        s.stake(accounts[who], SLUG, cid, side, unit(max(2, amount // 3)))
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

# ------------------------------------------------------------- the curation
#
# The half the chain cannot hold. Written from the SAME table, with the ids the
# scenario just counted, so it can never reference a claim that is not there.
def tree():
    out, index = [], {}
    for c in D:
        top, sub = c["path"]
        t = index.get(top)
        if t is None:
            t = index[top] = {"name": top, "claims": [], "folders": [], "_sub": {}}
            out.append(t)
        u = t["_sub"].get(sub)
        if u is None:
            u = t["_sub"][sub] = {"name": sub, "claims": [], "folders": []}
            t["folders"].append(u)
        u["claims"].append(ids[c["key"]])
    for t in out:
        t.pop("_sub")
    return out


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
    "desc": ("A docket on the origins and handling of COVID-19. Folders and "
             "relations are curation held in this browser; the chain stores "
             "neither."),
    "folders": tree(),
    "relations": relations,
}, indent=1) + "\n", encoding="utf-8")

SCENARIO = s
