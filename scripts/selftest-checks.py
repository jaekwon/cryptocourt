#!/usr/bin/env python3
"""Break things on purpose and check that the checkers notice.

A guard reporting success while measuring nothing is indistinguishable, from
the outside, from a guard that works. Every one in scripts/ is capable of it,
in a specific way:

  check-citations exempting a citation that names a file in its own scope —
  the exact class it exists for, exempted by name. Or failing to see a gno-tree
  file NAMED in the prose and never given a row, so a claim is exempt from the
  guard by never having been registered with it.

  check-storage reading the phrase "build errors", which matches the ordinary
  summary line "0 build errors, 1 test errors", so every catch from a filetest
  reads as a mutation that never compiled.

  mutate.py counting a mutation whose anchor matched zero times as a survivor,
  counting a mutant that could not build as a catch, or reporting every
  mutation as caught because the suite was already failing.

  A realm test passing only in company — needing a kind a neighbour registered,
  or asserting a literal epoch that only predates its holder because a
  neighbour moved the clock.

None of those are visible by reading the code. Each is found by breaking
something and noticing the guard stays quiet — and an ad-hoc control is
precisely the step that gets skipped when the guard is already green.

So the controls live here. Each one edits a copy, runs the guard, requires the
expected complaint, and puts the original back.

    python3 scripts/selftest-checks.py

Needs a gno toolchain for the storage arms; skips them without one, and says so
rather than passing quietly.
"""

import atexit
import glob
import json
import os
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import repolock  # noqa: E402

# This run rewrites the working tree, one guard at a time. Announce it so a
# concurrent `make check` refuses instead of reporting our breakage as its own.
_treelock = repolock.hold().__enter__()
# Release on ANY exit, including a failing run. Without this the lockfile
# outlives the process and the next reader has to notice the pid is dead before
# it will proceed — correct, but it makes a stale lock the normal case.
atexit.register(_treelock.__exit__, None, None, None)
os.chdir(REPO)

failures = []


# Which guards a control has actually been pointed at this run. Compared
# against scripts/check-*.py at the end, because this file naming its guards
# one by one is the same opt-in coverage that let a citation go unregistered
# and a filetest go unbudgeted: a new guard with no control would sail through
# a green self-test, which is the one outcome a self-test must never produce.
exercised = set()


def control(label, path, find, replace, want, argv=None, stdin=None, cwd=None):
    """Apply an edit, run the guard, and require `want` in its output."""
    for a in (argv or ["python3", "scripts/check-citations.py"]):
        if a.endswith(".py"):
            exercised.add(os.path.basename(a))
    backup = path + ".selftest-backup"
    shutil.copy(path, backup)
    try:
        src = open(path).read()
        n = src.count(find)
        if n != 1:
            print(f"  {label:<44} BROKEN CONTROL (anchor matched {n}x)")
            failures.append(label)
            return
        open(path, "w").write(src.replace(find, replace))
        r = subprocess.run(argv or ["python3", "scripts/check-citations.py"],
                           capture_output=True, text=True, input=stdin, cwd=cwd)
        out = r.stdout + r.stderr
        if want in out:
            print(f"  {label:<44} fires")
        elif r.returncode == 0:
            print(f"  {label:<44} SILENT — the guard did not notice")
            failures.append(label)
        else:
            # It DID complain, about something else. Both are failures, but they
            # need OPPOSITE fixes: silent means the guard has a hole, wrong
            # complaint means this control's expected text went stale while the
            # guard got better. Reporting the second as "SILENT" sends you
            # looking for a hole that is not there — measured, on the arm-3
            # retarget, which fired correctly and was reported as blind. So
            # print what it actually said rather than only that it missed.
            said = next((l.strip() for l in out.splitlines() if l.strip()), "")
            print(f"  {label:<44} FIRED, WRONG COMPLAINT")
            print(f"  {'':<44}   wanted: {want!r}")
            print(f"  {'':<44}   said:   {said[:100]!r}")
            failures.append(label)
    finally:
        shutil.move(backup, path)


def feed(label, mutations, want):
    """Run mutate.py on a mutation spec and require `want` in its verdict."""
    r = subprocess.run(["python3", os.path.join(REPO, "scripts/mutate.py")],
                       capture_output=True, text=True,
                       input=json.dumps(mutations),
                       cwd=os.path.join(REPO, GOVERN))
    out = r.stdout + r.stderr
    if want in out:
        print(f"  {label:<44} fires")
    else:
        print(f"  {label:<44} SILENT — the guard did not notice")
        failures.append(label)


def have_gno():
    try:
        r = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                           text=True, timeout=30)
        return bool(r.stdout.strip())
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


CITE = "scripts/check-citations.py"
STORE = "scripts/check-storage.py"
NONTRANS = "scripts/check-nontransferable.py"
EPOCHCOH = "scripts/check-epoch-coherence.py"
MEMCLEAR = "scripts/check-membership-clears.py"
READPURE = "scripts/check-read-purity.py"
SPENDPATH = "scripts/check-spend-paths.py"
ABORTASRT = "scripts/check-abort-assertions.py"
PATHS = "scripts/check-paths.py"
ANCHORS = "scripts/check-mutation-anchors.py"
MUTS = "scripts/mutations-kourtv2.json"
PHYSICS = "scripts/check-demo-physics.py"
HSHIM = "scripts/check-height-shim.py"
LIVER = "scripts/check-live-reads.py"
NODELEG = "scripts/check-nodelegate.py"
DUPES = "scripts/check-web-dupes.py"
WEBCSS = "scripts/check-web-css.py"
WEBSEL = "scripts/check-web-selectors.py"
BROWREG = "scripts/check-browser-checks-registered.py"
REACH = "scripts/check-web-tests-reachable.py"
CURREACH = "scripts/check-curation-reachable.py"
FOLDERSJS = "web/tests/folders_test.js"
RUNJS = "web/tests/browser/run.js"
CHATALL = "web/tests/browser/chat_all.js"
WEBPAGE = "web/index.html"
SELF = "scripts/selftest-checks.py"
ARMED = "scripts/check-guards-armed.py"
STALEG = "scripts/check-stale-guards.py"
BUY = "realm/r/kourtv2/buy.gno"
STAKE = "realm/r/kourtv2/stake.gno"
COURT = "realm/r/kourtv2/court.gno"
CLOCKF = "realm/r/kourtv2/clock.gno"
TWAP = "realm/p/twap/twap.gno"
TCLOCK = "realm/r/kourtv2/testclock.gno"
SEEDED = "gnoland/testdata/kourtv2_usedrealm_seeded.txtar"
GOVERN = "realm/r/govern"
KOURTV2 = "realm/r/kourtv2"
GOVERNORDIR = "realm/p/governor"
CCWRAP = "realm/r/ccwrap"
GRC20VOTESDIR = "realm/p/grc20votes"
GRC20VOTES = "realm/p/grc20votes"
VOTES = "realm/p/grc20votes"

print("check-citations")
control("an anchor that no longer matches", CITE,
        'r"LastObjectSize", "LastObjectSize"',
        'r"LastObjectSizeGone", "LastObjectSize"', "MOVED")
control("a file that has been renamed", CITE,
        '("gnovm/pkg/gnolang/store.go",\n     r"LastObjectSize", "LastObjectSize"',
        '("gnovm/pkg/gnolang/store_gone.go",\n     r"LastObjectSize", "LastObjectSize"', "GONE")
control("a manifest row nothing quotes", CITE,
        "CITATIONS = [\n",
        'CITATIONS = [\n    ("gnovm/pkg/gnolang/store.go", r"func ", "NoProseSaysThis", "x"),\n',
        "UNUSED")
control("a gno-tree file nobody cited", f"{GOVERN}/errors.gno",
        "package govern\n",
        "package govern\n\n// see `nobody_cited_this.gno` for the rule\n",
        "UNCITED")
control("a newly written file:line citation", f"{GOVERN}/errors.gno",
        "package govern\n",
        "package govern\n\n// see governor.gno:275\n", "line-number citation")
# The .txtar scope, which the guard did not have until the two usedrealm files
# were written with three line-number citations in them. This arm is what keeps
# that scope: drop ".txtar" from sources() again and it goes silent while every
# other citation arm keeps passing.
control("a file:line citation inside a txtar", SEEDED,
        "# A realm used WITHOUT MONEY is not a virgin realm either.",
        "# A realm used WITHOUT MONEY is not a virgin realm either.\n"
        "# see testclock.gno:110 for the gate",
        "line-number citation")

print("\ncheck-nontransferable")
# The guard is a tripwire on an ABSENCE — no exported entrypoint moves a court
# coin between two user addresses — and an absence check is the easiest kind to
# write so that it can never fire. Both arms exist because both failure modes
# are live: the thing it watches for actually appearing, and the guard losing
# sight of the tree it is supposed to be watching.
# INVERTED with the guard, and it had been silently dead since: the control
# planted a coin Transfer, which the guard PERMITS now that court coins are
# transferable by decision, so it could never fire again. Two arms now, one per
# property the guard actually watches.
control("reputation that became transferable", f"{KOURTV2}/records.gno",
        "func AnswerRecord(courtSlug string, who address) int {",
        "func AssignRecord(cur realm, courtSlug string, to address) {}\n\n"
        "func AnswerRecord(courtSlug string, who address) int {",
        "must not be movable appears to have become movable",
        argv=["python3", NONTRANS])
# The redemption arm. A verb list was the wrong instrument — it tripped on
# WithdrawStake and V1's Redeem* while a real redemption could be called anything
# — so the guard pins SendCoins to buy.gno at an exact count. This plants one
# elsewhere, which is what a CC-to-GNOT path would have to do.
control("a path that sends GNOT back to a user", f"{KOURTV2}/records.gno",
        "func AnswerRecord(courtSlug string, who address) int {",
        "func Payout(cur realm) { b.SendCoins(cur.Address(), to, x) }\n\n"
        "func AnswerRecord(courtSlug string, who address) int {",
        "must not be movable appears to have become movable",
        argv=["python3", NONTRANS])
# Fail CLOSED, not open. This is the shape that let check-isolation sweep 39% of
# the suite while reporting success: a scope list that no longer resolves must be
# an error, never an empty scan reported as a clean one.
control("a guard that lost the tree it watches", NONTRANS,
        'REALMS = ["kourtv1", "kourtv2"]',
        'REALMS = ["kourtv9_moved"]',
        "measuring nothing",
        argv=["python3", NONTRANS])

print("\ncheck-epoch-coherence")
# The guard that would have caught the reverted live-weight work on its FIRST
# commit, before a test ran. Every bar in this realm is frozen so it cannot move
# under an open vote; a live numerator against a frozen bar gave turnout at
# 200-400% of its own bar in several lanes, and a supplied weight voided the
# governor's `rest` contract outright. Three arms, three controls, plus fail-closed.
# The tally files hold no live read at all now — the expression lives in
# voteweight.gno — so this plants one where arm 1 pins zero.
control("a live weight read reached a tally file", f"{KOURTV2}/quality.gno",
        "w, snapshot := votingWeight(c, who, cs.qualityEpoch)",
        "w, snapshot := c.coin.BalanceOf(who), c.coin.BalanceOf(who)",
        "live weight read(s) in a file that decides by weight",
        argv=["python3", EPOCHCOH])
control("one function reading two different epochs", f"{KOURTV2}/quality.gno",
        "supply := c.coin.PastTotal(cs.qualityEpoch)",
        "supply := c.coin.PastTotal(c.coin.Epoch() - 1)",
        "reads", argv=["python3", EPOCHCOH])
# The CRITICAL one: an engine told its weight rather than deriving it is what let
# cast exceed p.total and dropped `no` out of the early-decide test.
control("the engine accepting a supplied weight", f"{GOVERNORDIR}/governor.gno",
        "func (g *Governor) Vote(who address, id int64, choice string) {",
        "func (g *Governor) VoteWithWeight(who address, id int64, choice string, weight int64) {}\n\n"
        "func (g *Governor) Vote(who address, id int64, choice string) {",
        "the engine must DERIVE weight",
        argv=["python3", EPOCHCOH])
# The cap arm's own control, and the reason the arm is not just a name match: a
# ceiling that RAISES is the supplied-weight defect wearing a legal signature.
# The engine derives w correctly, a consumer lifts it, and `cast` exceeds p.total
# exactly as VoteWithWeight did — through a parameter the first version allowed.
control("a supplied cap that raises instead of lowering",
        f"{GOVERNORDIR}/governor.gno",
        "if cap > 0 && cap < w {",
        "if cap > w {",
        "a supplied cap must only ever lower",
        argv=["python3", EPOCHCOH])
# ARM 4's own control, and it is the arm that has a job the census cannot do: with
# the floor's comparison reversed, arm 1 still counts two BalanceOf reads in
# voteweight.gno and says nothing. Only the SHAPE check stands between a ceiling
# and a floor. Measured: [one-weight] fires here and [live-census] does not.
control("the vote floor's comparison reversed", f"{KOURTV2}/voteweight.gno",
        "if held := c.coin.BalanceOf(who); held < w {",
        "if held := c.coin.BalanceOf(who); held > w {",
        "[one-weight]", argv=["python3", EPOCHCOH])
# And the other half: one expression, charged by three lanes and quoted to the
# elector. A second definition in the name family fails closed.
control("a second vote-weight definition", f"{KOURTV2}/voteweight.gno",
        "func voteCap(c *Court, who address) int64 {",
        "func voteCap2(c *Court, who address) int64 { return voteCap(c, who) }\n\n"
        "func voteCap(c *Court, who address) int64 {",
        "[one-weight]", argv=["python3", EPOCHCOH])
# ARM 5's control. The quality lock releases on "the claim is terminal", so a NEW
# way for a claim to end leaves those votes locked forever and in silence — the
# predicate just keeps answering "still open" about a claim that is over. Nothing
# else in the tree asks, which is why the writers are counted.
control("a fourth way for a claim to end", f"{KOURTV2}/session.gno",
        "\tcs.verdictAt = heightNow()",
        "\tcs.verdictAt = heightNow()\n\tcs.verdictAt = heightNow()",
        "[terminal]", argv=["python3", EPOCHCOH])
# ARM 6's control. mustStakable is the ONE exemption from the vote lock, and it is
# a helper with a reassuring name — reaching for it is the natural move when a new
# path hits the lock and the author decides the lock is being unhelpful. Planting
# exactly that.
control("a second path exempted from the vote lock", f"{KOURTV2}/claim.gno",
        "\t\tmustSpendable(c, who, dep+fee)",
        "\t\tmustStakable(c, who, dep+fee)",
        "[lock-exempt]", argv=["python3", EPOCHCOH])
# ARM 7's control, planting the ordinary version of the mistake: a path that moves a
# holder's coin with the gate above it deleted. Both locks live in mustSpendable, so
# such a path bypasses the stake lock AND the vote lock while the transfer succeeds
# and no arithmetic goes wrong — there is nothing for a test to notice unless a test
# happens to exist for that exact path.
control("a coin outflow with its gate removed", f"{KOURTV2}/quality.gno",
        "\tmustSpendable(c, who, bond)\n\tc.coin.Transfer(who, c.escrow, bond)",
        "\tc.coin.Transfer(who, c.escrow, bond)",
        "[ungated-outflow]", argv=["python3", EPOCHCOH])
# ARM 8's four controls, one per pin, each with a DISTINCT expected string: all four
# carry the [foreign-lock] tag, so matching on the tag alone would let any one of them
# pass on another pin's complaint. The hazard is one edit away in each direction — a
# lock row taxes its owner's own transfers at a measured 110,245 gas per dead row, so
# a row created for somebody else is a griefing weapon rather than a self-imposed cost.
control("a lock row created for a third party", f"{KOURTV2}/quality.gno",
        "lockVote(c, who, voteLockQuality,",
        "lockVote(c, cs.author, voteLockQuality,",
        "rather than `who`", argv=["python3", EPOCHCOH])
control("a fourth lane locking votes", f"{KOURTV2}/dispute.gno",
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)",
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)\n"
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)",
        "vote-lock site(s), expected 3", argv=["python3", EPOCHCOH])
control("`who` rebound away from the caller", f"{KOURTV2}/quality.gno",
        "\tlockVote(c, who, voteLockQuality,",
        "\twho = cs.author\n\tlockVote(c, who, voteLockQuality,",
        "binds `who` to", argv=["python3", EPOCHCOH])
control("a locking helper passed a foreign address", f"{KOURTV2}/modvote.gno",
        "\tapprove(cur.Previous().Address(), courtSlug, 0, true)",
        "\tapprove(cur.Previous().Address(), courtSlug, 0, true)\n"
        "\tapprove(c.treasury, courtSlug, 0, true)",
        "as the holder", argv=["python3", EPOCHCOH])
# ARM 12's controls. Two isolate the sub-checks — the receiver and the count — and the
# third is the mistake as it would actually arrive: a storage saving added inside the
# ledger, trimming the supply series that every bar in the realm is read from.
control("a Trim pointed at another archive", f"{KOURTV2}/stakeseries.gno",
        'c.csArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)',
        'c.coinArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)',
        "the only archive safe to trim is", argv=["python3", EPOCHCOH])
control("a third Trim call site", f"{KOURTV2}/stakeseries.gno",
        '\tc.csArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)',
        '\tc.csArch.Trim(csKey(cs.id, "nh"), keep, trimBudget)\n'
        '\tc.csArch.Trim(csKey(cs.id, "xh"), keep, trimBudget)',
        "Trim call(s), expected 2", argv=["python3", EPOCHCOH])
control("the coin's own supply series trimmed to save storage",
        f"{GRC20VOTESDIR}/grc20votes.gno",
        "\tl.supply.SetAt(l.archive, supplyKey, l.Epoch(), l.total)",
        "\tl.archive.Trim(supplyKey, l.Epoch()-1, 4)\n"
        "\tl.supply.SetAt(l.archive, supplyKey, l.Epoch(), l.total)",
        "trims `l.archive`", argv=["python3", EPOCHCOH])
# ARM 11's controls. It polices PROSE, so the three cases are: the code's summary
# rewritten, the SPEC's quote rewritten while the historical copy is left in place, and a
# fresh restatement appearing. The middle one is why the arm counts exactly rather than
# checking presence — presence was tried and passes on it, which is the failure the arm
# exists for.
control("the release rule reworded in the code", f"{KOURTV2}/votelock.gno",
        "some question is open now  OR  these weights carry forward",
        "the tally has not been superseded",
        "votelock.gno states the quality release clause 0", argv=["python3", EPOCHCOH])
control("the spec's copy reworded, the record left alone", "VOTEFLOOR.md",
        "> (some question is open now OR these weights carry forward).",
        "> (the tally has not been superseded).",
        "VOTEFLOOR.md states the quality release clause 1", argv=["python3", EPOCHCOH])
control("a fresh restatement of the release rule", "VOTEFLOOR.md",
        "> (some question is open now OR these weights carry forward).",
        "> (some question is open now OR these weights carry forward).\n>\n"
        "> Restated: some question is open now OR these weights carry forward.",
        "stated somewhere new", argv=["python3", EPOCHCOH])
# ARM 10's controls, one per sub-check, each with its own expected string. The arm has
# to tell three situations apart: a COPY of the liveness disjunction, a second
# DEFINITION of it, and crystallize's own question stopping being its own question.
control("the liveness disjunction copied back into a reader",
        f"{KOURTV2}/voteweight.gno",
        "\tif qualityQuestionOpen(cs) {\n\t\tquality, _ = votingWeight(c, who, cs.qualityEpoch)",
        "\tif cs.flagOpen || cs.disputeOpen || cs.counterOpen {\n"
        "\t\tquality, _ = votingWeight(c, who, cs.qualityEpoch)",
        "disjoin two or more", argv=["python3", EPOCHCOH])
control("a second definition of the same disjunction",
        f"{KOURTV2}/crystallize.gno",
        "if cs.flagOpen || cs.counterOpen || cs.pendingSlash > 0 {",
        "if cs.flagOpen || cs.disputeOpen || cs.counterOpen || cs.pendingSlash > 0 {",
        "carry all three quality-question flags", argv=["python3", EPOCHCOH])
control("crystallize's own question becoming a partial copy",
        f"{KOURTV2}/crystallize.gno",
        "if cs.flagOpen || cs.counterOpen || cs.pendingSlash > 0 {",
        "if cs.flagOpen || cs.counterOpen || cs.tierFinal {",
        "without pendingSlash", argv=["python3", EPOCHCOH])
# ARM 9's controls, one per formula shape, in the two realms that expose the figure.
# SpendableOf is stake-only and named as though it were not, and the tree has walked
# into that three times — so what is pinned is arithmetic WITH it, in either direction:
# quoting it as the movable amount over-promises by a vote commitment, and subtracting
# VoteLockedOf from it understates the room because the locks combine with MAX not SUM.
# The prose that explains the figure correctly carries no formula and is the bystander:
# it sits in lock.gno right now and the clean run does not flag it.
control("SpendableOf quoted as the movable amount", f"{KOURTV2}/lock.gno",
        "// min(AllowanceCC, DisposableOf).",
        "// min(AllowanceCC, SpendableOf).",
        "[spendable-as-movable]", argv=["python3", EPOCHCOH])
control("the two locks subtracted in series", f"{CCWRAP}/ccwrap.gno",
        "// mustSpendable actually enforces.",
        "// SpendableOf minus VoteLockedOf is what to wrap against.",
        "[spendable-as-movable]", argv=["python3", EPOCHCOH])
control("arm 9 losing the trees it watches", EPOCHCOH,
        'CCWRAP = ROOT / "realm" / "r" / "ccwrap"',
        'CCWRAP = ROOT / "realm" / "r" / "ccwrap_moved"',
        "measuring nothing", argv=["python3", EPOCHCOH])
control("a guard that lost the tree it watches", EPOCHCOH,
        'KOURTV2 = ROOT / "realm" / "r" / "kourtv2"',
        'KOURTV2 = ROOT / "realm" / "r" / "kourtv9_moved"',
        "measuring nothing", argv=["python3", EPOCHCOH])

# ARM 13, the mint census. Arm 7 pins coin LEAVING a holder; nothing pinned coin
# arriving, and the consequence is worse: an unaccounted mint is supply the dilution
# ceiling cannot see, because emittedTotal feeds d_eff and only mintEmission updates
# it while the two curve paths advance `minted` instead. Nothing goes wrong
# arithmetically and the recipient's balance is correct, so only a census notices.
control("a mint nothing accounts for", f"{KOURTV2}/emission.gno",
        "func mintEmission(c *Court, to address, amount int64) {",
        "func selfTestLeakMint(c *Court, to address, amount int64) {\n"
        "\tc.coin.Mint(to, amount)\n}\n\n"
        "func mintEmission(c *Court, to address, amount int64) {",
        "[unaccounted-mint]", argv=["python3", EPOCHCOH])
# THE RECEIVER GENERALITY IS THE ARM'S OWN BLIND SPOT, and it is not hypothetical:
# meta's franchise mint is on `mc`, not `c`. Hardcoding the spelling counts two of
# three and calls the census clean — the same mistake arm 7 records being widened for.
control("the mint scan hardcoding one receiver", EPOCHCOH,
        r'MINT = re.compile(r"^\s*" + RECV + r"\.coin\.Mint\(", re.M)',
        r'MINT = re.compile(r"^\s*c\.coin\.Mint\(", re.M)',
        "2 mint site(s), expected 3", argv=["python3", EPOCHCOH])

# ARM 14, the purge census. Purge is the LEGAL removal — it erases text behind a
# statutory code and takes a global-DAO threshold — and both gates are spelled out per
# verb rather than factored, deliberately: hiding ensureGlobalDAO behind a helper would
# take it out of check-read-purity's sight, which greps function BODIES. So what needs
# pinning is that every verb still carries them, and that a FIFTH verb cannot arrive
# without carrying them — a case no corpus row can cover, because the code does not
# exist yet.
control("a purge verb with no category-code gate", f"{KOURTV2}/moderation.gno",
        "func PurgeCourt(cur realm, courtSlug string, categoryCode string) {\n"
        "\tif !cur.IsCurrent() {\n\t\tpanic(errStaleRealm)\n\t}\n"
        "\twho := cur.Previous().Address()\n"
        "\td := ensureGlobalDAO()\n"
        "\tif !d.members.Has(who.String()) {\n"
        "\t\tpanic(\"kourtv2: only a global DAO member may purge\")\n\t}\n"
        "\tmustCategoryCode(categoryCode)\n",
        "func PurgeCourt(cur realm, courtSlug string, categoryCode string) {\n"
        "\tif !cur.IsCurrent() {\n\t\tpanic(errStaleRealm)\n\t}\n"
        "\twho := cur.Previous().Address()\n"
        "\td := ensureGlobalDAO()\n"
        "\tif !d.members.Has(who.String()) {\n"
        "\t\tpanic(\"kourtv2: only a global DAO member may purge\")\n\t}\n",
        "PurgeCourt does not carry mustCategoryCode",
        argv=["python3", EPOCHCOH])
# The gate that matters most, on the verb furthest from the tests.
control("a purge verb with no authority gate", f"{KOURTV2}/folders.gno",
        '\t\tpanic("kourtv2: only a global DAO member may purge")',
        '\t\tpanic("kourtv2: computer says no")',
        "PurgeFolder does not carry the global-DAO authority gate",
        argv=["python3", EPOCHCOH])
# Fail CLOSED: a verb pattern that stops matching leaves the census counting nothing.
control("the purge verb pattern drifting off the code", EPOCHCOH,
        r'PURGE_VERB = re.compile(r"^func (Purge\w*)\(cur realm", re.M)',
        r'PURGE_VERB = re.compile(r"^func (PurgeNOPE\w*)\(cur realm", re.M)',
        "0 purge verb(s), expected 4",
        argv=["python3", EPOCHCOH])

# ARM 15, the entitlement-queue census. enqueueSenior's tiling invariant — seniors and
# juniors occupy disjoint stretches of the accrual line — holds because ONE site places
# an entitlement and ONE writer moves each cursor. Every way to break it with a single
# mutation already has a caught row (21 of them across the queue and the reservoir), so
# what this pins is a SECOND placement path: code nobody has written, which no corpus row
# can reach. A drafted queue-walking test was thrown away for catching only what those
# rows already catch.
control("a second entitlement placement site", f"{KOURTV2}/emission.gno",
        "func enqueueSenior(c *Court, to address, amount int64, purpose string) uint64 {",
        "func selfTestPlaceSenior(c *Court, to address, amount int64) {\n"
        "\te := &entitlement{to: to, amount: amount, start: 0, purpose: \"comp\"}\n"
        "\tc.queue.Set(beClaimKey(c.queueSeq), e)\n}\n\n"
        "func enqueueSenior(c *Court, to address, amount int64, purpose string) uint64 {",
        "2 entitlement placement site(s), expected 1",
        argv=["python3", EPOCHCOH])
# A cursor moved from somewhere else desynchronises the tail from the queue. Planted on
# the META receiver, which is the spelling a second emission path would most plausibly
# use — mc already carries mc.minted sixteen lines from here.
control("a second reservedTail writer", f"{KOURTV2}/emission.gno",
        "// rMax banks at most rMaxPeriods of the CURRENT period's budget.",
        "func selfTestBumpTail(mc *Court, n int64) {\n"
        "\tmc.reservedTail = mustAdd(mc.reservedTail, n)\n}\n\n"
        "// rMax banks at most rMaxPeriods of the CURRENT period's budget.",
        "2 reservedTail writer(s), expected 1",
        argv=["python3", EPOCHCOH])
# Fail CLOSED: a placement pattern that stops matching counts nothing for ever.
control("the placement pattern drifting off the code", EPOCHCOH,
        r'ENT_NEW = re.compile(r"&entitlement\{")',
        r'ENT_NEW = re.compile(r"&entitlementNOPE\{")',
        "0 entitlement placement site(s), expected 1",
        argv=["python3", EPOCHCOH])

print("\ncheck-nodelegate")
# The ceiling (PastVotes) is delegation-aware; the floor (BalanceOf) is not. They
# agree in kourtv2 for one reason only — nothing there can delegate — and the day
# that changes, every delegatee is silently docked to their own coin while the
# arithmetic stays coherent and every suite stays green. A hazard no test can see
# gets a machine.
control("kourtv2 gaining a delegation entrypoint", f"{KOURTV2}/court.gno",
        "func mustCourt(",
        "func Delegate(cur realm, to address) {}\n\nfunc mustCourt(",
        "[delegates]", argv=["python3", NODELEG])
# And the other direction: with no floor there is no asymmetry to protect, so a
# guard still reporting success would be describing a property nothing has.
control("the own-balance floor disappearing", f"{KOURTV2}/voteweight.gno",
        "\tif held := c.coin.BalanceOf(who); held < w {\n\t\tw = held\n\t}\n",
        "",
        "[floor-count]", argv=["python3", NODELEG])
# Its premise is in ANOTHER package, so it can rot without anything here changing.
control("the ceiling ceasing to be delegation-aware", f"{GRC20VOTES}/grc20votes.gno",
        "return a.votes.ValueAt(l.archive, string(who), at)",
        "return a.balance",
        "may not exist", argv=["python3", NODELEG])
control("a guard that lost the tree it watches", NODELEG,
        'KOURTV2 = ROOT / "realm" / "r" / "kourtv2"',
        'KOURTV2 = ROOT / "realm" / "r" / "kourtv9_moved"',
        "measuring nothing", argv=["python3", NODELEG])

print("\ncheck-membership-clears")
# The guard exists because ResetModSet's clear cannot be pinned by any TEST — it
# empties the set, so nothing can act until AppointMods or installModSet
# re-installs one, and both clear on the way in. Its effect is always superseded,
# so a mutation deleting it survives every possible test and always will. What can
# still go wrong is a FOURTH install path that forgets to clear, which is
# structural, so it gets a script instead of a test.
control("a membership write that forgets to clear", f"{KOURTV2}/moderation.gno",
        "func ResetModSet(cur realm, courtSlug string) {",
        "func SelfTestSneakyInstall(c *Court, cm *courtMod) {\n\tcm.n = 1\n}\n\n"
        "func ResetModSet(cur realm, courtSlug string) {",
        "changes without discarding its pending approvals",
        argv=["python3", MEMCLEAR])
# Fail CLOSED: a write pattern that stops matching the code must be an error, not
# an empty scan reported as a clean one.
control("a membership pattern that drifted off the code", MEMCLEAR,
        r'r"^\s*cm\.(members\s*=|n\s*=|n\+\+|n--)"',
        r'r"^\s*cmNOPE\.(members)"',
        "cannot be right",
        argv=["python3", MEMCLEAR])

print("\ncheck-read-purity")
# The guard's failure mode is a read that allocates SUCCEEDING where it should
# have panicked, so nothing in the suite goes red — the drift is invisible to
# tests by construction. The control has to inject a whole read rather than edit
# one, because every existing read is already correct.
control("a read that allocates state", f"{KOURTV2}/modvote.gno",
        "func ElectionOpen(",
        "func SelfTestAllocatingRead(courtSlug string) bool {\n"
        "\tcm := ensureMod(mustCourt(courtSlug))\n\t_ = cm\n\treturn true\n}\n\n"
        "func ElectionOpen(",
        "allocates and persists state",
        argv=["python3", READPURE])
# Fail CLOSED, both ways. An allocator that gets renamed leaves the scan looking
# for a call that can no longer appear, and a read pattern that drifts leaves it
# scanning nothing — either would report clean forever.
# getPos joined ALLOCATORS because review MEASURED this guard green against an exported
# read that called it — the allowlist was three hardcoded names and getPos was not one,
# while being an allocate-and-persist helper of exactly the same species. This is the
# control for that fix: plant the read, and the guard must now object.
control("an exported read that reaches getPos", f"{KOURTV2}/stakeindex.gno",
        "func StakedSize(courtSlug string, who address) int {",
        "func StakedLeak(courtSlug string, who address) int64 {\n"
        "\tc := mustCourt(courtSlug)\n"
        "\treturn getPos(c, mustClaim(c, 1), who, sideYES).stake\n"
        "}\n\n"
        "func StakedSize(courtSlug string, who address) int {",
        # NOT bare "getPos": the guard PRINTS that word when it passes, listing the
        # allocators it confined ("… getPos, ensureArgs, ensureSup all confined to write
        # paths"), so this arm reported "fires" whatever the plant did. Found by the
        # vacuity audit below, not by reading. The planted function's own name cannot
        # appear in a clean run.
        "StakedLeak calls getPos", argv=["python3", READPURE])
# NARROWED TO ONE ELEMENT ON PURPOSE. This plant used to name the whole ALLOCATORS
# tuple, and the tuple GREW — ensureArgs and ensureSup joined it and pushed it onto two
# lines, so the literal stopped matching, the plant became a no-op, and the control
# reported "did not fire" for months of edits without anyone reading it as a dead control.
# One element cannot go stale the same way.
control("an allocator renamed out from under the scan", READPURE,
        '"ensureMod",',
        '"ensureModGone",',
        "cannot appear",
        argv=["python3", READPURE])
control("a read pattern that drifted off the code", READPURE,
        r'EXPORTED = re.compile(r"^func ([A-Z]\w*)\(([^)]*)\)")',
        r'EXPORTED = re.compile(r"^funcNOPE ([A-Z]\w*)\(([^)]*)\)")',
        "cannot be right",
        argv=["python3", READPURE])

print("\ncheck-spend-paths")
# THREE ARMS, one per way the promise in lock.gno's header can quietly stop being
# kept. The rule is that nothing takes CC out of a holder's balance without asking
# what they have already committed, and the harm is a mint: the coins stay in the
# balance under a lock, so the LEDGER cannot refuse the second commitment and the
# realm ends up owing CC it does not hold.
#
# A path that stops calling its guard. This used to assert the ADJACENCY complaint,
# which is gone: that rule was a weaker duplicate of check-epoch-coherence ARM 7 and
# was deleted rather than left to drift out of step with it. The census catches the
# same plant, from the other side - the function is still in SPEND_PATHS and no
# longer calls a guard.
control("a spend path that stopped calling its guard", f"{KOURTV2}/answer.gno",
        "\tmustSpendable(c, who, bond)\n",
        "",
        "no longer calls a spend guard",
        argv=["python3", SPENDPATH])
# The arm for the NEXT path somebody adds, which is the whole reason this guard
# exists: the suite cannot go red for a path no test names, so the census has to.
control("a new spend path nobody censused", f"{KOURTV2}/lock.gno",
        "func TransferCC(cur realm,",
        "func SelfTestDrainCC(cur realm, courtSlug string, to address, amount int64) {\n"
        "\tc := mustCourt(courtSlug)\n"
        "\tfrom := cur.Previous().Address()\n"
        "\tmustSpendable(c, from, amount)\n"
        "\tc.coin.Transfer(from, to, amount)\n"
        "}\n\n"
        "func TransferCC(cur realm,",
        "SelfTestDrainCC",
        argv=["python3", SPENDPATH])
# Fail CLOSED on the census itself. A map naming a test that has been deleted is
# the same failure as an `elsewhere` pointing at nothing: it reads as coverage and
# is not. The guard's own text is the thing edited here, deliberately - that is
# where this particular rot lives.
control("a census pointing at a deleted test", SPENDPATH,
        '"TestStakedCoinCannotBeTransferred"',
        '"TestDeletedLastWeek"',
        "does not exist",
        argv=["python3", SPENDPATH])

print("\ncheck-abort-assertions")
# The failure this exists for is a test that PASSES for the wrong reason, so
# nothing goes red on its own - both transfer-amount guards were unpinned for as
# long as their tests asserted the substring "must be positive", which grc20votes'
# own mustBePositive also satisfies. Loosening a tightened assertion is the plant.
control("an assertion an inner layer also satisfies", f"{KOURTV2}/dispute_test.gno",
        '"kourtv2: a dispute is already open on this claim", func() {',
        '"already open", func() {',
        "can be satisfied by a layer it is not testing",
        argv=["python3", ABORTASRT])
# THE SHAPE THAT MADE THE FIRST VERSION VACUOUS. It scanned line by line, so an
# assertion whose message sits on the line BELOW its call - which gofmt produces as
# soon as the message is long enough to wrap - was invisible, and the guard reported
# a clean tree while seeing neither of the two assertions this check was written
# for. Found by ablation, not by reading. This arm plants that exact shape.
control("a wrapped assertion the scan must still see", f"{KOURTV2}/stake_test.gno",
        '"kourtv2: stake must be positive", func() {',
        '"must be positive",\n\t\tfunc() {',
        "can be satisfied by a layer it is not testing",
        argv=["python3", ABORTASRT])
# Fail CLOSED: a pattern that stops matching the tests, and a reachable-package set
# that comes back empty, both leave this reporting clean for ever.
# THE WHOLE alternation, not just its first branch. The plant here used to read
# "AbortsContains" -> "AbortsNOPE", which left mustPanicWith( and AbortsWith( still
# matching, so the guard went on finding hundreds of assertions and reported clean:
# this arm was SILENT and the selftest said so on its first run. A pattern-drift
# plant has to break the pattern, not one of its branches.
control("an assertion pattern that drifted off the tests", ABORTASRT,
        r"r'(?:AbortsContains\(t, cur,|mustPanicWith\(|AbortsWith\(t, cur,)'",
        r"r'(?:AbortsNOPE\(t, cur,)'",
        "drifted off the tests",
        argv=["python3", ABORTASRT])
control("the reachable package set coming back empty", ABORTASRT,
        'ALWAYS = {"grc20votes"}',
        'ALWAYS = set()\nIMPORT = re.compile(r"NOTHINGMATCHESTHIS")',
        "scanning for a shape the tree no longer has",
        argv=["python3", ABORTASRT])

print("\ncheck-paths")
# Every want below NAMES THE FILE the mutation exposes. An earlier version of
# these arms wanted bare "STALE" and "ALLOWLIST", which the baseline output
# already contained while two real stale paths were outstanding — so two arms
# printed "fires" without their mutation doing anything. A fixture that cannot
# distinguish the arm it names proves nothing.
control("a retired path in a file nobody exempted", PATHS,
        '    "MODERATION.md": (1,',
        '    "MODERATION-gone.md": (1,', "STALE MODERATION.md",
        argv=["python3", PATHS])
# The count is the pin, because an allowlisted file can acquire a NEW stale
# mention alongside its deliberate ones — gnoroot.py did exactly that, carrying
# an intentional spelling and a rotted docstring in the same file.
control("an allowlist count that drifted", PATHS,
        '    "PLAN.md": (2,',
        '    "PLAN.md": (9,', "PLAN.md carries 2 retired-path mention(s), pinned at 9",
        argv=["python3", PATHS])
# An exemption for a file with nothing to exempt shrinks coverage silently,
# which is the failure check-citations names about its own stale manifest rows.
control("an exemption that guards nothing", PATHS,
        '    "PLAN.md": (2,',
        '    "Makefile": (2,', "Makefile is exempt",
        argv=["python3", PATHS])
# Fail CLOSED on a rotted regex. This is not hypothetical: the half-rename
# pattern shipped as `kourt/court(?![a-z0-9])`, which matched `kourt/court` and
# therefore NOT `kourt/courtv2` — the V2 half-rename escaped the pattern written
# for half-renames. The fixtures are what turn that into a build break.
control("a retired pattern that can no longer match", PATHS,
        r'(re.compile(r"(?:[pr]|\{p,r\})/cryptocourt"),',
        r'(re.compile(r"(?:[pr]|\{p,r\})/cryptocourtZZZ"),',
        "SELFTEST no pattern fires", argv=["python3", PATHS])
# And fail closed the OTHER way: a pattern that grew too greedy would flag
# correct paths, and a guard that cries wolf gets switched off faster than one
# with a known edge.
control("a pattern that grew greedy enough to flag correct paths", PATHS,
        r'(re.compile(r"kourt/court"),',
        r'(re.compile(r"kourt/"),',
        "fires on", argv=["python3", PATHS])

print("\ncheck-mutation-anchors")
# Each arm PREPENDS a row to the real corpus and wants a verdict that NAMES the
# injected row, so no arm can be satisfied by a pre-existing problem elsewhere in
# the 863. The guard's own fixtures pin each verdict behind an INJECTED resolver,
# which proves nothing about the real one — these arms are what exercise the pkg
# lookup, the path join and the file read against the actual tree.
#
# Written as a JSON round-trip, not a string splice. The first version anchored on
# the literal "[\n {\n", which is the corpus's `indent=1` head — and the corpus is
# `indent=2`. Re-serialising it at the right indent silently turned all six arms
# into BROKEN CONTROL. An arm must not depend on the whitespace of the file it
# edits.
def inject(label, rows, want):
    backup = MUTS + ".selftest-backup"
    exercised.add(os.path.basename(ANCHORS))
    shutil.copy(MUTS, backup)
    try:
        with open(MUTS, "w") as fh:
            json.dump(rows + json.load(open(backup)), fh,
                      indent=2, ensure_ascii=False)
            fh.write("\n")
        r = subprocess.run(["python3", ANCHORS], capture_output=True, text=True)
        out = r.stdout + r.stderr
        if want in out:
            print(f"  {label:<44} fires")
        else:
            print(f"  {label:<44} SILENT — the guard did not notice")
            failures.append(label)
    finally:
        shutil.move(backup, MUTS)


def srow(label, **kw):
    r = {"pkg": "kourtv2", "file": "buy.gno", "label": label,
         "find": "NoSourceLineSaysThis", "replace": "x"}
    r.update(kw)
    return r


inject("a row whose anchor has rotted away", [srow("SELFTEST rotted")],
       "matched 0x on 'SELFTEST rotted'")
inject("a row whose anchor is ambiguous",
       [srow("SELFTEST ambiguous", find="\t")],
       # Names the row rather than pinning a count: a bare tab occurs hundreds of
       # times in buy.gno, and only a BAD ANCHOR verdict prints "matched Nx on".
       "on 'SELFTEST ambiguous'")
# The check the batch cannot make: it sees one row at a time, so two rows holding
# the same mutation both report caught and the corpus reads bigger than it is.
# Not hypothetical — a merge left 18 such pairs, each carrying two different
# labels for one identical mutation.
inject("two rows carrying one identical mutation",
       [srow("SELFTEST twin A"), srow("SELFTEST twin B")],
       "SELFTEST twin A")
inject("two rows sharing one label",
       [srow("SELFTEST shared"), srow("SELFTEST shared", find="AlsoAbsentHere")],
       "DUPLICATE LABEL 'SELFTEST shared'")
# An unknown pkg is worse than a missing one: mutate.py's OBSERVERS lookup falls
# back to EVERY package, so any unrelated red suite reads as this row's catch.
inject("a pkg mutate.py cannot stage",
       [srow("SELFTEST unknown pkg", pkg="nosuchpkg")],
       "UNKNOWN PKG 'nosuchpkg'")
inject("an `elsewhere` excuse pointing at a deleted file",
       [srow("SELFTEST stale excuse",
             elsewhere="gnoland/testdata/no_such_file.txtar")],
       "STALE ELSEWHERE 'gnoland/testdata/no_such_file.txtar'")
# A row that is not shaped like a row used to crash with a KeyError, and one
# missing only `file` was reported as UNKNOWN PKG — naming a package that was
# right there in the map.
inject("a row that is not shaped like a row",
       [{"pkg": "kourtv2", "label": "SELFTEST malformed", "find": "x"}],
       "MALFORMED ROW 'SELFTEST malformed'")
# Fail CLOSED when the pkg map moves. It is IMPORTED from mutate.py so there is
# only one copy; the cost is a guard that resolves nothing if the name goes away,
# and resolving nothing must never read as clean.
control("a pkg map this guard can no longer find", ANCHORS,
        'getattr(mutate, "PKGS", None)', 'getattr(mutate, "PKGS_MOVED", None)',
        "could not read PKGS", argv=["python3", ANCHORS])
# And fail closed on the fixtures themselves, the way check-paths does: a verdict
# that has quietly stopped being produced must break the build, not report clean.
control("a verdict the guard no longer produces", ANCHORS,
        '"UNKNOWN PKG"),', '"UNKNOWN PKG THAT IS NEVER PRINTED"),',
        "SELFTEST no row verdict contains", argv=["python3", ANCHORS])

print("\ncheck-demo-physics")
# Arms written for the E2E workstream's guard, which arrived without any. The
# coverage ledger at the bottom of this file would have failed the whole selftest
# on it, and a guard nobody can break is a guard nobody has tested — this one
# exists precisely because "the demo is data and data has no tests".
#
# The headline arm reproduces the defect it was written for: DEMO's conviction
# values were 6x-29x above the realm's own ceiling for their stated stake and
# lifetime, and no test noticed.
control("a demo conviction above the realm's ceiling", WEBPAGE,
        "convYes:439774", "convYes:439774000",
        "orem/1", argv=["python3", PHYSICS])
# Fail CLOSED when the realm moves under it. The guard's whole design claim is
# that it READS the constants rather than copying them ("a check that hardcodes
# the number it is checking only pins the moment it was written"), and the cost of
# that is a guard which measures nothing if a name goes away. It must say so.
control("a realm constant this guard can no longer find", PHYSICS,
        'realm_const("r0WeeklyBps", "stake.gno")',
        'realm_const("r0WeeklyBpsMOVED", "stake.gno")',
        "has the realm moved?", argv=["python3", PHYSICS])
# And the same for its other input: the demo lives in a page this repo does not
# own the shape of, so losing the anchor must be loud rather than a clean scan.
control("a demo page that no longer defines NOW", WEBPAGE,
        "const NOW = ", "const NOW_RENAMED = ",
        "no longer defines NOW", argv=["python3", PHYSICS])

print("\ncheck-height-shim")
# The guard exists because 65 call sites went through a mechanical rename and
# nobody re-checks those by eye. A single missed one means ONE TRANSACTION
# SEEING TWO HEIGHTS — a claim opened at fabricated height 20,000 while the twap
# ring observes at real height 30 — so it must fail on a reintroduced raw read.
control("a height read that bypasses the shim", STAKE,
        "func rawHeight(cs *claimState) int64 {\n\th := heightNow()",
        "func rawHeight(cs *claimState) int64 {\n\th := runtime.ChainHeight()",
        "bypass heightNow", argv=["python3", HSHIM])
# An audit found the first version scanned only the realm, and so could not see
# the one live raw read outside it. A pure package that starts reading the chain
# directly must be caught.
control("a pure package reading the chain directly", TWAP,
        "func (r Ring) Head() int     { return r.head }",
        "func (r Ring) Head() int     { _ = runtime.ChainHeight(); return r.head }",
        "raw height read", argv=["python3", HSHIM])
# A literal scan is defeated by an import alias; the audit pointed that out.
control("chain/runtime imported under an alias", BUY,
        '\t"chain/runtime/unsafe"', '\trt "chain/runtime"',
        "aliases chain/runtime", argv=["python3", HSHIM])
# kourtv2 must never build a ledger without a clock: that ledger would read REAL
# height while the claims and rings around it read fabricated height.
control("a court built on a clockless ledger", COURT,
        "grc20votes.NewLedgerWithClock(name, courtSymbol(slug), coinDecimals, epochBlocks, realmClock{})",
        "grc20votes.NewLedger(name, courtSymbol(slug), coinDecimals, epochBlocks)",
        "use NewLedgerWithClock", argv=["python3", HSHIM])
# And it must fail CLOSED if its own anchor goes away, rather than scanning
# clean because heightNow() no longer reads anything.
control("a shim that no longer reads the chain", CLOCKF,
        "h = runtime.ChainHeight()", "h = int64(0)",
        "lost its anchor", argv=["python3", HSHIM])

print("\ncheck-web-selectors")
# The defect: three browser assertions queried .eline/.efill/.e50 for a day after
# the share card's chart started sharing the claim page's .ln/.ar/.mid. A
# querySelector for a class that does not exist returns null — the assertion goes
# on reporting on nothing. web-visual needs puppeteer and is deliberately not in
# `check`, so nothing said a word.
control("a browser check queries a class the overlay no longer has",
        "web/tests/browser/embed_layout.js",
        "sv.querySelector('.ln')", "sv.querySelector('.eline')",
        "appears in neither shipped file", argv=["python3", WEBSEL])
# And the tripwire. A scan that matches nothing must fail rather than report a
# clean tree — the same discipline check-web-dupes takes about its own corpus.
print("\ncheck-curation-reachable")
# The defect: nine curation entrypoints built in this programme — subfolders,
# MoveFolder, retire/restore, OrderFolders, both argument edges, SetCourtDesc —
# reachable from no page, while the curate page's own prose said the realm did
# all of it. Worst was OpenClaimP: a claim body was asked for by name, shipped,
# and RENDERED by the claim page, while both "Open a claim" buttons still called
# OpenClaim, so the field could be read and never written.
control("an entrypoint the product cannot ask for", WEBPAGE,
        '${btn("Order folders","OrderFolders"', '${btn("Order folders","OrderFoldersXX"',
        "named by neither shipped web file", argv=["python3", CURREACH])
# THE OTHER HALF: naming an entrypoint is not calling it correctly. btn() builds
# the transaction form from its object literal's KEYS, so a realm parameter that
# gets renamed leaves every stale button rendering a form that looks right and
# fills the wrong field. Neither side's tests can see it — the realm suite does
# not know buttons exist, the web harnesses do not know what a signature says.
control("a button argument the function does not have", WEBPAGE,
        '{courtSlug:slug,parentID:0,ids:"3,1,2"}',
        '{courtSlug:slug,parent:0,ids:"3,1,2"}',
        "do not match", argv=["python3", CURREACH])
control("a scan that finds no entrypoints", CURREACH,
        'r"^func ([A-Z]\\w*)\\(cur realm"', 'r"^func (ZZZ\\w*)\\(cur realm"',
        "matched too little to be real", argv=["python3", CURREACH])

print("\ncheck-web-tests-reachable")
# The defect: folders_test.js printed its summary and exited in the MIDDLE of its
# own IIFE, so seven assertions below it had never run — the whole chain-nesting
# block, written for a failure that then shipped. It reported 31 of the 38 it
# held and looked perfect doing it.
# THIS PLANT USED TO DELETE THE SUMMARY, and the guard skips a file that has none
# (`if m is None: continue` — a harness with no verdict of its own is the runner's
# problem). So it planted a defect the guard deliberately ignores, reported "did not
# fire", and the invariant it names — no assertion BELOW the verdict — had never been
# exercised at all. The summary stays put now and an assertion goes after it, which is
# the defect in the control's own name.
control("a harness prints its verdict with assertions below it", FOLDERSJS,
        '  process.exit(fail?1:0);',
        '  process.exit(fail?1:0);\n  ok("planted below the summary", true);',
        "assertion(s) after the summary", argv=["python3", REACH])
# The tripwire. A guard that scanned no harnesses would report a clean tree for
# ever, which is the vacuity it exists to catch in the harnesses themselves.
control("a scan too small to be real", REACH,
        'if not name.endswith(".js") or name in SKIP:', 'if True:',
        "too few to be a real scan", argv=["python3", REACH])

control("a scan that matches nothing", WEBSEL,
        'if not name.endswith(".js") or name == "run.js":',
        'if True or not name.endswith(".js"):',
        "matched nothing", argv=["python3", WEBSEL])

print("\ncheck-browser-checks-registered")
# The defect, and it is measured rather than imagined: run.js listed four checks
# while five more files sat beside it, four of them asserting harnesses for the
# chat panel. chat_all.js was written to wrap them and says in its own header
# that it was waiting for "one entry added to CHECKS later" — which never came.
# 157 assertions went unrun, and two of them had gone false in the meantime.
control("a browser harness no runner runs", RUNJS,
        ',\n                "chat_all.js"', "",
        "not reachable from run.js", argv=["python3", BROWREG])
# A registration that points at nothing. `make web-visual` would say FAIL missing
# at RUN time, but web-visual needs puppeteer and is not in `check` — which is
# the whole reason this guard is static.
control("a runner lists a file that is not there", RUNJS,
        '"route_crawl.js"', '"route_crwal.js"',
        "is registered but does not exist", argv=["python3", BROWREG])
# A wrapper that runs nothing prints "0 browser check(s) pass" — a green line for
# no work done, which is the exact shape of the failure this guard is about.
control("a registered wrapper with an empty list", CHATALL,
        '["chat_page.js", "chat_render.js", "chat_live.js", "chat_moderation.js"]', "[]",
        "empty CHECKS list", argv=["python3", BROWREG])
# And the tripwire, because a guard policing an empty directory reports a clean
# tree forever.
control("a scan too small to be real", BROWREG,
        'if f.endswith(".js")', 'if f == "run.js"',
        "too few to be a real scan", argv=["python3", BROWREG])

print("\ncheck-web-css")
# The defect this exists for: a comment edited badly, leaving prose and a second
# `*/` in front of a declaration. CSS error recovery skipped to the next `;` —
# which belonged to the declaration AFTER the comment — so `width:100%` was
# swallowed and the share card sized itself shrink-to-fit, 422px wide inside the
# 400px frame it exists to fit. make check, all 16 web harnesses and node --check
# all passed: none of them read CSS.
control("a stray */ leaving prose where a declaration goes", WEBPAGE,
        "  width:100%; min-width:0; max-width:520px; margin:auto}",
        "     and stray prose about widths */\n  width:100%; min-width:0; max-width:520px; margin:auto}",
        "stray */", argv=["python3", WEBCSS])
# An unclosed rule, which swallows every rule after it.
control("a rule left unclosed", WEBPAGE,
        ".emb::before{top:0; left:0; border-right:0; border-bottom:0}",
        ".emb::before{top:0; left:0; border-right:0; border-bottom:0",
        "unclosed rule", argv=["python3", WEBCSS])
# And the tripwire. A check that reads the wrong thing and reports success is
# worse than no check, so it refuses a <style> block it cannot find or that is
# too small to be this file's.
control("a stylesheet too small to be the real one", WEBPAGE,
        "<style>", "<style>/* gutted */</style><style>",
        "refusing to pass vacuously", argv=["python3", WEBCSS])

print("\ncheck-web-dupes")
# The defect this exists for, reintroduced: a second declaration of a name that
# is already taken. It cost the owner a broken court page in both modes —
# "pts.map is not a function" — because the LAST declaration silently wins in
# the overlay's one flat scope.
control("a second declaration of an existing name", WEBPAGE,
        "async function claimStakeSeries(slug,id,d){",
        "async function claimSeries(slug,id,d){",
        "declared more than",
        argv=["python3", DUPES])
# And the tripwire, which is the half that matters if the scan ever stops
# finding anything: a guard that counted zero declarations would report every
# name unique having asked nothing.
control("a script block the scan cannot find", WEBPAGE,
        "<script>", "<scriptX>",
        "no <script> block to scan",
        argv=["python3", DUPES])

print("\ncheck-live-reads")
# This one needs a running node, so its arms are the two refusals it makes
# WITHOUT one — which are the paths an operator actually hits, and the paths
# that must not report a clean scan.
# Needs no node, deliberately: the arm is the tripwire that fires BEFORE the
# network, because a guard whose probe table has been gutted would otherwise
# report a clean scan having asked nothing.
control("a gutted probe table", LIVER,
        "PROBES = [\n    # court-level", "PROBES = []\nUNUSED_PROBES = [\n    # court-level",
        "has been gutted", argv=["python3", LIVER, "--remote", "http://127.0.0.1:1"])

if not have_gno():
    print("\ncheck-storage: gno not installed - NOT CHECKED")
    failures.append("check-storage arms were not run")
else:
    print("\ncheck-storage")
    control("a budget nobody can meet", STORE,
            '"z_write_filetest.gno": 12_000,',
            '"z_write_filetest.gno": 100,', "OVER",
            argv=["python3", STORE])
    # The read that starts writing is introduced in the LEDGER now, since that
    # is where a balance is looked up. The realm's BalanceOf is a one-line
    # forward, which is the point of the split and also means there is nothing
    # there to break.
    control("a read that starts writing", f"{VOTES}/grc20votes.gno",
            "func (l *Ledger) BalanceOf(owner address) int64 {\n\tif a := l.getAccount(owner); a != nil {",
            "func (l *Ledger) BalanceOf(owner address) int64 {\n\tif a := l.openAccount(owner); a != nil {",
            "WROTE", argv=["python3", STORE])
    # UNKNOWN, not MISSING. MISSING is for a budget whose filetest did not
    # run; this is the other way round — a filetest that ran and nobody had
    # budgeted for. Expecting the wrong word here reports the guard as silent
    # when the guard is right, which is the failure mode a self-test has to be
    # most careful about: crying wolf about your own guards is how they get
    # switched off.
    # A REFUSAL THAT NAMES NOTHING COSTS A RE-RUN. check-storage refuses to price
    # a realm whose suite is red — correctly, since costs measured against broken
    # tests mean nothing — and it used to stop at "does not pass. Fix the tests
    # first." It already HAS the failure: it runs with -v and threw the output
    # away, so learning which test broke meant staging the realm again by hand and
    # waiting out a suite that takes over a minute. Twice today.
    # AFTER THE IMPORTS. The first version of this arm inserted the failing test
    # straight after `package kourtv2`, which puts a declaration above the import
    # block: the suite then fails to BUILD rather than to test, there is no
    # "--- FAIL: TestName" line to name, and the arm called the guard silent when
    # the guard was right. It printed the parser error through the no-test-named
    # fallback below, which is the only reason the bad arm was spotted at all.
    control("a red suite is named, not just refused", f"{KOURTV2}/court_test.gno",
            "func TestStartCourtCreatesABareCourt(cur realm, t *testing.T) {",
            "func TestSelfTestDeliberateFailure(cur realm, t *testing.T) {\n"
            "\tt.Error(\"deliberate\")\n}\n\n"
            "func TestStartCourtCreatesABareCourt(cur realm, t *testing.T) {",
            "TestSelfTestDeliberateFailure", argv=["python3", STORE])
    control("a filetest nobody budgeted for", STORE,
            '"z_use_filetest.gno": None,\n', "", "UNKNOWN",
            argv=["python3", STORE])

    print("\ncheck-docnumbers")
    # The bootstrap table in doc.gno against the values init installs. Broken
    # on the DOC side here; the code side is checked by hand in the commit that
    # added the guard, because mutating governor.gno's init would also fail
    # every other arm of this file and prove nothing about this one.
    control("a bootstrap term the docs disagree with", f"{GOVERN}/doc.gno",
            "//\tgrace      241920 blocks",
            "//\tgrace      241921 blocks", "STALE",
            argv=["python3", "scripts/check-docnumbers.py"])

    print("\ncheck-isolation")
    # Appended AFTER an existing function, not after the package clause: a
    # declaration inserted above the import block is a PARSE error, and a package
    # that will not parse never runs a test, so the control would be measuring the
    # parser rather than the classification. (It did, briefly.)
    control("an ordinary failure misreported as isolation",
            f"{GOVERN}/clock_test.gno",
            "func resumeClock() { advanceBlocks(0) }",
            "func resumeClock() { advanceBlocks(0) }\n\n"
            "func TestSelfTestBrokenEitherWay(t *testing.T) {\n"
            "\tt.Error(\"deliberate\")\n}",
            "fail either way",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestSelfTestBrokenEitherWay"])

    # The genuine article: a test that reads a court a NEIGHBOUR created. kourtv2's
    # package-global `courts` tree is never reset between tests, so alone this
    # panics with "no such court" and in company it passes — which is exactly the
    # dependency this guard exists to surface, and the label that must not be
    # confused with the one above.
    #
    # This used to be done in govern, by deleting the kind registration from
    # TestAMalformedRulesPayloadIsRefusedAtTheDoor. That control is retired
    # because its premise is dead, not because it was noisy: resetLedger now
    # builds a WHOLE NEW governor (`engine = governor.New(...)`), so the kind
    # registry no longer survives a reset and the leak it reproduced cannot
    # happen. Verified by running it — the test fails alone AND with its package
    # now, so the old control was pointing the new classifier at the wrong label.
    # The third label, and the one that exposed the guard's own false success. Two
    # tests claiming the same court slug kills the package the instant both run,
    # and it is INVISIBLE test-by-test: each passes alone. The guard used to run
    # the suite together only for packages that had already failed alone, so with
    # everything green it printed "pass alone as well as together" having never
    # checked the second half. The together-run is unconditional now, and this is
    # what proves it.
    control("a suite that dies with no test to blame", f"{KOURTV2}/stake_test.gno",
            'c := testCourt(cur, "rlk1", alice, 500_000_000_000)',
            'c := testCourt(cur, "st1", alice, 500_000_000_000)',
            "fails as a whole",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestReleasingMoreThanIsLockedIsRefused"])

    control("a test that passes only in company", f"{KOURTV2}/stake_test.gno",
            "// THE invariant the lock has to buy back.",
            "func TestSelfTestNeedsANeighboursCourt(cur realm, t *testing.T) {\n"
            "\tif StakePools(\"st1\", 1); false {\n"
            "\t\tt.Fatal(\"unreachable\")\n\t}\n}\n\n"
            "// THE invariant the lock has to buy back.",
            "ALONE",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestSelfTestNeedsANeighboursCourt"])

    # The failure this guard itself suffered, and the reason this file exists.
    # Its package list used to be a hand-kept COPY of the Makefile's, and the two
    # drifted: kourtv2 — the realm under active development — was never checked
    # for its entire life, while the guard kept printing "all N tests across M
    # packages pass alone as well as together". The list is derived from the
    # Makefile now, so drift is impossible; what remains is the derivation itself
    # breaking. It must break LOUDLY, never by quietly reading a shorter list.
    control("a guard that lost its coupling to the Makefile",
            os.path.join(REPO, "Makefile"),
            "for r in govern offerer kourtv1 kourtv2 ccwrap; do",
            "for rlm in govern offerer kourtv1 kourtv2 ccwrap; do",
            "cannot read realm-test's package lists",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestAMalformedRulesPayloadIsRefusedAtTheDoor"])

    # mutate.py takes its work on stdin rather than from a file it owns, so its
    # controls are shaped differently: feed it a mutation and require the right
    # verdict. The first three are the ways it can report a non-result as a
    # result, which is what the docstring names; the fourth is the way a
    # two-tree runner can quietly measure the wrong tree.
    print("\nmutate.py")
    feed("an anchor that matches nothing", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "no such text exists anywhere in this file",
        "replace": "y"}], "BAD ANCHOR")
    feed("a mutant that cannot build", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "\treturn p.yes, p.no, p.abstain, p.total",
        "replace": "\treturn p.yes, p.no, p.abstain, p.thereIsNoSuchField"}], "INVALID")
    # A pkg nobody has is refused rather than defaulted. Silently falling back
    # to the realm would mutate a file the caller did not name and report the
    # verdict as though it had — a mutation runner lying about WHAT it broke,
    # which is worse than lying about whether anything noticed.
    feed("a pkg that does not exist", [{
        "pkg": "checkpont", "file": "checkpoint.gno", "label": "x",
        "find": "x", "replace": "y"}], "no such pkg")
    # A row annotated `elsewhere` says "this guard is covered by a suite mutate.py
    # does not run" — today only the txtar tests. It must never be able to hide a
    # finding, so both directions are controlled: an annotated row that SURVIVES is
    # reported in its own block rather than vanishing, and one that turns out to be
    # caught here says so, since a stale excuse would mask a future regression.
    # A no-op replacement is the deterministic way to force a survivor: it applies
    # cleanly (so it is not a BAD ANCHOR) and changes nothing (so no test can object).
    noop = {"pkg": "governor", "file": "governor.gno",
            "label": "a row that cannot fail here",
            "find": "const maxLive = 64", "replace": "const maxLive = 64",
            "elsewhere": "somewhere this harness cannot run"}
    feed("an `elsewhere` row is named on its own line", [noop], "covered elsewhere")
    feed("and listed in the summary, never omitted", [noop], "survive here BY DESIGN")
    # The other direction: an annotation that is no longer true must say so, or a
    # stale excuse would mask a future regression.
    feed("a STALE `elsewhere` annotation is called out", [{
        "pkg": "governor", "file": "governor.gno",
        "label": "a row that IS caught here",
        "find": "const maxLive = 64", "replace": "const maxLive = 65",
        "elsewhere": "somewhere this harness cannot run"}], "drop its `elsewhere`")

    # A MUTANT THAT HANGS RATHER THAN FAILS, which is the one shape with no bound
    # at all until SUITE_TIMEOUT. This exact flip spun a suite for 56 minutes at
    # 110% of a core and would have spun for ever: `e` is the min of the two heads,
    # so the side that matches `e` is the side the flip stops advancing, neither
    # index moves, and the loop appends rows without end. A mutation like that can
    # never be caught, because catching needs the suite to finish and object.
    #
    # The `want` is TIMED OUT and not "caught": the branch order in mutate.py puts
    # this before the fallthrough that prints "caught: failed", because a row
    # nothing ever judged is a non-result, the same as one that did not build.
    #
    # 240s rather than the 600s default so the arm costs four minutes instead of
    # ten. It has to stay well clear of a legitimately slow suite on a loaded
    # machine, which is the same reason the default is as high as it is.
    os.environ["MUTATE_SUITE_TIMEOUT"] = "240"
    feed("a mutant that hangs rather than fails", [{
        "pkg": "kourtv2", "file": "stakeseries.gno",
        "label": "the merge loop stops advancing",
        "find": "if i < len(ys) && ys[i].e == e {",
        "replace": "if i < len(ys) && ys[i].e != e {"}], "TIMED OUT")
    os.environ.pop("MUTATE_SUITE_TIMEOUT", None)

    control("a suite that is already failing", f"{GOVERN}/clock_test.gno",
            "func resumeClock() { advanceBlocks(0) }",
            "func resumeClock() { advanceBlocks(0) }\n\nfunc TestSelfTestDeliberateFailure(t *testing.T) {\n\tt.Error(\"deliberate\")\n}",
            "BASELINE IS RED",
            argv=["python3", os.path.join(REPO, "scripts/mutate.py")],
            stdin='[{"pkg":"governor","file":"governor.gno","label":"x","find":"const maxLive = 64","replace":"const maxLive = 63"}]',
            cwd=os.path.join(REPO, GOVERN))

# --------------------------------------------------------- mutate-parallel --
# The batch is sharded now, so one more way to report a non-result as a result:
# a shard that DIES while its siblings pass. Its rows never ran, and if the driver
# merged what it got it would print a clean verdict over a hole. Both arms below
# feed it a shard that cannot survive and require it to refuse the whole run.
if not have_gno():
    print("\nmutate-parallel: gno not installed - NOT CHECKED")
    failures.append("mutate-parallel arms were not run")
else:
    print("\nmutate-parallel.py")
    exercised.add("mutate-parallel.py")
    bad = json.dumps([
        {"pkg": "governor", "file": "governor.gno", "label": "a row that runs",
         "find": "const maxLive = 64", "replace": "const maxLive = 63"},
        {"pkg": "nosuchpkg", "file": "x.gno", "label": "a shard that must die",
         "find": "a", "replace": "b"},
    ])
    r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "2"],
                       input=bad, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "NOT a result" in out:
        print(f"  {'a dead shard fails the whole run':<44} fires")
    else:
        print(f"  {'a dead shard fails the whole run':<44} SILENT — merged anyway")
        failures.append("a dead shard fails the whole run")
    if r.returncode != 0:
        print(f"  {'and the exit code says so':<44} fires")
    else:
        print(f"  {'and the exit code says so':<44} SILENT — exited 0")
        failures.append("a dead shard exits nonzero")

    # A HUNG BASELINE IS NOT A RED ONE, and this arm exists because the two
    # already drifted once. The driver knows a shard's baseline failed by a string
    # in its stderr OR by `code == 2` — and `code == 2` was dead for the whole
    # life of the file, because mutate.py returned 2 from main() and nobody passed
    # it to sys.exit. So the string carried it alone, and a NEW message the string
    # did not match would have fallen through to the summary tripwire and been
    # reported as "no summary line": true, and silent about what actually happened.
    lbl = "a hung baseline is reported as its own thing"
    src = os.path.join(REPO, "realm/r/kourtv2/stakeseries.gno")
    find = "if i < len(ys) && ys[i].e == e {"
    text = open(src).read()
    if text.count(find) != 1:
        # The arm did not apply, so it proves nothing. Said out loud rather than
        # passing quietly — an arm that silently no-ops is this file's own subject.
        print(f"  {lbl:<44} NOT ARMED — the anchor matched "
              f"{text.count(find)}x, so nothing hung")
        failures.append(lbl + " [anchor did not apply]")
    else:
        backup = src + ".selftest-backup"
        shutil.copy(src, backup)
        try:
            open(src, "w").write(text.replace(find, "if i < len(ys) && ys[i].e != e {"))
            os.environ["MUTATE_SUITE_TIMEOUT"] = "60"
            r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "1"],
                               input=json.dumps([
                                   {"pkg": "governor", "file": "governor.gno",
                                    "label": "a row that never gets its turn",
                                    "find": "const maxLive = 64",
                                    "replace": "const maxLive = 63"}]),
                               capture_output=True, text=True)
            out = r.stdout + r.stderr
        finally:
            shutil.move(backup, src)
            os.environ.pop("MUTATE_SUITE_TIMEOUT", None)
        if "baseline did not finish" in out:
            print(f"  {lbl:<44} fires")
        else:
            print(f"  {lbl:<44} SILENT — a hang read as something else")
            failures.append(lbl)

# ----------------------------------------------------------------- gnoroot --
# Each runner now gets its OWN GNOROOT — symlinks to everything but a private copy
# of examples/ — which is what lets two worktrees test at the same time. Two ways
# that can go wrong silently, so both get a control.
#
# If the isolation stops working, the runners are sharing a tree again and the
# collisions this replaced come back, with nothing to announce it. And remove()
# deletes a tree recursively whose entries are symlinks INTO a real gno checkout:
# if it ever followed one, or accepted a path that is not a shadow, it would
# delete the monorepo. No test in this repo would survive to report it.
print("\nrepolock.py")
# The mutating runner announces itself so the readers refuse instead of reporting
# its deliberate breakage as their own finding. This existed because `make check`
# beside a selftest printed two citation errors naming files nobody had touched --
# a false failure in a DIFFERENT gate, which is the worst kind to debug.
#
# selftest holds the lock for its own run, so a refusal arm has to stand up a
# DIFFERENT live holder and call the reader without the inherited owner pid.
def _lockcase(label, ok):
    exercised.add("repolock.py")
    print(f"  {label:<44} " + ("fires" if ok else "WRONG"))
    if not ok:
        failures.append(label)


_saved_owner = os.environ.get(repolock.ENV)
_ghost = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
try:
    with open(repolock.LOCK, "w") as f:
        f.write(str(_ghost.pid))
    _noenv = {k: v for k, v in os.environ.items() if k != repolock.ENV}
    r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                       capture_output=True, text=True, env=_noenv)
    _lockcase("a reader refuses while the tree is rewritten",
              r.returncode == 1 and "rewriting the working tree" in r.stderr)
    # Re-entrancy: selftest runs the readers AS its controls, so an inherited owner
    # pid must pass straight through or this file could not test anything at all.
    r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                       capture_output=True, text=True,
                       env={**os.environ, repolock.ENV: str(_ghost.pid)})
    _lockcase("the owner's own children are not locked out", r.returncode == 0)
    # THE RECIPE, NOT JUST THE READERS. Every python guard inside realm-test
    # called refuse_if_held; the recipe around them did not, so a run that was
    # scrupulous about check-citations went on to copy realm/r/*/*.gno into a
    # GNOROOT with no such scruple. Two consecutive `make check` runs then failed
    # on tests nobody had touched — argument_test once, argumentcaps_test the
    # next — because the copy caught a guard another session had armed by hand
    # and restored moments later. Neither reproduced, and both cost a diagnosis.
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/repolock.py"),
                        "check", "realm-test"],
                       capture_output=True, text=True, env=_noenv)
    _lockcase("the realm-test gate refuses before it stages",
              r.returncode == 1 and "rewriting the working tree" in r.stderr)
    # And the wiring itself, because an arm on a command the recipe stopped
    # calling would pass for ever while the hole was open again.
    _mk = open(os.path.join(REPO, "Makefile")).read()
    _lockcase("and realm-test still calls it",
              "repolock.py check realm-test" in _mk)
finally:
    _ghost.kill()
    _ghost.wait()
# A dead holder must CLEAR, not refuse forever: leaving it behind would wedge every
# reader, which is worse than the race it prevents.
with open(repolock.LOCK, "w") as f:
    f.write(str(_ghost.pid))
r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                   capture_output=True, text=True,
                   env={k: v for k, v in os.environ.items() if k != repolock.ENV})
_lockcase("a dead holder clears instead of wedging", r.returncode == 0)
# Put selftest's own claim back for the rest of the run.
with open(repolock.LOCK, "w") as f:
    f.write(str(os.getpid()))
if _saved_owner is not None:
    os.environ[repolock.ENV] = _saved_owner

print("\ngnoroot.py")
sys.path.insert(0, os.path.join(REPO, "scripts"))
import gnoroot  # noqa: E402


def rootcase(label, ok):
    exercised.add("gnoroot.py")
    print(f"  {label:<44} " + ("fires" if ok else "WRONG"))
    if not ok:
        failures.append(label)


if not have_gno():
    print("  gnoroot arms need a gno toolchain - NOT CHECKED")
    failures.append("gnoroot arms were not run")
else:
    real = gnoroot.real_root()
    a = gnoroot.build(real, "selftest-a")
    b = gnoroot.build(real, "selftest-b")
    # Two roots, one file: staging into one must not be visible in the other.
    mark = "examples/gno.land/p/kourt/selftest-marker"
    os.makedirs(os.path.join(a, mark))
    rootcase("two shadows are isolated", not os.path.exists(os.path.join(b, mark)))
    rootcase("and neither leaks into the real root",
             not os.path.exists(os.path.join(real, mark)))

    # The dangerous direction: anything that is not a shadow must be refused.
    rootcase("removing the real root is refused", gnoroot.remove(real) == 1)
    rootcase("removing a non-shadow under the base is refused",
             gnoroot.remove(os.path.join(gnoroot.BASE, "not-a-shadow")) == 1)

    # NO TOOLCHAIN MUST SAY SO. real_root() returns "" for every way of failing
    # to find one, and build() used to carry that straight to os.listdir(""),
    # which raises `FileNotFoundError: ''` — no file named, no cause, no fix.
    # `gno env GNOROOT` resolves against the CURRENT DIRECTORY, so running any of
    # these scripts from a git worktree answers with a path built from the
    # worktree's own prefix that does not exist; mutate.py died on that traceback
    # twice before anyone ran the command by hand. Both shapes, because "" and a
    # wrong path arrive by different routes.
    for _bad, _what in (("", "an empty GNOROOT"), ("/no/such/gnoroot", "a GNOROOT that is not there")):
        try:
            gnoroot.build(_bad, "selftest-noroot")
            rootcase(_what + " is refused", False)
        except SystemExit as _e:
            rootcase(_what + " is refused", "no gno toolchain to shadow" in str(_e))

    # The reaper must take an ABANDONED root and leave a live one alone. Getting
    # this backwards deletes the tree a running suite is testing against, which
    # is the same collision the whole module exists to remove.
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    ghost = os.path.join(gnoroot.BASE, f"{gnoroot.PREFIX}selftest-ghost-{dead.pid}")
    os.makedirs(ghost, exist_ok=True)
    gnoroot.reap()
    rootcase("an abandoned root is reaped", not os.path.exists(ghost))
    rootcase("a live root survives the reaper", os.path.isdir(a) and os.path.isdir(b))

    # And removal must unlink the symlinks rather than follow them.
    before = sorted(os.listdir(real))
    gnoroot.remove(a)
    gnoroot.remove(b)
    rootcase("removal leaves the real root intact", sorted(os.listdir(real)) == before)
    rootcase("removal leaves the real stdlibs intact",
             os.path.isdir(os.path.join(real, "gnovm", "stdlibs")))

# Every guard in scripts/ must have been pointed at by at least one control.
#
# check-*.py by name, plus the runners that are guards in everything but
# spelling: mutate.py decides whether a mutation counted, gnoroot.py decides
# whether a suite ran against its own staged tree. Naming them explicitly is
# the same opt-in coverage this file complains about elsewhere, but the
# alternative — every scripts/*.py — demands a control for this file itself,
# and a self-test that must break itself to prove it works is a worse trade.
RUNNERS = {"mutate.py", "gnoroot.py", "mutate-parallel.py"}
print("\ncheck-guards-armed")
# The cheap half of this very file, so an unarmed guard fails at commit time
# instead of waiting for the next selftest. It is itself a scripts/check-*.py and
# therefore subject to its own rule, which is deliberate: a registration check
# that forgot to register itself would be the exact failure it exists to catch.
#
# Editing THIS file while it runs is safe — Python has already read it — and the
# first arm does exactly that, because "a guard dropped from selftest-checks.py"
# cannot be staged any other way.
# THE LITERAL IS ASSEMBLED, NOT WRITTEN, and the reason is the only interesting
# thing about this arm. check-guards-armed reads THIS FILE as text, so a `find`
# argument spelling the guard's name out would keep that name present after the
# edit — the arm would rename the const, the name would still be here in the
# arm's own source, and UNARMED would never fire. Written plainly it was a
# BROKEN CONTROL that passed a by-hand probe before it was registered and stopped
# working the moment it landed. Do not "tidy" the concatenation away.
_reg = 'PATHS = "scripts/check-pa' + 'ths.py"'
control("a committed guard dropped from selftest-checks.py", SELF,
        _reg, _reg.replace('pa' + 'ths.py', 'paths-renamed.py'),
        "UNARMED",
        argv=["python3", ARMED])
# Fail CLOSED, the same rule the other guards carry: an empty scan reported as a
# clean one is how check-isolation swept 39% of the suite while printing success.
control("the guard glob matching nothing", ARMED,
        'glob.glob(os.path.join(REPO, "scripts", "check-*.py"))',
        'glob.glob(os.path.join(REPO, "scripts", "check-nothing-*.py"))',
        "measured nothing",
        argv=["python3", ARMED])


print("\ncheck-stale-guards")
# The substitute for a test that cannot exist: govern/token_test.gno established
# that no harness can hand an entrypoint a returned frame, so the ~105 crossing
# entrypoints are held by being "checkable by reading" — and this reads them.
# Written after a mutation deleting the check from mustDeployer survived the whole
# corpus, which is the right verdict from a harness that cannot reach the line and
# no comfort about the other sites.
#
# Every anchor carries its function SIGNATURE. `if !cur.IsCurrent() {` occurs up
# to sixteen times in one file, so the bare line would be an ambiguous edit and
# control() would refuse it.
control("an entrypoint that loses the frame check", BUY,
        "func Buy(cur realm, slug string) int64 {\n\tif !cur.IsCurrent() {\n\t\tpanic(errStaleRealm)\n\t}\n",
        "func Buy(cur realm, slug string) int64 {\n",
        "UNGUARDED",
        argv=["python3", STALEG])
# THE DELEGATE, not the call site. Four entrypoints defer to mustDeployer; a guard
# that accepted the call without verifying the delegate would bless a helper that
# had quietly stopped checking.
control("a mustX(cur) helper that stops checking", TCLOCK,
        "func mustDeployer(cur realm) {\n\tif !cur.IsCurrent() {\n\t\tpanic(errStaleRealm)\n\t}\n",
        "func mustDeployer(cur realm) {\n",
        "DELEGATED",
        argv=["python3", STALEG])
control("the entrypoint scan matching nothing", STALEG,
        'glob.glob(os.path.join(REPO, "realm/r/*/*.gno"))',
        'glob.glob(os.path.join(REPO, "realm/r/*/*.nope"))',
        "nothing was checked",
        argv=["python3", STALEG])
# An exemption list that rots silently is how a guard comes to watch nothing.
control("an exemption naming a function that is gone", STALEG,
        '    "govern/govern.gno:dispatch":',
        '    "govern/govern.gno:dispatchRenamed":',
        "STALE",
        argv=["python3", STALEG])

print("\ncoverage")
# COMMITTED guards only, which is the same line scripts/check-guards-armed.py
# draws and for the same reason: a guard somebody is still writing is not yet an
# obligation on anybody, and failing this shared gate because of an untracked
# work-in-progress file makes the run useless to whoever is writing it. The moment
# a guard is committed it owes the tree a control arm, and check-guards-armed says
# so at commit time rather than days later here.
#
# The skipped ones are PRINTED, never passed over in silence: without that line
# this ledger would read "all guards have a control" while the newest one was
# simply not counted.
found = {os.path.basename(p) for p in glob.glob(os.path.join(REPO, "scripts/check-*.py"))}
r = subprocess.run(["git", "ls-files", "--", "scripts/"], cwd=REPO,
                   capture_output=True, text=True)
if r.returncode != 0:
    print(f"  git ls-files failed, so coverage was not checked:\n{r.stderr.strip()}")
    failures.append("coverage could not determine which guards are committed")
    tracked_guards = set()
else:
    tracked_guards = {os.path.basename(x) for x in r.stdout.split()} & found
for g in sorted(found - tracked_guards):
    print(f"  {g:<44} untracked, not yet an obligation")
guards = tracked_guards | RUNNERS
unguarded = sorted(guards - exercised)
for g in unguarded:
    print(f"  {g:<44} NO CONTROL — nothing here can prove it fires")
    failures.append(f"{g} has no control")
if not unguarded:
    print(f"  all {len(guards)} committed guards in scripts/ have a control")

print("\nvacuity")
# THE ARM THAT AUDITS THE OTHER ARMS. A control whose `want` string is ALREADY in its
# guard's clean output reports "fires" no matter what its plant did — it is a green light
# wired to nothing. This file's own comments record the class happening once, two arms
# wanting bare "STALE" and "ALLOWLIST" that the baseline already printed while two real
# stale paths were outstanding; it happened again with an arm wanting bare "getPos", which
# check-read-purity prints in its SUCCESS line. Reading for it does not work: the arm looks
# right and the run says fires.
#
# So it is mechanical now. Parse this file's own control() calls, run each distinct guard
# on the CLEAN tree once, and object to any `want` the clean output already contains.
# Controls whose argv is not a plain list of literals or module constants cannot be
# resolved and are COUNTED OUT LOUD rather than skipped quietly — an audit that silently
# ignores what it cannot parse is the same vacuity one level up.
def vacuity_audit():
    import ast
    tree = ast.parse(open(__file__).read())
    consts = {}
    for node in tree.body:
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and isinstance(node.value, ast.Constant)):
            consts[node.targets[0].id] = node.value.value
    parsed, unresolved, cache, bad = 0, 0, {}, []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and getattr(node.func, "id", "") == "control"):
            continue
        parsed += 1
        if len(node.args) < 5 or not isinstance(node.args[4], ast.Constant):
            unresolved += 1
            continue
        want = node.args[4].value
        label = node.args[0].value if isinstance(node.args[0], ast.Constant) else "?"
        cmd = None
        for kw in node.keywords:
            if kw.arg == "argv" and isinstance(kw.value, ast.List):
                parts = []
                for e in kw.value.elts:
                    if isinstance(e, ast.Constant):
                        parts.append(e.value)
                    elif isinstance(e, ast.Name) and e.id in consts:
                        parts.append(consts[e.id])
                    else:
                        parts = None
                        break
                cmd = parts
        if not cmd:
            unresolved += 1
            continue
        key = tuple(cmd)
        if key not in cache:
            r = subprocess.run(list(cmd), capture_output=True, text=True,
                               errors="replace", cwd=REPO)
            cache[key] = r.stdout + r.stderr
        if want in cache[key]:
            bad.append((label, want, " ".join(cmd)))
    print(f"  {parsed} control(s) parsed, {len(cache)} guard(s) run clean, "
          f"{unresolved} not resolvable")
    for label, want, cmd in bad:
        print(f"  {label:<44} WANTS WHAT THE CLEAN RUN ALREADY PRINTS ({want!r})")
        failures.append(f"{label} wants a string {cmd} prints when it passes")
    if not bad:
        print("  no control wants a string its guard already prints")


vacuity_audit()

if failures:
    print(f"\n{len(failures)} control(s) did not fire. A guard that cannot fail "
          f"is not a guard:")
    for f in failures:
        print(f"  {f}")
    sys.exit(1)
print("\nevery control fires.")
