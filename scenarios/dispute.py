"""A dispute opened, voted and RESOLVED — with no blocks mined.

The most expensive gate in the realm. A dispute vote closes on HEIGHT:
`votingBlocks` is 120,960 (court.gno, one week at 5s a block), plus
`graceBlocks`. Before the height override, resolving one meant producing
138,240 blocks — measured at ~2 blocks per transaction and ~75 transactions a
minute, that is upwards of FIFTEEN HOURS. It is now two transactions.

This is the scenario the whole height override was for. `OpenRewards` (see
crystal.py) proved the realm's own gates move; this proves the PURE PACKAGES
move with them, which is the harder half: `p/governor` decides when a vote is
still "active" and `p/grc20votes` decides which epoch a vote weighs at, and
neither may import a realm. They read the height through the injected
`Electorate.Height()` — so if that injection were wrong, everything else could
fast-forward and a dispute would still sit open for ever.

QUORUM IS THE REASON THERE ARE FIVE BUYERS. `QuorumFloorOf` takes a max()
against 5% of supply, and a round that misses it FAILS rather than deciding —
which would look exactly like the height override not working. The stake is
sized so the cast weight clears the floor.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "scripts"))
from scenario import Scenario, YES  # noqa: E402

s = SCENARIO = Scenario("dispute", __doc__.split("\n\n")[0])

alice = s.account("alice", 900_000_000)
bob = s.account("bob", 900_000_000)
carol = s.account("carol", 900_000_000)
# dave and erin exist ONLY to vote. A participant — author, answerer, staker or
# disputer — may not vote on their own claim's verdict (dispute.gno), which the
# first run of this scenario discovered by being refused. So the voters must be
# holders who touched nothing else.
dave = s.account("dave", 900_000_000)
erin = s.account("erin", 900_000_000)

s.note("arm the clock")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=1780000000)

s.note("a court, and coin spread across three holders so a vote can reach quorum")
s.court(alice, "orem", "Orem Truth Court")
s.buy(alice, "orem", 400_000_000)
s.buy(bob, "orem", 400_000_000)
s.buy(carol, "orem", 400_000_000)
s.buy(dave, "orem", 400_000_000)
s.buy(erin, "orem", 400_000_000)

s.note("a claim, staked by alice only — bob and carol keep coin free for bonds")
s.claim(alice, "orem", "The county certified 12,412 mail ballots on Nov 6, 2025.")
s.stake(alice, "orem", 1, YES, 300_000_000)

s.note("ripen the answerability ring: 2,160 blocks, one transaction")
s.advance_height(2200, "answerWindow, without producing a block")
s.stake(alice, "orem", 1, YES, 1_000_000)
s.answer(bob, "orem", 1, YES)
s.expect("HasAnswer", ["orem", 1], "true")

s.note("carol disputes — she is not the answerer and her coin is unstaked")
s.dispute(carol, "orem", 1)
s.expect("DisputeOpen", ["orem", 1], "true")

s.note("votes cast while the round is open — by the two non-participants")
# The chain takes yes/no/abstain; "uphold" and "overturn" are the OVERLAY's
# words for them. The proposal asks "overturn the answer?", so a no upholds it.
s.vote(dave, "orem", 1, "no")
s.vote(erin, "orem", 1, "no")

s.note("THE POINT: close a week-long vote by telling the chain the height")
# votingBlocks (120,960) + graceBlocks. Sized generously — the scenario cannot
# predict real height (ruling O1) and only needs to be PAST the close.
s.advance_height(140_000, "votingBlocks + grace, in one transaction")
s.call(alice, "ResolveDispute", ["orem", 1])
s.expect("DisputeOpen", ["orem", 1], "false")

s.note("cross two emission periods — 241,920 blocks, for free")
# Two facts the first attempt here got wrong, both learned from the chain:
#   1. Advancing height does not itself roll a period. `rollPeriod` runs inside
#      `touch(c)`, so a TRANSACTION has to reach the court after the boundary.
#   2. The first roll only SETS `curPeriodBudget`; accrual is budget x blocks
#      elapsed, so a reservoir is still zero the instant it rolls.
# Hence: cross one boundary, touch, cross into the next, touch again.
# `Buy` is the touch: staking freezes once a claim has an answer (learned by
# being refused), and buy.gno:43 is the other cheap path through `touch(c)`.
s.advance_height(120_960, "one emission period")
s.buy(dave, "orem", 1_000_000)
s.advance_height(60_000, "half a period for the budget to accrue against")
s.buy(erin, "orem", 1_000_000)
# NOT asserting a non-zero Reservoir, and the reason is now measured rather than
# guessed: emission DOES accrue here — 376M over three periods on a bare court,
# see TestEmissionAccruesWithoutMining. `Reservoir` is the FREE-AND-CLEAR
# remainder, `reservoirR()` netting cumAccrual against reservedTail and
# juniorReserved, so a court with a live claim reserving against it reports zero
# while emission works perfectly. Asserting it here would have been a test that
# fails for a reason unrelated to what this scenario is for. What IS asserted is
# that: the chain really is 320,000 blocks further on, and nothing was mined.
s.expect("TestHeightPeakSkew", [], r"\(3[0-9]{5} int64\)")
s.expect("TestClockFabricated", [], "true")
