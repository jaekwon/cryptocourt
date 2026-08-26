#!/usr/bin/env python3
"""Two rows must not produce the same MUTANT by different anchors.

check-mutation-anchors compares the `(pkg, file, find, replace)` triple, so two
rows that express one mutation through different anchor text are distinct to it —
one anchored on `} else {\\n\\thalf := ...`, the other on the same line by
indentation alone. Its own author said so when eleven such pairs were found by
hand: "check-mutation-anchors could not see these." This is that check, so the
next pair is found by the tree rather than by somebody deciding to go looking.

WHY A DUPLICATE MUTANT IS WORTH FAILING OVER, given both rows are CAUGHT and
nothing is unsafe:

  1. It costs a full suite run per pass, every pass, for a fact already known.
     At ~75s per row per shard that is real wall clock on every regression run.
  2. It reports one fact twice, so the corpus reads bigger than it is. The count
     is the headline number in every summary — "1199 rows" should mean 1199
     measurements, not 1188 measurements and 11 echoes.
  3. It is a rot signal. Every pair found so far had the same shape: an early
     terse row and a later one naming the function, because a later round
     re-derived a mutation the corpus already had. A pair means two people (or
     two firings) did not see each other's work.

HOW: apply each row's find -> replace to its own source and hash the result,
keyed by file so identical edits to different files do not collide. Same hash
from two rows means the harness would compile and test byte-identical trees
twice.

FAILS CLOSED ON ANY ROW THAT YIELDS NO USABLE MUTANT, which is two cases. A row
whose anchor matches zero or twice is check-mutation-anchors' business and it will
say so, but it is NOT skipped quietly here: its mutant is unknown, and an unknown
mutant cannot be shown to be distinct. Reporting it costs one duplicated complaint
and buys the guarantee that this check saw every row. The second case is a row
that applies perfectly and changes NO BYTES, which is not unappliable at all — it
is a row that tests nothing, and it is caught here because the mutated source is
already in hand.
"""

import collections
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

# The corpus knows which tree a row's `file` lives in; mutate.py owns that map,
# and it is imported rather than copied so the two cannot drift.
import mutate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


# A short-variable declaration, at any indent, capturing the names on the left.
DECL = re.compile(r"^[\t ]*([A-Za-z_][\w, ]*?)\s*:=", re.M)


def unused_after(mutated, at):
    """The first name the mutation orphaned, or None.

    Scoped to the ENCLOSING FUNCTION of the mutation site, and only to `:=`
    declarations, because those are the ones a deleted statement orphans. A name
    used anywhere else in the same function — including inside a closure — counts
    as used, so the test is deliberately conservative: it under-reports rather
    than blocking a legitimate row. Every one of the ten INVALID rows that
    prompted it is caught by exactly this rule.
    """
    head = mutated.rfind("\nfunc ", 0, at)
    if head == -1:
        return None
    tail = mutated.find("\n}\n", head)
    body = mutated[head:tail if tail != -1 else len(mutated)]
    for m in DECL.finditer(body):
        for name in (n.strip() for n in m.group(1).split(",")):
            if not name or name == "_" or not name.isidentifier():
                continue
            if len(re.findall(r"\b%s\b" % re.escape(name), body)) == 1:
                return name
    return None


def main():
    repolock.refuse_if_held("check-mutant-collisions")

    rows = []
    for path in sorted(glob.glob(os.path.join(ROOT, "scripts", "mutations-*.json"))):
        for r in json.load(open(path, encoding="utf-8")):
            rows.append((os.path.basename(path), r))
    if not rows:
        print("check-mutant-collisions: no corpus rows found, so this check is "
              "measuring nothing. The corpus was renamed or moved.",
              file=sys.stderr)
        return 1

    mutants = collections.defaultdict(list)
    unappliable, cache = [], {}
    for corpus, r in rows:
        label = r.get("label", "<unlabelled>")
        entry = getattr(mutate, "PKGS", {}).get(r.get("pkg"))
        if not entry:
            unappliable.append((corpus, label, "pkg %r is not in mutate.py's PKGS map"
                                % r.get("pkg")))
            continue
        path = os.path.join(entry[0], r.get("file", ""))
        if path not in cache:
            try:
                cache[path] = open(path, encoding="utf-8").read()
            except OSError:
                cache[path] = None
        src = cache[path]
        if src is None:
            unappliable.append((corpus, label, "its file does not exist: %s" % r.get("file")))
            continue
        if "find" not in r or "replace" not in r:
            unappliable.append((corpus, label, "the row has no find/replace pair"))
            continue
        n = src.count(r["find"])
        if n != 1:
            unappliable.append((corpus, label, "its anchor matches %dx, so its mutant "
                                               "is unknown (`make anchors` owns that)" % n))
            continue
        mutated = src.replace(r["find"], r["replace"], 1)
        # AND A ROW THAT CHANGES NO BYTES MEASURES NOTHING. Same rule the corpus
        # applies to its own findings — "a mutation that cannot change behaviour is
        # INVALID, not a survivor" — at the textual level, where it is exact rather
        # than an argument. The realistic way in is a re-point after a refactor:
        # `find` is updated to the moved text and the same text lands in `replace`.
        # In the main corpus such a row reports SURVIVED and fails the run, which is
        # loud but misdiagnosed; in KNOWN-GAPS it sits as a recorded gap for ever
        # while testing nothing at all. Free to check here because the mutated
        # source is already in hand. Measured zero across 1199 rows when added.
        if mutated == src:
            unappliable.append((corpus, label, "its replace changes NO BYTES, so the "
                                               "row applies cleanly and tests nothing"))
            continue
        # AND IT MUST PARSE, which is a hole this guard is well placed to close.
        # mutate.py scores a failing suite as a catch, and a mutant that cannot parse
        # fails the suite — measured on a staged copy, an unbalanced paren reports
        # "0 build errors, 1 test errors" with code=gnoParserError and nothing that
        # said "build failure", so it read exactly like coverage. mutate's detector is
        # widened to any code=gno*Error now, but a row whose mutant does not parse is
        # testing nothing whichever way it is scored, so it is refused HERE where the
        # mutated source is already in hand and no suite has to run.
        #
        # gofmt is the parser: .gno is Go syntax, so a temp .go file is all it needs.
        # About 7 seconds for the whole corpus, and zero failures across 1,240 mutants
        # when this arm was added — latent, not live.
        with tempfile.NamedTemporaryFile("w", suffix=".go", delete=False) as tf:
            tf.write(mutated)
            tmp = tf.name
        try:
            pr = subprocess.run(["gofmt", "-e", tmp], capture_output=True, text=True)
        finally:
            os.unlink(tmp)
        if pr.returncode != 0:
            first = (pr.stderr.strip().split("\n") or [""])[0]
            unappliable.append((corpus, label, "its mutant does not PARSE: %s"
                                % first.split(":", 1)[-1].strip()[:80]))
            continue

        # AND IT MUST TYPE-CHECK, which parsing does not cover and which is the
        # hole that actually bit. gofmt above answers "is this Go?"; it does not
        # answer "would the compiler accept it?", and Go's loudest difference
        # between those two is the UNUSED VARIABLE. Delete an
        # `if !fire { return }` and `fire` is still declared, still parses, and
        # will not build.
        #
        # That is not hypothetical: TEN rows in this corpus were reported CAUGHT
        # by a hand-rolled probe that read a non-zero exit code as coverage, and
        # mutate-parallel — which classifies build errors separately — showed all
        # ten as INVALID. Two of the ten, once rebuilt so they compiled, turned
        # out to be genuine survivors guarding a single-key comment purge and a
        # single-moderator hide. A row that cannot build is not a weak test, it
        # is no test, and until now nothing in `make check` could tell.
        if bad := unused_after(mutated, src.index(r["find"])):
            unappliable.append((corpus, label, "its mutant leaves %r declared and "
                                "unused, so it never compiles and tests nothing" % bad))
            continue

        blob = r["file"] + "\0" + mutated
        mutants[hashlib.sha256(blob.encode()).hexdigest()].append((corpus, label))

    collisions = {h: v for h, v in mutants.items() if len(v) > 1}

    if collisions or unappliable:
        if collisions:
            print("check-mutant-collisions: %d group(s) of rows produce the SAME "
                  "mutant by different anchors.\n" % len(collisions), file=sys.stderr)
            for group in collisions.values():
                print("  one mutant, %d rows:" % len(group), file=sys.stderr)
                for corpus, label in group:
                    print("      [%s] %s" % (corpus, label), file=sys.stderr)
            print("\nKeep the row that NAMES THE FUNCTION and the defect — that is the "
                  "line a run prints when the row survives — and fold any reference the "
                  "other carried into it rather than losing it.", file=sys.stderr)
        if unappliable:
            print("\ncheck-mutant-collisions: %d row(s) yielded no usable mutant, so "
                  "this check cannot say their mutants are distinct:"
                  % len(unappliable), file=sys.stderr)
            for corpus, label, why in unappliable:
                print("  [%s] %s\n      %s" % (corpus, label, why), file=sys.stderr)
        return 1

    print("check-mutant-collisions: %d row(s) across %d corpus file(s) produce %d "
          "distinct mutant(s), every one parsing — no two rows measure the same tree."
          % (len(rows), len({c for c, _ in rows}), len(mutants)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
