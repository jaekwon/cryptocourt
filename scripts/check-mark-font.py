#!/usr/bin/env python3
"""Every set mark the page draws must wear the class that carries its font.

THE GLYPH IS NOT IN A SYSTEM FONT ON MOST MACHINES. U+13080 and U+1307C are
Egyptian hieroglyphs; macOS ships a face that has them and most other systems do
not. So the overlay embeds a subsetted woff2 as a data URI and applies it through
`.wedjat` — and a mark drawn WITHOUT that class renders as a tofu box for the
majority of readers while looking perfect to everyone who works on it.

MEASURED, WHICH IS WHY THIS EXISTS. On kourt.xyz the map drew its marks as
`text.mset.wedjat` and computed wedjat-font, while the chat panel drew
`span.chatmark` and computed -apple-system. Same glyph, two surfaces, one of them
silently broken for everyone without an Egyptian font installed. It was found by
hand; nothing would have caught the next one.

SCOPE, STATED NARROWLY. This looks at web/index.html and web/chat.js for an
ELEMENT whose text contains a mark — written as a `\\u{...}` escape, as a literal
glyph, or interpolated from a constant whose name ends in MARK — and requires
`wedjat` among its classes. It says nothing about anything else that mentions the
codepoints: a bare `const SET_MARK = "\\u{13080}"`, a comment, the @font-face rule
and a test fixture are all fine, because none of them is a thing a reader sees.

AND IT CHECKS THE CLASS STILL DOES ITS JOB, because "every mark wears .wedjat" is
worth nothing if .wedjat stops naming the font. Both halves, or this passes while
every mark on the site is a box.
"""

import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = ["web/index.html", "web/chat.js"]

# THE FOUR WAYS A MARK REACHES MARKUP, and the fourth is why this file has a
# mutation test. `\u{...}` and the literal glyph are what they look like. The third
# is a template hole filled from a constant, matched on the NAME because the value
# is not there to see. The fourth is CONCATENATION — `'...>' + hit.mark` — which is
# how web/chat.js builds every tag it emits, since that file has no template
# literals to spare inside its own stylesheet string.
#
# THE FIRST VERSION OF THIS GUARD MISSED THAT, and so passed cleanly against the
# exact bug it was written for: chat.js's mark stripped of `wedjat` sailed through.
# Caught by mutating the source rather than by trusting the summary line, which is
# the only way a blind spot in a scanner ever shows up.
INSIDE = (r"\\u\{130(?:80|7C)\}", "[\U00013080\U0001307C]",
          # A template hole that IS the mark, not one that mentions one. The sites
          # that draw a set mark have gone from `${SET_MARK}` to `${p.mark}` and
          # `${setHead.mark}` as the parser replaced the constants, so this matches
          # a bare path rather than a roster of names.
          #
          # AND "mark" IS TWO VOCABULARIES IN THIS CODEBASE. The verdict marks —
          # `?`, `…`, `.`, `–`, `!` — travel as `rv.mark` and `dv.mark`, and a
          # looser pattern flagged `${verdictSentence(r.title, sd, rv.mark, …)}`
          # as an unfonted hieroglyph twice. Requiring the hole to be ONLY the
          # path, with no call and no arguments, tells the two apart without
          # needing to know either name.
          r"\$\{\s*(?:[A-Za-z_$][\w$]*\.)?(?:mark|SET_MARK|SHUT_MARK)\s*\}",
          # ...and the quote may be a BACKTICK, which was the fifth miss: setMarkHtml
          # closes its opening tag with a template literal and concatenates the
          # glyph after it. Every miss this scanner has had is the same mistake —
          # assuming the tag and its content are adjacent in the SOURCE because
          # they are adjacent in the OUTPUT.
          r"['\"`]\s*\+\s*[A-Za-z_$][\w.$]*[Mm]ark\b")

# FOUND FROM THE MARK BACKWARDS, not from the tag forwards, and the direction is
# the whole difference. Matching "an opening tag, then up to a little text, then a
# mark" missed a site three times: once because chat.js concatenates the tag and
# the glyph as separate strings, once because a template hole is not a literal,
# and once because a <title> child sat between the two and the pattern demanded
# no angle brackets in between.
#
# Every one of those is the same mistake — assuming the two are adjacent in the
# SOURCE because they are adjacent in the OUTPUT. They are not: this file builds
# markup by concatenation and interpolation, so the tag and its content routinely
# live in different expressions.
#
# So find the MARK first — that part is unambiguous — and walk backwards for the
# nearest opening span or text. Anything between them is somebody else's problem.
MARK = re.compile("|".join(INSIDE))
# The LAST opening tag in the window, not one anchored to the end of it. Anchoring
# was the fourth miss: an SVG <text> whose glyph follows a <title> child has two
# more angle brackets in between, so a pattern demanding none after the tag found
# nothing at all. Take every opener and keep the nearest.
OPEN = re.compile(r"<(span|text)\b([^>]*)>", re.S)


def in_comment(src, i):
    r"""Is offset i inside a // or /* */ comment?

    THE DOCSTRING ABOVE PROMISED COMMENTS WERE FINE and they were only fine by
    accident: prose mentioning a codepoint had no tag near enough to walk back to,
    until a comment explaining this very rule mentioned BOTH — "a <text> in the
    embedded face" three lines above "this was \u{13080} spelled into it" — and the
    scanner read the pair as markup drawing an unfonted glyph.

    Cheap and sufficient: a line comment wins if // precedes the offset on its own
    line; a block comment wins if the nearest /* before it is nearer than the
    nearest */. Neither is a JS parser, and neither needs to be — the question is
    only whether a matched GLYPH is code or prose.
    """
    line_start = src.rfind("\n", 0, i) + 1
    if "//" in src[line_start:i]:
        return True
    return src.rfind("/*", 0, i) > src.rfind("*/", 0, i)


def classes(attrs):
    m = re.search(r'class="([^"]*)"', attrs)
    return set((m.group(1) if m else "").split())


def main():
    bad = 0
    drawn = 0
    for rel in FILES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            continue
        src = io.open(path, encoding="utf-8").read()
        for m in MARK.finditer(src):
            if in_comment(src, m.start()):
                continue
            # The nearest opening tag before it. 400 chars is generous for a tag
            # plus an intervening <title>, and short enough that an unrelated span
            # a page away cannot answer for this glyph.
            opens = list(OPEN.finditer(src[max(0, m.start() - 400):m.start()]))
            if not opens:
                continue
            back = opens[-1]
            drawn += 1
            cls = classes(back.group(2))
            if "wedjat" in cls:
                continue
            line = src.count("\n", 0, m.start()) + 1
            print("check-mark-font: %s:%d draws a set mark in <%s class=%r> with no "
                  "`wedjat` class. The glyph is an Egyptian hieroglyph and most "
                  "machines have no font for it — without that class this renders "
                  "as a tofu box for every reader who is not on a Mac, and looks "
                  "correct to everyone who could have noticed."
                  % (rel, line, back.group(1), " ".join(sorted(cls)) or ""),
                  file=sys.stderr)
            bad += 1

    # And the class must still carry the font, or the rule above is theatre.
    web = io.open(os.path.join(REPO, "web/index.html"), encoding="utf-8").read()
    face = re.search(r'@font-face\{font-family:"([^"]+)"', web)
    rule = re.search(r"^\.wedjat\{([^}]*)\}", web, re.M)
    if not face:
        print("check-mark-font: web/index.html no longer embeds a @font-face for "
              "the mark. Every mark on the site is a box on any machine without an "
              "Egyptian hieroglyph font.", file=sys.stderr)
        bad += 1
    elif not rule or face.group(1) not in rule.group(1):
        print("check-mark-font: `.wedjat` no longer names %r. The class is what "
              "every mark-drawing element relies on; if it stops applying the "
              "embedded face, this guard passes while nothing draws."
              % (face.group(1) if face else "the embedded face"), file=sys.stderr)
        bad += 1

    if bad:
        return 1
    print("check-mark-font: %d mark-drawing element(s) across %d file(s), every one "
          "wearing `wedjat`, and the class still applies the embedded %s."
          % (drawn, len(FILES), face.group(1)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
