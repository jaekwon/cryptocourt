"""A small court, told as a story: the CI-sized scenario.

Deliberately does NOT answer a claim. Answering needs ~2,160 blocks of stake
history (answerWindow = 3 * epochBlocks) at ~103ms a block — about 3.7 minutes,
which is a fifth of the whole txtar budget for one file. Everything here runs
under ~30 seconds and still exercises the parts that only a real chain can
prove: the clock latch, real GNOT burned into court coin, staking, moderation,
folders, and — the point of the test clock — a deadline crossed by moving the
date rather than by waiting for it.

The seeded demo (a longer scenario, run by hand) is where answering, settling
and crystallizing belong, because there the 3.7 minutes buys real conviction.
"""

import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import Scenario, YES, NO, DEPLOYER

s = Scenario("smoke", __doc__)

alice = s.account("alice", 500_000_000)
bob = s.account("bob", 500_000_000)

s.note("arm the clock — deployer only, and only while the realm is pristine")
s.expect("TestClockActive", [], "false")
s.arm_clock(at=1_780_000_000)          # a fixed base: dates are then a pure
s.expect("TestClockActive", [], "true")  # function of this file
s.expect("TestClockSkew", [], r"\(0 int64\)")

s.note("a stranger may not drive it, and the chain says so in a block")
s.expect_refuse("alice", "AdvanceTestClock", [3600], "only the deployer may drive",
                note="not merely refused by the simulator: -simulate skip proves the chain refuses")

s.note("a court, and real GNOT burned into its coin")
s.court(DEPLOYER, "orem", "Orem Truth Court")
s.expect("TestClockActive", [], "true")   # creating a court must NOT disarm it
s.buy("alice", "orem", 50_000_000)
s.buy("bob", "orem", 50_000_000)
s.expect("CoinSupply", ["orem"], r"int64")

s.note("two claims and stake on both sides")
s.claim("alice", "orem", "The county certified 12,412 mail ballots on Nov 6, 2025.")
s.claim("bob", "orem", "The Center St. bridge inspection was completed in 2025.")
# ClaimCount returns nextID, which is pre-incremented (claim.gno:276-277), so
# it equals the highest id issued: 2 after two claims, not 3.
s.expect("ClaimCount", ["orem"], r"\(2 uint64\)")
s.stake("alice", "orem", 1, YES, 40_000_000)
s.stake("bob", "orem", 1, NO, 12_000_000)
s.stake("bob", "orem", 2, YES, 9_000_000)
s.expect("StakePools", ["orem", 1], r"40000000")

s.note("moderation is listing-level: hidden from lists, reachable by id")
s.hide(DEPLOYER, "orem", 2, "off-topic pending review")
s.expect("HiddenFromListing", ["orem", 2], "true")
s.expect("ClaimCount", ["orem"], r"\(2 uint64\)")   # the claim still exists

s.note("folders are real chain state (flat; nesting lives in the overlay)")
s.folder(DEPLOYER, "orem", "Municipal record", "Filings, audits, inspections.")
s.folder_add(DEPLOYER, "orem", 1, 1)
s.expect("FolderItems", ["orem", 1], r"1")

s.note("the whole point: cross a deadline by moving the date, not by waiting")
s.expect_refuse("alice", "CloseDeadClaim", ["orem", 1],
                "dead-claim timeout has not passed")
s.advance(12 * 7 * 86400 - 1, why="one second short of the 12-week timeout")
s.expect_refuse("alice", "CloseDeadClaim", ["orem", 1],
                "dead-claim timeout has not passed",
                note="the boundary is the assertion: a frozen clock can sit exactly here")
s.advance(2, why="over the line")
s.call("alice", "CloseDeadClaim", ["orem", 1])
s.expect("ClaimClosed", ["orem", 1], "true")

s.note("a handful of blocks, to prove height moves independently of the date")
s.mine(5, why="cheap: the ring maturity a real answer needs is 2,160")

SCENARIO = s
