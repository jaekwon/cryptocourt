"""The association bond, on a real chain: who pays to connect two claims.

WHAT THIS IS FOR. `AddArgument` lets anybody say "claim 4 bears on claim 1", and
COURTS_STRUCTURE.md §5 says anybody still may. What changed is the price, and the
price is the whole story this file tells, in the order it happens:

  * a claim's own AUTHOR connects their own claim — pays nothing;
  * a MODERATOR connects two claims it did not write — pays nothing;
  * a STRANGER connects two claims — posts a refundable bond;
  * a moderator APPROVES one — the bond goes back and the edge stays;
  * a moderator DISAPPROVES another — the bond BURNS and the edge is dropped;
  * a griefer fills one claim with junk and a moderator clears it in ONE tx;
  * the mass APPROVE gives every bond back and leaves every edge standing.

WHAT IS ASSERTED, AND WHAT IS ONLY NARRATED. Every edge appearing and vanishing
is asserted against `ClaimArguments`, which is the read the claim page draws from.
The MONEY is narrated but not asserted, and the reason is a limitation of this
DSL rather than a choice: `Balance` takes an address, and `_args_sh` runs every
argument through `shlex.quote`, so a `$ACTOR_ADDR` would reach the chain as the
literal nine characters. Reading the balances back is a `gnokey query` away once
the node is up, and the plan prints the command.

ONE MODERATOR, SO m = 1, and that is worth saying plainly rather than leaving a
reader to wonder why the bulk burn fires on the first signature. `AppointMods`
takes addresses too, so this scenario cannot build the two-moderator set that
would show `DisapproveAllAssociations` waiting for a second key. That threshold is
pinned by TestTheBulkBurnTakesTwoSignaturesAndSparesWhatArrivedMidVote instead,
which also covers the part no demo can show: a bond posted BETWEEN the two
signatures is spared, because it has been judged by nobody.

WHY THE BOND IS REPRICED HERE. The realm default is 1 CC, and CC is bought with
GNOT along the court's curve, so the interesting figure would be buried in
curve arithmetic. The court's own moderators set it to 5 CC — which is itself one
of the two places the figure lives, so the demo exercises the override on the way
to needing it.

    scripts/seed-node.sh scenarios/assoc_demo.py

Not a CI scenario: it is a fixture to point a browser at.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from scenario import DEPLOYER, Scenario

s = Scenario("assoc", __doc__)

# The deployer starts the court, so it is the court's admin and — through
# ensureMod, which seeds the creator — its first and only moderator.
author = s.account("author", 500_000_000)
stranger = s.account("stranger", 500_000_000)
griefer = s.account("griefer", 500_000_000)

s.note("a court, whose creator moderates it because ensureMod seeds the creator")
s.court(DEPLOYER, "assoc", "The Association Court")

s.note("everybody buys court coin: the bond is CC, not GNOT")
for who in (DEPLOYER, "author", "stranger", "griefer"):
    s.buy(who, "assoc", 200_000_000)

s.note("the bond starts on the realm-wide default that every court inherits")
s.expect("AssociationBondDefault", [], r"1000000")
s.expect("AssociationBond", ["assoc"], r"1000000")

s.note("the second of the two places it lives: this court's moderator reprices it")
s._call(DEPLOYER, "SetCourtAssociationBond", ["assoc", "5000000"])
s.expect("AssociationBond", ["assoc"], r"5000000")
s.expect("AssociationBondDefault", [], r"1000000")  # the realm default is untouched

s.note("a stranger may not: repricing association is a moderator's act")
s.expect_refuse("stranger", "SetCourtAssociationBond", ["assoc", "1"],
                "not a moderator of this court")

s.note("four claims, all by one author, so every edge below crosses a real pair")
s.claim("author", "assoc", "The county certified 12,412 mail ballots on Nov 6, 2025.")
s.claim("author", "assoc", "The certification ran 9 days past the statutory deadline.")
s.claim("author", "assoc", "No court has ruled on the 2025 deadline extension.")
s.claim("author", "assoc", "The clerk's office logged 41 provisional ballots that week.")

# ---------------------------------------------------------------- free ----

s.note("THE AUTHOR CONNECTS THEIR OWN CLAIM AND PAYS NOTHING")
s._call("author", "AddArgument", ["assoc", "2", "1", "contests"])
s.expect("ClaimArguments", ["assoc", 1], r'in:2:c"')

s.note("A MODERATOR CONNECTS TWO CLAIMS IT DID NOT WRITE, AND PAYS NOTHING")
s._call(DEPLOYER, "AddArgument", ["assoc", "3", "2", "supports"])
s.expect("ClaimArguments", ["assoc", 2], r'out:1:c;in:3:s"')

# -------------------------------------------------------------- priced ----

s.note("A STRANGER CONNECTS TWO CLAIMS AND POSTS 5 CC — held in the court escrow")
s._call("stranger", "AddArgument", ["assoc", "4", "1", "supports"])
s.expect("ClaimArguments", ["assoc", 1], r'in:2:c,4:s"')

s.note("a moderator judges it worth carrying: APPROVE returns the bond, edge stays")
s._call(DEPLOYER, "ApproveAssociation", ["assoc", "4", "1"])
s.expect("ClaimArguments", ["assoc", 1], r'in:2:c,4:s"')

s.note("the same stranger connects another pair, so a second bond goes up")
s._call("stranger", "AddArgument", ["assoc", "4", "3", "contests"])
s.expect("ClaimArguments", ["assoc", 3], r'out:2:s;in:4:c"')

s.note("this one a moderator judges junk: DISAPPROVE burns it and drops the edge")
s._call(DEPLOYER, "DisapproveAssociation", ["assoc", "4", "3"])
s.expect("ClaimArguments", ["assoc", 3], r'out:2:s;in:"')

s.note("and neither judgement was ever the poster's to make")
s.expect_refuse("stranger", "ApproveAssociation", ["assoc", "2", "1"],
                "not a moderator of this court")

# --------------------------------------------------------------- bulk ----

s.note("A GRIEFER FILLS ONE CLAIM WITH JUNK: three bonded edges onto claim 4")
s._call("griefer", "AddArgument", ["assoc", "1", "4", "contests"])
s._call("griefer", "AddArgument", ["assoc", "2", "4", "contests"])
s._call("griefer", "AddArgument", ["assoc", "3", "4", "contests"])
s.expect("ClaimArguments", ["assoc", 4], r'in:1:c,2:c,3:c"')

s.note("ONE TRANSACTION CLEARS IT: three bonds burned, three edges dropped")
s._call(DEPLOYER, "DisapproveAllAssociations", ["assoc", "4", "coordinated junk"])
# Claim 4's own outbound 4->1 SURVIVES: its bond was approved, so it is no longer
# pending, and the sweep takes only what still holds one.
s.expect("ClaimArguments", ["assoc", 4], r'out:1:s;in:"')

s.note("the mass APPROVE is single-signer, because it only ever gives money back")
s._call("stranger", "AddArgument", ["assoc", "1", "3", "supports"])
s._call("stranger", "AddArgument", ["assoc", "2", "3", "supports"])
s.expect("ClaimArguments", ["assoc", 3], r'out:2:s;in:1:s,2:s"')
s._call(DEPLOYER, "ApproveAllAssociations", ["assoc", "3"])
s.expect("ClaimArguments", ["assoc", 3], r'out:2:s;in:1:s,2:s"')

s.note("read the balances back: gnokey query vm/qeval -data '...Balance(\"assoc\",ADDR)'")

SCENARIO = s
CI = False
