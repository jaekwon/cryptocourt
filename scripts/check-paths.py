#!/usr/bin/env python3
"""Check that no file still points at a realm path the rename retired.

The project was cryptocourt and is Kourt. `realm/r/court` became
`realm/r/kourtv1`, `realm/r/courtv2` became `realm/r/kourtv2`, and the import org
`gno.land/{p,r}/cryptocourt/...` became `gno.land/{p,r}/kourt/...`. A reference to
any retired spelling points at nothing.

This guard exists because hand searching failed TWICE — once during the branch
merge and once in the cleanup after it — and both times the same way: a set of
grep patterns was assumed to be the whole class. Four spellings slipped through,
and WHY each one did is the useful part:

  - `realm/r/court` written WITHOUT a trailing slash, so a search for
    `realm/r/court/` missed it. It sat in a .gno comment.
  - `{p,r}/cryptocourt` inside a docstring, so a search for `r/cryptocourt`
    missed it — and that docstring told the reader the staging path "cannot be
    changed" while the Makefile had already changed it.
  - `p/cryptocourt`, for the mirror reason.
  - `r/kourt/court` — a HALF-rename, org updated and realm not. This is the one
    worth the whole file: a path that has never existed at any point, so a search
    for the OLD name misses it and a search for the NEW name misses it too. It
    sat in three files and was found only by a reviewer reading prose.

AN ENUMERATION THAT CLAIMS TO BE COMPLETE IS A CLAIM, NOT A FACT, and a set of
search patterns is exactly such an enumeration. Review proved that again on this
very file: the first version's half-rename pattern ended in `(?![a-z0-9])`, which
matched `kourt/court` and therefore NOT `kourt/courtv2` — the V2 half-rename
escaped the pattern written for half-renames. So the patterns are now pinned by
FIXTURES that run before any scan (see SELFTEST below). A regex that stops
matching what it was written for now fails the build instead of reporting clean.

SCOPE: PATHS, not the project's name in prose. `Cryptocourt's own ledger` is a
stale NAME and a different, lesser problem — it misleads nobody about where code
lives. Every pattern below is anchored to a path separator for that reason, which
is also why this guard needs almost no allowlist: a bare word would have needed
one row per changelog entry that mentions the old name.

Three questions:

  1. Do the patterns still match what they were written to match? (SELFTEST)
  2. Does any tracked file contain a retired path outside the allowlist?
  3. Is the allowlist itself still accurate? Every exemption pins a COUNT, not a
     filename, because a file can legitimately mention an old path while ALSO
     acquiring a new stale one — gnoroot.py did exactly that, carrying two
     deliberate spellings and one rotted docstring together. A blanket per-file
     exemption would have hidden it. Drift is reported in both directions: too
     many means new rot, too few means the exemption has outlived its reason.

Pure text scan. No gno checkout, no staging, no lock.

    python3 scripts/check-paths.py
"""

import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The retired spellings, each with what to write instead. Anchored on a path
# separator: see SCOPE above.
RETIRED = [
    (re.compile(r"(?:[pr]|\{p,r\})/cryptocourt"),
     "the org is `kourt` now: gno.land/{p,r}/kourt/..."),
    (re.compile(r"\b[pr]/courtv2|realm/r/courtv2"),
     "V2 lives at realm/r/kourtv2 (import gno.land/r/kourt/kourtv2)"),
    (re.compile(r"realm/r/court(?![a-z0-9])"),
     "V1 lives at realm/r/kourtv1 — fires with or without a trailing slash"),
    (re.compile(r"kourt/court"),
     "half-rename: the org moved and the realm did not. V1 is "
     "gno.land/r/kourt/kourtv1, V2 is gno.land/r/kourt/kourtv2"),
]

# Inputs every pattern set must agree on, checked before the tree is scanned.
# These are the cheap half of the lesson above: counting mentions in prose is an
# aggregate canary, but a fixture names the exact string a pattern exists for.
MUST_FIRE = [
    "gno.land/r/cryptocourt/courtv2",
    "gno.land/p/cryptocourt/twap/v0",
    "$GNOROOT/examples/gno.land/{p,r}/cryptocourt and removes that tree",
    "realm/r/courtv2/court.gno",
    "loadpkg p/courtv2",
    "the V1 realm at realm/r/court is untouched",   # no trailing slash
    "gno.land/r/kourt/court",                       # half-rename, V1
    "gno.land/r/kourt/courtv2",                     # half-rename, V2
    "gno.land/r/kourt/courtv1",                     # half-rename, V1 spelled long
]
MUST_NOT_FIRE = [
    "gno.land/r/kourt/kourtv1",
    "gno.land/r/kourt/kourtv2",
    "gno.land/p/kourt/checkpoint/v0",
    "realm/r/kourtv1/court.gno",
    "realm/r/kourtv2/court.gno",
    "cm := ensureMod(c); courtMod state",
    "courtNameFor(c)",
    "mustCourt(courtSlug)",
    "CourtSuspended(courtSlug)",
    "courtIsPurged(c)",
    "courts.Set(slug, c)",
    "Cryptocourt's own ledger never gets there",     # a stale NAME, out of scope
    'BASE = os.path.join(tempfile.gettempdir(), "cryptocourt-gnoroot")',
    'STAGED = ("cryptocourt", "kourt")',
]

# Files permitted to name the retired paths, with the count each may carry and
# the reason. The count is the pin: see question 3 above.
#
# This file and the self-test are exempt because they must SPELL the retired
# paths to guard them — the same reason check-citations exempts its own scope.
ALLOW = {
    "scripts/check-paths.py": (None,
        "the patterns and fixtures ARE the retired paths; a guard cannot scan itself"),
    "scripts/selftest-checks.py": (None,
        "its control arms quote this file's patterns verbatim in order to break them"),
    "BRANCHING.md": (None,
        "documents the rename for anyone arriving from the old branch, and names the "
        "exact spellings that hid from a hand search so the next person does not "
        "repeat it"),
    "PLAN.md": (2,
        "two dated changelog entries: one names the staging path as it was when the "
        "entry was written, the other the module path V2 landed under. Editing "
        "either would falsify the record rather than fix anything"),
    "WEBSITE-ITERATION.md": (None,
        "another workstream's append-only iteration log, which QUOTES the wrong "
        "paths it found and corrected — including the r/kourt/courtv2 half-rename. "
        "Uncounted on purpose: it grows on every iteration, and a pinned count "
        "would break this guard on somebody else's unrelated append"),
    "MODERATION.md": (1,
        "a changelog entry QUOTES the old link string when recording the bug about "
        "it; rewriting a quotation makes the entry describe something that never "
        "happened"),
}

SKIP_SUFFIX = (".png", ".jpg", ".jpeg", ".gif", ".pdf", ".rtf", ".ico",
               ".woff", ".woff2", ".pyc")


def selftest():
    """Pin the patterns themselves. Returns a list of failure strings."""
    bad = []
    for s in MUST_FIRE:
        if not any(p.search(s) for p, _ in RETIRED):
            bad.append("SELFTEST no pattern fires on %r.\n"
                       "         A retired path this guard exists to catch would "
                       "pass unnoticed." % s)
    for s in MUST_NOT_FIRE:
        for p, _ in RETIRED:
            if p.search(s):
                bad.append("SELFTEST %s fires on %r, which is correct code or "
                           "out of scope.\n         A guard that cries wolf gets "
                           "switched off." % (p.pattern, s))
    return bad


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=REPO,
                         capture_output=True, text=True, check=True).stdout
    return [f for f in out.split("\n")
            if f and os.path.isfile(os.path.join(REPO, f))
            and not f.endswith(SKIP_SUFFIX)]


def main():
    bad = 0
    for msg in selftest():
        print(msg, file=sys.stderr)
        bad += 1
    if bad:
        print("\n%d pattern(s) no longer match what they were written for." % bad,
              file=sys.stderr)
        return 1

    files = tracked_files()
    if not files:
        print("check-paths: git ls-files returned nothing, so this guard measured "
              "nothing. Is %s a repository?" % REPO, file=sys.stderr)
        return 1

    found = {}
    for rel in files:
        try:
            text = open(os.path.join(REPO, rel), encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for lineno, line in enumerate(text.split("\n"), 1):
            for pat, advice in RETIRED:
                if pat.search(line):
                    found.setdefault(rel, []).append((lineno, line.strip(), advice))

    for rel, hits in sorted(found.items()):
        if rel not in ALLOW:
            for lineno, line, advice in hits:
                print("STALE %s:%d\n      %s\n      -> %s"
                      % (rel, lineno, line[:110], advice), file=sys.stderr)
                bad += 1
            continue
        want, _ = ALLOW[rel]
        if want is not None and len(hits) != want:
            print("ALLOWLIST %s carries %d retired-path mention(s), pinned at %d.\n"
                  "          %s\n"
                  "          If the new one is deliberate, raise the count and say "
                  "why. If a mention went away, lower it — an exemption that guards "
                  "nothing passes forever."
                  % (rel, len(hits), want,
                     "; ".join("%d: %s" % (n, l[:70]) for n, l, _ in hits[:4])),
                  file=sys.stderr)
            bad += 1

    # A counted allowlist row whose file holds nothing is a dead exemption, and
    # dead exemptions are how a guard's coverage quietly shrinks.
    for rel, (want, _) in sorted(ALLOW.items()):
        if want is not None and rel not in found:
            print("ALLOWLIST %s is exempt for %d mention(s) and has none. Delete "
                  "the row; the exemption is guarding nothing." % (rel, want),
                  file=sys.stderr)
            bad += 1

    if bad:
        print("\n%d retired-path problem(s)." % bad, file=sys.stderr)
        return 1
    counted = [w for w, _ in ALLOW.values() if w is not None]
    print("check-paths: %d files scanned against %d retired spelling(s), "
          "%d fixture(s) hold, %d deliberate mention(s) across %d allowlisted "
          "file(s)." % (len(files), len(RETIRED),
                        len(MUST_FIRE) + len(MUST_NOT_FIRE),
                        sum(counted), len(ALLOW)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
