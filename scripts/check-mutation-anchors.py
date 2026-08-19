#!/usr/bin/env python3
"""Check that every mutation row still anchors to exactly one place in its target.

A mutation row is a (pkg, file, find, replace) tuple: `mutate.py` locates `find`
in the file, swaps in `replace`, and requires the suite to go red. If `find` no
longer occurs, nothing was mutated and nothing was measured.

`mutate.py` ALREADY reports that as BAD ANCHOR and counts it as not-caught, so
this guard is not closing a hole in the batch. What it changes is WHEN you find
out. The batch stages a gno checkout, runs whole suites per row, takes minutes,
holds a lock, and cannot run beside anything else — so it is the gate run last
and least. This is a pure text scan of the corpus against the working tree:
sub-second, no checkout, no lock, safe to put in `make check`. Rot gets caught by
the commit that causes it instead of by whoever next runs the batch.

The rule itself and the pkg→directory map are IMPORTED from `mutate.py`
(`anchor_count`, `PKGS`), never restated. The first version of this file
hand-rolled both and read PKGS back out with a regex, which is the drift it
exists to prevent — and the regex failed loudly in a traceback rather than in
this guard's own words.

WHY IT IS WORTH A FILE. A merge brought 563 unique rows across from another
branch; 45 of them anchored nowhere and were dropped. They were not 45 problems.
They were three:

  - 19 quoted a panic string, and the rename moved the prefix `courtv2:` to
    `kourtv2:`. 15 of them needed nothing but the respelling; the other 4 had
    moved as well. A path guard cannot see this class — `courtv2:` inside a panic
    message is not a path. A HALF-RENAME HIDES IN DATA AS WELL AS IN PATHS.
  - 8 were anchored in the `defaultParams()` struct literal, and ONE added field
    (`stakeOpenDelayBlocks`, the longest name in the block) made gofmt re-align
    every line in it. SEVEN of those eight died to one space, with nothing about
    their values or their guards changed. The eighth looked like the same defect
    and was not: `minAnswerX` had also gone 100 CC → 1 CC in `a2b1123`, so it
    belongs in the third class below. A UNIFORM SYMPTOM IS NOT A UNIFORM CAUSE —
    the first pass here recorded all eight as one thing, twice: once as eight
    moved values, then as eight lost spaces. Both were wrong by one.
  - the rest tracked code that genuinely moved: sanitization pulled up into
    modrender helpers, and stake escrow replaced by a lock.

The first two classes are the reason for this guard. Both are invisible to
review, neither touches behaviour, and both are the ordinary consequence of a
rename or a field addition — which is to say they will happen again.

THREE CHECKS THE BATCH DOES NOT MAKE, because it sees one row at a time:

  - DUPLICATE TRIPLES. Two rows with the same (pkg, file, find, replace) are one
    mutation billed twice. The batch runs both, reports both caught, and reads as
    more coverage than exists. Eighteen such pairs were in this corpus, left by a
    merge that deduped on the LABEL. Three of the 45 dropped rows above turned out
    the same way: once respelled they landed on triples the corpus already had.
    A ROW THAT APPLIES CAN STILL BE A DUPLICATE.
  - ACROSS CORPUS FILES, not just within one. `mutate.py` documents a promotion
    path out of `mutations-*-KNOWN-GAPS.json` into the main batch; a promotion
    done by COPY instead of MOVE leaves the identical row in both files, and
    per-file checking would never see it.
  - DUPLICATE LABELS. The label is a row's only identity: `mutate.py` prints it
    with no index and its survivor list is labels alone, and `mutate-parallel.py`
    shards rows ROUND-ROBIN, so twins land in different shards and report in
    unrelated places. One label caught and the same label survived leaves a reader
    nothing to grep for. (A guard that genuinely exists in two realms would
    collide here; the fix then is a label prefix, which is an improvement.)

Also checked: the row is shaped like a row at all; `pkg` names a package
`mutate.py` can stage (`where()` raises SystemExit on an unknown one, which kills
the WHOLE batch at that row — loud, but every later row goes unmeasured, and
`mutate-parallel.py` turns the non-zero exit into "the run is NOT a result");
every `PKGS` key also has an `OBSERVERS` entry, because `OBSERVERS.get(pkg,
list(PKGS))` falls back to running EVERY package's suite, and then a suite red for
an unrelated reason reads as this row being caught — a `PKGS` entry added without
an `OBSERVERS` entry is exactly the silent version of the loud failure above;
the target file exists;
`replace` differs from `find` (a no-op row applies cleanly, leaves the source
unchanged, and is reported as a SURVIVOR — a phantom finding in a batch whose
whole contract is that there are none); and an `elsewhere` annotation — the one
sanctioned way to record that a row's coverage lives outside the mutated package
— names a file that is really there. An excuse pointing at a deleted file is
worse than no excuse.

That last one is deliberately STRICTER than `mutate.py`, which only prints the
value and would accept prose like "the txtar suite". Prose cannot rot detectably;
a path can. The corpus's one `elsewhere` is a path, so the tightening costs
nothing today and stops the annotation from decaying into a shrug.

    python3 scripts/check-mutation-anchors.py
"""

import glob
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import mutate  # noqa: E402  — the rule and the path map, imported not restated
import repolock  # noqa: E402

# A corpus file that is allowed to hold no rows, and why. `[]` here is an
# ACHIEVEMENT, not a fault: a commit named "closing the last known gap" (8e4c33a)
# emptied it, and it fills again when the next gap is found. Failing on it would
# make this guard cry wolf about the one state the project worked toward.
#
# Named per file rather than inferred from an aggregate. "One empty file is fine,
# all of them is a deleted corpus" passes clean the moment KNOWN-GAPS refills and
# the MAIN corpus is truncated to `[]` — an aggregate canary cannot tell those
# apart, and the total==0 backstop below only catches the case where nothing at
# all is left.
MAY_BE_EMPTY = {
    "scripts/mutations-kourtv2-KNOWN-GAPS.json":
        "every row here is a deliberate survivor, so `[]` means every known gap "
        "is closed (8e4c33a). It fills again when the next one is found.",
}

REQUIRED = ("file", "find", "replace")


def row_verdicts(rows, resolve):
    """Problems visible in ONE row. `resolve(pkg, file)` returns (path, text),
    text None when the file is missing; (None, None) when the pkg is unknown.
    Injected so the fixtures below can reach every verdict without a real tree."""
    bad = []
    for r in rows:
        label = r.get("label") if isinstance(r, dict) else None
        if not isinstance(r, dict) or not set(REQUIRED) <= set(r):
            bad.append("MALFORMED ROW %r: a row is (pkg, file, find, replace); "
                       "this one has %s."
                       % (label or "<unlabelled>",
                          sorted(r) if isinstance(r, dict) else type(r).__name__))
            continue
        if not label:
            bad.append("UNLABELLED row in %s: %r.\n"
                       "           The label is a row's only identity in the "
                       "batch's output." % (r["file"], r["find"][:60]))
        # Independent of whether the row resolves, so it is not swallowed by a
        # `continue` below: a dead excuse is a dead excuse either way.
        where = r.get("elsewhere")
        if where and not os.path.exists(os.path.join(REPO, where)):
            bad.append("STALE ELSEWHERE %r on %r names a file that does not "
                       "exist.\n                An excuse pointing at nothing is "
                       "worse than no excuse." % (where, label or "<unlabelled>"))
        pkg = r.get("pkg", "govern")
        path, text = resolve(pkg, r["file"])
        if path is None:
            bad.append("UNKNOWN PKG %r on %r.\n"
                       "            mutate.py's where() raises SystemExit on it, "
                       "killing the whole batch at this row — every row after it "
                       "goes unmeasured." % (pkg, label or "<unlabelled>"))
            continue
        if text is None:
            bad.append("MISSING FILE %s (pkg %s) on %r.\n"
                       "             The row cannot run at all."
                       % (r["file"], pkg, label or "<unlabelled>"))
            continue
        if r["find"] == r["replace"]:
            bad.append("NO-OP ROW %r: find and replace are identical, so the row "
                       "applies cleanly, changes nothing, and is reported as a "
                       "SURVIVOR." % (label or "<unlabelled>"))
            continue
        n = text.count(r["find"])
        if n != 1:
            why = ("the anchor is gone — a rename, a re-format, or the guard it "
                   "targeted was rewritten" if n == 0 else
                   "the anchor is ambiguous; widen it upward until it is unique")
            bad.append("BAD ANCHOR %s/%s matched %dx on %r.\n"
                       "           %s\n           %s"
                       % (pkg, r["file"], n, label or "<unlabelled>", why,
                          repr(r["find"])[:120]))
    return bad


def cross_verdicts(pairs):
    """Problems only visible ACROSS rows, and across corpus FILES. `pairs` is
    [(corpus_rel_path, row), ...] for every row in every corpus."""
    bad = []
    by_mutation, by_label = {}, {}
    for rel, r in pairs:
        if not isinstance(r, dict) or not set(REQUIRED) <= set(r):
            continue
        # `pkg` is part of the identity: two staged trees may hold a same-named
        # file, and a shared idiom in both is not one mutation billed twice.
        # `replace` is part of it too — 174 rows share a (file, find) with another
        # row and differ only in what they swap in.
        key = (r.get("pkg", "govern"), r["file"], r["find"], r["replace"])
        by_mutation.setdefault(key, []).append((rel, r.get("label")))
        if r.get("label"):
            by_label.setdefault(r["label"], []).append((rel, r["file"]))
    for (_, f, _, _), hits in sorted(by_mutation.items(), key=lambda kv: str(kv[0])):
        if len(hits) > 1:
            bad.append("DUPLICATE TRIPLE in %s — one mutation, %d rows:\n%s\n"
                       "                 The batch runs each and reports each "
                       "caught, so the corpus reads bigger than it is."
                       % (f, len(hits),
                          "\n".join("                   %s: %s" % (rel, lab)
                                    for rel, lab in hits)))
    for label, hits in sorted(by_label.items()):
        if len(hits) > 1:
            bad.append("DUPLICATE LABEL %r in %s. The label is a row's only "
                       "identity in the batch's output, and mutate-parallel.py "
                       "shards round-robin, so the two report in unrelated places."
                       % (label, ", ".join("%s(%s)" % (r, f) for r, f in hits)))
    return bad


# ---- fixtures ----------------------------------------------------------------
# Every verdict is pinned, because a guard whose checks have rotted reports clean.
FIXTURE_TREE = {("kourtv2", "a.gno"): '\tif x < 1 {\n\t\tpanic("no")\n\t}\n\tif x < 1 {\n',
                ("kourtv2", "b.gno"): "\tonce := 1\n"}


def fixture_resolve(pkg, f):
    if pkg != "kourtv2":
        return None, None
    return "synthetic/" + f, FIXTURE_TREE.get((pkg, f))


def R(**kw):
    r = {"pkg": "kourtv2", "file": "b.gno", "label": "L",
         "find": "once", "replace": "x"}
    r.update(kw)
    return r


ROW_FIXTURES = [
    ([R(pkg="nope")], "UNKNOWN PKG"),
    ([R(file="gone.gno")], "MISSING FILE"),
    ([R(replace="once")], "NO-OP ROW"),
    ([R(find="absent")], "matched 0x"),
    ([R(file="a.gno", find="\tif x < 1 {\n")], "matched 2x"),
    ([R(elsewhere="no/such/file.txtar")], "STALE ELSEWHERE"),
    ([{"pkg": "kourtv2", "file": "b.gno", "find": "once", "replace": "x"}],
     "UNLABELLED"),
    ([{"pkg": "kourtv2", "label": "L", "find": "once"}], "MALFORMED ROW"),
    (["not a row at all"], "MALFORMED ROW"),
    # A missing `file` used to be reported as UNKNOWN PKG, naming a package that
    # was right there in PKGS.
    ([{"pkg": "kourtv2", "label": "L", "find": "once", "replace": "x"}],
     "MALFORMED ROW"),
    # The clean case must stay clean, or every fixture above proves nothing.
    ([R()], None),
]

CROSS_FIXTURES = [
    ([("c.json", R(label="A")), ("c.json", R(label="B"))], "DUPLICATE TRIPLE"),
    # The promotion-by-copy case: one row, two corpus files.
    ([("main.json", R(label="A")), ("gaps.json", R(label="B"))],
     "DUPLICATE TRIPLE"),
    ([("c.json", R(label="A")), ("c.json", R(label="A", find="other"))],
     "DUPLICATE LABEL"),
    # pkg is part of the identity, so the same idiom in two staged trees is not
    # one mutation billed twice. (Distinct labels, or this fixture would trip the
    # duplicate-LABEL check instead and prove nothing about the triple key.)
    ([("c.json", R(label="A")), ("c.json", R(label="B", pkg="govern"))], None),
    # ...and `replace` is, or the 174 rows sharing a (file, find) all collide.
    ([("c.json", R(label="A")), ("c.json", R(label="B", replace="y"))], None),
    ([("c.json", R())], None),
]


def selftest():
    bad = []
    for rows, want in ROW_FIXTURES:
        got = "\n".join(row_verdicts(rows, fixture_resolve))
        bad += _check(got, want, "row")
    for pairs, want in CROSS_FIXTURES:
        got = "\n".join(cross_verdicts(pairs))
        bad += _check(got, want, "cross")
    return bad


def _check(got, want, kind):
    if want is None:
        if got:
            return ["SELFTEST a well-formed %s fixture was reported as a "
                    "problem:\n         %s\n         A guard that cries wolf "
                    "gets switched off." % (kind, got.split("\n")[0])]
    elif want not in got:
        return ["SELFTEST no %s verdict contains %r.\n"
                "         A corpus row this guard exists to catch would pass "
                "unnoticed. Got: %s"
                % (kind, want, got.split("\n")[0] or "(clean)")]
    return []


def main():
    # A selftest run rewrites this corpus and mutate.py on purpose. Reading them
    # mid-flight would report ITS deliberate breakage as MY finding.
    repolock.refuse_if_held("check-mutation-anchors")

    broken = selftest()
    for msg in broken:
        print(msg, file=sys.stderr)
    if broken:
        print("\n%d fixture(s) no longer hold." % len(broken), file=sys.stderr)
        return 1

    pkgs = getattr(mutate, "PKGS", None)
    if not pkgs:
        print("check-mutation-anchors: could not read PKGS out of scripts/"
              "mutate.py, so nothing was resolved. Did the map move?",
              file=sys.stderr)
        return 1

    # A pkg mutate.py can stage but has no OBSERVERS entry for runs EVERY
    # package's suite, so a suite red for an unrelated reason reads as a catch.
    # Unlike an unknown pkg, nothing announces it.
    blind = sorted(set(pkgs) - set(getattr(mutate, "OBSERVERS", {})))
    if blind:
        print("NO OBSERVERS for %s. mutate.py's OBSERVERS.get(pkg, list(PKGS)) "
              "falls back to running every package, so a suite failing for an "
              "unrelated reason reads as these rows being caught."
              % ", ".join(blind), file=sys.stderr)
        return 1

    def resolve(pkg, f):
        if pkg not in pkgs:
            return None, None
        path = os.path.join(pkgs[pkg][0], f)
        if not os.path.isfile(path):
            return path, None
        return path, open(path, encoding="utf-8", errors="ignore").read()

    corpora = sorted(glob.glob(os.path.join(REPO, "scripts/mutations-*.json")))
    if not corpora:
        print("check-mutation-anchors: no scripts/mutations-*.json, so this guard "
              "measured nothing.", file=sys.stderr)
        return 1

    bad, total, counts, pairs = 0, 0, {}, []
    for path in corpora:
        rel = os.path.relpath(path, REPO)
        try:
            rows = json.load(open(path))
        except (OSError, ValueError) as e:
            print("UNREADABLE %s: %s" % (rel, e), file=sys.stderr)
            bad += 1
            continue
        if not isinstance(rows, list):
            print("NOT A LIST %s holds %s, not an array of rows."
                  % (rel, type(rows).__name__), file=sys.stderr)
            bad += 1
            continue
        if not rows and rel not in MAY_BE_EMPTY:
            print("EMPTY CORPUS %s carries no rows, and is not one of the files "
                  "allowed to.\n             %s"
                  % (rel, "; ".join(sorted(MAY_BE_EMPTY)) or "(none are)"),
                  file=sys.stderr)
            bad += 1
            continue
        counts[rel] = len(rows)
        total += len(rows)
        pairs += [(rel, r) for r in rows]
        for msg in row_verdicts(rows, resolve):
            print("%s: %s" % (rel, msg), file=sys.stderr)
            bad += 1

    for msg in cross_verdicts(pairs):
        print(msg, file=sys.stderr)
        bad += 1

    # The backstop under MAY_BE_EMPTY: an exemption for one file must not become
    # a clean report for a corpus that has entirely gone away.
    if total == 0:
        print("check-mutation-anchors: every corpus file is empty, so this guard "
              "measured nothing.", file=sys.stderr)
        bad += 1

    if bad:
        print("\n%d mutation-corpus problem(s). Every one of these is a row that "
              "measures nothing, or measures something twice." % bad,
              file=sys.stderr)
        return 1
    print("check-mutation-anchors: %d row(s) across %d corpus file(s) each anchor "
          "exactly once and appear once, %d fixture(s) hold. (%s)"
          % (total, len(corpora), len(ROW_FIXTURES) + len(CROSS_FIXTURES),
             ", ".join("%s: %d" % (os.path.basename(k), v)
                       for k, v in sorted(counts.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
