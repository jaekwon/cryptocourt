"""A claim walked all the way to a verdict, on a real chain.

CI = False. This scenario mines its way past `answerWindow`, which is 2,160
blocks (answer.gno:15, `3 * epochBlocks`), and at the measured ~525ms a block
that is around twenty minutes. Round 4 ruled CI scenarios stay under ~200
blocks, so this one never becomes a txtar; it exists to seed a node by hand:

    scripts/seed-node.sh scenarios/deep.py
    python3 scripts/check-live-reads.py --remote http://127.0.0.1:26657

WHY IT IS WORTH TWENTY MINUTES. Every state past "open" has never once been
exercised against a live chain. The smoke scenario reaches open, staked, hidden
and dead-closed; the conformance harness then SKIPS seven reads — AnswerVerdict,
Answerer, AnswerBond, Verdict, VerdictRoute, QuorumFloorOf, DrawSlices —
because their guards are false, which means the page's answered and settled
paths have no live evidence behind them at all. Two live-node runs have already
found defects no unit test did (sealing erased the clock disclosure; the curve's
integer price rendered a court's coin as free), and both were in exactly this
kind of untested seam.

WHAT IT TAKES TO ANSWER A CLAIM, read from the realm rather than guessed:

  * `PostAnswer` demands a MATURE trailing average (answer.gno:47-50). Maturity
    is `count == want && filled >= want` (twap.gno:243) with
    `want = answerWindow / epochBlocks = 2160 / 720 = 3`. So the claim's ring
    needs observations spanning three 720-block buckets.
  * `Observe` carries the last value forward across skipped buckets and counts
    each step, so two stakes far enough apart fill the ring — you do not need
    three separate transactions, you need three buckets of HEIGHT.
  * The trailing average must also clear `effMinAnswerX`, so the stake has to be
    substantial relative to the court's supply.
  * Settling is wall-clock gated (session.gno:32, 72h), which the test clock
    crosses for free — that is the whole point of the clock, and it is why this
    scenario costs twenty minutes and not three days.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from scenario import Scenario, YES  # noqa: E402

CI = False  # never generate a txtar for this one

s = SCENARIO = Scenario("deep", __doc__.split("\n\n")[0])

alice = s.account("alice", 900_000_000)
bob = s.account("bob", 900_000_000)
carol = s.account("carol", 900_000_000)

s.note("arm the clock before anything else happens")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=1780000000)

s.note("a court with real coin behind it")
s.court(alice, "orem", "Orem Truth Court")
s.buy(alice, "orem", 400_000_000)
s.buy(bob, "orem", 400_000_000)
s.buy(carol, "orem", 400_000_000)

s.note("BOTH claims open now, so one mine matures both rings")
# Maturity is per-claim but measured in HEIGHT, so two claims opened together
# ripen on the same 2,200 blocks. Opening the second one later would cost a
# second 2,200-block run for nothing.
s.claim(alice, "orem", "The county certified 12,412 mail ballots on Nov 6, 2025.")
s.claim(alice, "orem", "The Center St. bridge inspection was completed in 2025.")
# ALICE stakes; BOB and CAROL do not, and that is load-bearing. PostAnswer and
# OpenDispute both take a bond through mustSpendable (lock.gno:73), and staked
# coin is committed: it keeps voting but cannot also back a bond. An earlier run
# had bob stake and then fail to answer with "not enough unstaked CC" — a real
# rule, found only because the seed ran against a chain.
s.stake(alice, "orem", 1, YES, 400_000_000)
s.stake(alice, "orem", 2, YES, 300_000_000)

s.note("the twenty minutes: three 720-block buckets of stake history")
# 2,200 not 2,160 — the ring is read at the CURRENT height, and a scenario that
# lands exactly on the boundary depends on which block its own transaction gets
# into. tm2 inserts a proof block whenever the app hash changed, so height is
# not predictable to the block (ruling O1); the margin absorbs that.
s.mine(2200, "answerWindow is 2,160 blocks and maturity needs all three buckets",
       with_time=True)  # ~3h of chain time, so the ladder reads honestly
s.stake(alice, "orem", 1, YES, 1_000_000)
s.stake(alice, "orem", 2, YES, 1_000_000)

s.note("both claims answered — the state no live run had ever reached")
s.answer(bob, "orem", 1, YES)
s.answer(bob, "orem", 2, YES)
s.expect("HasAnswer", ["orem", 1], "true")
s.expect("Answerer", ["orem", 1], "g1")

s.note("claim 2 disputed BEFORE the window closes — a sealed vote, mid-flight")
# OpenDispute refuses once settleSecs has passed (dispute.gno:27-29), so this
# has to happen before the advance below. The vote itself resolves on HEIGHT
# (votingBlocks = 120,960, ~3.4h of mining), so the claim stays mid-vote — which
# is exactly the state the page renders and nothing had ever served it live.
s.dispute(carol, "orem", 2)
s.expect("DisputeOpen", ["orem", 2], "true")

s.note("settle is wall-clock gated: 72 hours, crossed by moving the date")
s.advance(72 * 3600 + 60, "just past the settle window")
s.settle(alice, "orem", 1)
s.expect("Settled", ["orem", 1], "true")
s.expect("Verdict", ["orem", 1], "int")
s.expect("DisputeOpen", ["orem", 2], "true")
