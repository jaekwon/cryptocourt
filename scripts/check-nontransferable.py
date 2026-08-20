#!/usr/bin/env python3
"""Trip if REPUTATION ever becomes transferable.

INVERTED 2026-08-20. This script used to forbid the opposite: a court coin
becoming transferable between users. That was an owner call held open since v0.32,
and it has been decided the other way — `TransferCC` now exists, gated on
`spendable()` so committed capital cannot be sold out from under a live stake,
bond or deposit. Coin transfer is DELIBERATE and no longer a defect.

What must stay soulbound is the thing that was never really protected by the
coin's immobility: an address's earned standing. `answerRecord` is keyed by
address, has no `Remove`, and no path assigns one address's record to another —
and that property stands on its own, which is why it survives the coin becoming
tradeable. This guard now protects it directly instead of relying on a side
effect.

WHY THE OLD PATTERN WOULD NOT HAVE CAUGHT THIS. It matched coin-transfer verbs —
Transfer/Approve/TransferFrom/Delegate/Sell/Send/Gift. An entrypoint called
`AssignRecord`, `MigrateCredential`, `SetStanding`, `Bequeath` or `MoveScore`
would have sailed straight through while doing the one thing that must never be
possible. So the verb list is now about records, not coins.

WHAT THE INVERSION COST, recorded because it was real and is now load-bearing
again. The old docstring named three pieces of settled reasoning that assumed
transferability was false, and each is now live:

  - The v0.31 KEEP-NETTING ruling on electionFloor. Its refutation of the
    park-stake-to-cheapen-a-coup vector turned on an attacker being unable to
    acquire existing float. A secondary market restores that ability.
  - MODERATION.md's sybil doctrine. "Only capital-keyed defences hold" was
    stronger than it read while capital itself could not move between addresses;
    transferability lets one pile of capital back several identities in sequence.
  - Vote-buying. Conviction accrues to a holder over time, and while a coin could
    not change hands its accrued conviction could not be sold. Note the narrow
    consolation: conviction lives on `stakePos`, keyed (address, side), so selling
    coin does NOT carry conviction with it — only the future ability to earn it.

And the pricing consequence the owner accepted knowingly: the quorum floor, both
quality bars, the credential bar, the election floor and the supplyFloor lid are
all denominated in % of court supply, and were calibrated when the only way to
acquire supply was a one-way curve burning GNOT at a rising price. A secondary
market can clear below that, so those bars may now be cheaper to reach than when
their constants were chosen.

So: still a tripwire, not a rule. It no longer asserts that soulbound coin is
correct — it asserts that soulbound REPUTATION is, and that flipping THAT must be
a decision rather than an accident.
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
    r"^func (Assign|Migrate|Move|Set|Bequeath|Gift|Sell|Grant|Delegate|Transfer)"
    r"[A-Za-z0-9_]*(Record|Credential|Standing|Score|Reputation|Priority)"
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
        print("check-nontransferable: REPUTATION appears to have become "
              "transferable.\n", file=sys.stderr)
        for realm, fname, line, name in hits:
            print(f"  {realm}/{fname}:{line}  {name}", file=sys.stderr)
        print("\nAn address's earned standing must not be movable. The coin is "
              "transferable by decision (TransferCC), but answerRecord is keyed "
              "by address with no Remove precisely so a credential cannot be "
              "sold — the answer-priority window and the difficulty record both "
              "price a CAREER, and a sellable one prices nothing. If this is "
              "intended, it is an owner decision: say so here and in "
              "MODERATION.md, and price rent-a-lead first.", file=sys.stderr)
        return 1

    print(f"check-nontransferable: {scanned} realm files, no entrypoint moves "
          f"an address's record. Coin is transferable by decision; standing is "
          f"not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
