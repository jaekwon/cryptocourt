#!/usr/bin/env python3
"""The two seed emitters must tell the SAME STORY.

WHY THIS EXISTS, and it is not hypothetical. scenario.py can seed a node two
ways: --emit plan broadcasts one `gnokey maketx` per step, and --emit txs writes
a genesis transactions file that gnodev applies at startup. The second exists
because the first is slow (measured on covid_demo: 636 transactions at 0.365s
each, 3m52s of a 4m06s run), and the whole point is that the two produce the
SAME CHAIN from the same scenario.

They did not. emit_txs walks scenario STEPS, and sealing the test clock is not a
step — emit_plan appends it in a postamble for a scenario that armed the clock
and never sealed it. So the genesis path ended with the clock still ARMED while
the broadcast path ended sealed, and the difference is the one piece of state
that decides whether any later transaction can still move every date on the
chain. MEASURED on kourt-1: after a genesis seed of covid_demo,
TestClockActive() answered true where the plan path leaves it false. It is
invisible in the docket — every claim, folder and board row reads the same —
which is why it survived until the genesis path was pointed at a chain somebody
reads.

emit_txs' own comment states the standing requirement this file enforces: "the
knowledge is duplicated exactly twice, on purpose, and the pair is what has to
agree."

WHAT IS COMPARED. The ordered sequence of (who, func, args, send) for every
transaction each emitter produces, postamble included. Comparing the sequence
rather than just the seal is deliberate: the seal was one instance of the class,
and the class is "one emitter turns a step into a transaction and the other does
not". Which STEP KINDS become transactions, in what ORDER, is exactly that
question.

    note    narration      -> neither emits a transaction
    expect  a read         -> neither
    refuse  a test's job   -> neither (both skip it explicitly)
    mine    real blocks    -> plan only, and emit_txs REFUSES such a scenario
    call                   -> both
    the clock seal         -> both, from a postamble in each

THE COMPARISON IS EXACT, NOT FUZZY. emit_plan quotes its arguments with
shlex.quote (via _q_sh), so shlex.split inverts it precisely — this reads the
arguments back rather than pattern-matching them, and a quoting change that
altered what the chain receives would show up here as a mismatch.

emit_txtar IS DELIBERATELY NOT IN THIS COMPARISON. It does not seal the clock,
and that is not an oversight: a txtar is a test, it asserts and exits, and
sealing under it would take away a clock a later assertion may need to advance.
The seal belongs to the two emitters that produce a SERVED chain. So this guard
holds the pair that must agree and says nothing about the third.
"""
import glob
import json
import os
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# NO BYTECODE CACHE, AND THIS LINE MUST STAY ABOVE THE IMPORT. It prevents a
# defect this guard would otherwise cause in the selftest that arms it.
#
# Importing scenario writes scripts/__pycache__/scenario.cpython-3xx.pyc, and the
# control arms for this guard PLANT INTO scripts/scenario.py, run, and restore it.
# A plant and a restore inside the same second can leave that .pyc validating as
# current against a source it no longer matches. MEASURED: after ablating the
# emitters three ways the sources were byte-identical to the repo and this guard
# still reported the mining defect from the THIRD ablation; deleting __pycache__
# alone returned it to green. That is planted bytecode outliving its plant, and
# the next arm — or the next guard — would have run against it.
#
# Every other guard here runs as __main__, which writes no .pyc, so these are the
# first arms that plant into a module something IMPORTS.
#
# It is set rather than worked around: exec-ing a fresh compile of scenario.py
# instead of importing it does NOT help, because the scenario files themselves
# import scenario, so the cache gets written anyway — and that route also leaves
# two module instances of one file. One import with the cache off is both simpler
# and complete.
sys.dont_write_bytecode = True

sys.path.insert(0, str(ROOT / "scripts"))
import scenario  # noqa: E402


def plan_calls(text):
    """Every transaction the broadcast plan sends, read back out of the shell.

    ONE TRANSACTION IS NOT ONE LINE. A claim body carries newlines, and
    shlex.quote wraps such a value in single quotes with the newlines intact —
    so the `tx call` for it spans several physical lines. Reading line by line
    splits that transaction in half and shlex then refuses the fragment with
    "No closing quotation", which is how this was found rather than guessed:
    the first version of this guard crashed on covid_demo.

    So a candidate line is extended until it parses. Balanced quoting is the
    test for "this is the whole command", which is the same rule the shell
    itself applies.
    """
    out = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        if not lines[i].strip().startswith("tx call "):
            i += 1
            continue
        buf, j = lines[i], i
        while True:
            try:
                t = shlex.split(buf.strip())
                break
            except ValueError:
                j += 1
                if j >= len(lines):
                    raise SystemExit(
                        "check-seed-emitters: a `tx call` in the emitted plan "
                        "never closes its quoting, so the plan itself would not "
                        "run under /bin/sh")
                buf += "\n" + lines[j]
        i = j + 1
        # `k`, NOT `i`: `i` is the line cursor of the loop above, and reusing it
        # here reset the outer walk to zero on the first transaction.
        func, args, send = None, [], ""
        k = 0
        while k < len(t):
            if t[k] == "-func" and k + 1 < len(t):
                func = t[k + 1]
                k += 2
            elif t[k] == "-args" and k + 1 < len(t):
                args.append(t[k + 1])
                k += 2
            elif t[k] == "-send" and k + 1 < len(t):
                send = t[k + 1]
                k += 2
            elif t[k] == "-pkgpath" and k + 1 < len(t):
                k += 2
            else:
                k += 1
        # emit_plan joins [prefix, args, send, who], so the signer is last.
        out.append((t[-1], func, tuple(args), send))
    return out


def txs_calls(text, addr2name):
    """Every transaction the genesis file carries."""
    out = []
    for line in text.splitlines():
        if not line.strip():
            continue
        msg = json.loads(line)["tx"]["msg"][0]
        who = addr2name.get(msg["caller"], msg["caller"])
        out.append((who, msg["func"], tuple(msg["args"]), msg.get("send") or ""))
    return out


def fake_accounts(scn):
    """An accounts map with the right NAMES and throwaway key material.

    The comparison is about which transactions get made by whom, so the keys
    are irrelevant — but emit_txs bech32-decodes a gpub to write a pub_key, and
    a made-up one would not decode. Stubbing that one function is narrower than
    inventing valid key material, and it cannot mask a sequence difference:
    the caller field this guard reads comes from the ADDRESS, not the key.
    """
    names = {st["who"] for st in scn.steps if st["kind"] == "call"}
    names.add(scenario.DEPLOYER)
    addrs = {n: (f"g1seedcheck{n}", f"gpubseedcheck{n}") for n in sorted(names)}
    # emit_plan calls the deployer by its keyring name, so the two sides are
    # canonicalised onto that spelling rather than onto the txtar harness's.
    addr2name = {a: ("deployer" if n == scenario.DEPLOYER else n)
                 for n, (a, _) in addrs.items()}
    return addrs, addr2name


def main():
    scns = sorted(glob.glob(str(ROOT / "scenarios" / "*.py")))
    if not scns:
        sys.exit("check-seed-emitters: no scenarios/*.py — nothing to compare, "
                 "and a guard that finds no subjects reports a clean tree forever")
    real_pubkey = scenario.pubkey_b64
    scenario.pubkey_b64 = lambda gpub: "c2VlZGNoZWNr"
    hits, compared, refused = [], 0, []
    try:
        for path in scns:
            rel = os.path.relpath(path, ROOT)
            try:
                scn, _ = scenario._load(path)
            except SystemExit as e:
                hits.append(f"  {rel}: will not load ({e})")
                continue
            mined = sum(st["n"] for st in scn.steps if st["kind"] == "mine")
            addrs, addr2name = fake_accounts(scn)
            try:
                txs = scenario.emit_txs(scn, addrs)
            except SystemExit as e:
                # THE REFUSAL IS PART OF THE CONTRACT, so it is asserted rather
                # than merely tolerated: a scenario that mines cannot be a
                # genesis file, because every genesis transaction lands in the
                # same block. An emitter that started accepting one would produce
                # a chain at the wrong height with no complaint.
                if not mined:
                    hits.append(f"  {rel}: --emit txs refused a scenario that "
                                f"does not mine: {e}")
                else:
                    refused.append(rel)
                continue
            if mined:
                hits.append(f"  {rel}: mines {mined} block(s) and --emit txs "
                            f"still produced a file; genesis transactions all "
                            f"land in one block, so this chain would be at the "
                            f"wrong height")
                continue
            a = plan_calls(scenario.emit_plan(scn))
            b = txs_calls(txs, addr2name)
            compared += 1
            if a == b:
                continue
            hits.append(f"  {rel}: the two seeds do not agree — "
                        f"plan sends {len(a)}, genesis carries {len(b)}")
            for i in range(max(len(a), len(b))):
                x = a[i] if i < len(a) else None
                y = b[i] if i < len(b) else None
                if x != y:
                    hits.append(f"      first difference at transaction {i + 1}")
                    hits.append(f"        plan:    {x}")
                    hits.append(f"        genesis: {y}")
                    break
    finally:
        scenario.pubkey_b64 = real_pubkey

    if hits:
        print("check-seed-emitters: the two seed paths would build different "
              "chains", file=sys.stderr)
        for h in hits:
            print(h, file=sys.stderr)
        print("  A scenario means one chain. Whichever emitter is wrong, the "
              "fix is in scripts/scenario.py — and if a step kind is meant to "
              "reach only one of them, say so at both sites.", file=sys.stderr)
        return 1
    # NAME WHAT WAS SKIPPED. A count of agreements says nothing about the
    # scenarios that never got compared, and "0 disagreements" out of 0
    # comparisons is the shape of a guard that stopped watching.
    note = f", {len(refused)} correctly refused as mining ({', '.join(refused)})" \
        if refused else ""
    print(f"check-seed-emitters: {compared} scenario(s) emit the same "
          f"transactions both ways{note}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
