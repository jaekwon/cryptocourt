#!/usr/bin/env python3
"""Check that index.html's stylesheet is not silently broken.

SCOPE, STATED BECAUSE THE LAST GUARD THAT LEFT IT VAGUE COST A BUG. This reads
the <style> block in web/index.html and nothing else. The overlay ships a SECOND
stylesheet — CHATCSS in web/chat.js, 1.2KB and 19 rules, injected by chatStyles()
— and it is NOT checked here.

That is a deliberate boundary, not an oversight, and it is worth the sentence
because check-web-dupes had the same shape and was not deliberate: its docstring
said "the overlay" while it read one of the two shipped files, so a cross-file
function collision walked past it and a demo court page started calling the real
chat service (500e543, fixed in c1df426).

Why the boundary is left where it is: this script is a flat scan over one `css`
string, so a second source means restructuring it into a function — real risk to
a working guard — and two of its three checks cannot fire on CHATCSS at all,
which contains no comments. Only brace balance could, on 1.2KB. If CHATCSS grows
comments, or grows at all, that arithmetic changes and this should be a loop over
both sources rather than a note.

WHY THIS EXISTS. A `/* ... */` comment inside `.emb{}` was edited badly and left
a stray `*/` with prose in front of it. CSS error recovery then skipped forward
to the next `;` — which belonged to the declaration AFTER the comment — so
`width:100%` was swallowed and the share card sized itself shrink-to-fit. The
card came out 422px wide inside the 400px frame it exists to fit.

Nothing caught it. `make check` passed, all 16 web harnesses passed, and
`node --check` passed because the mistake was in CSS and that only parses the
script block. The stylesheet is roughly a third of the one file that IS the
product, and until now no gate read it at all.

Three things, all cheap and all things that have actually happened here:

  1. Comment markers balance. A stray `*/` or an unclosed `/*` silently eats
     declarations rather than failing.
  2. Braces balance. An unclosed rule swallows every rule after it.
  3. No declaration is left orphaned between a comment's end and a `;` — the
     specific shape of the bug above, where prose sits where a property should.

Deliberately NOT a CSS validator: unknown properties and vendor prefixes are
fine, and a check that argues about taste gets switched off. This one only
answers "does the parser see what the author wrote".

WHAT IT DOES NOT CATCH, stated because a check that implies more than it tests is
worse than none. An unterminated `/*` whose swallowed region happens to contain
balanced braces is lexically indistinguishable from one long legitimate comment —
armed and confirmed: that case passes. Case 1 catches it only when the comment
eats a rule boundary. The incident this file was written for is case 3, which is
caught.

    python3 scripts/check-web-css.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "web", "index.html")

src = io.open(PATH, encoding="utf-8").read()

# The overlay is one file with one <style>; find it or fail loudly rather than
# reporting success on nothing (a vacuous pass is worse than no check).
try:
    a = src.index("<style>") + len("<style>")
    b = src.index("</style>", a)
except ValueError:
    sys.exit("check-web-css: no <style> block in web/index.html")
css = src[a:b]
if len(css) < 10000:
    sys.exit("check-web-css: <style> block is only %d bytes — refusing to "
             "pass vacuously" % len(css))

line_of = lambda i: css[:i].count("\n") + 1 + src[:a].count("\n")
bad = []

# ---- 1 & 3: comments, and what follows them ------------------------------
i = 0
spans = []          # (start, end) of every comment, for the orphan scan
while i < len(css):
    if css.startswith("/*", i):
        j = css.find("*/", i + 2)
        if j < 0:
            bad.append("unclosed /* opened at line %d" % line_of(i))
            break
        spans.append((i, j + 2))
        # A COMMENT THAT ATE REAL RULES. An unterminated `/*` does not announce
        # itself: it closes against the NEXT comment's `*/`, swallowing every
        # declaration in between, and a naive balance check sees a tidy pair —
        # which is exactly what the CSS parser sees, and why this needs its own
        # test. The signature is braces: prose does not open a rule it fails to
        # close. Measured on this file, all 78 comments balance their braces, so
        # an unbalanced one means real CSS is inside a comment.
        body = css[i:j]
        if body.count("{") != body.count("}"):
            bad.append("line %d: a comment contains %d '{' and %d '}' — an "
                       "unterminated /* has swallowed real rules up to the next "
                       "comment's terminator: %r"
                       % (line_of(i), body.count("{"), body.count("}"),
                          body[:60].replace("\n", " ")))
        i = j + 2
        continue
    if css.startswith("*/", i):
        bad.append("stray */ at line %d — the comment it would close is already "
                   "closed, so the parser is discarding declarations" % line_of(i))
        i += 2
        continue
    i += 1

# Between a comment's end and the next ; or } there must be either nothing, or
# something shaped like a declaration / selector / at-rule. Prose there is the
# mangled-comment signature.
for _, end in spans:
    m = re.match(r"[\s]*([^;{}]*)", css[end:])
    if not m:
        continue
    tail = m.group(1).strip()
    if not tail or tail.startswith(("/*", "@")):
        continue
    # a declaration has a colon before any space-separated word soup; a selector
    # is followed by a brace, which [^;{}] would have stopped at
    if ":" in tail.split(" ")[0] or re.match(r"^[-\w]+\s*:", tail):
        continue
    nxt = css[end + m.end():end + m.end() + 1]
    if nxt == "{":
        continue
    if len(tail.split()) > 2:
        bad.append("line %d: prose where a declaration should be, right after a "
                   "comment: %r" % (line_of(end), tail[:60]))

# ---- 2: braces ------------------------------------------------------------
stripped = css
for s0, e0 in reversed(spans):
    stripped = stripped[:s0] + " " * (e0 - s0) + stripped[e0:]
depth, opened = 0, []
for i, ch in enumerate(stripped):
    if ch == "{":
        depth += 1
        opened.append(i)
    elif ch == "}":
        depth -= 1
        if depth < 0:
            bad.append("unbalanced } at line %d" % line_of(i))
            depth = 0
        elif opened:
            opened.pop()
if depth:
    bad.append("%d unclosed rule(s); the first opens at line %d"
               % (depth, line_of(opened[0])))

if bad:
    print("check-web-css: the overlay's stylesheet is broken", file=sys.stderr)
    for b2 in bad:
        print("  " + b2, file=sys.stderr)
    sys.exit(1)

rules = stripped.count("{")
print("check-web-css: %d bytes of CSS, %d rule(s) — comments and braces balance, "
      "no orphaned declarations." % (len(css), rules))
