#!/usr/bin/env python3
"""What the mutation corpus covers is a claim about the import graph.

mutate.py's PKGS map decides which trees a mutation run can stage and break, and
the map is deliberately SMALLER than the realm tree. cshares and tickbook are
left out, and the reasoning is written down at length where the exclusion lives:

    "the import graph says only the V1 court realm uses those, and V1 is
     deliberately absent here, so staging them added two suites to every
     mutation for nothing."

That is a cost decision resting on a FACT — who imports what — and the same
comment says exactly what should happen when the fact changes:

    "If either package is ever imported by something deployed, it belongs in
     this map with rows of its own."

Nothing checked it. The import graph is edited by whoever adds an import, in a
file nowhere near mutate.py, and the exclusion would go on reading as considered
long after the consideration expired. A premise that has stopped being true is
worse than one that was never stated, because it has a paragraph vouching for it.

TWO ASSERTIONS, both of them the map's own words turned around:

  1. EVERY IMPORT OF A MAPPED PACKAGE IS ITSELF MAPPED. Scoped to PKGS members
     rather than to the whole tree, which is what makes it exactly right without
     an exemption list: kourtv1 is absent on purpose, so its imports of cshares
     and tickbook are none of this guard's business — until somebody either adds
     kourtv1 to the map or makes a mapped realm import them, which are the two
     events the comment says should force the issue.

  2. EVERY MAPPED PACKAGE HAS AT LEAST ONE CORPUS ROW. The map's own note on
     offerer states the principle and the reason it was added: "a package present
     in this map with no row in the corpus is exactly as unmeasured as one that
     is missing, and this comment explained only the staging." A staged package
     with no rows is a suite nothing has measured, reported as covered.

The reverse — a corpus row naming a package outside the map — is already refused
at runtime by mutate.py itself ("UNKNOWN PKG"), so it is not repeated here.

WHAT THIS DOES NOT CHECK: whether the rows are any good, or whether a package's
suite has teeth. That is what a mutation RUN measures. This checks that the run
is pointed at everything it claims to cover.

    python3 scripts/check-mutation-scope.py
"""
import collections
import glob
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MUTATE = os.path.join(ROOT, "scripts", "mutate.py")
CORPORA = ["scripts/mutations-kourtv2.json",
           "scripts/mutations-kourtv2-KNOWN-GAPS.json"]

# ---------------------------------------------------------------------------
# PKGS, read from the source. Its values are os.path.join(...) calls rather than
# literals, so this reads the shape rather than eval'ing it — and it is bounded
# to the PKGS block so a path string elsewhere in the file cannot be mistaken
# for an entry.
src = io.open(MUTATE, encoding="utf-8").read()
try:
    block = src[src.index("PKGS = {"):]
    block = block[:block.index("\n}")]
except ValueError:
    sys.exit("check-mutation-scope: mutate.py no longer has a PKGS = { ... } "
             "block this guard can read. Reshape the parse rather than deleting "
             "the check — a guard that cannot find its subject reports a clean "
             "tree.")

ENTRY = re.compile(r'^\s{4}"(\w+)":\s*\(os\.path\.join\(REPO,\s*"([^"]+)"\)', re.M)
mapped = {name: rel for name, rel in ENTRY.findall(block)}
if len(mapped) < 5:
    sys.exit("check-mutation-scope: parsed %d PKGS entries, which is too few to "
             "be real — the map has had at least nine for a long time. The "
             "pattern has stopped matching." % len(mapped))

# ---------------------------------------------------------------------------
# The import graph, over shipped sources only. A _test.gno importing something
# extra is a test dependency, not a deployed one, and the map is about what runs
# on chain.
IMPORT = re.compile(r'"gno\.land/(?:p|r)/kourt/(\w+)')
imports = collections.defaultdict(set)
files = 0
for path in sorted(glob.glob(os.path.join(ROOT, "realm", "**", "*.gno"),
                             recursive=True)):
    if path.endswith("_test.gno"):
        continue
    files += 1
    pkg = os.path.basename(os.path.dirname(path))
    for m in IMPORT.finditer(io.open(path, encoding="utf-8").read()):
        if m.group(1) != pkg:  # a package naming itself in its own doc comment
            imports[pkg].add(m.group(1))

if files < 20:
    sys.exit("check-mutation-scope: scanned %d realm .gno file(s), which is too "
             "few to be real. That is a broken guard, not a clean tree." % files)

unmapped = []
for name in sorted(mapped):
    for dep in sorted(imports.get(name, ())):
        if dep not in mapped:
            unmapped.append((name, dep))

# ---------------------------------------------------------------------------
# And the rows.
rows = []
for rel in CORPORA:
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        sys.exit("check-mutation-scope: %s is missing" % rel)
    rows += json.load(io.open(path, encoding="utf-8"))
if len(rows) < 100:
    sys.exit("check-mutation-scope: read %d corpus row(s), far below the "
             "sixteen hundred this repo carries — the corpus did not load."
             % len(rows))

counted = collections.Counter(r.get("pkg") for r in rows)
rowless = sorted(name for name in mapped if not counted.get(name))

# ---------------------------------------------------------------------------
if unmapped:
    print("check-mutation-scope: a mutated package imports one that is never "
          "mutated", file=sys.stderr)
    for name, dep in unmapped:
        print("  %-14s imports %-14s which has no entry in PKGS" % (name, dep),
              file=sys.stderr)
    print("  mutate.py's own note: \"If either package is ever imported by "
          "something deployed, it belongs in this map with rows of its own.\"",
          file=sys.stderr)

if rowless:
    print("check-mutation-scope: a package is staged for mutation and never "
          "mutated", file=sys.stderr)
    for name in rowless:
        print("  %-14s is in PKGS with no corpus row" % name, file=sys.stderr)
    print("  Staged-but-unmutated reads as covered and is not: \"a package "
          "present in this map with no row in the corpus is exactly as "
          "unmeasured as one that is missing.\"", file=sys.stderr)

if unmapped or rowless:
    sys.exit(1)

print("check-mutation-scope: %d mutated package(s), every import of one is "
      "mutated too, and each carries rows (%s). %d realm file(s) scanned."
      % (len(mapped),
         ", ".join("%s %d" % (n, counted[n]) for n in sorted(mapped)),
         files))
