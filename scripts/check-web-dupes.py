#!/usr/bin/env python3
"""No two function declarations in the overlay may share a name.

WHY THIS IS A GUARD AND NOT A CONVENTION. web/index.html is one file with a
single ~4,000-line <script> and 156 function declarations in one flat scope.
A second `function foo(...)` does not warn, does not throw, and does not
show up in `node --check`: it silently REPLACES the first, and every existing
caller starts calling the new one.

That is not hypothetical. `claimSeries(d)` fed the docket's sparkline from the
three ratio series the realm keeps. A later `async function claimSeries(slug,
id, d)` was added 2,200 lines away for the embed card, so every docket row
called the async one instead and handed sparkSvg() a Promise:

    pts.map is not a function

on the court page, in BOTH modes, reported by the owner using the app. Nothing
caught it: the source harnesses eval slices of the file and never see two
distant declarations together, and no browser check visited the court docket.
Reading 4,000 lines to notice a name is already taken is not a thing anybody
does, and grep only helps if you already suspect the collision.

WHAT IS ALLOWED. Nothing, for top-level declarations — the whole point is that
the flat scope makes shadowing invisible. Declarations NESTED inside another
function are fine and are excluded by their indentation: a `function` at column
0 is top-level in this file, anything indented is local to its enclosing scope
and shadows deliberately.

Object-literal methods, class methods and assignments to properties are not
declarations and are not scanned; they cannot collide in this way.

    python3 scripts/check-web-dupes.py
"""
import collections
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAGE = ROOT / "web" / "index.html"

# Column 0 only. An indented `function` is nested and shadows on purpose.
DECL = re.compile(r"^(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(", re.M)


def main():
    if not PAGE.is_file():
        print(f"check-web-dupes: no overlay at {PAGE}", file=sys.stderr)
        return 2
    text = PAGE.read_text(encoding="utf-8")

    # Only the script body. A `function` inside a template literal that this
    # page prints as sample code is text, not a declaration — but the script
    # block is where every real one lives, so bound the scan to it.
    a = text.find("<script>")
    b = text.rfind("</script>")
    if a < 0 or b < 0 or b <= a:
        print("check-web-dupes: the overlay has no <script> block to scan — the "
              "page cannot have been parsed correctly, so a clean result here "
              "would mean nothing.", file=sys.stderr)
        return 1
    body = text[a + len("<script>"):b]

    seen = collections.defaultdict(list)
    for m in DECL.finditer(body):
        line = body[:m.start()].count("\n") + 1 + text[:a].count("\n")
        seen[m.group(1)].append(line)

    # A page with no declarations at all would pass every check below having
    # asked nothing. There were 156 when this was written.
    if len(seen) < 100:
        print(f"check-web-dupes: only {len(seen)} top-level function(s) found in "
              f"{PAGE.name} — the scan has lost its anchor (a changed script "
              f"delimiter or indentation style) and would pass vacuously.",
              file=sys.stderr)
        return 1

    dupes = {k: v for k, v in seen.items() if len(v) > 1}
    if dupes:
        print(f"check-web-dupes: {len(dupes)} function name(s) declared more than "
              f"once in web/index.html:", file=sys.stderr)
        for name, lines in sorted(dupes.items()):
            at = ", ".join(f"line {n}" for n in lines)
            print(f"  {name}(): {at}", file=sys.stderr)
        print("\n  One flat scope: the LAST declaration wins and every earlier\n"
              "  caller silently calls it instead. Rename one of them. This is\n"
              "  the defect that made the court page throw 'pts.map is not a\n"
              "  function' — a docket sparkline handed an async function's\n"
              "  Promise.", file=sys.stderr)
        return 1

    print(f"check-web-dupes: {len(seen)} top-level function(s) in web/index.html, "
          f"every name declared exactly once.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
