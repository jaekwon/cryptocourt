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
    run (measured: 6/7/7/6/8). Height is ASSERTED against the chain, never
    assumed. Wall-clock IS predicted, because the test clock is frozen while
    armed and only `advance` moves it.
  * It does not let an assertion call a write. Six entrypoints read like getters
    and are transactions (AuthorBonus, AnswererBonus, PullCarrot, WithdrawStake,
    WithdrawBonus, PullSenior); an `expect` naming one of those would broadcast
    while pretending to query, so the emitter refuses by name.
  * It does not let a refusal pass on a simulation. `gnokey maketx` defaults to
    -simulate test and returns BEFORE broadcasting when the simulation errors —
    so a plain `! gnokey ...` proves only that the simulator refused. Refusals
    emit -simulate skip and are asserted on-chain.
"""

import json
import shlex
import pathlib
import sys

REALM = "gno.land/r/kourt/kourtv2"
CHAINID = "tendermint_test"
GAS = "-gas-fee 1000000ugnot -gas-wanted 200000000"
DEPLOYER = "test1"  # the key the txtar harness deploys with, hence the deployer
# On a live node the deployer is a fresh key instead, premined at genesis: it
# pays for every moderator tx and for the sends that mine blocks.
DEPLOYER_PREMINE = 100000000000

YES, NO, ABSTAIN = "0", "1", "abstain"

# Writes that read like getters. An `expect` naming one of these would BROADCAST.
WRITE_SHAPED_GETTERS = {
    "AuthorBonus", "AnswererBonus", "PullCarrot",
    "WithdrawStake", "WithdrawBonus", "PullSenior",
}

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
        self._advanced = 0          # the one axis we can predict

    # -- actors ----------------------------------------------------------
    def account(self, name, ugnot=100_000_000):
        if name == DEPLOYER:
            raise ValueError(f"{DEPLOYER} is the harness's own key; it needs no adduser")
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

    def mine(self, blocks, why=""):
        """Burn blocks. The ONLY way to age height — conviction accrues per
        block, and PostAnswer needs ~2160 blocks of stake history."""
        self.steps.append({"kind": "mine", "n": blocks, "note": why})

    # -- the realm -------------------------------------------------------
    def court(self, who, slug, name, polish=None):
        if polish is None:
            self._call(who, "StartCourt", [slug, name])
        else:
            self._call(who, "StartCourtP", [slug, name, str(polish)])
        return slug

    def buy(self, who, slug, ugnot):
        self._call(who, "Buy", [slug], send=f"{ugnot}ugnot")

    def claim(self, who, slug, title):
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

    def call(self, who, func, args, send=None, note=""):
        """The escape hatch: any entrypoint the builder has not learned."""
        self._call(who, func, [str(a) for a in args], send=send, note=note)

    # -- assertions ------------------------------------------------------
    def expect(self, func, args, matches, note=""):
        """Assert a READ. Refuses the six write-shaped getters by name."""
        if func in WRITE_SHAPED_GETTERS:
            raise ValueError(
                f"{func} is a WRITE that reads like a getter — an expect on it "
                f"would broadcast a transaction. Use a step, not an assertion.")
        self.steps.append({"kind": "expect", "func": func,
                           "args": [_lit(a) for a in args], "re": matches, "note": note})

    def expect_refuse(self, who, func, args, stderr, note=""):
        """Assert that the CHAIN refuses — not merely that the simulator did."""
        self.steps.append({"kind": "refuse", "who": who, "func": func,
                           "args": [str(a) for a in args], "re": stderr, "note": note})

    def note(self, text):
        self.steps.append({"kind": "note", "text": text})

    # -- internals -------------------------------------------------------
    def _call(self, who, func, args, send=None, note=""):
        self.steps.append({"kind": "call", "who": who, "func": func,
                           "args": args, "send": send, "note": note})

    @property
    def advanced_seconds(self):
        return self._advanced


# ---------------------------------------------------------------- emit ----

def _lit(a):
    """A gno literal for a qeval expression: numbers bare, strings quoted."""
    if isinstance(a, bool):
        return "true" if a else "false"
    if isinstance(a, int):
        return str(a)
    return '\\"' + str(a) + '\\"'


def _arg(a):
    """One -args token. Quoted only when it has to be."""
    return f"-args '{a}'" if (" " in str(a) or str(a) == "") else f"-args {a}"


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
        if st.get("note"):
            out.append(f"# {st['note']}")
        if k == "call":
            send = f" -send {st['send']}" if st.get("send") else ""
            args = " ".join(_arg(a) for a in st["args"])
            out.append(f"gnokey maketx call -pkgpath {REALM} -func {st['func']} "
                       f"{args}{send} {GAS} -broadcast -chainid={CHAINID} {st['who']}".replace("  ", " "))
            out.append("stdout 'OK!'")
        elif k == "refuse":
            args = " ".join(_arg(a) for a in st["args"])
            # -simulate skip: prove the CHAIN refuses, in a block, not the simulator
            out.append(f"! gnokey maketx call -pkgpath {REALM} -func {st['func']} "
                       f"{args} {GAS} -simulate skip -broadcast -chainid={CHAINID} {st['who']}".replace("  ", " "))
            out.append(f"stderr '{st['re']}'")
        elif k == "expect":
            inner = ",".join(st["args"])
            out.append(f'gnokey query vm/qeval --data "{REALM}.{st["func"]}({inner})"')
            out.append(f"stdout '{st['re']}'")
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
    rows = [f"deployer\t{DEPLOYER_PREMINE}"]
    rows += [f"{n}\t{u}" for n, u in scn.accounts]
    return "\n".join(rows) + "\n"


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
         "tx() { gnokey maketx \"$@\" $TX <<EOF >/dev/null",
         "$PASS",
         "EOF",
         "}",
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
            send = f" -send {st['send']}" if st.get("send") else ""
            args = " ".join(_arg(a) for a in st["args"])
            # The deployer is a keyring name here, not the harness's test1.
            who = "deployer" if st["who"] == DEPLOYER else st["who"]
            L.append(f'tx call -pkgpath {REALM} -func {st["func"]} {args}{send} {who}')
        elif k == "expect":
            inner = ",".join(st["args"]).replace('\\"', '"')
            expr = f"{REALM}.{st['func']}({inner})"
            L.append(f'q {shlex.quote(expr)} | grep -Eq {shlex.quote(st["re"])} '
                     f'|| {{ echo "seed: {st["func"]} did not match {st["re"]}" >&2; exit 1; }}')
        elif k == "refuse":
            L.append(f'# refusal step skipped — a seed run is not a test ({st["func"]})')
        elif k == "mine":
            L += [f'# {st["n"]} blocks — a live node advances height only on real txs',
                  f'i=0; while [ $i -lt {st["n"]} ]; do '
                  f'tx send -send 1ugnot -to "$DEPLOYER_ADDR" deployer; i=$((i+1)); done']
    L += ["", "# Seal the clock: from here the node behaves like any other chain, and no",
          "# later transaction can move its dates again.",
          "tx call -pkgpath %s -func SealTestClock deployer" % REALM,
          'echo "seeded: $REMOTE"']
    return "\n".join(L) + "\n"


def main():
    if len(sys.argv) < 2:
        print("usage: scenario.py <scenarios/name.py> [--out <path>]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    # __file__ must exist in the module's namespace: a scenario locates the
    # builder relative to itself, exactly as it would when run directly.
    ns = {"__file__": str(pathlib.Path(path).resolve()), "__name__": "__scenario__"}
    exec(compile(open(path).read(), path, "exec"), ns)
    scn = ns.get("SCENARIO")
    if scn is None:
        print(f"{path}: defines no SCENARIO", file=sys.stderr)
        return 2
    kind = sys.argv[sys.argv.index("--emit") + 1] if "--emit" in sys.argv else "txtar"
    emit = {"txtar": emit_txtar, "plan": emit_plan, "accounts": emit_accounts}.get(kind)
    if emit is None:
        print(f"--emit {kind}: want one of txtar, plan, accounts", file=sys.stderr)
        return 2
    text = emit(scn)
    out = None
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
    if out:
        open(out, "w").write(text)
        blocks = sum(s["n"] for s in scn.steps if s["kind"] == "mine")
        txs = sum(1 for s in scn.steps if s["kind"] in ("call", "refuse"))
        print(f"{out}: {txs} transactions, {blocks} mined blocks, "
              f"{scn.advanced_seconds}s advanced, {len(text.splitlines())} lines")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
