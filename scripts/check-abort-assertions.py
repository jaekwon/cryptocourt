#!/usr/bin/env python3
"""An abort assertion must not be satisfiable by a layer it is not testing.

THE BUG THAT PRODUCED THIS CHECK. TransferCC and TransferFromCC both open

    if amount <= 0 { panic("kourtv2: transfer amount must be positive") }

and both had a test passing 0 and asserting AbortsContains(..., "must be
positive"). That reads like the guard is pinned. It was not: grc20votes carries
its own mustBePositive panicking "grc20votes: amount must be positive", so the
substring is satisfied by EITHER layer. An operator sweep flipped both guards to
`< 0` and reported SURVIVED, and the measurement says why — with the realm guard
weakened, a zero-amount transfer still aborts:

    panic: grc20votes: amount must be positive

Two rows that looked unpinnable became caught the moment the assertions named
the realm's own full message. Nothing about the realm changed.

THE RULE. An assertion is ambiguous when its substring is contained in BOTH a
kourtv2 panic message AND a panic message in a p/ package kourtv2 imports. Both
halves are required, and the second one is what keeps this usable:

  - "allowance exceeded" is produced ONLY by grc20votes. kourtv2 delegates
    allowance enforcement to the ledger, so asserting the ledger's message is
    correct, not ambiguous. No kourtv2 competitor, no finding.
  - kourtv1 and ccwrap also share messages with kourtv2 by the dozen — they are
    its ancestor and its wrapper — but the kourtv2 suite never calls into them,
    so those pairs cannot fool any assertion here. Only IMPORTED packages count.

WHAT THIS DELIBERATELY DOES NOT CHECK, because the check would be worse than the
gap. A substring can also be loose WITHIN kourtv2: measured at the time of
writing, 46 assertions match more than one kourtv2 panic message, "moderator"
matching fifteen of them. Almost all are harmless — the other messages are not
reachable from the call under assertion — and a check reporting 46 findings
against a correct tree is the kind of nuisance that gets switched off, which
would cost more than it saves. The cross-layer rule is the one with a
demonstrated failure behind it, and it sits at zero.

If this fires: name the full message of the guard you are testing, including its
"kourtv2:" prefix. If you genuinely mean to assert the inner layer's refusal,
assert the inner layer's full message instead — and then no kourtv2 message
matches it, so this check goes quiet on its own.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"
PKGS = ROOT / "realm" / "p"

PANIC = re.compile(r'panic\("((?:[^"\\]|\\.)*)"')
IMPORT = re.compile(r'"gno\.land/p/kourt/(\w+)/v0"')
ASSERT = re.compile(r'(?:AbortsContains\(t, cur,|mustPanicWith\(|AbortsWith\(t, cur,)'
                    r'\s*"((?:[^"\\]|\\.)*)"')

# c.coin is a grc20votes Ledger, reached on every balance, transfer and epoch
# call — it is a dependency whether or not an import line names it in a given
# file, so it is never omitted from the reachable set.
ALWAYS = {"grc20votes"}


def sources(d):
    return sorted(p for p in d.glob("*.gno")
                  if not p.name.endswith("_test.gno") and "filetest" not in p.name)


def main():
    repolock.refuse_if_held("check-abort-assertions")

    realm_files = sources(REALM)
    tests = sorted(REALM.glob("*_test.gno"))
    if not realm_files or not tests:
        print("check-abort-assertions: no kourtv2 sources or tests found; the "
              "realm moved.", file=sys.stderr)
        return 1

    reachable = set(ALWAYS)
    for p in realm_files:
        reachable.update(IMPORT.findall(p.read_text()))

    realm_msgs, pkg_msgs = [], []
    for p in realm_files:
        for msg in PANIC.findall(p.read_text()):
            realm_msgs.append((p.name, msg))
    for pkg in sorted(reachable):
        d = PKGS / pkg
        if not d.is_dir():
            continue
        for p in sources(d):
            for msg in PANIC.findall(p.read_text()):
                pkg_msgs.append((pkg, msg))

    if not realm_msgs or not pkg_msgs:
        print(f"check-abort-assertions: found {len(realm_msgs)} realm panic(s) and "
              f"{len(pkg_msgs)} package panic(s) across {sorted(reachable)}; one "
              f"being zero means this check is scanning for a shape the tree no "
              f"longer has.", file=sys.stderr)
        return 1

    # WHOLE FILE, NOT LINE BY LINE, and the ablation is what found that out. The
    # first version scanned each line on its own and reported 345 assertions and a
    # clean tree — while being structurally blind to every assertion whose message
    # sits on the line below its call, which gofmt produces the moment the message
    # is long enough to wrap. Reverting a tightened assertion to its loose form
    # made the guard say nothing at all. The `\s*` in ASSERT spans newlines, so
    # matching against the file text sees both shapes; the line number comes from
    # counting newlines up to the match.
    seen, bad = 0, []
    for p in tests:
        text = p.read_text()
        for m in ASSERT.finditer(text):
            seen += 1
            sub = m.group(1)
            pk = sorted({pkg for pkg, msg in pkg_msgs if sub in msg})
            rl = sorted({f for f, msg in realm_msgs if sub in msg})
            if pk and rl:
                bad.append((p.name, text.count("\n", 0, m.start()) + 1,
                            sub, pk, rl))

    if not seen:
        print("check-abort-assertions: found no abort assertions at all, so the "
              "pattern has drifted off the tests rather than the tests having "
              "stopped asserting.", file=sys.stderr)
        return 1

    if bad:
        print("check-abort-assertions: an abort assertion can be satisfied by a "
              "layer it is not testing.\n", file=sys.stderr)
        for name, line, sub, pk, rl in bad:
            print(f"  {name}:{line}: asserts {sub!r}", file=sys.stderr)
            print(f"      also matched by p/{', p/'.join(pk)} — and by kourtv2's "
                  f"own {', '.join(rl)}", file=sys.stderr)
        print("\nA guard whose refusal is indistinguishable from an inner layer's "
              "is not pinned: weakening it leaves the inner layer aborting and the "
              "test still passing. That already happened to both transfer amount "
              "guards. Name the full message of the guard under test, prefix "
              "included.", file=sys.stderr)
        return 1

    print(f"check-abort-assertions: {seen} abort assertion(s), none satisfiable by "
          f"a p/ layer that also has a kourtv2 counterpart "
          f"(reachable: {', '.join(sorted(reachable))}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
