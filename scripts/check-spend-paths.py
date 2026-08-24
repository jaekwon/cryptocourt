#!/usr/bin/env python3
"""Every path that takes CC out of a holder's balance must size itself against
what that holder has already committed, and must name the test that proves it.

lock.gno's header states this rule and states the risk in the same breath:

    Custody made double-committing arithmetically impossible. The coins
    physically left the balance, so the LEDGER refused the second spend,
    automatically and on every path, including paths nobody thought about. A
    lock does not [...] Stake 100, then post a 100 bond against the same 100 —
    the bond transfer succeeds, and at unstake the realm owes 100 CC it does not
    hold and would have to MINT to return, which breaks supply conservation.
    That is the one invariant a token cannot lose.

Then it says how the rule is kept: "every path that moves a user's CC into the
escrow sizes itself against `spendable`, never against `BalanceOf`, and there is
a test that stakes a whole balance and then tries to bond it
(TestLockedStakeCannotBeSpentTwice). If a new spend path is ever added, it
belongs in that test too."

WHY A SCRIPT AND NOT A TEST. That last sentence is a promise made to whoever
reads the header, and nothing enforced it. Measured when this was written the
promise was being kept exactly: EIGHT spend paths in the realm, all five of the
holder-to-escrow transfers guarded on the IMMEDIATELY preceding line, the six
escrow paths carrying an arm each in TestLockedStakeCannotBeSpentTwice and the
two holder-to-holder ones proved by tests of their own. The rule was not being
broken; it was unenforced, which is a different problem and the one that
outlives the current contributors.

The failure mode is silent and it ends in a mint: a ninth path is added, nobody
adds its proof, and the suite stays green because a test can only ever assert
about the paths it names. Custody used to make this structural — the coins left
the balance, so the LEDGER refused the second spend on every path including the
ones nobody thought about. A lock cannot do that. Only a structural check can.

ADJACENCY IS NOT CHECKED HERE, AND THIS FILE ONCE DID CHECK IT. That was a
duplicate: check-epoch-coherence.py ARM 7 already requires every user-sourced
coin movement to be immediately preceded by a gate, with the same
`must(?:Spendable|Stakable)\\(` regex and the same three-line lookback, plus a
pinned count of seven such movements. Its version is strictly better — it covers
Burn as well as Transfer, and any Court receiver (c, mc, c2, m, c3), where the
copy here matched only `c.coin.Transfer(`; ARM 7's own comments record fixing
both of those blind spots, calling the narrow regex out as having "assumed a
spelling the file already contradicts elsewhere". The copy was written without
grepping the guards for the policy first, and two implementations of one rule is
how the second one comes to disagree with the first. Deleted, with the rule left
where it was already enforced.

WHAT IS LEFT IS THE HALF NOTHING ELSE PINS: the CENSUS — the set of functions that call a spend guard must be exactly the set
  named in SPEND_PATHS below, each mapped to the test that proves its refusal.
  This is the arm that catches the new path: adding one makes the tree and the
  map disagree, and the only way to make it agree is to name the test that
  covers it. A COUNT was the first design and it was worse. The obvious count is
  against the `// PATH n` arms in TestLockedStakeCannotBeSpentTwice, and it fires
  on correct code, because two of the eight spend paths are not in that test and
  should not be: TransferCC and TransferFromCC move coin holder-to-holder rather
  than into the escrow, and their refusals are proved by three tests of their
  own. The map records where each proof actually lives, which is the thing a
  reader wants and a count cannot say.

  Counting GUARD CALLERS rather than transfers is also deliberate: the stake path
  locks in place instead of transferring (that is the whole point of lock.gno),
  so it has a guard but no transfer, and a census over transfers would miss it.

  ARM 7 makes a new outflow get LOOKED AT, by failing its count. It does not make
  the new path get a TEST, which is the thing lock.gno's header actually promises.
  That is the gap this file fills, and the reason it survives as its own check
  rather than folding into that one.

The census refuses to pass vacuously: no guards found, or a named test missing,
both mean the pattern has drifted off the code rather than that the code is clean.

votelock.gno's header states the same census independently — "All SEVEN
mustSpendable call sites move coin OUT of the holder's balance", enumerating them,
with Stake the single mustStakable exemption. Seven plus one is the eight below, so
the number here is one the design commits to in two places.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"

# Every function that may take CC out of a holder's balance, and the test that
# proves it refuses to dip into a lock. Adding a spend path means adding a line
# here, which means deciding which test covers it — that decision being forced is
# the point of this file.
#
# The first six are the `// PATH n` arms of TestLockedStakeCannotBeSpentTwice,
# which stakes a whole balance and then tries to commit it six ways and ends on
# the supply-conservation assertion. The last two are holder-to-holder and are
# proved separately, one test per lock, because a transfer is refused by the
# stake lock and the vote lock independently.
SPEND_PATHS = {
    ("claim.gno", "openClaim"): "TestLockedStakeCannotBeSpentTwice",
    ("answer.gno", "PostAnswer"): "TestLockedStakeCannotBeSpentTwice",
    ("quality.gno", "OpenFlag"): "TestLockedStakeCannotBeSpentTwice",
    ("dispute.gno", "OpenDispute"): "TestLockedStakeCannotBeSpentTwice",
    ("modvote.gno", "addNomination"): "TestLockedStakeCannotBeSpentTwice",
    ("stake.gno", "Stake"): "TestLockedStakeCannotBeSpentTwice",
    ("lock.gno", "TransferCC"): "TestStakedCoinCannotBeTransferred",
    ("lock.gno", "TransferFromCC"): "TestAnAllowanceDoesNotOutrankALock",
    ("association.gno", "AddAssociation"): "TestLockedStakeCannotBeSpentTwice",
}

# The test lock.gno's header names: "there is a test that stakes a whole balance
# and then tries to bond it ... If a new spend path is ever added, it belongs in
# that test too." The refusal below quoted this by name and the name did not
# exist, so the message crashed with a NameError instead of printing — found by
# adding the first new spend path since it was written.
CENSUS_TEST = "TestLockedStakeCannotBeSpentTwice"

FUNC = re.compile(r"^func (?:\([^)]*\) )?([A-Za-z_]\w*)\(")

# The two spend guards. Both take (c, who, amount) and both panic.
GUARD = re.compile(r"\bmust(?:Spendable|Stakable)\(")




def sources():
    return sorted(p for p in REALM.glob("*.gno")
                  if not p.name.endswith("_test.gno") and "filetest" not in p.name)


def main():
    repolock.refuse_if_held("check-spend-paths")

    files = sources()
    if not files:
        print("check-spend-paths: no kourtv2 sources found; the realm moved.",
              file=sys.stderr)
        return 1

    guards, bad = 0, []
    callers = set()
    for p in files:
        fn = None
        for line in p.read_text().splitlines():
            m = FUNC.match(line)
            if m:
                fn = m.group(1)
            hits = len(GUARD.findall(line))
            # The declarations themselves are not call sites.
            if hits and not line.startswith("func must"):
                guards += hits
                callers.add((p.name, fn))

    if not guards:
        print("check-spend-paths: found no spend guards at all, so this check is "
              "scanning for a shape the realm no longer has.", file=sys.stderr)
        return 1

    tests = "\n".join(p.read_text() for p in REALM.glob("*_test.gno"))
    for (f, fn), want in sorted(SPEND_PATHS.items()):
        if (f, fn) not in callers:
            bad.append((f, 0, f"func {fn}",
                        "SPEND_PATHS names this as a spend path but it no longer "
                        "calls a spend guard — either the guard was dropped or "
                        "this line is stale"))
        if f"func {want}(" not in tests:
            bad.append((f, 0, f"func {fn}",
                        f"its covering test {want} does not exist; a census "
                        f"pointing at nothing is worse than no census"))
    for f, fn in sorted(callers):
        if (f, fn) not in SPEND_PATHS:
            bad.append((f, 0, f"func {fn}",
                        "a NEW spend path: it takes CC out of a holder's balance "
                        "and is not in SPEND_PATHS. Add it there with the test "
                        "that proves it refuses to dip into a lock"))

    if bad:
        print("check-spend-paths: a spend path has no proof that it refuses to "
              "dip into a lock.\n", file=sys.stderr)
        for name, line, src, why in bad:
            where = f"{name}:{line}" if line else name
            print(f"  {where}: {src}\n      {why}", file=sys.stderr)
        print(f"\nStaked CC stays in the holder's balance, so the ledger cannot "
              f"refuse a second commitment of the same coins — only this realm "
              f"can, and only if every spend path asks. A path that does not ask "
              f"leaves the realm owing CC it does not hold, which it can settle "
              f"only by MINTING. Size the path against spendable() via "
              f"mustSpendable/mustStakable, and give it an arm in {CENSUS_TEST} "
              f"(lock.gno's header: \"If a new spend path is ever added, it "
              f"belongs in that test too\").", file=sys.stderr)
        return 1

    print(f"check-spend-paths: {len(callers)} spend path(s) ({guards} guard call "
          f"site(s)) all named in SPEND_PATHS with a covering test that exists.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
