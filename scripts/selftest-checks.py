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

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import gnoroot  # noqa: E402
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
    """Apply an edit, run the guard, and require `want` in its output.

    Whether that `want` is a string the guard ALREADY prints on a clean tree
    is asked once, in aggregate, by vacuity_audit() at the end of this file.
    It is not asked here: doing both means running every distinct guard
    baseline twice in a run that already takes twenty-four minutes.
    """
    for a in (argv or ["python3", "scripts/check-citations.py"]):
        if a.endswith(".py"):
            exercised.add(os.path.basename(a))
    # A PLANT WHOSE FILE IS GONE IS A ROTTED ARM, NOT A CRASH. shutil.copy on a
    # missing path raises, and an unhandled raise here does not fail one arm — it
    # ends the whole run, so every arm BELOW it never executes and nothing says
    # so. MEASURED: five arms still point at realm/r/kourtv2/quality.gno, deleted
    # with the quality lane, and this file died at the first of them after
    # exercising check-citations alone. One guard of thirty-one. The rotted
    # browser-check arm and the broken guard it arms both sat below that line.
    #
    # Reported the same way an anchor that no longer matches is reported, and for
    # the same reason: the arm proves nothing either way, and the run has to
    # continue to say what else is broken.
    if not os.path.exists(path):
        print(f"  {label:<44} BROKEN CONTROL (no such file: {path})")
        failures.append(label)
        return
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
    """Whether there is a toolchain for the gno-dependent controls to use.

    THIS ASKED A DIFFERENT QUESTION UNTIL NOW: whether `gno env GNOROOT`
    printed anything. That is not the same as whether there is a GNOROOT.
    The command resolves against the CURRENT DIRECTORY, so from a git
    worktree it answers with a path derived from the worktree's prefix that
    does not exist — non-empty output, no toolchain — and this said yes.
    gnoroot.real_root() has carried the os.path.isdir() for exactly that
    since it cost mutate.py two runs; the reasoning is in gnoroot.build,
    which is also why this now defers to it rather than keeping a third
    copy of the same three lines.
    """
    return bool(gnoroot.real_root())


CITE = "scripts/check-citations.py"
STORE = "scripts/check-storage.py"
NONTRANS = "scripts/check-nontransferable.py"
EPOCHCOH = "scripts/check-epoch-coherence.py"
MEMCLEAR = "scripts/check-membership-clears.py"
READPURE = "scripts/check-read-purity.py"
SPENDPATH = "scripts/check-spend-paths.py"
ELSEWHERE = "scripts/check-elsewhere.py"
CONTROLS = "scripts/check-control-anchors.py"
COLLISIONS = "scripts/check-mutant-collisions.py"
RENDERTEXT = "scripts/check-render-text.py"
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
CHATLIM = "scripts/check-chat-limits.py"
CHATJS = "web/chat.js"
SANITIZE = "internal/chat/sanitize.go"
FOLDERSJS = "web/tests/folders_test.js"
RUNJS = "web/tests/browser/run.js"
CHATALL = "web/tests/browser/chat_all.js"
WEBPAGE = "web/index.html"
WEBCONST = "scripts/check-web-constants.py"
MEDIAHOSTS = "scripts/check-media-hosts.py"
MEDIAGNO = "realm/r/kourtv2/media.gno"
BLOCKTIME = "scripts/check-block-time.py"
CLOCKGNO = "realm/r/kourtv2/clock.gno"
GOVGNO = "realm/p/governor/governor.gno"
NGINXCONF = "deploy/nginx.conf"
SEEDEMIT = "scripts/check-seed-emitters.py"
SCENARIO = "scripts/scenario.py"
SELF = "scripts/selftest-checks.py"
ARMED = "scripts/check-guards-armed.py"
GRUN = "scripts/check-guards-run.py"
MAKEFILE = "Makefile"
STALEG = "scripts/check-stale-guards.py"
BUY = "realm/r/kourtv2/buy.gno"
STAKE = "realm/r/kourtv2/stake.gno"
COURT = "realm/r/kourtv2/court.gno"
CLOCKF = "realm/r/kourtv2/clock.gno"
TCTEST = "realm/r/kourtv2/testclock_test.gno"
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
# TWO ABSENCE/UNIQUENESS CLAIMS the source states and nothing checked until now.
# Both plants are static-only: this guard reads .gno as text, so a plant that
# changes a call's meaning without regard for the body is legitimate here.
control("a position is removed from the stake index", f"{KOURTV2}/stakeindex.gno",
        "if pv := cs.stakers.Get(posKey(who, side)); pv != nil {",
        "if pv := cs.stakers.Remove(posKey(who, side)); pv != nil {",
        "position-removed",
        argv=["python3", EPOCHCOH])
# The write at :189 rather than :170: lockStake's Set sits next to a lockedOf
# CALL, so flipping that one would read as a reader either way and the arm could
# pass for the wrong reason.
# A UNIQUENESS census rather than an absence one, and that changes what it needs.
# The twap.Ring arm and the stakers.Remove arm both expect ZERO, so a pattern that
# drifts off the code still counts zero and stays silent — each needed a second
# arm for the drift. This one expects ONE, so both directions mismatch on their
# own: a second writer counts 2, and a dead pattern counts 0. One arm is enough,
# and that is a property of the expected value, not an oversight.
#
# governor.gno says setState "is the only writer of p.state, and does everything
# that follows from a proposal reaching one, so no new code path has to remember".
# The three things a second writer would skip are the clip on the reason, the slot
# release, and the announcement — and the first is an unbounded string kept for the
# life of the realm.
control("a second writer of the proposal state", f"{GOVERNORDIR}/governor.gno",
        "func (g *Governor) setState(p *proposal, st int8, reason string) {",
        "func (g *Governor) selfTestSecondStateWriter(p *proposal) {\n"
        "\tp.state = stateActive\n}\n\n"
        "func (g *Governor) setState(p *proposal, st int8, reason string) {",
        "proposal-state writer(s), expected 1",
        argv=["python3", EPOCHCOH])
# ARM 17: S1, the one-way coupling between money and the comment lane. The plant
# is the first read — a settlement asking what level the author has — because that
# is exactly how a one-way coupling stops being one: it looks harmless at the call
# site and is invisible from the other side. If a payout could read a level or a
# vote, a flooded board would move money and S5 would be false.
#
# RE-POINTED, because this arm was BROKEN CONTROL (anchor matched 0x) and therefore
# testing nothing. It used to plant into `creditAuthorHigh(c, cs, cs.tier)`, and
# creditAuthorHigh is GONE — standing_test.gno now carries three comments saying so.
# A plant whose anchor has been deleted reports as a passing suite in every
# implementation that does not check its own controls, which is the reason that
# check exists and the reason this was found.
#
# The rule itself is untouched and live: arm 17 fires on a file that is not in
# BOARD_LANE, contains a coin.Transfer/Mint/Burn, and reads board state.
# openrewards.gno still satisfies all three preconditions — measured: 2 money
# moves (lines 222 and 227), not in BOARD_LANE, and 0 board reads today.
#
# The new plant is a STRICTER reading of the arm's own sentence than the old one:
# it guards the author's OWN refund on the level the author holds, so it is
# literally "a settlement asking what level the author has" and the money it
# gates is a coin.Transfer to that same address. Anchored on the deposit refund
# rather than the fee refund on line 227, which is the same shape — cs.deposit
# makes it unique.
control("a money path reading board state", f"{KOURTV2}/openrewards.gno",
        "\t\tc.coin.Transfer(c.escrow, cs.author, cs.deposit)",
        "\t\tif postLevel(c, cs.author) > 0 {\n"
        "\t\t\tc.coin.Transfer(c.escrow, cs.author, cs.deposit)\n\t\t}",
        "money-reads-board",
        argv=["python3", EPOCHCOH])
# ARM 16, and its plant is the failure the arm exists for. courtIsPurged used to
# document its own readers in a comment, which had already drifted from two to
# five. The rule is a predicate — the gate belongs on paths that BEGIN a
# commitment — and Unstake is the canonical release path: gating it means a
# purged court strands an answered claim's stakers, which MODERATION.md §2
# forbids outright.
control("the purged-court gate on a release path", f"{KOURTV2}/stake.gno",
        "func Unstake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {\n"
        "\tif !cur.IsCurrent() {",
        "func Unstake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {\n"
        "\tif courtIsPurged(c) {\n\t\tpanic(\"selftest\")\n\t}\n"
        "\tif !cur.IsCurrent() {",
        "purged-gate-on-a-release-path",
        argv=["python3", EPOCHCOH])
control("a second reader of the lock tree", f"{KOURTV2}/lock.gno",
        "\tc.locked.Set(string(who), l-amount)",
        "\tc.locked.Get(string(who))",
        "second-lock-reader",
        argv=["python3", EPOCHCOH])
# The guard that would have caught the reverted live-weight work on its FIRST
# commit, before a test ran. Every bar in this realm is frozen so it cannot move
# under an open vote; a live numerator against a frozen bar gave turnout at
# 200-400% of its own bar in several lanes, and a supplied weight voided the
# governor's `rest` contract outright. Three arms, three controls, plus fail-closed.
# The tally files hold no live read at all now — the expression lives in
# voteweight.gno — so this plants one where arm 1 pins zero.
#
# BOTH RE-POINTED FROM quality.gno TO dispute.gno, which is the other tally file
# TALLY_LIVE_ALLOWED pins at zero. They were BROKEN CONTROL (no such file) and so
# exercised nothing. The rules are live and needed no change.
#
# The first plant is now a STRICTER reading of arm 1 than the old one: rather than
# swapping a votingWeight call for two BalanceOf calls, it turns quorumFloor's
# sealed denominator into a LIVE one (PastTotal(at) -> TotalSupply()). TotalSupply
# is in the LIVE pattern, so arm 1 fires — and this is the exact defect the note
# above describes, a live figure measured against a frozen bar.
control("a live weight read reached a tally file", f"{KOURTV2}/dispute.gno",
        "\tsupply := c.coin.PastTotal(at)",
        "\tsupply := c.coin.TotalSupply()",
        "live weight read(s) in a file that decides by weight",
        argv=["python3", EPOCHCOH])
# AND ITS EXPECTED STRING WAS VACUOUS. This arm wanted 'reads', which
# check-epoch-coherence prints on a CLEAN run, so even with a working anchor it
# could not tell a defect from a pass — the suite's own vacuity pass reports it.
# It now wants the [two-epochs] tag, verified ABSENT from the clean output.
#
# The plant adds a SECOND sealed read at a different instant (at-1) beside the
# existing one, which is arm 2's subject exactly: one function, two epochs.
control("one function reading two different epochs", f"{KOURTV2}/dispute.gno",
        "\tat := c.coin.Epoch() - 1\n\tsupply := c.coin.PastTotal(at)",
        "\tat := c.coin.Epoch() - 1\n"
        "\tsupply := c.coin.PastTotal(at) + c.coin.PastTotal(at-1)",
        "[two-epochs]", argv=["python3", EPOCHCOH])
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
# RE-POINTED from quality.gno to dispute.gno, which carries the IDENTICAL shape at
# 112-113: the same mustSpendable(c, who, bond) above the same
# c.coin.Transfer(who, c.escrow, bond). A one-for-one move, so the arm plants the
# same defect it always did — the dispute bond instead of the flag bond.
control("a coin outflow with its gate removed", f"{KOURTV2}/dispute.gno",
        "\tmustSpendable(c, who, bond)\n\tc.coin.Transfer(who, c.escrow, bond)",
        "\tc.coin.Transfer(who, c.escrow, bond)",
        "[ungated-outflow]", argv=["python3", EPOCHCOH])
# ARM 8's four controls, one per pin, each with a DISTINCT expected string: all four
# carry the [foreign-lock] tag, so matching on the tag alone would let any one of them
# pass on another pin's complaint. The hazard is one edit away in each direction — a
# lock row taxes its owner's own transfers at a measured 110,245 gas per dead row, so
# a row created for somebody else is a griefing weapon rather than a self-imposed cost.
# RE-POINTED to the dispute lane, one of the two lanes that still lock votes
# (LOCKVOTE_CALLS_N = 2: dispute.gno and modvote.gno). ARM 8's four controls sit
# on four distinct pins and the two aimed at the quality lane went BROKEN CONTROL
# with it; the rule and the other two are untouched.
#
# THE DISTINCT-STRING DISCIPLINE IS THE POINT and it is now measured rather than
# asserted. This pin and the `who`-rebinding pin below both emit [foreign-lock],
# so matching the tag would let either pass on the other's complaint. Probed
# both ways: this plant produces "rather than `who`" and NOT "binds `who` to",
# and the one below produces "binds `who` to" and NOT "rather than `who`".
control("a lock row created for a third party", f"{KOURTV2}/dispute.gno",
        "lockVote(c, who, voteLockDispute,",
        "lockVote(c, cs.author, voteLockDispute,",
        "rather than `who`", argv=["python3", EPOCHCOH])
# ITS EXPECTED STRING WAS OFF BY THE DELETED LANE, so this arm never fired even
# though its anchor matched live code — which is why it was not BROKEN CONTROL and
# survived the sweep that fixed the eight that were.
#
# The arm wants the count pin's complaint. The guard emits
# "[foreign-lock] {found} vote-lock site(s), expected {pinned}", and the pin went
# 3 -> 2 when the quality lane went (LOCKVOTE_CALLS_N: dispute.gno, modvote.gno).
# The want still read "expected 3", the pinned half — so it matched neither the
# clean run nor the planted one. MEASURED: with the doubled call planted the guard
# says "3 vote-lock site(s), expected 2", and the old string appears in NEITHER
# output.
#
# It now pins the guard's own current pin. If a fourth lane is ever legitimately
# added and LOCKVOTE_CALLS_N moves, this arm goes quiet and the selftest says so —
# which is the right failure, since a new vote-locking lane is exactly the thing
# the guard's message says "has to be argued".
control("a fourth lane locking votes", f"{KOURTV2}/dispute.gno",
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)",
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)\n"
        "\tlockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)",
        "vote-lock site(s), expected 2", argv=["python3", EPOCHCOH])
control("`who` rebound away from the caller", f"{KOURTV2}/dispute.gno",
        "\tlockVote(c, who, voteLockDispute,",
        "\twho = cs.author\n\tlockVote(c, who, voteLockDispute,",
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
# DEFINITION of it, and open the rewards's own question stopping being its own question.
# ARM 10'S THREE CONTROLS ARE RETIRED, because ARM 10 ITSELF IS GONE.
#
# They were BROKEN CONTROL ("anchor matched 0x") and hid better than the five that
# named quality.gno: they plant into voteweight.gno and openrewards.gno, which both
# still EXIST, so a pass that counts missing plant FILES does not see them. What is
# gone is the code they name — qualityQuestionOpen, cs.qualityEpoch,
# cs.pendingSlash, cs.tierFinal, cs.flagOpen and cs.counterOpen all have ZERO
# non-comment references in realm/r/kourtv2 today, flagOpen and counterOpen
# included, which read as though they were live.
#
# NOT RE-POINTED, and that is check-epoch-coherence's own decision rather than a
# convenience. Its note at the site of the deleted arm says the hazard was a
# DISJUNCTION drifting between two readers, which needs two or more flags to exist
# before it can happen, and that "re-aiming it at a single flag would leave a check
# that passes for a reason unrelated to the one it was written for — the kind of
# green this file exists to refuse." There is one liveness question now and
# cs.disputeOpen is it, so a control here would have no subject either.
#
# THE INSTRUCTION THAT COMES WITH THE RETIREMENT, carried here so it survives with
# the arm: "If a second liveness flag is ever added, restore this arm from git
# history rather than writing a new one." That applies to these three controls too
# — they are in the history alongside it.
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
        r'MINT = re.compile(r"^(?!\s*//).*\b" + RECV + r"\.coin\.Mint\(", re.M)',
        r'MINT = re.compile(r"^(?!\s*//).*\bc\.coin\.Mint\(", re.M)',
        "2 mint site(s), expected 3", argv=["python3", EPOCHCOH])
# AND THE OTHER HALF OF THE SAME BLIND SPOT: the CALL SHAPE, not the receiver.
#
# The arm above plants a narrowed receiver, and the arm two above plants an extra
# mint at the start of its own statement. Neither could see the anchoring, because
# both plant in the shape the pattern already assumed — `^\s*` matched them
# whichever way it was written. This one plants a mint inside an `if err := ...`,
# which is how a mint with a returned error would actually be written, and the
# anchored pattern counted it as nothing at all. That is not a hypothesis: the
# sibling absence census next to it, stakers.Remove, was written anchored and its
# own arm reported SILENT for exactly this reason.
#
# THE PLANTED MINT IS ACCOUNTED FOR, deliberately, and that is what makes this arm
# about SHAPE rather than about accounting. An unaccounted mint never reaches the
# count: the guard returns at its `if hits:` as soon as any per-file complaint
# exists, so the census registry below it is unreachable and the arm would report a
# WRONG COMPLAINT — measured, that is exactly what the first version of this arm
# did. With `.minted +=` on the line above, the per-file check is satisfied and the
# only thing left to notice is that the realm now has four mint sites where the
# census says three.
control("a mint the census cannot see because of where it sits", f"{KOURTV2}/emission.gno",
        "func mintEmission(c *Court, to address, amount int64) {",
        "func selfTestMidLineMint(c *Court, to address, amount int64) {\n"
        "\tc.minted += amount\n"
        "\tif err := c.coin.Mint(to, amount); err != nil {\n\t\tpanic(err)\n\t}\n}\n\n"
        "func mintEmission(c *Court, to address, amount int64) {",
        "mint site(s), expected 3", argv=["python3", EPOCHCOH])

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
#
# ITS EXPECTED STRING WAS OFF BY ONE VERB, the same defect as the fourth-lane arm
# above and just as invisible: the anchor matches, so it was never BROKEN CONTROL,
# it simply never fired. PURGE_VERBS_N went 7 -> 8 when PurgeClaimMedia arrived
# ("the eighth", as its own comment in the guard says), and this want still read
# "expected 7". MEASURED with the pattern broken: the guard says
# "[ungated-purge] 0 purge verb(s), expected 8", and the old string appears in
# NEITHER the clean nor the planted output.
#
# Counted the live verbs rather than trusting either number: 8 in
# realm/r/kourtv2, tests excluded — PurgeBoardRow, PurgeBoardRange,
# PurgeCourtLogRow, PurgeFolder, PurgeClaimMedia, PurgeClaim, PurgeCourt,
# PurgeModLogRow. So the guard's pin is right and the arm was wrong.
control("the purge verb pattern drifting off the code", EPOCHCOH,
        r'PURGE_VERB = re.compile(r"^func (Purge\w*)\(cur realm", re.M)',
        r'PURGE_VERB = re.compile(r"^func (PurgeNOPE\w*)\(cur realm", re.M)',
        "0 purge verb(s), expected 8",
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
# THE SECOND HALF OF THE SAME RULE: an exported read must not hand out a POINTER.
# Three sites cite "borrow rule #2" for it and nothing enforced it — a pointer
# across the realm boundary is mutable by whoever holds it, and a write through it
# commits under this realm's authority, so a reader becomes a writer with no
# crossing call and no storage deposit.
#
# The plant does not have to COMPILE, and that is worth saying: this guard reads
# .gno as text and never builds the realm, so turning a return type into a pointer
# is a legitimate plant even though the body no longer matches it.
control("an exported read that hands out a pointer", f"{KOURTV2}/folders.gno",
        "func FolderItems(courtSlug string, folderID uint64) []uint64 {",
        "func FolderItems(courtSlug string, folderID uint64) *[]uint64 {",
        "FolderItems returns *[]uint64",
        argv=["python3", READPURE])
# AND THE OTHER END OF THE SAME POINTER: one held in realm STATE, which is what the
# arm above stops from being handed out. twap.gno states it about the whole realm —
# the Ring "is never a heap object of its own, and never held by pointer in realm
# state" — and gives its reason, that inline it costs nothing extra where a *Ring is
# a second object per field. Nothing enforced it, and it is borrow rule #2 waiting
# for a read to hand it over.
#
# Two arms, because the two failures need opposite fixes: a pointer field is the
# violation, and a field pattern that has drifted off the code leaves the pointer arm
# scanning nothing and silent on a real one.
control("a twap.Ring held in realm state by pointer", f"{KOURTV2}/claim.gno",
        "\toi  twap.Ring // total stake, hourly, one week",
        "\toi  *twap.Ring // total stake, hourly, one week",
        "BY POINTER",
        argv=["python3", READPURE])
control("the Ring field pattern drifting off the code", f"{KOURTV2}/claim.gno",
        "\tyes twap.Ring // YES pool, hourly, one week",
        "\tyes twap.Circle // YES pool, hourly, one week",
        "expected 2",
        argv=["python3", READPURE])
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
        # allocators it confined ("… getPos, ensureAssocs, ensureSup all confined to write
        # paths"), so this arm reported "fires" whatever the plant did. Found by the
        # vacuity audit below, not by reading. The planted function's own name cannot
        # appear in a clean run.
        "StakedLeak calls getPos", argv=["python3", READPURE])
# NARROWED TO ONE ELEMENT ON PURPOSE. This plant used to name the whole ALLOCATORS
# tuple, and the tuple GREW — ensureAssocs and ensureSup joined it and pushed it onto two
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

print("\ncheck-render-text")
# The census that keeps user text behind its gate. Both policies it enforces are
# stated in modrender.gno and were enforced by nothing: claimTitleFor is "THE
# single place a claim's title becomes display text", and claimBodyVisible's
# callers "MUST SANITISE FOR [their] OWN OUTPUT CONTEXT". The plant drops one
# caller's sanitiser, which is the violation with teeth — sanitize.Block escapes
# CommonMark block types 1-5 but not 6 and 7, so a <form> in a body would only be
# CONTAINED, and gnoweb runs no HTML sanitiser after the realm.
control("a render gate that stops sanitising", f"{KOURTV2}/modrender.gno",
        "\treturn sanitize.Block(body)",
        "\treturn body",
        "does not apply sanitize.Block",
        argv=["python3", RENDERTEXT])

# AND THE FOREIGN HALF, added when the census grew past kourtv2 — which is where it
# had a hole. CourtName is sanctioned to return raw text because "consumers sanitise
# at their own output", and the one consumer, ccwrap, did not: it wrote the wrapped
# token's name into an H1. The guard's first run against the SHIPPED tree named that
# site, so this arm had a real defect to prove itself on before it had a plant.
#
# Two arms, because the two failures need opposite fixes. A display site that stops
# sanitising is an injection. A NEW reader of raw court text is a consumer nobody
# reviewed, and it may be perfectly fine — it just cannot be silent.
control("a wrap page that stops sanitising", f"{CCWRAP}/ccwrap.gno",
        "sanitize.InlineText(w.tok.GetName())",
        "w.tok.GetName()",
        "without applying sanitize.InlineText",
        argv=["python3", RENDERTEXT])

control("a new foreign reader of raw court text", f"{CCWRAP}/ccwrap.gno",
        "func Enabled(slug string) bool { return wraps.Has(slug) }",
        "func Enabled(slug string) bool { _ = kourtv2.CourtName(slug); return wraps.Has(slug) }",
        "not in FOREIGN_TEXT_READERS",
        argv=["python3", RENDERTEXT])

print("\ncheck-mutant-collisions")
# check-mutation-anchors compares the (pkg, file, find, replace) TRIPLE, so two
# rows expressing one mutation through different anchor text are distinct to it —
# eleven such pairs were found by hand before this guard existed. The arm uses an
# EXACT duplicate rather than a widened anchor, deliberately: the guard hashes the
# mutated SOURCE, so both arrive at the same code path and the hash cannot tell
# how the anchors differed. An exact twin needs no hardcoded realm text and so
# cannot rot. The widened-anchor case was ablated by hand when the guard landed.
#
# A ROW WHOSE ANCHOR STILL APPLIES, chosen by predicate rather than by position.
#
# Both arms below used to copy _corpus[0] and it has been pointing at
# realm/r/kourtv2/quality.gno, deleted with the quality lane. So the planted row
# was unappliable for the ANCHOR reason and never reached the question the arm
# asks -- the duplicate never got compared, the no-op never got measured -- and
# both arms reported SILENT, which reads as "the guard has a hole" when the truth
# is "the plant was smothered". MEASURED: planting a copy of row 0 puts "PROBE
# duplicate mutant" in the unappliable list and prints neither "SAME mutant" nor
# "one mutant"; planting a copy of the first LIVE row (index 9, SetTier's admin
# guard, directory.gno) prints both. The guard was right the whole time.
#
# Positional selection is the fragility, not that row 0 happens to be dead: a
# corpus reorder would break these arms again, silently, in the same way.
def _live_row(corpus):
    """The first row whose `find` still matches exactly once in its file."""
    for row in corpus:
        p = os.path.join(REPO, "realm/r", row.get("pkg", "kourtv2"), row["file"])
        if os.path.exists(p) and open(p, encoding="utf-8").read().count(row["find"]) == 1:
            return row
    raise SystemExit("selftest: no mutation row in the corpus still applies — "
                     "these two arms cannot plant anything (see `make anchors`)")


# Prepended with a JSON round-trip, not a string splice, for the reason inject()
# records below: an arm must not depend on the whitespace of the file it edits.
_col = "two rows that produce one mutant"
exercised.add(os.path.basename(COLLISIONS))
_bk = MUTS + ".selftest-backup"
shutil.copy(MUTS, _bk)
try:
    _corpus = json.load(open(_bk))
    _twin = dict(_live_row(_corpus))
    _twin["label"] = "SELFTEST duplicate mutant"
    with open(MUTS, "w") as _fh:
        json.dump([_twin] + _corpus, _fh, indent=2, ensure_ascii=False)
        _fh.write("\n")
    _r = subprocess.run(["python3", COLLISIONS], capture_output=True, text=True)
    _out = _r.stdout + _r.stderr
    if _r.returncode != 0 and "SAME mutant" in _out:
        print(f"  {_col:<44} fires")
    else:
        print(f"  {_col:<44} SILENT — exit {_r.returncode} on a duplicated row")
        failures.append(_col)
finally:
    shutil.move(_bk, MUTS)

# THE SECOND FAILURE MODE: a row that applies cleanly and changes NO BYTES. Not
# unappliable — it tests nothing. The realistic way in is a re-point after a
# refactor, where `find` is updated to the moved text and the same text lands in
# `replace`. Planted as find == replace, which is the degenerate form.
_nop = "a row whose replace changes nothing"
_bk2 = MUTS + ".selftest-backup"
shutil.copy(MUTS, _bk2)
try:
    _corpus2 = json.load(open(_bk2))
    _flat = dict(_live_row(_corpus2))
    _flat["label"] = "SELFTEST no-op row"
    _flat["replace"] = _flat["find"]
    with open(MUTS, "w") as _fh2:
        json.dump([_flat] + _corpus2, _fh2, indent=2, ensure_ascii=False)
        _fh2.write("\n")
    _r2 = subprocess.run(["python3", COLLISIONS], capture_output=True, text=True)
    _out2 = _r2.stdout + _r2.stderr
    if _r2.returncode != 0 and "changes NO BYTES" in _out2:
        print(f"  {_nop:<44} fires")
    else:
        print(f"  {_nop:<44} SILENT — exit {_r2.returncode} on a no-op row")
        failures.append(_nop)
finally:
    shutil.move(_bk2, MUTS)

# THE THIRD FAILURE MODE: a row whose mutant does not PARSE. It is not unappliable
# and it is not a no-op — it is a row that mutate.py would score as a CATCH, because
# a failing suite is what a catch looks like and an unparseable mutant fails the
# suite. mutate's detector is a catch-all over gno's error codes now, but this
# refuses the row where no suite has to run to find out, and the mutated source is
# already in hand. The plant is spelled out rather than derived from corpus[0], so it
# cannot quietly become parseable when the first row changes.
_unp = "a row whose mutant does not parse"
_bk3 = MUTS + ".selftest-backup"
shutil.copy(MUTS, _bk3)
try:
    _corpus3 = json.load(open(_bk3))
    _brk = {"pkg": "governor", "file": "governor.gno",
            "label": "SELFTEST unparseable row",
            "find": "\treturn p.yes, p.no, p.abstain, p.total",
            "replace": "\treturn p.yes, p.no, p.abstain, p.total))"}
    with open(MUTS, "w") as _fh3:
        json.dump([_brk] + _corpus3, _fh3, indent=2, ensure_ascii=False)
        _fh3.write("\n")
    _r3 = subprocess.run(["python3", COLLISIONS], capture_output=True, text=True)
    _out3 = _r3.stdout + _r3.stderr
    if _r3.returncode != 0 and "does not PARSE" in _out3:
        print(f"  {_unp:<44} fires")
    else:
        print(f"  {_unp:<44} SILENT — exit {_r3.returncode} on an unparseable row")
        failures.append(_unp)
finally:
    shutil.move(_bk3, MUTS)

# THE FOURTH FAILURE MODE, and the one that actually cost something: a row whose
# mutant PARSES and does not COMPILE. Go's loudest difference between those two is
# the unused variable — delete an `if !fire { return }` and `fire` is still
# declared, still parses, and never builds.
#
# Ten rows sat in this corpus that way. A hand-rolled probe read the non-zero exit
# of a build failure as coverage and reported all ten CAUGHT; mutate-parallel, which
# classifies build errors separately, showed them INVALID. Two of the ten, once
# rebuilt so they compiled, were genuine SURVIVORS — one guarding a single-key
# comment purge, the other a single-moderator hide. Nothing in `make check` could
# see any of it. This arm is why it can now.
_unb = "a row whose mutant parses but cannot build"
_bk4 = MUTS + ".selftest-backup"
shutil.copy(MUTS, _bk4)
try:
    _corpus4 = json.load(open(_bk4))
    # Spelled out rather than derived from the corpus, for the same reason the
    # parse plant above is: it must not quietly become buildable.
    _orph = {"pkg": "kourtv2", "file": "boardlegal.gno",
             "label": "SELFTEST orphaned-variable row",
             "find": "\tif !fire {\n\t\treturn\n\t}\n\tr.purged = true",
             "replace": "\tr.purged = true"}
    with open(MUTS, "w") as _fh4:
        json.dump([_orph] + _corpus4, _fh4, indent=2, ensure_ascii=False)
        _fh4.write("\n")
    _r4 = subprocess.run(["python3", COLLISIONS], capture_output=True, text=True)
    _out4 = _r4.stdout + _r4.stderr
    if _r4.returncode != 0 and "declared and unused" in _out4:
        print(f"  {_unb:<44} fires")
    else:
        print(f"  {_unb:<44} SILENT — exit {_r4.returncode} on an unbuildable row")
        failures.append(_unb)
finally:
    shutil.move(_bk4, MUTS)

print("\ncheck-control-anchors")
# The other half of check-guards-armed's division of labour: that one says
# REGISTERED, selftest says BROKEN CONTROL — and until this guard existed, only
# selftest said it, which means only when selftest ran. A plant whose anchor has
# rotted is a no-op: the guard runs against an unmodified tree, correctly says
# nothing, and the arm reports SILENT. Six arms were lost that way at once.
#
# THE PLANT IS BUILT BY CONCATENATION, deliberately, exactly as the
# check-guards-armed arm below builds _reg: if this file contained the literal
# it searches for, the string would appear TWICE here — once in the arm it
# breaks and once in this arm's own find — and the plant would be ambiguous.
# Do not tidy it away.
_ca = 'if r.get("elsewh' + 'ere"):'
control("a control arm whose plant no longer applies", SELF,
        _ca, _ca.replace("elsewhere", "elsewhereGONE"),
        "anchor matches 0x",
        argv=["python3", CONTROLS])

print("\ncheck-elsewhere")
# The third level of the `elsewhere` question. A row carrying one is excused from the
# mutation harness because something ELSE objects; if that something stops objecting,
# the row keeps surviving in `make gaps` — the expected result there — and nothing
# notices the excuse went hollow. So the plant weakens the assertion inside a named
# txtar and requires the check to say the harness no longer holds the property.
control("a named txtar that stopped asserting", "gnoland/testdata/kourtv2_paymentauth.txtar",
        "stderr 'direct user call'",
        "stderr ''",
        "does not assert this property",
        argv=["python3", ELSEWHERE])
# Fail CLOSED: the annotation renamed out from under the collector leaves it checking
# nothing, which would report clean for ever.
control("the elsewhere annotation renamed", ELSEWHERE,
        'if r.get("elsewhere"):',
        'if r.get("elsewhereNOPE"):',
        "measuring nothing",
        argv=["python3", ELSEWHERE])
# A HARNESS THAT DIES IS NOT A HARNESS THAT OBJECTS, and "exited nonzero" cannot
# tell them apart. The plant makes every mutation unbuildable by appending a broken
# declaration to the file the check writes; the realm then kills the in-memory node
# during genesis, the txtar never runs, and the exit code is nonzero all the same.
# Planting here rather than in the corpus on purpose — an arm that edits the corpus
# JSON depends on its whitespace, which turned six anchor arms into BROKEN CONTROL
# once already (see inject's comment).
control("a harness that dies instead of objecting", ELSEWHERE,
        'open(path, "w").write(src.replace(row["find"], row["replace"], 1))',
        'open(path, "w").write(src.replace(row["find"], row["replace"], 1)'
        ' + "\\nfunc (")',
        "WITHOUT NAMING A LINE",
        argv=["python3", ELSEWHERE])

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

print("\ncheck-seed-emitters")
# THE HEADLINE ARM REPRODUCES THE DEFECT THE GUARD WAS WRITTEN FOR. emit_txs
# walks scenario STEPS and the clock seal is not one, so the genesis path used to
# end with the test clock still ARMED where the broadcast path ends sealed — two
# different chains from one scenario, differing in the single piece of state that
# decides whether later transactions can still move every date on the chain.
# Measured on kourt-1 before the fix: TestClockActive() answered true after a
# genesis seed. Invisible in the docket, which is why it survived until the
# genesis path was pointed at a chain somebody reads.
#
# WANTS "SealTestClock", NOT the generic mismatch line, and the arm below is why:
# both plants produce "the two seeds do not agree", so sharing that string would
# leave two arms each able to pass on the other's complaint. The guard prints the
# differing transaction as a tuple, so the seal's own name is available and pins
# this arm to the defect it was written for.
control("a genesis seed that forgets to seal the clock", SCENARIO,
        '    if scn._clock_armed:\n        out.append(tx_line(DEPLOYER, "SealTestClock", []))',
        '    if False:\n        out.append(tx_line(DEPLOYER, "SealTestClock", []))',
        "'SealTestClock'", argv=["python3", SEEDEMIT])
# The same class from the other direction: a step kind that reaches one emitter
# and not the other. Refusals are skipped by BOTH today, each saying so at its
# own site, so letting them into the genesis file is the mirror of the seal.
# Keeps the generic mismatch line, which is all this plant can promise: which
# transaction differs first depends on where the scenario's first refusal sits.
control("a step kind that reaches only one emitter", SCENARIO,
        '        if st["kind"] != "call":\n            continue',
        '        if st["kind"] not in ("call", "refuse"):\n            continue',
        "the two seeds do not agree", argv=["python3", SEEDEMIT])
# THE REFUSAL IS PART OF THE CONTRACT. A scenario that mines cannot become a
# genesis file, because every genesis transaction lands in the same block — an
# emitter that quietly accepted one would seed a chain at the wrong height. This
# plants exactly that acceptance, and wants the height complaint rather than the
# sequence one, so it cannot pass on the arms above.
control("a mining scenario accepted as a genesis file", SCENARIO,
        '    mined = sum(st["n"] for st in scn.steps if st["kind"] == "mine")\n    if mined:',
        '    mined = sum(st["n"] for st in scn.steps if st["kind"] == "mine")\n    if False:',
        "still produced a file", argv=["python3", SEEDEMIT])
# And the tripwire, because a guard that finds no scenarios reports a clean tree
# forever — the same shape as check-browser-checks-registered's "too few to be a
# real scan".
control("a scan that finds no scenarios", SEEDEMIT,
        '"scenarios" / "*.py"', '"scenarios" / "*.nope"',
        "nothing to compare", argv=["python3", SEEDEMIT])

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
# The latch is a package GLOBAL and the suite pairs every arming with a deferred
# reset, in comment as well as in code — but nothing enforced the pairing, so the
# 21st test would have leaked an armed clock and frozen heightNow() for everything
# after it. The symptom lands far away: a test deriving state from the RAW chain
# height then writes into heightNow()'s future and checkpoint panics with "the
# clock went backwards", in a test that did nothing wrong. Measured that panic on
# an ad-hoc probe before this arm existed.
control("a test that arms the clock and leaves it armed", TCTEST,
        "\tdefer resetTestClock(alice) // the latch is global; do not leak an armed clock\n"
        "\ttcArmed, tcBase, tcFloor = true, testingTime(), testingTime()\n"
        "\ttcHeightBase, tcHeightFloor = testingHeight(), testingHeight() // a fresh scenario chain",
        "\ttcArmed, tcBase, tcFloor = true, testingTime(), testingTime()\n"
        "\ttcHeightBase, tcHeightFloor = testingHeight(), testingHeight()",
        "never defers resetTestClock", argv=["python3", HSHIM])
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
print("\ncheck-chat-limits")
# The defect: a limit restated in a second language and left to drift. It already
# has — chat_render.js asserted the moniker input's maxlength equalled the
# server's limit, which stopped being true when the limit moved to counting
# LETTERS, and the assertion was wrong for two commits with nothing to say so.
control("the client drifts from the server", CHATJS,
        "const CHATLIMITS = {body: 400, moniker: 24, bytes: 4096};",
        "const CHATLIMITS = {body: 500, moniker: 24, bytes: 4096};",
        "disagree about a limit", argv=["python3", CHATLIM])
control("the server moves and the client does not", SANITIZE,
        "\tMaxMonikerRunes = 24\n", "\tMaxMonikerRunes = 32\n",
        "disagree about a limit", argv=["python3", CHATLIM])
# And the tripwire: a comparison that found nothing to compare must not report
# agreement.
control("the CHATLIMITS anchor is lost", CHATJS,
        "const CHATLIMITS = {body: 400, moniker: 24, bytes: 4096};",
        "const CHATLIMITSX = {body: 400, moniker: 24, bytes: 4096};",
        "lost its anchor", argv=["python3", CHATLIM])

print("\ncheck-curation-reachable")
# The defect: nine curation entrypoints built in this programme — subfolders,
# MoveFolder, retire/restore, OrderFolders, both association verbs, SetCourtDesc —
# reachable from no page, while the curate page's own prose said the realm did
# all of it. Worst was OpenClaimP: a claim body was asked for by name, shipped,
# and RENDERED by the claim page, while both "Open a claim" buttons still called
# OpenClaim, so the field could be read and never written.
# THE ANCHOR NAMES THE ENTRYPOINT, NOT THE LABEL. It carried the button's words
# — "Order folders" — and folders became sets, so the plant stopped applying and
# the arm went SILENT while the guard it protects went on passing. The label is
# prose and will move again; the entrypoint is the thing under test, and renaming
# it is the defect being planted.
control("an entrypoint the product cannot ask for", WEBPAGE,
        '"OrderFolders",{courtSlug', '"OrderFoldersXX",{courtSlug',
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
# RE-ANCHORED. The plant used to cut ',\n                "chat_all.js"', and the
# list was later reflowed onto fewer lines when run.js gained ONLY= filtering —
# so the plant matched nothing, `make controls` reported this arm SILENT, and the
# guard it arms was meanwhile broken by the same edit for the same reason (the
# literal moved from CHECKS to ALL). Two failures, one reflow, and the arm that
# should have caught the first was disabled by it.
control("a browser harness no runner runs", RUNJS,
        ', "chat_all.js"', "",
        "not reachable from run.js", argv=["python3", BROWREG])
# A registration that points at nothing. `make web-visual` would say FAIL missing
# at RUN time, but web-visual needs puppeteer and is not in `check` — which is
# the whole reason this guard is static.
control("a runner lists a file that is not there", RUNJS,
        '"route_crawl.js"', '"route_crwal.js"',
        "is registered but does not exist", argv=["python3", BROWREG])
# A wrapper that runs nothing prints "0 browser check(s) pass" — a green line for
# no work done, which is the exact shape of the failure this guard is about.
# THE PLANT NAMES THE WHOLE LIST, so it breaks every time a check joins the
# wrapper — which it just did, and the arm went SILENT rather than red. Anchored
# on the opening bracket and the first entry instead: enough to be unique, and
# short enough that the next sub-harness to arrive does not cost this arm.
control("a registered wrapper with an empty list", CHATALL,
        'const CHECKS = [', 'const CHECKS = []; const CHECKS_WAS = [',
        "empty CHECKS list", argv=["python3", BROWREG])
# And the tripwire, because a guard policing an empty directory reports a clean
# tree forever.
# A LEAF THAT NAMES HARNESSES AND NEVER RUNS THEM is walked as a wrapper, so
# everything it names is counted as reached — coverage claimed for checks nothing
# invokes, which is this guard's own failure mode one level in. The agreement
# between the two markers was a measurement in a comment ("MEASURED across all 18
# files") until the tree grew to twenty-seven; it is a loop now, and this is what
# holds the loop.
control("a leaf that lists harnesses it never spawns", "web/tests/browser/map_draws.js",
        "const {PAGE, demoPage} = require('./harness');",
        'const CHECKS = ["eye_inline.js"];\nconst {PAGE, demoPage} = require(\'./harness\');',
        "names .js files but never spawns one", argv=["python3", BROWREG])
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
# ACROSS THE FILE BOUNDARY, which this guard could not see until it read both
# shipped files. chat.js and index.html's inline script share one global scope —
# the page loads chat.js with a plain <script src> — and chat.js's
# `function chatBase(cfg)` lost to index.html's `function chatBase()`, declared
# later. That silently removed chat.js's demo guard and a demo court page started
# calling the real chat service (500e543). The guard for exactly that defect was
# reading one of the two files.
control("a name declared in chat.js AND the page", "web/chat.js",
        "function chatEndpoint(cfg) {", "function chatBase(cfg) {",
        "declared more than", argv=["python3", DUPES])
# And the tripwire, which is the half that matters if the scan ever stops
# finding anything: a guard that counted zero declarations would report every
# name unique having asked nothing.
control("a script block the scan cannot find", WEBPAGE,
        "<script>", "<scriptX>",
        "no <script> block to scan",
        argv=["python3", DUPES])

print("\ncheck-web-constants")
# WEEK is not decoration: the overlay passes it INTO realm reads — TrailingOI and
# TrailingYes both take it as the trailing window — so a drift from periodBlocks
# queries the wrong span while the page keeps rendering and keeps looking right.
# The realm side carries three corpus rows; the overlay's copy carried nothing,
# and check-live-reads is the only other thing that mentions it and is
# deliberately outside `make check`.
control("the overlay's mirrored constant drifts", WEBPAGE,
        "const WEEK = 120960;", "const WEEK = 120961;",
        "queries the wrong window", argv=["python3", WEBCONST])
# THE ROUNDING, NOT ONLY THE CONSTANT. CURVE_D was mirrored and the ceil was not,
# so a purchase quote could round down while the chain rounded up — a receipt
# promising a unit the chain will not give, silently, and only on the amounts
# where the division does not come out even. buy_test.js cross-checks curveQuote
# against a brute-force reference written in JavaScript, which encodes the same
# intent as the code beside it and would follow it into the same mistake.
# BOTH SIDES ARE ARMED, because the divergence is symmetric: the overlay can
# stop rounding up, or the realm can, and the reader of a receipt cannot tell
# which happened.
control("the overlay stops rounding the curve up", WEBPAGE,
        "(s1*s1 - s0*s0 + 2n*CURVE_D - 1n)/(2n*CURVE_D)",
        "(s1*s1 - s0*s0)/(2n*CURVE_D)",
        "no longer computes cost as ceil", argv=["python3", WEBCONST])
control("the realm stops rounding the curve up", "realm/p/curve/curve.gno",
        "lo2, carry := bits.Add64(lo, m-1, 0)",
        "lo2, carry := bits.Add64(lo, 0, 0)",
        "stopped doing", argv=["python3", WEBCONST])

print("\ncheck-block-time")
# TWO FAILURE MODES, and they are not the same shape, so both are armed.
#
# The first is the block time drifting between the three languages that each
# hold a copy — the overlay, p/governor (which stamps closesTime from it) and
# the scenario generator. Nothing imports it across those boundaries; a check is
# the only thing that can.
#
# The second is nastier and is the one that motivated the file: a deadline is
# written down in BLOCKS and in SECONDS, and the realm reads whichever half a
# record carries — openrewards.gno, "Seconds first, blocks only for a claim
# whose verdict predates the stamp". So changing one half does not fail, it
# gives an old record and a new one different windows, forever, correctly per
# the code. The seconds half is the one with no mirror in check-web-constants
# (FINALIZE_GRACE pins the BLOCKS half only), so that is the direction planted.
control("a block is a different length in p/governor", GOVGNO,
        "const secsPerBlock = int64(5)", "const secsPerBlock = int64(6)",
        "disagrees with itself", argv=["python3", BLOCKTIME])
control("a deadline's seconds half moves without its blocks half", CLOCKGNO,
        "finalizeGraceSecs = int64(7 * 86400)",
        "finalizeGraceSecs = int64(3 * 86400)",
        "two different deadlines", argv=["python3", BLOCKTIME])

print("\ncheck-media-hosts")
# The hosts a claim's evidence may live on are written down three times — the
# realm refuses to STORE a mirror elsewhere, the overlay refuses to OFFER one,
# and the page's CSP is what the browser actually obeys. Drift between them is
# invisible in both directions: add a host to the realm and forget the CSP and
# the author sees a broken image with no error anywhere, because the browser's
# refusal never reaches the chain. These three arms are one per copy.
control("the realm allows a host the overlay does not", MEDIAGNO,
        '"ipfs.io",', '"ipfs.io",\n\t"drifted.example",',
        "disagree", argv=["python3", MEDIAHOSTS])
# The plant has to name the img-src copy UNIQUELY. It used to be
# " https://cloudflare-ipfs.com;", which matched once — until media-src arrived
# carrying the same host list, and then it matched twice and the arm quietly
# stopped testing anything. check-control-anchors caught that; the trailing
# directive name is what makes each copy distinguishable.
control("the page's CSP drops a host the realm still stores", NGINXCONF,
        " https://cloudflare-ipfs.com; connect-src", "; connect-src",
        "refuses to load", argv=["python3", MEDIAHOSTS])
control("the page's media-src drops a host the realm still stores", NGINXCONF,
        " https://cloudflare-ipfs.com; font-src", "; font-src",
        "refuses to play", argv=["python3", MEDIAHOSTS])
# Not a host list at all, but the same guard and the same class of silent
# failure: without the route, every exhibit on every claim page is a broken
# image, because the realm's markdown points every reader at /m/<sha256>.
control("the archive route goes missing", NGINXCONF,
        "location /m {", "location /gone {",
        "unreachable", argv=["python3", MEDIAHOSTS])

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
    # And the realm nobody budgeted OR exempted. The arm above catches a filetest
    # with no budget; a realm with NO FILETEST never reached that check at all,
    # which is how ccwrap sat unwatched — and the enumeration that found ccwrap read
    # the TARGETS list instead of the directory and missed offerer as well. The
    # directory is the authority now, so this arm removes an EXEMPT reason rather
    # than a budget: the realm still exists, and nothing accounts for it.
    control("a realm nobody budgeted or exempted", STORE,
            '    "offerer": "a demo realm offering one kind to govern; its whole exported read "\n'
            '               "surface is Greeted(), two package scalars that cannot allocate",\n',
            "", "UNBUDGETED", argv=["python3", STORE])

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

    # AND THE HALF THE TOGETHER-RUN FIX LEFT BEHIND. That fix made the guard check
    # "passes together"; this one is about whether the per-test run happened AT ALL.
    # `gno test -run` exits 0 when the filter matches nothing, and without `-v` the
    # output is indistinguishable from a pass — filetests run either way, printing
    # their GAS lines and then `ok`. The loop read only the return code, so such a
    # test was counted in `total` and asserted to pass alone having never run.
    #
    # THE PLANT IS IN THE GUARD'S OWN FILTER, not in a test source, and that is
    # forced rather than lazy: nothing a test file can contain produces a name the
    # harvester finds and `-run` misses. Measured across the tree — every one of the
    # 751 `func Test*` declarations has a real test signature (564 crossing, 187
    # plain) — so the hole is latent today and only a mutated filter can reach it.
    control("a test that never ran is not a pass",
            os.path.join(REPO, "scripts/check-isolation.py"),
            'f"^{t}$", "-v"',
            'f"^{t}zzzNOMATCH$", "-v"',
            "never ran at all",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestARefilingIsLegalExactlyAtTheDeathDeadline"])

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
    # AND THE PARSE DOOR, which is a different one. The arm above plants a
    # nonexistent FIELD, so gno answers with gnoTypeCheckError — the one code the
    # detector used to name. A mutant that does not PARSE answers with
    # code=gnoParserError and "0 build errors", and nothing in that output says
    # "build failure", so it scored as a CATCH: coverage that did not exist.
    # Measured on a staged copy with an unbalanced paren in lock.gno before the
    # detector was widened to any code=gno*Error.
    feed("a mutant that cannot parse", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "\treturn p.yes, p.no, p.abstain, p.total",
        "replace": "\treturn p.yes, p.no, p.abstain, p.total))"}], "INVALID")
    # AND THE THIRD DOOR, which no amount of reading gno's output can close. The two
    # arms above are decided from error codes; this one cannot be. A planted goroutine
    # is a mutant that CANNOT RUN — gno excludes them — and it reports
    # "0 build errors, 1 test errors ... goroutines are not permitted
    # (code=gnoUnknownError)". A mutation whose only failure is a REALM PANIC AT INIT,
    # which is a genuine catch, reports gnoUnknownError too. Same code, opposite
    # verdicts, so mutate.py asks `gno lint` instead of reading the text — measured
    # both ways: the goroutine mutant lints 1, and the Bps mutation whose kourtv2
    # init invariant panics lints 0 and stays a catch.
    feed("a mutant that cannot run at all", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "\treturn p.yes, p.no, p.abstain, p.total",
        "replace": "\tgo func() {}()\n\treturn p.yes, p.no, p.abstain, p.total"}], "INVALID")
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

    # AN EMPTY BATCH IS THE CHEAPEST NON-RESULT OF ALL, and it read as a pass for
    # the whole life of the file: `[]` decodes, no shard dies, and the verdict is
    # "0 not caught ... of 0" at exit 0. The way to reach it is a filtered batch
    # whose filter matched nothing — which is how every ad-hoc batch here is built.
    lbl = "an empty batch is refused, not reported"
    r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "2"],
                       input="[]", capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode != 0 and "measure nothing" in out:
        print(f"  {lbl:<44} fires")
    else:
        print(f"  {lbl:<44} SILENT — exit {r.returncode} on zero rows")
        failures.append(lbl)

    # AND THE GAP FILE READ THE OTHER WAY ROUND. `make gaps` runs the KNOWN-GAPS
    # batch, where every row is SUPPOSED to survive — so the finding there is a row
    # that has STARTED being caught, meaning the gap closed and nobody struck it
    # off. Until --expect-survive existed the run printed its verdict and exited 0
    # either way, so that finding was visible only to a reader who did the
    # arithmetic by hand (sent − surviving − by-design). Same governor anchor as the
    # arms above, deliberately: if it rots, three arms break loudly rather than one
    # silently. Measured caught by TestTheSlotCountBelongsToThePageNotTheSection.
    lbl = "a closed gap is a finding, not a footnote"
    r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "1",
                        "--expect-survive"],
                       input=json.dumps([
                           {"pkg": "governor", "file": "governor.gno",
                            "label": "SELFTEST a row that is caught",
                            "find": "const maxLive = 64",
                            "replace": "const maxLive = 63"}]),
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode != 0 and "CAUGHT in a batch" in out:
        print(f"  {lbl:<44} fires")
    else:
        print(f"  {lbl:<44} SILENT — exit {r.returncode} on a caught row")
        failures.append(lbl)

    # AND THE OTHER HALF OF THAT FLAG, which the first version got wrong. mutate.py
    # puts four things in its not-caught list and three are NON-RESULTS —
    # `[timed out]`, `[invalid]`, `[bad anchor]`. Counting them as not-caught is
    # right for the main corpus (fail closed), but inverted for the gap file it
    # flips: a row that never ran would be reported as "still surviving", which is
    # the very thing --expect-survive was added to stop. Measured for real — the
    # pre-fix code printed "every one of the 1 row(s) still survives" for a row that
    # HUNG and was killed at 120s.
    #
    # The plant is a rotted anchor rather than a hang: same non-result class, and it
    # needs no timeout, so this arm costs one baseline instead of three minutes.
    lbl = "an unmeasured row is not a surviving gap"
    r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "1",
                        "--expect-survive"],
                       input=json.dumps([
                           {"pkg": "kourtv2", "file": "emission.gno",
                            "label": "SELFTEST an anchor that matches nothing",
                            "find": "NoSourceLineSaysThis", "replace": "x"}]),
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode != 0 and "UNMEASURED" in out:
        print(f"  {lbl:<44} fires")
    else:
        print(f"  {lbl:<44} SILENT — exit {r.returncode} on a row that never ran")
        failures.append(lbl)

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
    # on tests nobody had touched — association_test once, associationcaps_test the
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


print("\ncheck-guards-run")
# The OTHER half of "is this guard doing anything": check-guards-armed proves a
# guard has a control arm, and this one proves `make check` still reaches it. A
# guard nothing runs reads like coverage in the tree and in review, and reports
# nothing — and the Makefile is edited by hand, so the way one is lost is an
# ordinary edit. Both mutations below were verified to SURVIVE before this guard
# existed: nothing in the tree noticed either.
control("a target `check` no longer depends on", MAKEFILE,
        "paths guards web-guards controls", "paths guards controls",
        "reachable from no target", argv=["python3", GRUN])
control("a guard dropped from its target", MAKEFILE,
        "\tpython3 scripts/check-curation-reachable.py\n", "",
        "reachable from no target", argv=["python3", GRUN])
# AN EXEMPTION IS A CLAIM ABOUT TODAY, so both ways it can rot are armed: naming
# a guard that no longer exists, and shadowing one that `check` has since started
# running. A list that only grows becomes the place unrun guards go to be
# forgotten, which is the failure this guard is about.
control("an exemption for a guard that is gone", GRUN,
        '    "check-live-reads.py":',
        '    "check-gone-forever.py": "stale",\n    "check-live-reads.py":',
        "no such guard exists", argv=["python3", GRUN])
control("an exemption shadowing a guard check runs", GRUN,
        '    "check-isolation.py":',
        '    "check-web-css.py": "stale",\n    "check-isolation.py":',
        "runs it now", argv=["python3", GRUN])
# Fail CLOSED, the rule every census here carries: a scan that matches nothing
# must not report a clean tree.
control("a guard scan too small to be real", GRUN,
        'os.path.join(REPO, "scripts", "check-*.py")',
        'os.path.join(REPO, "scripts", "check-zzz-*.py")',
        "matched too little to be real", argv=["python3", GRUN])


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
# THE RESOLVER IS SHARED, not re-written here. This function's first version took
# `want` and every argv element only as an ast.Constant, and counted the rest out
# loud: 7 of 117 unresolvable. Six of those seven were arms passing no `argv` at
# all — control() defaults them to check-citations, so they were resolvable all
# along — and the seventh builds its want by concatenation. check-control-anchors
# already evaluates the five shapes these call sites use (literal, module
# constant, f-string, os.path.join, concatenation) and is measured at 117 of 117,
# so it is imported rather than copied. A third copy of this logic is exactly the
# duplication the corpus now fails a build over.
def _resolver():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "cca", os.path.join(REPO, "scripts", "check-control-anchors.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def vacuity_audit():
    import ast
    cca = _resolver()
    src = open(__file__).read()
    tree = ast.parse(src)
    consts = cca.build(tree, {"REPO": REPO})
    parsed, unresolved, cache, bad = 0, 0, {}, []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and getattr(node.func, "id", "") == "control"):
            continue
        parsed += 1
        want = cca.ev(node.args[4], consts) if len(node.args) >= 5 else None
        if want is None:
            unresolved += 1
            continue
        label = cca.ev(node.args[0], consts) or "?"
        # control()'s own default when an arm passes no argv.
        cmd = ["python3", "scripts/check-citations.py"]
        for kw in node.keywords:
            if kw.arg == "argv":
                if not isinstance(kw.value, ast.List):
                    cmd = None
                    break
                parts = [cca.ev(e, consts) for e in kw.value.elts]
                cmd = None if any(x is None for x in parts) else parts
        if not cmd:
            unresolved += 1
            continue
        key = tuple(cmd)
        if key not in cache:
            # stdin CLOSED, and a timeout, because this loop runs whatever a
            # control arm names — and one of those things reads a batch from
            # stdin. With stdin inherited it blocks on a pipe that never reaches
            # EOF, and the whole selftest deadlocks in its last section with no
            # output and nothing to blame: measured, a 32-minute run that had to
            # be unstuck by killing the child by hand. A guard-runner that can
            # hang forever is worse than one that reports a wrong answer, because
            # a wrong answer at least ends.
            r = subprocess.run(list(cmd), capture_output=True, text=True,
                               errors="replace", cwd=REPO,
                               stdin=subprocess.DEVNULL, timeout=600)
            cache[key] = r.stdout + r.stderr
        # THE RETURN CODE IS DELIBERATELY IGNORED, and this was tried the other way
        # round and REVERTED, so do not "fix" it again.
        #
        # The question here is only ever "does this guard print `want` WITHOUT the
        # plant", and the output answers that whatever the exit status. Gating on
        # rc == 0 looks like an improvement because a RED guard prints its findings,
        # and an arm whose want names the defect the guard is currently reporting
        # gets flagged — which feels like a false accusation. It is not. That arm
        # genuinely cannot tell its plant from the standing failure while the repo
        # is in that state, so "wants what the clean run prints" is the precise and
        # actionable truth, and the remedy is to FIX THE GUARD'S FINDING rather than
        # to touch the arm.
        #
        # Two cases proved it. "a control arm whose plant no longer applies" wants
        # 'anchor matches 0x'; with the eight broken arms still in this file
        # check-control-anchors exited 1 saying that three times, the arm was flagged,
        # and fixing the eight cleared the flag with no change to the arm. And "an
        # entrypoint the product cannot ask for" is flagged today because
        # check-curation-reachable is red over four image verbs the product cannot
        # invoke — correct, and it stays flagged until that is decided.
        #
        # Gating on rc costs more than it buys: FOUR of the five guards that exit
        # non-zero here are red BY DESIGN, because the arm's own argv names a
        # deliberately failing subject — mutate.py's "a suite that is already
        # failing", check-isolation's two --only TestSelfTest* tests, and
        # check-live-reads pointed at 127.0.0.1:1 to exercise its refusal. Skipping
        # those turned one exact verdict into five vague ones and took the
        # did-not-fire list from 4 to 6. Measured, then reverted.
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
