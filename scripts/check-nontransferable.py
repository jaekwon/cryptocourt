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
# TWO patterns, because the inversion of this guard dropped coverage nobody
# replaced and it took an external review to notice.
#
# REPUTATION, which is what the inversion was for: an address's earned standing
# must not be movable.
SUSPECT = re.compile(
    r"^func (Assign|Migrate|Move|Set|Bequeath|Gift|Sell|Grant|Delegate|Transfer)"
    r"[A-Za-z0-9_]*(Record|Credential|Standing|Score|Reputation|Priority)"
    r"[A-Za-z0-9_]*\(cur realm",
    re.M,
)

# REDEMPTION, which the inversion silently stopped watching, guarded on the axis
# that actually matters: DENOMINATION, not verb names.
#
# The inversion added a required reputation-noun suffix, and `SellCC` and
# `RedeemForGNOT` both began to PASS — tested, they did. A verb list was the wrong
# instrument anyway: it trips on `WithdrawStake`, `WithdrawBonus` and V1's three
# `Redeem*` entrypoints, all of which return a holder's own CC INSIDE the court and
# touch no GNOT, while a genuine redemption could be called anything.
#
# What is existential is that no GNOT ever leaves this realm to a user. buy.gno
# says it ("the GNOT is BURNED ... nothing ever redeems") and REGULATIONS.md's whole
# position rests on it. GNOT can only move via a banker's SendCoins, so the property
# is checkable exactly: SendCoins appears in buy.gno ONLY, at a pinned count.
#
# kourtv2's two are the burn to the keyless sink and the buyer's dust change from
# the curve; kourtv1's one is its burn. A third in kourtv2, or a first anywhere
# else, is a redemption path and this refuses it.
SENDCOINS = re.compile(r"\bSendCoins\s*\(")
SENDCOINS_ALLOWED = {("kourtv1", "buy.gno"): 1, ("kourtv2", "buy.gno"): 2}

# Exact names both patterns would otherwise trip on. WithdrawStake and
# WithdrawBonus are the reason REDEEM needs a list at all: they return a holder's
# own CC inside the court and touch no GNOT.
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
            src = p.read_text()
            for m in SUSPECT.finditer(src):
                name = m.group(0)[len("func "):].split("(")[0]
                if name in ALLOWED:
                    continue
                line = src[: m.start()].count("\n") + 1
                hits.append(("reputation", realm, p.name, line, name))
            n = len(SENDCOINS.findall(src))
            want = SENDCOINS_ALLOWED.get((realm, p.name), 0)
            if n != want:
                hits.append(("GNOT leaves the realm", realm, p.name, 0,
                             f"{n} SendCoins call(s), expected {want}"))

    if hits:
        print("check-nontransferable: something that must not be movable "
              "appears to have become movable.\n", file=sys.stderr)
        for kind, realm, fname, line, name in hits:
            print(f"  [{kind}] {realm}/{fname}:{line}  {name}", file=sys.stderr)
        print("\nTwo properties are guarded here. An address's earned standing "
              "must not be movable. The coin is "
              "transferable by decision (TransferCC), but answerRecord is keyed "
              "by address with no Remove precisely so a credential cannot be "
              "sold — the answer-priority window and the difficulty record both "
              "price a CAREER, and a sellable one prices nothing. If this is "
              "intended, it is an owner decision: say so here and in "
              "MODERATION.md, and price rent-a-lead first.\n\nAnd no GNOT may "
              "leave the realm to a user: SendCoins belongs in buy.gno only, at "
              "the pinned count (the burn, plus the buyer's dust change). A new "
              "one anywhere is a redemption path, and \"the payment is burned, "
              "nothing ever redeems\" is the claim REGULATIONS.md rests on.",
              file=sys.stderr)
        return 1

    print(f"check-nontransferable: {scanned} realm files, no entrypoint moves "
          f"an address's record and none redeems CC for GNOT. Coin is "
          f"transferable between holders by decision; standing and the one-way "
          f"curve are not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
