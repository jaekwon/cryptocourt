#!/usr/bin/env python3
"""Scenario runner: a chain story, written once, run two ways.

A scenario is a Python module that builds a list of steps against the API in
this file. It compiles to a txtar script (run by `make txtar-test`, a real
in-memory node) and — later — to a plan of gnokey calls against a live node the
website can read. One source, two targets, so the demo and the end-to-end test
cannot drift apart.

WHY PYTHON DATA AND NOT A BESPOKE GRAMMAR. Two design passes argued this out.
The domain needs quoted free text (folder names and descriptions), trees (the
demo's folders nest), and repetition (three failed dispute rounds; two thousand
blocks) — so a line grammar would have grown quoting, then key=value, and would
have rebuilt Python's own call syntax with worse errors and a parser of its own
to test. A module gets comments, real line numbers in tracebacks, and constants
like YES/NO that cannot coerce (YAML would read a bare `no` as false, and this
domain's tokens are literally yes and no).

WHAT THIS FILE REFUSES TO DO.

  * It does not predict height. tm2 proposes an extra "proof block" whenever the
    app hash changed, so the same script can finish at different heights run to
    run (measured: 6/7/7/6/8), so no step names an absolute height and no
    assertion compares one. Wall-clock IS predicted, because the test clock is
    frozen while armed and only `advance` moves it. (An earlier draft of this
    paragraph claimed height was "ASSERTED against the chain"; no such verb was
    ever built, and a docstring promising a guard that does not exist is worse
    than one that admits the gap.)
  * It does not let an assertion call a write. Several entrypoints read like
    getters and are transactions (AuthorBonus, PullCarrot, ClaimMetaFranchise
    ...); an `expect` naming one would broadcast while pretending to query. The
    guard is an ALLOWLIST read out of the realm source at emit time, not a
    hand-kept denylist — a denylist is only as good as the last time someone
    remembered to extend it, and this one had already missed
    ClaimMetaFranchise(cur realm).
  * It does not let a refusal pass on a simulation. `gnokey maketx` defaults to
    -simulate test and returns BEFORE broadcasting when the simulation errors —
    so a plain `! gnokey ...` proves only that the simulator refused. Refusals
    emit -simulate skip and are asserted on-chain.
"""

import base64
import json
import re
import shlex
import pathlib
import sys

REALM = "gno.land/r/kourt/kourtv2"
CHAINID = "tendermint_test"
GAS = "-gas-fee 1000000ugnot -gas-wanted 200000000"
# The same ceiling, as a number: the genesis txs-file writes JSON, not flags,
# and two spellings of one budget is how they drift apart.
GAS_WANTED = 200_000_000
DEPLOYER = "test1"  # the key the txtar harness deploys with, hence the deployer
# Every transaction pays GAS_FEE_UGNOT, including the self-transfers that mine
# blocks — so a scenario's premine has to cover its own mining or the deployer
# goes broke PARTWAY THROUGH, leaving a half-seeded chain and a confusing
# "insufficient funds". emit_accounts sizes it from the scenario instead of
# guessing; this is the floor for a scenario that mines nothing.
GAS_FEE_UGNOT = 1_000_000
# gnodev premines EVERY key in the keybase at 10e12 ugnot and lets -add-account
# override it (contribs/gnodev/accounts.go:53-68 — the address branch assigns and
# continues past the default). So naming an account can only make it POORER, and
# an earlier sizing pass quietly did exactly that to the deployer. Never go below
# the default we would have got for free.
GNODEV_DEFAULT_PREMINE = 10_000_000_000_000
DEPLOYER_PREMINE_MIN = GNODEV_DEFAULT_PREMINE

YES, NO, ABSTAIN = "0", "1", "abstain"

def _realm_reads():
    """Every exported entrypoint that is genuinely a READ, from the source.

    FAILS CLOSED. The set is built by union, so every looseness in the scan
    ADDS permission, and the thing being permitted is an assertion that would
    otherwise broadcast a transaction. Two proven leaks are closed here:

      * a write whose realm parameter is not spelled `cur` — the realm already
        writes `rlm realm` in one place (dispute.gno) — so ANY first parameter
        of type `realm` marks a write, whatever it is named;
      * a `func` inside a block comment, whose name was harvested as a read
        even though the live function of that name takes `cur realm`.

    Derived rather than listed because the previous hand-kept denylist had
    already missed ClaimMetaFranchise(cur realm).
    """
    d = pathlib.Path(__file__).resolve().parent.parent / "realm" / "r" / "kourtv2"
    if not d.is_dir():
        raise SystemExit(f"scenario.py: no realm at {d} — has it been renamed again?")
    reads, writes = set(), set()
    for f in sorted(d.glob("*.gno")):
        if f.name.endswith("_test.gno") or f.name.endswith("_filetest.gno"):
            continue
        src = f.read_text(encoding="utf-8")
        src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)   # block comments
        src = re.sub(r"^\s*//.*$", "", src, flags=re.M)    # line comments
        for m in re.finditer(r"^func\s+([A-Z]\w*)\s*(?:\[[^\]]*\])?\(([^)]*)\)", src, re.M):
            name, params = m.group(1), m.group(2).strip()
            first = params.split(",")[0].strip()
            (writes if re.search(r"\brealm\b", first) else reads).add(name)
    # A name seen as a write ANYWHERE loses its read status: overlap means the
    # scan is ambiguous, and ambiguity must not resolve to "safe to assert".
    reads -= writes
    if not reads:
        raise SystemExit("scenario.py: found no realm reads — has realm/r/kourtv2 moved?")
    return reads


REALM_READS = None  # filled lazily; the realm is only read when a scenario compiles

DEPS = [
    "gno.land/p/kourt/checkpoint/v0",
    "gno.land/p/kourt/grc20votes/v0",
    "gno.land/p/kourt/governor/v0",
    "gno.land/p/kourt/twap/v0",
    "gno.land/p/kourt/curve/v0",
    REALM,
]


class Scenario:
    """A story about a chain. Build it, then emit it."""

    def __init__(self, name, preamble=""):
        self.name = name
        self.preamble = preamble  # NOT `note`: that is a step verb below
        self.accounts = []          # hoisted: adduser must precede gnoland start
        self.steps = []
        self._clock_armed = False
        # ARMED and EVER-ARMED are different questions, and conflating them is
        # exactly the bug this project already fixed inside the realm
        # (testclock.gno's tcEverArmed): sealing removes the steering wheel, not
        # the invented dates. A scenario that armed, advanced twelve weeks and
        # sealed has _clock_armed False and a chain full of fabricated stamps.
        self._clock_ever_armed = False
        self._advanced = 0          # the one axis we can predict
        self._advanced_height = 0   # blocks moved by the override, not mined

    # -- actors ----------------------------------------------------------
    def account(self, name, ugnot=100_000_000):
        if name == DEPLOYER:
            raise ValueError(f"{DEPLOYER} is the harness's own key; it needs no adduser")
        if name == "deployer":
            # emit_accounts already emits a `deployer` row, and seed-node.sh
            # feeds every row to -add-account, where LAST WRITE WINS. A second
            # row silently reset the chain deployer's balance — and made the two
            # emitters disagree about who signs, since `deployer` means the
            # adduser actor in the txtar and the chain deployer in the plan.
            raise ValueError(
                "'deployer' is the reserved name of the chain's own deploying key; "
                "an actor by that name would overwrite its premine. Pick another.")
        if not re.match(r"^[a-z][a-z0-9_]*$", name):
            # The name is spliced into shell variable names and a sed pattern.
            raise ValueError(
                f"{name!r}: actor names must be lowercase [a-z][a-z0-9_]* — the "
                f"generated plan builds a shell variable and a sed regex from them.")
        self.accounts.append((name, ugnot))
        return name

    # -- the clock -------------------------------------------------------
    def arm_clock(self, at=None):
        """Arm the test clock. Deployer only, and only on a pristine realm."""
        if at is None:
            self._call(DEPLOYER, "EnableTestClock", [])
        else:
            self._call(DEPLOYER, "EnableTestClockAt", [str(at)])
        self._clock_armed = True
        self._clock_ever_armed = True

    def advance(self, seconds, why=""):
        if not self._clock_armed:
            raise ValueError("advance before arm_clock: the clock only moves when armed")
        if seconds <= 0:
            raise ValueError("the test clock only moves forward")
        self._call(DEPLOYER, "AdvanceTestClock", [str(seconds)], note=why)
        self._advanced += seconds

    def seal_clock(self):
        self._call(DEPLOYER, "SealTestClock", [])
        self._clock_armed = False

    # A mine this large is refused outright. At the MEASURED ~525ms a block
    # (round 12; the ~100ms this file used to quote was retracted in the same
    # round that measured it) that is days of wall clock, so it is almost always
    # a units mistake — weeks of blocks where hours were meant.
    MINE_CAP = 500_000
    MS_PER_BLOCK = 525

    # A block is 5 seconds of chain time (the overlay's own BLOCK_SECS).
    BLOCK_SECS = 5

    def advance_height(self, blocks, why=""):
        """Move the BLOCK HEIGHT forward without producing blocks.

        The twin of advance(). Conviction accrues per block, emission rolls per
        period, votes close on a block and the twap ring matures on one — so
        before the height override existed, every one of those could only be
        reached by mining: ~2,160 blocks to answer, 17,280 to crystallize,
        120,960 to resolve a dispute. Those are minutes to hours of real time
        for something the chain will happily be told.

        Prefer this to mine(). `mine` is still right when a scenario is
        asserting something about REAL block production; it is wrong when the
        scenario is merely waiting.
        """
        if not self._clock_armed:
            raise ValueError("advance_height before arm_clock: the height only moves when armed")
        if blocks <= 0:
            raise ValueError("the test height moves forward")
        self._call(DEPLOYER, "AdvanceTestHeight", [str(blocks)], note=why)
        self._advanced_height += blocks

    def mine(self, blocks, why="", with_time=False):
        """Burn blocks. The ONLY way to age height — conviction accrues per
        block, and PostAnswer needs ~2160 blocks of stake history.

        `with_time` also advances the clock by blocks x BLOCK_SECS, so the
        seeded chain's dates and heights stay in a plausible relationship.
        Without it the frozen clock does not move while blocks are mined, and a
        node seeded through 2,200 blocks reports the claim as OPENED AND
        ANSWERED AT THE SAME INSTANT — observed on the deep node, where the
        resolution ladder read "opened ... 82 days ago / answered ... 82 days
        ago" with 2,200 blocks between them.

        It is OPT-IN, not the default, because a scenario testing a deadline
        boundary needs the clock to move only when it says so: smoke.py advances
        to one second short of the dead-claim timeout and asserts the chain still
        refuses, which silent per-block time would break.

        APPROXIMATE, and it cannot be otherwise. The advance is keyed to the
        blocks the scenario REQUESTS, not to the blocks the chain ends up
        producing — tm2 inserts a proof block whenever the app hash changed, so
        the real height is unpredictable (ruling O1). Measured on the deep node:
        2,200 requested blocks became 4,408 real ones, so the seeded chain
        implies ~2.5s a block rather than 5. That is a plausible chain, which is
        the goal; it is not an exact one, and nothing downstream should treat
        the seeded height-to-time ratio as the network's.
        """
        if blocks <= 0:
            raise ValueError("mine moves height forward")
        total = blocks + sum(st["n"] for st in self.steps if st["kind"] == "mine")
        if total > self.MINE_CAP:
            raise ValueError(
                f"mine({blocks:,}) takes this scenario to {total:,} blocks, past the "
                f"{self.MINE_CAP:,}-block cap — about "
                f"{total * self.MS_PER_BLOCK / 3_600_000:.1f} hours of real mining. "
                f"Accounting clocks are "
                f"denominated in blocks and must not be faked, so a scenario that needs "
                f"this much height has to earn it in a deliberate long run, not inside a "
                f"routine seed.")
        self.steps.append({"kind": "mine", "n": blocks, "note": why})
        if with_time:
            if not self._clock_armed:
                raise ValueError("mine(with_time=True) needs the clock armed")
            self.advance(blocks * self.BLOCK_SECS,
                         f"{blocks:,} blocks of chain time, so dates track heights")

    # -- the realm -------------------------------------------------------
    def court(self, who, slug, name, polish=None):
        if polish is None:
            self._call(who, "StartCourt", [slug, name])
        else:
            self._call(who, "StartCourtP", [slug, name, str(polish)])
        return slug

    def buy(self, who, slug, ugnot):
        self._call(who, "Buy", [slug], send=f"{ugnot}ugnot")

    def claim(self, who, slug, title, body=None):
        """OpenClaim, or OpenClaimP when a body is given.

        Two entrypoints rather than one with an empty argument: OpenClaim is what
        every committed txtar in the tree calls, and passing it a third argument
        would rewrite all of them for a field most scenarios do not want.
        """
        if body:
            self._call(who, "OpenClaimP", [slug, title, body])
        else:
            self._call(who, "OpenClaim", [slug, title])

    def stake(self, who, slug, cid, side, amount):
        self._call(who, "Stake", [slug, str(cid), side, str(amount)])

    def unstake(self, who, slug, cid, side, amount):
        self._call(who, "Unstake", [slug, str(cid), side, str(amount)])

    def answer(self, who, slug, cid, verdict):
        self._call(who, "PostAnswer", [slug, str(cid), verdict])

    def settle(self, who, slug, cid):
        self._call(who, "SettleUndisputed", [slug, str(cid)])

    def dispute(self, who, slug, cid):
        self._call(who, "OpenDispute", [slug, str(cid)])

    def vote(self, who, slug, cid, choice):
        self._call(who, "VoteDispute", [slug, str(cid), choice])

    def folder(self, who, slug, name, desc):
        self._call(who, "CreateFolder", [slug, name, desc])

    def folder_add(self, who, slug, fid, cid):
        self._call(who, "AddToFolder", [slug, str(fid), str(cid)])

    def hide(self, who, slug, cid, reason):
        self._call(who, "HideItem", [slug, str(cid), reason])

    # -- the board -------------------------------------------------------
    # Row ids are `cs.boardNextID++`, per claim, sequential from 1 (board.gno),
    # so a caller can count them the way this file's callers already count claim
    # ids. Nothing here returns one: a scenario emits transactions, it does not
    # read them back.

    def comment_pass(self, who, slug):
        """BuyCommentPass — the entry rung, bought rather than earned.

        A scenario's actors have CC and usually no STANDING, and standing is what
        postLevel reads. Without a pass, PostComment refuses at level 0 and the
        whole board section of a fixture silently produces nothing.
        """
        self._call(who, "BuyCommentPass", [slug])

    def comment(self, who, slug, cid, text, parent=0):
        """PostComment. parent 0 is top-level; depth stops at one."""
        self._call(who, "PostComment", [slug, str(cid), str(parent), text])

    def upvote(self, who, slug, cid, row):
        self._call(who, "UpvoteComment", [slug, str(cid), str(row)])

    def withdraw_comment(self, who, slug, cid, row, hide=True):
        """HideOwnComment — the AUTHOR's own discovery bit, not a delete.

        Distinct from hide_comment below and deliberately not merged with it:
        they are different acts by different authorities, the realm keeps two
        bits for exactly that reason, and a fixture that used one for both would
        make the two tombstones untestable.
        """
        self._call(who, "HideOwnComment",
                   [slug, str(cid), str(row), "true" if hide else "false"])

    def hide_comment(self, who, slug, cid, row, code):
        """HideBoardRow — a MODERATOR's hide, M-of-N over the speech threshold."""
        self._call(who, "HideBoardRow", [slug, str(cid), str(row), code])

    def call(self, who, func, args, send=None, note=""):
        """The escape hatch: any entrypoint the builder has not learned.

        Clock entrypoints reached this way still count: arming through `call`
        used to leave the plan reporting "never armed" AND emitting no seal, so
        the node was left armed and unsealed — the state ruling O5 forbids —
        while announcing the opposite.
        """
        if func in ("EnableTestClock", "EnableTestClockAt"):
            self._clock_armed = True
            self._clock_ever_armed = True
        elif func == "SealTestClock":
            self._clock_armed = False
        self._call(who, func, [str(a) for a in args], send=send, note=note)

    # -- assertions ------------------------------------------------------
    def expect(self, func, args, matches, note="", final=False):
        """Assert a read matches, at THIS POINT in the story.

        `final=True` promises something stronger: that it is still true when the
        scenario ENDS. The distinction is not pedantry — it is what makes the
        genesis seed path checkable at all. That path applies every transaction
        in one block and can only read the state afterwards, so a point-in-time
        assertion moved to the end silently changes meaning. covid_demo asserts
        `TestClockActive == false` before arming and `== true` after; neither
        survives the move, and the first one failing is what surfaced this.

        Default false, so an unmarked assertion is never assumed to be an
        end-state one. emit_checks reports how many it had to skip.
        """
        """Assert a READ. The realm's own source decides what counts as one."""
        global REALM_READS
        if REALM_READS is None:
            REALM_READS = _realm_reads()
        if func not in REALM_READS:
            raise ValueError(
                f"{func} is not an exported READ of {REALM}. If it takes `cur realm` "
                f"it is a transaction, and an expect on it would broadcast one while "
                f"pretending to query — use a step. If it is new, it will be picked "
                f"up automatically once it exists in realm/r/kourtv2.")
        self.steps.append({"kind": "expect", "func": func,
                           "args": [_lit(a) for a in args],
                           "re": _portable_pattern(matches, "expect"), "note": note,
                           "final": bool(final)})

    def expect_refuse(self, who, func, args, stderr, note=""):
        """Assert that the CHAIN refuses — not merely that the simulator did.

        The named entrypoint must be a WRITE. `! gnokey maketx call -func <read>`
        also "fails", but because you cannot maketx a non-crossing function —
        so the assertion would pass without the realm ever refusing anything.
        """
        global REALM_READS
        if REALM_READS is None:
            REALM_READS = _realm_reads()
        if func in REALM_READS:
            raise ValueError(
                f"{func} is a READ. `! gnokey maketx call` on it fails because it is "
                f"not a crossing function, not because the realm refused — the "
                f"assertion would pass for the wrong reason. Name the write instead.")
        self.steps.append({"kind": "refuse", "who": who, "func": func,
                           "args": [str(a) for a in args],
                           "re": _portable_pattern(stderr, "expect_refuse"), "note": note})

    def note(self, text):
        # A newline here used to emit its tail as a LIVE testscript line rather
        # than a comment — `note("x\nstdout 'INJECTED'")` became an assertion.
        if "\n" in str(text) or "\r" in str(text):
            raise ValueError("a note is one line; its tail would become a live script line")
        self.steps.append({"kind": "note", "text": str(text)})

    # -- internals -------------------------------------------------------
    def _call(self, who, func, args, send=None, note=""):
        self.steps.append({"kind": "call", "who": who, "func": func,
                           "args": args, "send": send, "note": note})

    @property
    def advanced_seconds(self):
        return self._advanced


# ---------------------------------------------------------------- emit ----

# Patterns are compiled TWICE by two different engines: Go's regexp (testscript
# `stdout`/`stderr`) and POSIX ERE (`grep -E` in the live plan). Where the two
# disagree, the plan can PASS on data the txtar would reject — measured here:
# `[[:alpha:]]+` matches "naive" with a diaeresis under grep and does NOT under
# Go, whose POSIX classes are ASCII-only. Rather than pick a dialect (a design
# call, not a bug fix) the emitter refuses the constructs whose meaning differs,
# so every pattern that survives means the same thing to both.
_DIALECT_TRAPS = (
    (r"\(\?", "an inline group or flag like (?i) — Go only; ERE reads it literally"),
    (r"\\[pP]\{", "a Unicode class \\p{...} — Go only"),
    (r"\\[1-9]", "a backreference — Go refuses to compile it; grep matches it"),
    (r"\\[a-zA-Z]", "a perl class like \\d or \\w — Go only, and grep varies by build"),
    (r"\[\[:", "a POSIX class — ASCII-only in Go, locale-dependent in grep"),
)


def _portable_pattern(pat, where):
    """Refuse a match pattern the two engines would read differently."""
    for rx, why in _DIALECT_TRAPS:
        if re.search(rx, pat):
            raise ValueError(
                f"{where} pattern {pat!r} contains {why}.\n"
                f"The same pattern is compiled by Go's regexp for the txtar and by "
                f"grep -E for the live plan, and those disagree here — the plan could "
                f"report success on data the txtar rejects. Use a plain substring, or "
                f"a class written out like [0-9] or [A-Za-z].")
    return pat


def _lit(a):
    """One argument as a gno literal, for a qeval expression.

    Refuses what it cannot escape provably. The expression is wrapped in outer
    double quotes and its inner strings use backslash-quote, so a value that
    itself contains a quote or a backslash sits at an escaping level I could
    not verify end-to-end against gno's qeval parser. Emitting a guess there
    would produce a query that is silently wrong, which is the whole failure
    class this function exists to close. Everything else — apostrophes, $, #,
    spaces — now passes through safely because the token is quoted.
    """
    if getattr(a, "_is_addr", False):
        return a          # resolved per-emitter; never quoted as a literal name
    if isinstance(a, bool):
        return "true" if a else "false"
    if isinstance(a, int):
        return str(a)
    if isinstance(a, float):
        raise ValueError(f"{a!r}: no read takes a float; pass the base-unit int")
    if a is None:
        raise ValueError("None is not a gno value")
    t = str(a)
    for ch, why in ((chr(34), "a double quote"), (chr(92), "a backslash")):
        if ch in t:
            raise ValueError(
                f"{a!r} contains {why}. The qeval expression escapes its inner\n"
                f"strings with backslash-quote inside an outer double-quoted\n"
                f"argument, and this emitter will not guess at that nesting.\n"
                f"Assert on a substring without it, or add a realm read that\n"
                f"takes an id instead of free text.")
    return chr(92) + chr(34) + t + chr(92) + chr(34)


def _q_txtar(a):
    """Quote one token for testscript.

    testscript uses rc-shell/Pascal quoting, NOT sh: inside a single-quoted
    chunk, '' is a literal quote (go-internal/testscript.go:1287). Eight of the
    demo's own claim titles contain an apostrophe, and the previous rule —
    wrap in single quotes if it contains a space — emitted
    `-args 'The mayor's email'`, which tokenises as garbage.
    """
    a = str(a)
    if "\n" in a or "\r" in a:
        # A newline leaves testscript with an unterminated quote; a \r is
        # silently DROPPED by the txtar path and kept by the sh path, so the
        # two emitters would disagree about the value on the chain.
        raise ValueError("a token cannot contain a newline or carriage return")
    return "'" + a.replace("'", "''") + "'"


def _q_sh(a):
    """Quote one token for /bin/sh. Different rule, same job."""
    return shlex.quote(str(a))


def _args_txtar(args):
    return " ".join("-args " + _q_txtar(a) for a in args)


def _args_sh(args):
    return " ".join("-args " + _q_sh(a) for a in args)


def emit_txtar(scn):
    out = [f"# GENERATED by scripts/scenario.py from scenarios/{scn.name}.py — do not edit.",
           "# Regenerate with: make scenarios", "#"]
    for line in scn.preamble.strip().splitlines():
        out.append(f"# {line}".rstrip())
    out.append("")
    for d in DEPS:
        out.append(f"loadpkg {d}")
    out.append("")
    if scn.accounts:
        out.append("# Actors. adduser must precede `gnoland start`, so these hoist.")
        for name, ugnot in scn.accounts:
            out.append(f"adduser {name} {ugnot}ugnot")
        out.append("")
    out.append("gnoland start")
    out.append("")

    for st in scn.steps:
        k = st["kind"]
        if k == "note":
            out.append("")
            out.append(f"# --- {st['text']} " + "-" * max(0, 66 - len(st["text"])))
            continue
        # `mine` prints its own note alongside the block count, so skip the
        # generic one for that kind — it was emitting the same sentence twice.
        if st.get("note") and k != "mine":
            out.append(f"# {st['note']}")
        if k == "call":
            send = f" -send {st['send']}" if st.get("send") else ""
            args = _args_txtar(st["args"])
            out.append(" ".join(x for x in [
                f"gnokey maketx call -pkgpath {REALM} -func {st['func']}",
                args, send.strip(), GAS, f"-broadcast -chainid={CHAINID} {st['who']}"] if x))
            out.append("stdout 'OK!'")
        elif k == "refuse":
            args = _args_txtar(st["args"])
            # -simulate skip: prove the CHAIN refuses, in a block, not the simulator
            out.append(" ".join(x for x in [
                f"! gnokey maketx call -pkgpath {REALM} -func {st['func']}",
                args, GAS, f"-simulate skip -broadcast -chainid={CHAINID} {st['who']}"] if x))
            out.append("stderr " + _q_txtar(st["re"]))
        elif k == "expect":
            inner = ",".join(st["args"])
            # Quoted like every other token. `"` is NOT a quoting character in
            # testscript, so this argument used to reach ts.expand UNQUOTED:
            # an apostrophe killed the script ("unterminated quoted argument"),
            # `$5.00` silently became `.00`, `#` truncated the line, and a space
            # split the token. The plan emitter quoted it correctly all along,
            # so one IR was issuing two different queries.
            out.append("gnokey query vm/qeval --data "
                       + _q_txtar(f'"{REALM}.{st["func"]}({inner})"'))
            out.append("stdout " + _q_txtar(st["re"]))
        elif k == "mine":
            out.append(f"# {st['n']} blocks" + (f" — {st['note']}" if st.get("note") else ""))
            out.extend(["gnoland wait-for-new-block"] * st["n"])
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def emit_accounts(scn):
    """The account manifest: who the launcher must create and premine.

    The launcher needs this BEFORE the node boots, because gnodev premines at
    genesis (-add-account) and fixes the deploy key (-deploy-key) at startup.
    Emitted as plain `name<TAB>ugnot` so shell can read it without a parser.
    """
    # Size the deployer premine to what this scenario actually spends: one gas
    # fee per mined block, plus its own transactions, plus generous headroom.
    blocks = sum(st["n"] for st in scn.steps if st["kind"] == "mine")
    txs = sum(1 for st in scn.steps if st["kind"] in ("call", "refuse"))
    sent = sum(int(re.sub(r"[^0-9]", "", str(st.get("send") or "0")) or 0)
               for st in scn.steps if st["kind"] == "call" and st["who"] == DEPLOYER)
    need = max((blocks + txs) * GAS_FEE_UGNOT * 3 + sent, DEPLOYER_PREMINE_MIN)
    rows = [f"deployer\t{need}"]
    rows += [f"{n}\t{u}" for n, u in scn.accounts]
    return "\n".join(rows) + "\n"


class Addr(str):
    """An account NAME that must be resolved to its ADDRESS by the emitter.

    A bare string in an expect's arguments is a bare string: `s.expect("Standing",
    [SLUG, accounts[w]], ...)` emitted `Standing("covid","virology")`, and the
    realm answered 0 — not because the address had no standing, but because
    "virology" is not an address and matches no row. The assertion could not fail
    for the reason it was written to check, and it could not pass at all. Both
    emitters had the bug; it went unnoticed because no expect had taken an
    address argument before.

    Wrapping the name marks the intent, so an emitter that does not know how to
    resolve it fails loudly instead of quoting it.

    MARKED BY ATTRIBUTE, NOT BY isinstance. scenario.py runs as `__main__` when
    invoked as a script, while a scenario's `from scenario import Addr` imports
    the module a SECOND time — so the class the scenario wraps with is not the
    class the emitter would test against, and isinstance quietly returns False.
    The symptom is an unquoted account name in the generated query, which is how
    this was found.
    """

    _is_addr = True


BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def pubkey_b64(gpub):
    """The keyring's bech32 `gpub1…` as the base64 amino form genesis JSON wants.

    NEEDED EVEN THOUGH NOTHING VERIFIES IT. A genesis transaction is refused
    outright for an EMPTY signatures array — "no signatures error", a structural
    check that runs before verification — so an entry must be present. Measured:
    a borrowed pubkey from gno.land's own genesis file let all 634 apply, which
    says the bytes are never read. Writing somebody else's key next to this
    court's callers would still be a lie in a file people read, so the real one
    goes in.

    The decode is plain bech32 (BIP-173) minus the checksum, and the compressed
    secp256k1 key is the last 33 bytes of what comes out — the bytes before it
    are the amino type prefix for /tm.PubKeySecp256k1, which the JSON names in
    its own field.
    """
    s = gpub.lower()
    pos = s.rfind("1")
    if pos < 0:
        raise ValueError(f"not bech32: {gpub}")
    vals = [BECH32_CHARSET.find(c) for c in s[pos + 1:]]
    if -1 in vals:
        raise ValueError(f"bad bech32 character in {gpub}")
    acc = bits = 0
    out = bytearray()
    for v in vals[:-6]:                      # the last six symbols are the checksum
        acc = (acc << 5) | v
        bits += 5
        while bits >= 8:
            bits -= 8
            out.append((acc >> bits) & 0xFF)
    if len(out) < 33:
        raise ValueError(f"{gpub} decodes to {len(out)} bytes, too short for a key")
    return base64.b64encode(bytes(out[-33:])).decode()


def emit_txs(scn, addrs):
    """The same story again, as a gnodev GENESIS TRANSACTIONS FILE.

    WHY THIS EXISTS. emit_plan broadcasts one `gnokey maketx` per step and waits
    for each to commit. Measured on covid_demo: 636 transactions at 0.365s each,
    which is 3m52s of a 4m06s run — the seed IS that loop. Almost all of the
    0.365s is local: keyring decrypt and signature, not the node, which answers a
    query in 33ms. Broadcasting from several accounts at once does not help; a
    batch of eight fired together landed NONE while eight sequential landed all
    eight.

    Genesis transactions skip every one of those costs. gnodev applies a txs-file
    at startup, and sets SkipGenesisSigVerification (contribs/gnodev/pkg/dev/
    node.go), so the `caller` field is taken at face value and the signature is
    never checked — which is why gno.land's own genesis_txs.jsonl ships
    `"signature":""`. So this emitter signs nothing and spawns no processes: it
    writes a file.

    WHAT IT GIVES UP, stated plainly because it is the reason emit_plan stays.
    The plan checks every transaction as it lands and prints the realm's own
    panic when one fails; that check caught four separate mistakes in one
    afternoon. Genesis application is bulk, so a failed transaction here does not
    stop the run. The `expect` assertions are the compensating control and they
    still run afterwards, against the node, at query speed — so a scenario whose
    seed silently half-applied is caught by what it then reads back, not by what
    it wrote.

    REFUSES A SCENARIO IT CANNOT REPRESENT rather than emitting a file that
    quietly differs: `mine` steps advance real block height, and every genesis
    transaction lands in the same block. A scenario that mines has to keep the
    broadcast path. (covid_demo does not mine — it walks the realm's test clock,
    which is state and therefore a transaction like any other.)
    """
    mined = sum(st["n"] for st in scn.steps if st["kind"] == "mine")
    if mined:
        raise SystemExit(
            f"scenario.py: {scn.name} mines {mined} block(s), and every genesis "
            f"transaction lands in the same block — seed it with --emit plan.")
    missing = sorted({st["who"] for st in scn.steps if st["kind"] == "call"} - set(addrs))
    if missing:
        raise SystemExit(f"scenario.py: no address for {', '.join(missing)} — "
                         f"the accounts map is stale.")
    keys = {n: pubkey_b64(gpub) for n, (_, gpub) in addrs.items()}
    out = []
    for st in scn.steps:
        if st["kind"] != "call":
            continue          # notes are narration; expects are reads; refusals are for tests
        msg = {"@type": "/vm.m_call",
               "caller": addrs[st["who"]][0],
               "send": str(st.get("send") or ""),
               "pkg_path": REALM,
               "func": st["func"],
               "args": [str(a) for a in st["args"]]}
        out.append(json.dumps({"tx": {
            "msg": [msg],
            "fee": {"gas_wanted": str(GAS_WANTED), "gas_fee": f"{GAS_FEE_UGNOT}ugnot"},
            # ONE SIGNATURE ENTRY, with an EMPTY signature string. An empty
            # ARRAY is refused structurally ("no signatures error") before
            # verification is ever reached — which is why gno.land's own
            # genesis_txs.jsonl carries a pub_key and `"signature":""` rather
            # than nothing at all.
            "signatures": [{"pub_key": {"@type": "/tm.PubKeySecp256k1",
                                        "value": keys[st["who"]]},
                            "signature": ""}],
            "memo": ""}}, separators=(",", ":")))
    return "\n".join(out) + "\n"


def emit_checks(scn, addrs=None):
    """The assertions alone, for the genesis path.

    emit_plan interleaves writes and reads in one script. With the writes moved
    into genesis, the reads have to run after the node is up — and they are the
    ONLY check that the seed applied, so they are not optional there.
    """
    L = ["#!/bin/sh",
         f"# GENERATED from scenarios/{scn.name}.py by scripts/scenario.py — do not edit.",
         "#",
         "# The scenario's assertions, run against a node seeded from a genesis",
         "# txs-file. Genesis application is bulk and does not stop on a failed",
         "# transaction, so these reads are what proves the seed landed.",
         "set -eu",
         'REMOTE="${REMOTE:-http://127.0.0.1:26657}"',
         'q() { gnokey query vm/qeval -remote "$REMOTE" --data "$1"; }',
         "say() { printf '  %s\\n' \"$1\"; }",
         ""]
    total = sum(1 for st in scn.steps if st["kind"] == "expect")
    kept = sum(1 for st in scn.steps if st["kind"] == "expect" and st.get("final"))
    if kept < total:
        L.append(f"say {shlex.quote(f'{kept} of {total} assertions are end-state and re-checked here; the other {total - kept} are point-in-time and only the broadcast path can make them')}")
    for st in scn.steps:
        if st["kind"] == "note":
            L.append("say " + shlex.quote(st["text"]))
        elif st["kind"] == "expect" and st.get("final"):
            parts = []
            for a in st["args"]:
                if getattr(a, "_is_addr", False):
                    if not addrs or a not in addrs:
                        raise SystemExit(f"scenario.py: expect names account {a!r}, "
                                         f"which the accounts map does not carry.")
                    parts.append('"' + addrs[a][0] + '"')
                else:
                    parts.append(str(a))
            inner = ",".join(parts).replace('\\"', '"')
            expr = f"{REALM}.{st['func']}({inner})"
            # PRINTS WHAT IT GOT, not only what it wanted. "Standing did not
            # match" names the expectation and leaves the actual value — the one
            # fact that identifies which account and how far off — unsaid, so
            # every diagnosis needs another run.
            L.append(f"got=$(q {shlex.quote(expr)} 2>&1 | tr -d '\\n')")
            L.append(f"case \"$got\" in *) printf '%s' \"$got\" | grep -Eq "
                     f"{shlex.quote(st['re'])} || {{ printf 'seed: %s(%s) is %s, wanted %s\\n' "
                     f"{shlex.quote(st['func'])} {shlex.quote(expr)} \"$got\" "
                     f"{shlex.quote(st['re'])} >&2; exit 1; }};; esac")
    L.append("")
    return "\n".join(L)


def emit_plan(scn):
    """The same story, as a shell script against a LIVE node.

    Not a second implementation — the same IR, a different back end. It differs
    from the txtar emitter only where a live chain genuinely differs from a
    genesis harness:

      * funding is absent, because the launcher premines at genesis instead;
      * actor names resolve to real keyring addresses, read back at run time;
      * refusal steps are DROPPED — a seed run is not a test, and a deliberate
        failure would only leave a confusing error in an operator's log;
      * assertions become greps, since testscript's stdout matching is gone;
      * mining is explicit sends, because a live node with -empty-blocks=false
        advances height only on real transactions.

    Consumes $KEYDIR/$REMOTE/$CHAINID/$PASS from the launcher; makes no node.
    """
    L = ["#!/bin/sh",
         f"# GENERATED from scenarios/{scn.name}.py by scripts/scenario.py — do not edit.",
         "#",
         "# Seeds a node that is ALREADY RUNNING (see scripts/seed-node.sh).",
         "# The realm's test clock gets armed here, so every date on the seeded",
         "# node is fabricated. Never point this at a chain you care about.",
         "set -eu",
         ': "${KEYDIR:?run me through scripts/seed-node.sh}"',
         'REMOTE="${REMOTE:-http://127.0.0.1:26657}"',
         'CHAINID="${CHAINID:-dev}"',
         'PASS="${PASS:-scenario}"',
         'TX="-gas-fee 1000000ugnot -gas-wanted 200000000 -broadcast '
         '-insecure-password-stdin -home $KEYDIR -remote $REMOTE -chainid $CHAINID"',
         'Q="-remote $REMOTE"',
         "",
         "# Addresses are read back from the keyring rather than hardcoded: the",
         "# launcher makes fresh random keys every run, on purpose.",
         "addr() { gnokey list -home \"$KEYDIR\" -insecure-password-stdin <<EOF 2>/dev/null |",
         "$PASS",
         "EOF",
         "  sed -n \"s/^[0-9]*\\. $1 (.*addr: \\(g1[a-z0-9]*\\).*/\\1/p\" | head -1; }",
         # 2>&1 on the tx path: gnokey prints an "Enter password." prompt for every
         # signature even when the password arrives on stdin, and 18 of them bury
         # the scenario's own narration. Failures still surface — set -e trips on
         # the exit code, and the assertions read the chain rather than the log.
         "# Output goes to a log, not to /dev/null. Silencing gnokey's per-signature",
         "# \"Enter password.\" prompt also silenced every REASON a transaction",
         "# failed: a deep seed died at PostAnswer and reported nothing at all.",
         "TXLOG=\"${TXLOG:-$(mktemp)}\"",
         "tx() { if ! gnokey maketx \"$@\" $TX >>\"$TXLOG\" 2>&1 <<EOF",
         "$PASS",
         "EOF",
         "  then echo \"seed: transaction failed: gnokey maketx $*\" >&2",
         "       tail -25 \"$TXLOG\" >&2",
         "       exit 1",
         "  fi; }",
         "q() { gnokey query vm/qeval $Q --data \"$1\"; }",
         "say() { printf '  %s\\n' \"$1\"; }",
         "",
         'DEPLOYER_ADDR="$(addr deployer)"',
         ': "${DEPLOYER_ADDR:?no deployer key in $KEYDIR}"']
    for name, _ in scn.accounts:
        U = name.upper()
        L += [f'{U}_ADDR="$(addr {name})"', f': "${{{U}_ADDR:?no {name} key in $KEYDIR}}"']
    L.append("")
    for st in scn.steps:
        k = st["kind"]
        if k == "note":
            L += ["", f"# --- {st['text']} " + "-" * max(0, 60 - len(st["text"])),
                  f"say {shlex.quote(st['text'])}"]
        elif k == "call":
            send = f" -send {_q_sh(st['send'])}" if st.get("send") else ""
            args = _args_sh(st["args"])
            # The deployer is a keyring name here, not the harness's test1.
            who = "deployer" if st["who"] == DEPLOYER else st["who"]
            L.append(" ".join(x for x in [
                f"tx call -pkgpath {REALM} -func {st['func']}", args, send.strip(), who] if x))
        elif k == "expect":
            # An Addr becomes the shell variable the header already defines, so
            # the query carries a real address instead of an account's name.
            #
            # QUOTED IN DOUBLE QUOTES WHEN IT DOES, and that is not cosmetic:
            # shlex.quote picks SINGLE quotes for anything containing `$`, which
            # would send the chain the literal text `$VIROLOGY_ADDR`. The realm
            # answers 0 for an address it has never seen, so the assertion fails
            # for a reason that has nothing to do with what it checks — the same
            # silent-zero the Addr sentinel exists to prevent, one layer down.
            parts = []
            for a in st["args"]:
                if getattr(a, "_is_addr", False):
                    parts.append('"$' + a.upper() + '_ADDR"')
                else:
                    parts.append(str(a).replace('\\"', '"'))
            expr = f"{REALM}.{st['func']}({','.join(parts)})"
            if "$" in expr:
                qexpr = '"' + expr.replace('"', '\\"') + '"'
            else:
                qexpr = shlex.quote(expr)
            L.append(f'q {qexpr} | grep -Eq {shlex.quote(st["re"])} '
                     f'|| {{ printf "seed: %s did not match %s\\n" '
                     f'{shlex.quote(st["func"])} {shlex.quote(st["re"])} >&2; exit 1; }}')
        elif k == "refuse":
            L.append(f'# refusal step skipped — a seed run is not a test ({st["func"]})')
        elif k == "mine":
            L += [f'# {st["n"]} blocks — a live node advances height only on real txs',
                  f'i=0; while [ $i -lt {st["n"]} ]; do '
                  f'tx send -send 1ugnot -to "$DEPLOYER_ADDR" deployer; i=$((i+1)); done']
    # Three end states, not two. Reporting only "armed now / not armed now"
    # printed "never armed" directly beneath a SealTestClock call, on a chain
    # whose dates had been moved twelve weeks.
    if scn._clock_armed:
        L += ["", "# Seal the clock: from here the node behaves like any other chain, and",
              "# no later transaction can move its dates again.",
              "tx call -pkgpath %s -func SealTestClock deployer" % REALM,
              'echo "  clock: sealed — its dates are fabricated and now fixed"']
    elif scn._clock_ever_armed:
        # Armed and sealed by the scenario itself. Still a test chain forever:
        # the realm keeps saying so through TestClockFabricated().
        L.append('echo "  clock: sealed by the scenario — its dates are fabricated and now fixed"')
    else:
        L.append('echo "  clock: never armed — this node keeps real wall-clock time"')
    L += ["", 'echo "seeded: $REMOTE"']
    return "\n".join(L) + "\n"


def _load(path):
    """Exec a scenario module and hand back (SCENARIO, is_ci)."""
    ns = {"__file__": str(pathlib.Path(path).resolve()), "__name__": "__scenario__"}
    exec(compile(open(path, encoding="utf-8").read(), path, "exec"), ns)
    scn = ns.get("SCENARIO")
    if scn is None:
        print(f"{path}: defines no SCENARIO", file=sys.stderr)
        raise SystemExit(2)
    # CI = False marks a scenario too slow for the shared gate — a run that
    # mines its way to an answered claim costs ~2,160 blocks, and round 4 ruled
    # CI scenarios stay under ~200. Such a scenario is for seeding a node by
    # hand; generating a txtar for it would put 20 minutes into txtar-test.
    return scn, bool(ns.get("CI", True))


def _list_ci():
    """The scenarios `make scenarios` should compile, one per line."""
    d = pathlib.Path(__file__).resolve().parent.parent / "scenarios"
    for f in sorted(d.glob("*.py")):
        try:
            _, ci = _load(str(f))
        except SystemExit:
            continue
        if ci:
            print(f)
    return 0


def flag(name, default=None):
    if name not in sys.argv:
        return default
    i = sys.argv.index(name) + 1
    if i >= len(sys.argv):
        print(f"{name}: needs a value", file=sys.stderr)
        raise SystemExit(2)
    return sys.argv[i]


def main():
    if "--list-ci" in sys.argv:
        return _list_ci()
    if len(sys.argv) < 2:
        print("usage: scenario.py <scenarios/name.py> [--out <path>] | --list-ci",
              file=sys.stderr)
        return 2
    path = sys.argv[1]
    scn, is_ci = _load(path)
    if not is_ci and flag("--emit", "txtar") == "txtar":
        print(f"{path}: CI = False — this scenario is for seeding a node by hand, "
              f"not for txtar-test. Use --emit plan.", file=sys.stderr)
        return 2

    kind = flag("--emit", "txtar")
    if kind in ("txs", "checks"):
        # The accounts map has to exist FIRST: genesis transactions carry the
        # caller's address, and the launcher makes fresh random keys every run.
        amap = flag("--accounts-map")
        if not amap:
            print(f"--emit {kind}: needs --accounts-map <file> of "
                  f"`name<TAB>addr<TAB>gpub` lines", file=sys.stderr)
            return 2
        addrs = {}
        for line in open(amap, encoding="utf-8"):
            parts = line.split()
            if len(parts) >= 3:
                addrs[parts[0]] = (parts[1], parts[2])
        # The txtar harness's deployer name is not a keyring name.
        if DEPLOYER not in addrs and "deployer" in addrs:
            addrs[DEPLOYER] = addrs["deployer"]
        text = emit_txs(scn, addrs) if kind == "txs" else emit_checks(scn, addrs)
    else:
        emit = {"txtar": emit_txtar, "plan": emit_plan,
                "accounts": emit_accounts, "checks": emit_checks}.get(kind)
        if emit is None:
            print(f"--emit {kind}: want one of txtar, plan, txs, checks, accounts",
                  file=sys.stderr)
            return 2
        text = emit(scn)
    out = flag("--out")
    if out:
        open(out, "w", encoding="utf-8").write(text)
        blocks = sum(s["n"] for s in scn.steps if s["kind"] == "mine")
        txs = sum(1 for s in scn.steps if s["kind"] in ("call", "refuse"))
        print(f"{out}: {txs} transactions, {blocks} mined blocks, "
              f"{scn.advanced_seconds}s + {scn._advanced_height} blocks advanced, "
              f"{len(text.splitlines())} lines")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
