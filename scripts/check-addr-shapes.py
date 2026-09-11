#!/usr/bin/env python3
"""An address is recognised in two places, and both have to mean the same thing.

  internal/scan/prefilter.go   decides whether a CLAIM mentions an account, and
                               floors the verdict when it does
  internal/chat/bot.go         refuses to POST a clerk reply that names one

They exist for different reasons and neither can be deleted for the other. The
prefilter is about grading what somebody filed; the reply filter is about what
the site's own voice is allowed to say, because an address in the clerk's name is
a payment instruction wearing a reserved moniker and the panel renders message
text verbatim for copying.

WHAT DRIFT LOOKS LIKE, and why it is silent. Loosen the prefilter's pattern to
catch a new form and the reply filter keeps posting that form; tighten the reply
filter and a claim that mentions an account stops being floored. Neither shows up
in any test that does not compare the two files, which is what this does.

TWO DEFINITIONS RATHER THAN AN EXPORT, on purpose: the packages are otherwise
unrelated, chat does not import scan and should not start in order to share a
regex. A guard is cheaper than a dependency, and this is the guard.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN = os.path.join(ROOT, "internal", "scan", "prefilter.go")
CHAT = os.path.join(ROOT, "internal", "chat", "bot.go")

# name in scan  -> name in chat. Both are Go backquoted regexp literals.
PAIRS = [("reGnoAddr", "botReplyGnoAddr"), ("reEVMAddr", "botReplyEVMAddr")]


def literal(path, name):
    src = open(path).read()
    m = re.search(re.escape(name) + r"\s*=\s*regexp\.MustCompile\(`([^`]*)`\)", src)
    if not m:
        sys.exit(
            "check-addr-shapes: %s not found in %s as a backquoted "
            "regexp.MustCompile — if it moved, point this guard at the new home "
            "rather than deleting it." % (name, os.path.relpath(path, ROOT))
        )
    return m.group(1)


def main():
    import re as _re

    # VACUITY FIRST, AND PER FILE. A pattern that matched nothing would satisfy
    # the comparison below perfectly, so each file's own pattern is exercised
    # against an address of its kind and against a lookalike that must NOT match.
    # Checked before the comparison on purpose: with the order reversed, a single
    # edit that loosened one pattern would report drift and these arms would be
    # unreachable, which is a guard with two rules nothing can break.
    samples = {
        "gno": ("g1w746drdmenjdg0ll38dltjt7kkgtq5lmsmghcg", "g1short"),
        "evm": ("0x52908400098527886E0F7030069857D2E4169EE7", "0xdead"),
    }
    kinds = [("gno", SCAN, "reGnoAddr"), ("gno", CHAT, "botReplyGnoAddr"),
             ("evm", SCAN, "reEVMAddr"), ("evm", CHAT, "botReplyEVMAddr")]
    for kind, path, name in kinds:
        pat = literal(path, name)
        hit, miss = samples[kind]
        rx = _re.compile(pat)
        where = "%s:%s" % (os.path.relpath(path, ROOT), name)
        if not rx.search(hit):
            sys.exit(
                "check-addr-shapes: %s no longer matches a real address (%s) — a "
                "pattern that catches nothing satisfies every comparison in this "
                "guard while recognising no account at all." % (where, hit)
            )
        if rx.search(miss):
            sys.exit(
                "check-addr-shapes: %s matches %s, which is not an address. Too "
                "loose withholds honest clerk replies and floors honest claims, "
                "and a filter that eats good answers gets switched off." % (where, miss)
            )

    bad = []
    for a, b in PAIRS:
        pa, pb = literal(SCAN, a), literal(CHAT, b)
        if pa != pb:
            bad.append(
                "  %s and %s no longer agree\n    scan: %s\n    chat: %s" % (a, b, pa, pb)
            )
    if bad:
        sys.exit(
            "check-addr-shapes: the two address patterns have drifted\n"
            + "\n".join(bad)
            + "\n\nOne recognises an account in a filed claim, the other refuses to "
            "let the clerk say one. A form only one of them knows about is a form "
            "the other mishandles in silence."
        )
    print(
        "check-addr-shapes: %d address pattern(s) identical in internal/scan and "
        "internal/chat, each matching a real address and not a lookalike."
        % len(PAIRS)
    )


if __name__ == "__main__":
    main()
