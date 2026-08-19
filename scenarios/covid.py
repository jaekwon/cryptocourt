"""The COVID-19 origins court: five years of docket, on the real calendar.

WHY THIS SCENARIO EXISTS. Every other scenario here is a mechanism test wearing
placeholder text — "The county certified 12,412 mail ballots". This one is the
demo: a court whose docket a stranger can read and recognise, with claims that
really are disputed, positions taken in the weeks the evidence actually landed,
and claims that die unanswered because nobody could answer them yet.

THE CALENDAR IS REAL. The clock is armed at 1 February 2020 and walked forward,
so a position carries the timestamp of the week it was taken and the claim under
it is the one people were arguing about that week.

    2020-02  the Proximal Origin authors draft; the first positions are taken
    2020-03  "The Proximal Origin of SARS-CoV-2" is published in Nature Medicine
    2021-05  a Senate exchange on NIH funding of gain-of-function work
    2021-07  a second Senate exchange
    2022-01  drafting correspondence is released under subpoena
    2023-02  the Department of Energy assessment is reported
    2023-03  the FBI's assessment is confirmed publicly
    2023-07  a criminal referral goes to the Department of Justice
    2024-05  HHS suspends EcoHealth Alliance's federal funding
    2024-06  public testimony before a House subcommittee
    2025-01  a revised CIA assessment is reported

THE DOCKET'S SHAPE IS FORCED BY A REAL RULE, and it is the most realistic thing
here. `deadClaimSecs` is twelve weeks: a claim nobody answers within that window
CLOSES rather than resolving. So a court cannot hold a five-year-old open
question — and a real market on an unresolved question does not try to. It asks
again each time new evidence lands, and the old contract expires unanswered.

That is exactly the history of this question, so the docket tells it that way. The
laboratory-origin claim is opened in 2020, dies unanswered, is opened again after
the 2023 agency assessments, dies again, and is open once more after the 2025
assessment. Eleven claims, of which:

  * three are matters of record and RESOLVE — the funding trail, the drafting
    correspondence, the reporting failure;
  * five DIE UNANSWERED, because they were asked before anybody could answer
    them, which is a real outcome this system has a verb for;
  * three are OPEN at the end, because the world has not resolved them.

WHAT THE CLAIMS SAY. A court adjudicates propositions, so each is written as
something that could be found true or false on evidence. Nothing here asserts a
finding the world has not made. The laboratory-origin claims stay open because the
intelligence community is itself split — some elements assess a laboratory origin
as more likely, others natural spillover, at low to moderate confidence either
way. The testimony claim is an allegation referred to prosecutors on which no
charge has been brought, so it is on the docket as a question about what a
tribunal WOULD find, unresolved. An unadjudicated allegation is precisely the
thing this product exists to price, and pricing one is not asserting it.
"""

import datetime
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import Scenario, YES, NO, DEPLOYER  # noqa: E402


def epoch(iso):
    """A date on the real calendar, as an instant."""
    return int(datetime.datetime.strptime(iso, "%Y-%m-%d")
               .replace(tzinfo=datetime.timezone.utc).timestamp())


BASE = "2020-02-01"

s = SCENARIO = Scenario("covid", __doc__.split("\n\n")[0])

_at = {"iso": BASE}


def goto(iso, why):
    """Walk the clock to a real date. Forward only, like the chain's."""
    delta = epoch(iso) - epoch(_at["iso"])
    if delta <= 0:
        raise ValueError(f"the calendar only moves forward: {_at['iso']} -> {iso}")
    s.advance(delta, why=f"{iso} — {why}")
    _at["iso"] = iso


# ---------------------------------------------------------------- the room
#
# Nine accounts, because a docket with two is a test and a docket with nine is a
# room. Who takes which side, and when, is what makes a reader believe the court
# was used rather than dressed.
#
# Every account that takes a position buys roughly twice what it commits. That is
# not padding: a deposit or a bond cannot be backed by committed stake, and the
# chain says so in as many words — "staked coins stay in your balance and keep
# voting, but they are committed and cannot also back a deposit, a bond, or
# another stake". It is also how somebody with a view behaves; they keep powder.
virology = s.account("virology", 400_000_000)   # coronavirus work; doubts lab origin
biosafety = s.account("biosafety", 400_000_000)  # containment; thinks a leak likely
foia = s.account("foia", 300_000_000)            # reads the released documents
epi = s.account("epi", 350_000_000)              # field epidemiology; market-origin case
oversight = s.account("oversight", 400_000_000)  # follows the congressional record
journo = s.account("journo", 300_000_000)        # reporting the funding trail
skeptic = s.account("skeptic", 250_000_000)      # sceptical of every side, his own included
trader = s.account("trader", 400_000_000)        # no view; takes the other side of crowds
arbiter = s.account("arbiter", 300_000_000)      # answers claims; holds no position

s.note("arm the clock on the real calendar, before any court exists")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=epoch(BASE))
s.expect("TestClockActive", [], "true")

s.note("the court, and real GNOT burned into its coin by nine participants")
s.court(DEPLOYER, "covid", "COVID-19 Origins Court")
for who, amount in ((virology, 250_000_000), (biosafety, 240_000_000),
                    (foia, 140_000_000), (epi, 200_000_000),
                    (oversight, 260_000_000), (journo, 170_000_000),
                    (skeptic, 120_000_000), (trader, 240_000_000),
                    (arbiter, 200_000_000)):
    s.buy(who, "covid", amount)
s.expect("CoinSupply", ["covid"], r"int64")

s.note("a case file for the documentary claims — CreateFolder is moderator-only, "
       "and the court's creator is its moderator (the chain refused foia outright)")
s.folder(DEPLOYER, "covid", "Document trail",
         "Claims resting on released grant records, correspondence and audits.")

# ============================================================ February 2020
#
# The first claim is asked far too early and dies for it. That is not a flaw in the
# fixture: in February 2020 there was nothing anybody could answer this on, and a
# market that lets you ask anyway — then expires the contract when no answer comes
# — is behaving correctly.
s.note("2020-02 — the question is asked immediately, and cannot be answered yet")
s.claim(biosafety, "covid",
        "SARS-CoV-2 entered the human population through a laboratory-associated "
        "incident in Wuhan rather than by natural spillover. [asked Feb 2020]")
LAB20 = 1
s.stake(biosafety, "covid", LAB20, YES, 12_000_000)
s.stake(virology, "covid", LAB20, NO, 20_000_000)
s.stake(epi, "covid", LAB20, NO, 15_000_000)

goto("2020-03-17", "Proximal Origin is published; the natural-origin case firms up")
s.stake(virology, "covid", LAB20, NO, 30_000_000)
s.stake(epi, "covid", LAB20, NO, 18_000_000)
s.stake(skeptic, "covid", LAB20, NO, 6_000_000)

s.note("2020-03 — and the funding trail, which nobody disputes even in 2020")
s.claim(journo, "covid",
        "NIH funds reached coronavirus research at the Wuhan Institute of Virology "
        "through EcoHealth Alliance subawards before 2020.")
FUNDING = 2
s.stake(journo, "covid", FUNDING, YES, 25_000_000)
s.stake(virology, "covid", FUNDING, YES, 10_000_000)
s.stake(foia, "covid", FUNDING, YES, 14_000_000)

s.note("answer it inside the twelve-week window: ripen the ring, then answer")
s.advance_height(2_400, why="answerWindow, without producing a block")
goto("2020-04-28", "six weeks on — comfortably inside deadClaimSecs")
s.stake(journo, "covid", FUNDING, YES, 1_000_000)
s.answer(arbiter, "covid", FUNDING, YES)
s.expect("HasAnswer", ["covid", FUNDING], "true")
s.folder_add(DEPLOYER, "covid", 1, FUNDING)

s.note("the 2020 laboratory claim is now past twelve weeks and closes unanswered — "
       "the deposit refunds, the fee burns, and the docket records that it expired")
goto("2020-05-20", "past deadClaimSecs for a claim opened on 1 February")
s.call(biosafety, "CloseDeadClaim", ["covid", str(LAB20)],
       note="asked too early: nobody could answer this in 2020")

# ============================================================ May 2021
goto("2021-05-11", "a Senate exchange on NIH funding of gain-of-function work")
s.note("2021-05 — the definitional question, asked for the first time")
s.claim(oversight, "covid",
        "The NIH-funded work at the Wuhan Institute of Virology met the federal "
        "definition of gain-of-function research of concern then in force. "
        "[asked May 2021]")
GOF21 = 3
s.stake(oversight, "covid", GOF21, YES, 22_000_000)
s.stake(virology, "covid", GOF21, NO, 28_000_000)
s.stake(biosafety, "covid", GOF21, YES, 16_000_000)

goto("2021-07-20", "a second Senate exchange")
s.note("2021-07 — and the question about the testimony itself")
s.claim(oversight, "covid",
        "A tribunal reviewing the May 2021 Senate testimony on NIH funding of "
        "gain-of-function research would find it knowingly false. [asked Jul 2021]")
TEST21 = 4
s.stake(oversight, "covid", TEST21, YES, 18_000_000)
s.stake(trader, "covid", TEST21, NO, 24_000_000)
s.stake(skeptic, "covid", TEST21, NO, 12_000_000)
s.note("a trader taking the other side of a crowded position is what a trader is for")

s.note("both 2021 claims die unanswered — a definitional dispute and an "
       "unprosecuted allegation are not answerable in twelve weeks")
goto("2021-11-01", "past twelve weeks for both")
s.call(oversight, "CloseDeadClaim", ["covid", str(GOF21)])
s.call(oversight, "CloseDeadClaim", ["covid", str(TEST21)])

# ============================================================ January 2022
goto("2022-01-11", "drafting correspondence is released under subpoena")
s.note("2022-01 — a documentary claim, and this one CAN be answered")
s.claim(foia, "covid",
        "The authors of 'The Proximal Origin of SARS-CoV-2' privately discussed a "
        "laboratory origin as plausible while drafting the paper that dismissed it.")
PROXIMAL = 5
s.stake(foia, "covid", PROXIMAL, YES, 30_000_000)
s.stake(journo, "covid", PROXIMAL, YES, 20_000_000)
s.stake(virology, "covid", PROXIMAL, NO, 8_000_000)
s.stake(skeptic, "covid", PROXIMAL, NO, 5_000_000)

s.advance_height(2_400, why="answerWindow for the correspondence claim")
goto("2022-02-22", "six weeks on")
s.stake(foia, "covid", PROXIMAL, YES, 1_000_000)
s.answer(arbiter, "covid", PROXIMAL, YES)
s.folder_add(DEPLOYER, "covid", 1, PROXIMAL)

s.note("and it is DISPUTED — the sceptic is not the answerer and holds free coin")
s.dispute(skeptic, "covid", PROXIMAL)
s.expect("DisputeOpen", ["covid", PROXIMAL], "true")

# THE ELECTORATE IS DISJOINT FROM THE TRADERS, and not by choice — the chain
# refuses a participant's vote outright ("a participant may not vote on their own
# claim's verdict"). On this claim that bars almost everyone who cared about it:
# foia authored it, arbiter answered it, and virology, journo and skeptic all
# hold stake on it. Skeptic may OPEN the dispute — only the answerer is barred
# from that — and then may not vote in the round they paid for.
#
# So a verdict here is decided by holders with no position on the question, which
# is the design's own answer to "why would a staker vote honestly": they cannot
# vote at all. It also means a claim's verdict needs turnout from people with
# nothing at stake on it, and that is a real property of this system rather than
# an artifact of this scenario. The first draft of this file had virology and
# skeptic voting; the node refused both.
s.note("the room votes — and it is NOT the traders. The proposal asks whether "
       "to OVERTURN, so a no upholds")
s.vote(epi, "covid", PROXIMAL, "no")
s.vote(biosafety, "covid", PROXIMAL, "no")
s.vote(oversight, "covid", PROXIMAL, "no")
s.vote(trader, "covid", PROXIMAL, "yes")
s.advance_height(140_000, why="votingBlocks + grace, in one transaction")
s.call(journo, "ResolveDispute", ["covid", str(PROXIMAL)])
s.expect("DisputeOpen", ["covid", PROXIMAL], "false")

# ============================================================ 2023: the agencies
goto("2023-02-26", "the Department of Energy assessment is reported")
s.note("2023-02 — the laboratory question is asked a SECOND time, three years on")
s.claim(biosafety, "covid",
        "SARS-CoV-2 entered the human population through a laboratory-associated "
        "incident in Wuhan rather than by natural spillover. [asked Feb 2023]")
LAB23 = 6
s.stake(biosafety, "covid", LAB23, YES, 40_000_000)
s.stake(foia, "covid", LAB23, YES, 22_000_000)
s.stake(oversight, "covid", LAB23, YES, 18_000_000)

goto("2023-03-01", "the FBI's assessment is confirmed publicly")
s.stake(biosafety, "covid", LAB23, YES, 20_000_000)
s.note("the natural-origin side does not fold: the market-origin papers stand")
s.stake(epi, "covid", LAB23, NO, 35_000_000)
s.stake(virology, "covid", LAB23, NO, 25_000_000)

goto("2023-07-18", "a criminal referral goes to the Department of Justice")
s.note("2023-07 — the testimony question, asked a second time")
s.claim(oversight, "covid",
        "A tribunal reviewing the May 2021 Senate testimony on NIH funding of "
        "gain-of-function research would find it knowingly false. [asked Jul 2023]")
TEST23 = 7
s.stake(oversight, "covid", TEST23, YES, 26_000_000)
s.stake(journo, "covid", TEST23, YES, 12_000_000)
s.stake(trader, "covid", TEST23, NO, 30_000_000)

s.note("no charge follows, and neither 2023 claim can be answered — both expire")
goto("2023-11-01", "past twelve weeks for both")
s.call(biosafety, "CloseDeadClaim", ["covid", str(LAB23)])
s.call(oversight, "CloseDeadClaim", ["covid", str(TEST23)])

# ============================================================ 2024: the audit
goto("2024-05-15", "HHS suspends EcoHealth Alliance's federal funding")
s.note("2024-05 — a claim nobody defends, and the docket should show that")
s.claim(journo, "covid",
        "EcoHealth Alliance failed to file a required progress report on the "
        "subaward covering work at the Wuhan Institute of Virology.")
REPORTING = 8
s.stake(journo, "covid", REPORTING, YES, 28_000_000)
s.stake(oversight, "covid", REPORTING, YES, 16_000_000)
s.stake(virology, "covid", REPORTING, YES, 9_000_000)
s.stake(skeptic, "covid", REPORTING, YES, 4_000_000)

s.advance_height(2_400, why="answerWindow for the reporting claim")
goto("2024-06-26", "six weeks on, after the June testimony")
s.stake(journo, "covid", REPORTING, YES, 1_000_000)
s.answer(arbiter, "covid", REPORTING, YES)
s.expect("HasAnswer", ["covid", REPORTING], "true")
s.folder_add(DEPLOYER, "covid", 1, REPORTING)

# ============================================================ 2025: still open
goto("2025-01-25", "a revised CIA assessment is reported")
s.note("2025-01 — the laboratory question, asked a THIRD time, and still open at "
       "the end of this file because the world has not answered it")
s.claim(biosafety, "covid",
        "SARS-CoV-2 entered the human population through a laboratory-associated "
        "incident in Wuhan rather than by natural spillover. [asked Jan 2025]")
LAB25 = 9
s.stake(biosafety, "covid", LAB25, YES, 24_000_000)
s.stake(trader, "covid", LAB25, YES, 20_000_000)
s.stake(epi, "covid", LAB25, NO, 18_000_000)
s.stake(virology, "covid", LAB25, NO, 12_000_000)
s.stake(foia, "covid", LAB25, YES, 10_000_000)

goto("2025-02-14", "three weeks on, positions still moving")
s.claim(oversight, "covid",
        "The NIH-funded work at the Wuhan Institute of Virology met the federal "
        "definition of gain-of-function research of concern then in force. "
        "[asked Feb 2025]")
GOF25 = 10
s.stake(oversight, "covid", GOF25, YES, 20_000_000)
s.stake(skeptic, "covid", GOF25, NO, 14_000_000)
s.stake(trader, "covid", GOF25, NO, 18_000_000)
s.stake(virology, "covid", GOF25, NO, 16_000_000)
s.note("a definitional claim, evenly matched, because the definition IS the dispute")

s.claim(oversight, "covid",
        "A tribunal reviewing the May 2021 Senate testimony on NIH funding of "
        "gain-of-function research would find it knowingly false. [asked Feb 2025]")
TEST25 = 11
s.stake(oversight, "covid", TEST25, YES, 22_000_000)
s.stake(journo, "covid", TEST25, YES, 10_000_000)
s.stake(trader, "covid", TEST25, NO, 26_000_000)
s.stake(skeptic, "covid", TEST25, NO, 8_000_000)

goto("2025-03-07", "the docket as it stands")
s.note("eleven claims: three resolved, five expired unanswered, three open")
s.expect("ClaimCount", ["covid"], r"11")

s.note("seal the clock: the fabricated calendar is on the realm's record forever")
s.seal_clock()
s.expect("TestClockFabricated", [], "true")
