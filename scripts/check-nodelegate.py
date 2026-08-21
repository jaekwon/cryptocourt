#!/usr/bin/env python3
"""Trip if a court coin ever gains a DELEGATE entrypoint.

Vote weight in kourtv2 is the voter's LIVE BalanceOf, and voting locks that coin
against transfer until the round closes (VOTELOCK.md). Renting weight therefore
requires selling it back, which is the one thing the lock forbids.

DELEGATION WOULD ROUTE STRAIGHT AROUND THAT, and this guard is the only thing
standing in the way. grc20votes supports it: `VotesOf(who)` returns `a.votes`,
which includes power delegated IN. So if a court coin ever exposed `Delegate`:

  1. the delegator hands power to a delegate,
  2. the delegate votes with it — and the lock lands on the DELEGATE's coin,
  3. the delegator, unlocked, sells.

Rented weight again, and cheaper than the vector this replaced, because it needs
no epoch of holding at all.

Two things keep it shut, and neither is sufficient alone. The vote lanes read
BalanceOf rather than VotesOf, so delegated-in power does not count even if it
exists — that is the real defence. And this guard refuses the entrypoint, so
nobody adds one believing the weighting will follow along. Delete either and the
hole is a two-line change away.

If delegation is genuinely wanted, the weighting has to be redesigned first: the
lock would have to reach the delegator's coin, which means the realm needs to
know who delegated to whom and lock all of them. That is a design, not a patch.
Read VOTELOCK.md, decide it, then change this file.

Note r/govern DOES expose Delegate and keeps the snapshot weighting. That is not
an inconsistency to tidy up — it is why the governor grew VoteWithWeight instead
of having its default changed.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"

# Any exported entrypoint whose name suggests moving voting power to another
# address. Deliberately wider than the literal `Delegate`: the point is to catch
# the CAPABILITY under whatever name it arrives, the same way
# check-nontransferable.py had to be widened past coin verbs.
SUSPECT = re.compile(
    r"^func (Delegate|Undelegate|Redelegate|Assign|Lend|Proxy|Grant|Appoint)"
    r"[A-Za-z0-9_]*(Vote|Voting|Power|Weight|Delegat)?[A-Za-z0-9_]*"
    r"\(cur realm",
    re.M,
)

# Exact names that are NOT voting-power delegation and never will be. Kept as an
# exact list rather than a pattern so a new name has to be added deliberately.
ALLOWED = {
    "AppointMods",       # moderation set installation, not voting power
    "GrantGlobalAdmin",  # role transfer, carries no weight
}


def main() -> int:
    repolock.refuse_if_held("check-nodelegate")
    files = [p for p in sorted(REALM.glob("*.gno"))
             if not p.name.endswith("_test.gno")]
    if not files:
        # FAIL CLOSED. A silent zero here would report success forever, which is
        # the shape that let another check in this repo sweep 39% of the suite
        # while claiming a clean run. An absence check with nothing to scan is
        # measuring nothing, and that has to be an error rather than a pass.
        print(f"check-nodelegate: no .gno files under {REALM}; the layout moved "
              f"and this check is measuring nothing.", file=sys.stderr)
        return 1
    hits, scanned = [], 0
    for path in files:
        scanned += 1
        src = path.read_text()
        for m in SUSPECT.finditer(src):
            name = src[m.start() + len("func "):].split("(")[0]
            if name in ALLOWED:
                continue
            line = src[: m.start()].count("\n") + 1
            hits.append(f"{path.parent.name}/{path.name}:{line}  {name}")

    if hits:
        print("check-nodelegate: a court coin appears to have gained a way to "
              "delegate voting power.\n", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        print("\nVote weight is the LIVE balance and voting locks it against "
              "transfer. Delegation breaks that: the lock lands on the "
              "delegate's coin while the delegator's stays free to sell, which "
              "is rented weight with no holding period at all. Closing it means "
              "locking every delegator too — a design, not a patch. Read "
              "VOTELOCK.md, decide it, then change this check.", file=sys.stderr)
        return 1

    print(f"check-nodelegate: {scanned} realm files, no way to delegate voting "
          f"power. Live-weight voting stays rental-proof.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
