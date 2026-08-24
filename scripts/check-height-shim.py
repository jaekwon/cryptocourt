#!/usr/bin/env python3
"""No height read in the realm may bypass heightNow().

WHY THIS IS A GUARD AND NOT A CONVENTION. The test clock overrides height as
well as wall-clock, so a test chain can advance conviction, emission, vote
windows and twap maturity without mining. That works only if EVERY read goes
through the shim. Miss one and a single transaction sees two different heights
— a claim opened at fabricated height 20,000 while the twap ring observes at
real height 30 — which is corrupt state, not a display bug.

There were 65 call sites across 15 files when this was written. Nobody is going
to re-check them by eye, and the next person to add a height read will reach for
`runtime.ChainHeight()` because that is what the rest of gno does.

Two files are allowed to hold the raw read, and only those:
  clock.gno     — defines heightNow(), the shim itself
  testclock.gno — the latch that computes the skew, and must see REAL height

IT ALSO GUARDS THE PURE PACKAGES, because an audit found the guard proved less
than it claimed. `p/grc20votes` keeps a nil-clock fallback to `ChainHeight()` so
other realms can use it unchanged — which means a ledger built with `NewLedger`
instead of `NewLedgerWithClock` reads REAL height while the claims, twap rings
and checkpoints in the same transaction read fabricated height. Today kourtv2
constructs exactly one ledger and passes a clock; that was convention, not a
guard. It is a guard now.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"
PURE = ROOT / "realm" / "p"
SHIM_FILES = {"clock.gno", "testclock.gno"}
# The one sanctioned raw read outside the realm: the ledger's documented
# fallback for consumers that supply no clock.
PURE_ALLOWED = {("grc20votes", "grc20votes.gno"): 1}
RAW = re.compile(r"runtime\.ChainHeight\s*\(")
# An alias defeats a literal match: `rt "chain/runtime"` then `rt.ChainHeight()`.
ALIAS = re.compile(r'^\s*(\w+)\s+"chain/runtime"\s*$', re.M)
# The latch is a package GLOBAL, so a test that arms it and returns leaves every
# later test reading a FROZEN height while the real chain keeps advancing. A test
# that then derives state from the raw chain height writes into heightNow()'s
# future, and the next production write goes backwards — checkpoint panics with
# "the clock went backwards". The suite already pairs every arming with a
# `defer resetTestClock(...)` and says why in a comment; this makes the 21st one
# fail here instead of somewhere unrelated.
ARMS = re.compile(r'\btcArmed\s*,?[^=\n]*=\s*true')
DISARMS = re.compile(r'defer\s+resetTestClock')


def main():
    if not REALM.is_dir():
        print(f"check-height-shim: no realm at {REALM}", file=sys.stderr)
        return 2

    offenders, scanned, shim_sites = [], 0, 0
    shim_per_file = {}
    for f in sorted(REALM.glob("*.gno")):
        if f.name.endswith("_test.gno") or f.name.endswith("_filetest.gno"):
            continue
        scanned += 1
        text = f.read_text(encoding="utf-8")
        # strip comments so a mention in prose is not an offence
        code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        code = re.sub(r"^\s*//.*$", "", code, flags=re.M)
        hits = list(RAW.finditer(code))
        if f.name in SHIM_FILES:
            shim_sites += len(hits)
            shim_per_file[f.name] = len(hits)
            continue
        for m in hits:
            line = code[:m.start()].count("\n") + 1
            offenders.append((f"realm/r/kourtv2/{f.name}", f"line {line}"))

    # Per-file, not a total. clock.gno DEFINES heightNow(); if it stops reading
    # the chain then the shim is reading nothing and every "clean" scan below is
    # vacuous. A total let testclock.gno's own read cover for it — which a
    # selftest arm caught by replacing clock.gno's read and seeing this stay
    # quiet.
    if shim_per_file.get("clock.gno", 0) < 1:
        print("check-height-shim: clock.gno holds NO raw height read — heightNow() "
              "must be reading something, so this check has lost its anchor and "
              "would pass vacuously.", file=sys.stderr)
        return 1

    # --- the pure packages -------------------------------------------------
    for f in sorted(PURE.glob("*/*.gno")):
        if f.name.endswith("_test.gno") or f.name.endswith("_filetest.gno"):
            continue
        text = f.read_text(encoding="utf-8")
        code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        code = re.sub(r"^\s*//.*$", "", code, flags=re.M)
        n = len(RAW.findall(code))
        allowed = PURE_ALLOWED.get((f.parent.name, f.name), 0)
        if n > allowed:
            offenders.append((f"p/{f.parent.name}/{f.name}",
                              f"{n} raw height read(s), {allowed} sanctioned"))

    # --- the alias evasion, anywhere ----------------------------------------
    for f in sorted(list(REALM.glob("*.gno")) + list(PURE.glob("*/*.gno"))):
        if f.name.endswith("_test.gno") or f.name.endswith("_filetest.gno"):
            continue
        for m in ALIAS.finditer(f.read_text(encoding="utf-8")):
            if m.group(1) not in ("runtime", "_"):
                offenders.append((f.name, f'aliases chain/runtime as {m.group(1)!r},'
                                          f" which defeats this scan"))

    # --- kourtv2 must never build a clockless ledger ------------------------
    for f in sorted(REALM.glob("*.gno")):
        if f.name.endswith("_test.gno") or f.name.endswith("_filetest.gno"):
            continue
        code = re.sub(r"^\s*//.*$", "", f.read_text(encoding="utf-8"), flags=re.M)
        if re.search(r"grc20votes\.NewLedger\s*\(", code):
            offenders.append((f.name, "builds a ledger with NewLedger — it would read "
                                      "REAL height while this realm reads fabricated; "
                                      "use NewLedgerWithClock"))

    # --- the test clock's latch must be restored by whoever armed it --------
    armings = 0
    for f in sorted(REALM.glob("*_test.gno")):
        text = f.read_text(encoding="utf-8")
        code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        code = re.sub(r"^\s*//.*$", "", code, flags=re.M)
        for m in re.finditer(r"func (Test\w+)\([^)]*\)\s*\{", code):
            i = m.end()
            depth = 1
            while i < len(code) and depth:
                if code[i] == "{":
                    depth += 1
                elif code[i] == "}":
                    depth -= 1
                i += 1
            body = code[m.end():i]
            if not ARMS.search(body):
                continue
            armings += 1
            if not DISARMS.search(body):
                offenders.append((f"{f.name}:{m.group(1)}",
                                  "arms the test clock and never defers "
                                  "resetTestClock — the latch is a global"))

    if offenders:
        print(f"check-height-shim: {len(offenders)} problem(s) — reads that "
              f"bypass heightNow(), or a test clock left armed:", file=sys.stderr)
        for name, why in offenders:
            print(f"  {name}: {why}", file=sys.stderr)
        print("\n  For a raw read: use heightNow(). runtime.ChainHeight() ignores the\n"
              "  test clock's height skew, so on a seeded chain that one read sees a\n"
              "  different height from every other read in the same transaction.\n"
              "\n  For an armed latch: add `defer resetTestClock(...)`. tcArmed is a\n"
              "  package global, so leaving it set freezes heightNow() for every test\n"
              "  that runs after yours while the real chain keeps advancing — and a\n"
              "  test deriving state from the raw height then writes into heightNow()'s\n"
              "  future, which surfaces as checkpoint's \"the clock went backwards\"\n"
              "  somewhere unrelated to the test that actually broke it.",
              file=sys.stderr)
        return 1

    print(f"check-height-shim: {scanned} realm files and the pure packages — every "
          f"height read goes through heightNow() ({shim_sites} raw read(s), all inside "
          f"the shim), no alias evasion, no clockless ledger, and all "
          f"{armings} test(s) that arm the clock disarm it again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
