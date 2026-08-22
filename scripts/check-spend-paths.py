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

TWO ARMS, because the promise has two halves.

  ADJACENCY — every `c.coin.Transfer(<who>, c.escrow, <amt>)` must be preceded,
  within a few lines, by `mustSpendable(c, <who>, <amt>)` or `mustStakable(c,
  <who>, <amt>)` for the SAME holder and the SAME amount. Same amount matters as
  much as same holder: sizing the check against one figure and the transfer
  against another is how the double-commit arrives with a guard sitting right
  above it. Escrow-to-holder transfers are payouts and are not spends, so they
  are skipped.

  CENSUS — the set of functions that call a spend guard must be exactly the set
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

Both arms refuse to pass vacuously: no transfers found, no guards found, or the
named test missing all mean the pattern has drifted off the code rather than
that the code is clean.
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
}

FUNC = re.compile(r"^func (?:\([^)]*\) )?([A-Za-z_]\w*)\(")

# The two spend guards. Both take (c, who, amount) and both panic.
GUARD = re.compile(r"\bmust(?:Spendable|Stakable)\(")
TRANSFER = re.compile(r"\bc\.coin\.Transfer\(")

# How far above a transfer its guard may sit. Three lines covers a guard, a
# comment and a blank; more than that and the two are not obviously a pair to a
# human reader either.
LOOKBACK = 3


def args_at(text, start):
    """Split the argument list of a call whose '(' is at `start`, respecting
    nesting so an amount like mulDiv128(a, b, c) stays one argument. Returns
    None when the parens do not close on this text."""
    depth, cur, out = 0, "", []
    for ch in text[start:]:
        if ch == "(":
            depth += 1
            if depth == 1:
                continue
        elif ch == ")":
            depth -= 1
            if depth == 0:
                out.append(cur)
                return [a.strip() for a in out]
        if depth == 1 and ch == ",":
            out.append(cur)
            cur = ""
        else:
            cur += ch
    return None


def calls(line, pattern):
    """Every (args) of `pattern` on this line, as lists of argument text."""
    found = []
    for m in pattern.finditer(line):
        a = args_at(line, m.end() - 1)
        if a is not None:
            found.append(a)
    return found


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

    spends, guards, bad = 0, 0, []
    callers = set()
    for p in files:
        lines = p.read_text().splitlines()
        fn = None
        for i, line in enumerate(lines):
            m = FUNC.match(line)
            if m:
                fn = m.group(1)
            hits = len(calls(line, GUARD))
            # The declarations themselves are not call sites.
            if hits and not line.startswith("func must"):
                guards += hits
                callers.add((p.name, fn))
            for a in calls(line, TRANSFER):
                if len(a) != 3:
                    bad.append((p.name, i + 1, line.strip(),
                                "the argument list did not parse as (from, to, amount)"))
                    continue
                src, dst, amt = a
                if dst != "c.escrow" or src == "c.escrow":
                    continue  # a payout, or not an escrow move at all
                spends += 1
                window = lines[max(0, i - LOOKBACK):i]
                ok = any([src, amt] == g[1:]
                         for w in window for g in calls(w, GUARD))
                if not ok:
                    bad.append((p.name, i + 1, line.strip(),
                                f"no mustSpendable/mustStakable(c, {src}, {amt}) "
                                f"in the {LOOKBACK} lines above"))

    if not spends or not guards:
        print(f"check-spend-paths: found {spends} escrow spend(s) and {guards} "
              f"spend guard(s); one of them being zero means this check is "
              f"scanning for a shape the realm no longer has.", file=sys.stderr)
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
        print("check-spend-paths: a holder's CC can leave their balance without "
              "being checked against what they have already committed.\n",
              file=sys.stderr)
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

    print(f"check-spend-paths: {spends} holder-to-escrow transfer(s) each guarded "
          f"on the lines above, and {len(callers)} spend path(s) all named in "
          f"SPEND_PATHS with a covering test that exists.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
