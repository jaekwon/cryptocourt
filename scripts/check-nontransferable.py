#!/usr/bin/env python3
"""Trip if a court coin ever becomes transferable between two user addresses.

CC is currently mint-only, escrow-only, burn-only: every `coin.Transfer` call
site in the realm has the escrow account as its source or its destination, the
exported write surface has no Transfer/Approve/TransferFrom/Delegate, and the
bonding curve is one-way so there is no burn-for-GNOT exit. A court coin is
effectively soulbound, and it has been in both V1 and V2 from the start.

That is NOT what MODERATION.md says. The document records "meta-CC stays
transferable" as an owner call, and the capture analysis reasons explicitly that
transferable coins let an attacker resell the franchise and that transferability
is what enables the cheap-float capture route. So the spec and the code disagree,
the disagreement is recorded in the v0.32 changelog entry, and the resolution is
the owner's to make.

This script exists because of which DIRECTION that gap is dangerous in. Today it
errs safe: the constants were chosen against a resale threat the code does not
expose, so they are conservative. The hazard is the reverse — the day somebody
adds a transfer entrypoint, a pile of already-settled reasoning silently becomes
load-bearing again, and nothing in the test suite would notice, because adding a
feature does not break tests that never imagined it.

What specifically has to be re-opened, and why each one needs transferability to
be false:

  - The v0.31 KEEP-NETTING ruling on electionFloor. The refutation of the
    park-stake-to-cheapen-a-coup vector turns on an attacker being unable to
    acquire existing float: with no secondary market they can only park their own
    CC, which is monotonically self-defeating. A transferable coin restores the
    secondary market and reopens the question.
  - The sybil doctrine at the top of MODERATION.md. "Only capital-keyed defences
    hold" is stronger than it reads while the capital itself cannot move between
    addresses; transferability is what lets one pile of capital back several
    identities in sequence.
  - Vote-buying generally. Conviction accrues to a holder over time, and a coin
    that cannot change hands cannot have its accrued conviction sold.

So: a tripwire, not a rule. It is not asserting that soulbound is correct — it is
asserting that the choice is currently soulbound and that flipping it must be
deliberate. If the owner decides to ship transfer, the fix is to work through the
list above and then delete this file, which is the point.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALMS = ["kourtv1", "kourtv2"]

# An exported entrypoint whose name says it moves value between holders. Matched
# on the exported surface only: unexported helpers are this realm's own business,
# and the escrow-to-user refunds are exactly what the realm is supposed to do.
SUSPECT = re.compile(
    r"^func (Transfer|Approve|TransferFrom|Delegate|Sell|Send|Gift)"
    r"[A-Za-z0-9_]*\(cur realm",
    re.M,
)

# Exported names that match the pattern and move no coins:
#   TransferGlobalAdmin  — hands over an admin role.
#   ApproveCandidate     — casts a ballot approval in a moderator election.
#   ApproveRetain        — the same, for the retain line.
# Excluded by exact name rather than by narrowing the pattern, so that a genuine
# ERC20-style `Approve`, or a future `ApproveSpender`/`TransferAnythingElse`,
# still trips. A tripwire that stops catching things is worse than none.
ALLOWED = {"TransferGlobalAdmin", "ApproveCandidate", "ApproveRetain"}


def main() -> int:
    repolock.refuse_if_held("check-nontransferable")
    scanned, hits = 0, []
    for realm in REALMS:
        d = ROOT / "realm" / "r" / realm
        files = [p for p in sorted(d.glob("*.gno")) if not p.name.endswith("_test.gno")]
        if not files:
            # A silent zero here would make this check report success forever.
            print(f"check-nontransferable: no .gno files under {d}; the layout "
                  f"moved and this check is measuring nothing.", file=sys.stderr)
            return 1
        for p in files:
            scanned += 1
            for m in SUSPECT.finditer(p.read_text()):
                name = m.group(0)[len("func "):].split("(")[0]
                if name in ALLOWED:
                    continue
                line = p.read_text()[: m.start()].count("\n") + 1
                hits.append((realm, p.name, line, name))

    if hits:
        print("check-nontransferable: a court coin appears to have become "
              "transferable.\n", file=sys.stderr)
        for realm, fname, line, name in hits:
            print(f"  {realm}/{fname}:{line}  {name}", file=sys.stderr)
        print("\nCC has been mint-only/escrow-only/burn-only since V1, and a "
              "pile of settled reasoning rests on that — the v0.31 KEEP-NETTING "
              "ruling on electionFloor, the capital-keyed sybil doctrine, and "
              "the un-sellability of accrued conviction. Read the v0.32 entry "
              "in MODERATION.md, work through that list, then delete this "
              "check.", file=sys.stderr)
        return 1

    print(f"check-nontransferable: {scanned} realm files, no user-to-user coin "
          f"transfer entrypoint. The v0.31 electionFloor ruling and the "
          f"capital-keyed sybil doctrine still hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
