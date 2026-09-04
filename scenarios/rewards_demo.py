"""A claim walked to a rewardsOpened draw — with no blocks mined at all.

This file is the height override's receipt. It used to be `CI = False` and cost
roughly two hours, because `OpenRewards` is barred until block 17,280
(openrewards.gno, `priorityWindowBlocks`) and the only way to a block was to
produce one. It now runs in the ordinary suite, because the chain will happily
be TOLD the height.

WHAT EACH WAIT ACTUALLY IS, read from the realm rather than guessed:

  answerWindow          2,160 blocks  (answer.gno: 3 x epochBlocks) — the
                        trailing average must be mature before an answer.
  settleSecs               72 hours   (clock.gno) — wall-clock, so the calendar
                        half of the override handles it.
  priorityWindowBlocks 17,280 blocks  (court.gno, 24h) — the quiet window after
                        the last flag event; `lastFlagEventAt` is 0 on a claim
                        nobody flagged, so the gate reads `now < 17_280` in
                        ABSOLUTE height.

Total: ~19,440 blocks and three days, in about a dozen transactions.

WHAT IT DOES NOT CLAIM. The draw comes out ZERO on every slice, and that is
correct rather than a defect: `want` is clamped to `c.curPeriodBudget`
(openrewards.gno), which stays zero until a court's first `rollPeriod` at
`createdAt + periodBlocks` — 120,960 blocks. Advancing that far is now cheap
too, but a court with one claim has nothing to emit against, so a non-zero draw
needs a fuller scenario than this one. Stated here so a zero is read as the
chain's answer and not as a broken seed.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from scenario import Scenario, YES  # noqa: E402

s = SCENARIO = Scenario("rewards_demo", __doc__.split("\n\n")[0])

alice = s.account("alice", 900_000_000)
bob = s.account("bob", 900_000_000)

s.note("arm the clock — both halves of it")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=1780000000)

s.note("a court with real coin, and one claim staked")
s.court(alice, "orem", "Orem Truth Court")
s.buy(alice, "orem", 400_000_000)
s.buy(bob, "orem", 400_000_000)
s.claim(alice, "orem", "The county certified 12,412 mail ballots on Nov 6, 2025.")
# alice stakes and so is a PARTICIPANT, which is what lets her open the rewards
# without waiting out finalizeGraceBlocks. bob keeps his coin unstaked so he can
# post the answer bond — staked coin is committed and cannot back one.
s.stake(alice, "orem", 1, YES, 400_000_000)

s.note("ripen the trailing average — 2,160 blocks, one transaction")
s.advance_height(2200, "answerWindow, without producing a block")
s.stake(alice, "orem", 1, YES, 1_000_000)  # an observation in the new bucket
s.answer(bob, "orem", 1, YES)
s.expect("HasAnswer", ["orem", 1], "true")

s.note("settle: 72 hours on the calendar half")
s.advance(72 * 3600 + 60, "just past the settle window")
s.settle(alice, "orem", 1)
s.expect("Settled", ["orem", 1], "true")

s.note("the quiet window: 17,280 blocks, and this is the part that cost 2 hours")
s.expect_refuse(alice, "OpenRewards", ["orem", 1], "quiet window",
                note="the gate must REFUSE before the advance, or the test proves nothing")
s.advance_height(17300, "past priorityWindowBlocks")
s.call(alice, "OpenRewards", ["orem", 1])
s.expect("RewardsOpened", ["orem", 1], "true")
