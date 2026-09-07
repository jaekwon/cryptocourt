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

SCOPE, STATED NARROWLY, AND IT WORKS BACKWARDS. It finds a MARK in web/index.html
or web/chat.js — as a `\\u{...}` escape, a literal glyph, a template hole that IS
the mark, or one concatenated onto a string — and then walks back to the nearest
opening span or text, requiring `wedjat` among its classes.

THAT DIRECTION IS THE POINT, and it was learned the hard way. Scanning FORWARDS
from a tag missed a real site three times, because these files build markup by
concatenation and interpolation: a tag and the glyph it wraps routinely live in
different expressions, with a <title> child or a string boundary in between.

A BARE `const SET_MARK` and a test fixture never reach an opening tag and drop out
on their own. COMMENTS ARE SKIPPED EXPLICITLY, which is not the same thing — they
used to drop out by accident, until a comment explaining this very rule mentioned
a <text> and the escape within a few lines of each other and was read as markup.

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
# THE HEX IS EITHER CASE, AND THAT WAS A REAL BLIND SPOT. This read `7C` only,
# and web/index.html spells one of its two eyes `\u{1307c}` — so a mark sitting in
# a span was invisible to the whole scanner over a letter's case. Found by
# widening the pattern for something else and noticing the count move.
INSIDE = (r"(?i:\\u\{130(?:80|7C)\})", "[\U00013080\U0001307C]",
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
OPEN = re.compile(r"<(span|text)\b", re.S)
# ...and its classes are looked for AFTER it rather than inside it, which is the
# sixth version of the same lesson. The pattern used to be `<(span|text)\b([^>]*)>`
# — the whole tag — and the map's mark stopped being covered the moment a comment
# landed between that tag's name and its `>`:
#
#     + `<text class="mset wedjat" data-fid="${i}" x="..." `
#       /* THE MARK IN ITS OWN TSPAN, ... without touching the <title> beside it */
#       + `text-anchor="middle">`
#
# The comment contains `<title>`, so `[^>]*` could not reach the real `>`, no
# opener was found within the window, and the site was SKIPPED — not failed.
# Coverage fell from 7 sites to 6 and the total still read 7, because a new site
# had just been added elsewhere. A guard that goes quiet is worse than one that
# shouts, and a count that moves for two reasons at once hides it.
CLASSATTR = re.compile(r'class="([^"]*)"')
# HOW FAR BACK THE OPENING TAG MAY BE, and 400 was not far enough. The map's
# mark sits 679 characters after its `<text` — the tag, two attribute fragments,
# a six-line comment and a <title> child all come between — so the walk found
# nothing and the site was skipped in silence. Measured, then rounded up; the
# LAST opener before the glyph is the one taken, so a wider window only matters
# when there is no nearer tag to find.
BACK = 900


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


def classes_after(after):
    """The classes of the tag that opened just before the glyph.

    `after` is everything between the tag's NAME and the glyph. The first
    class attribute in it is that tag's, because a tag's own attributes come
    before any child's — and a nested <tspan> that adds none simply leaves the
    parent's found, which is right: font-family inherits.
    """
    m = CLASSATTR.search(after)
    return set((m.group(1) if m else "").split())


def fonted_classes(web, face):
    """Which classes does the stylesheet actually give the embedded face to?

    THIS WAS THE LITERAL "wedjat" AND THE STYLESHEET HAD MOVED ON. Three rules
    name the face now — `.wedjat`, `.mapsvg .wedjat`, and `.foldsel .eyeshut` —
    so a mark in a `.eyeshut` span renders perfectly and a guard checking for one
    class calls it broken. Rather than keep a second list in step with the CSS,
    ask the CSS: any selector whose declarations name the face lends its classes.

    A DESCENDANT SELECTOR IS TAKEN AT ITS WORD, which is the honest limit here.
    `.foldsel .eyeshut` only applies inside `.foldsel`, and this cannot see an
    ancestor — so `.eyeshut` counts as fonted wherever it appears. Checked by
    hand today: its one draw site is inside a `.foldsel` row, and the live page
    computes wedjat-font on it. A second site outside that row would be a tofu
    box this guard waves through.

    THE STYLESHEET ONLY, WHICH COST A ROUND. Run over the whole file this also
    reads JavaScript block bodies as CSS rules, and any brace-block near the
    string "wedjat-font" lent its dotted words to the accepted set — `.org` and
    `.sil` arrived that way, two property accesses promoted to font-bearing
    classes. A guard that accepts too much is the failure mode that never shows.

    ...AND NOT THE @font-face, WHICH IS WHERE `.org` AND `.sil` CAME FROM. That
    block declares the face, so it matches on the name every time, and the text
    standing where its selector would be is the COMMENT above it — prose about
    the subsetting, with dotted words in it. Two of them became font-bearing
    classes. Comments go first, at-rules are not selectors.
    """
    out = set()
    for block in re.findall(r"<style[^>]*>(.*?)</style>", web, re.S):
        block = re.sub(r"/\*.*?\*/", " ", block, flags=re.S)
        for sel, decls in re.findall(r"([^{}]+)\{([^{}]*)\}", block):
            if face in decls and not sel.lstrip().startswith("@"):
                out.update(re.findall(r"\.([a-zA-Z][\w-]*)", sel))
    return out


def main():
    bad = 0
    drawn = 0
    # THE FACE AND ITS CLASSES ARE READ FIRST, because the per-site check below
    # now asks the stylesheet which classes carry the font rather than naming one.
    web = io.open(os.path.join(REPO, "web/index.html"), encoding="utf-8").read()
    face = re.search(r'@font-face\{font-family:"([^"]+)"', web)
    ok_classes = fonted_classes(web, face.group(1)) if face else set()
    for rel in FILES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            continue
        src = io.open(path, encoding="utf-8").read()
        for m in MARK.finditer(src):
            if in_comment(src, m.start()):
                continue
            # The nearest opening tag before it, within BACK characters.
            opens = list(OPEN.finditer(src[max(0, m.start() - BACK):m.start()]))
            if not opens:
                continue
            back = opens[-1]
            drawn += 1
            # The first class attribute between the tag's name and the glyph. A
            # tag is not always one fragment here — it is assembled from several
            # strings with holes and comments in between — so this reads forward
            # from the name rather than trying to bound the tag.
            cls = classes_after(src[max(0, m.start() - BACK) + back.end():m.start()])
            if cls & ok_classes:
                continue
            line = src.count("\n", 0, m.start()) + 1
            print("check-mark-font: %s:%d draws a set mark in <%s class=%r>, and no "
                  "class on it is one the stylesheet gives the embedded face to "
                  "(%s). The glyph is an Egyptian hieroglyph and most "
                  "machines have no font for it — without that class this renders "
                  "as a tofu box for every reader who is not on a Mac, and looks "
                  "correct to everyone who could have noticed."
                  % (rel, line, back.group(1), " ".join(sorted(cls)) or "",
                     ", ".join("." + c for c in sorted(ok_classes))),
                  file=sys.stderr)
            bad += 1

    # And some class must still carry the font, or the rule above is theatre —
    # `ok_classes` is empty when nothing names the face, and an empty set matches
    # no element, so every site would already have failed above. This says why.
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
          "wearing one of the classes the stylesheet fonts (%s), which still name "
          "the embedded %s."
          % (drawn, len(FILES), ", ".join("." + c for c in sorted(ok_classes)),
             face.group(1)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
