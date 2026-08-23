#!/usr/bin/env python3
"""User text reaches the page through a named gate, and only through it.

AGENTS.md states the rule in prose: "Render(path string) receives
attacker-controlled input. Never write path segments, user-supplied keys, or
free-form string values directly into markdown output." modrender.gno states it
twice more, about its own two gates:

  claimTitleFor  "is THE single place a claim's title becomes display text"
  claimBodyVisible  "EVERY CALLER MUST SANITISE FOR ITS OWN OUTPUT CONTEXT, and
                     they do not agree on which helper"

Three statements of one policy, and nothing enforced any of them. This does.

WHY IT IS WORTH A GUARD rather than a comment, given both policies hold today
(measured: `.title`'s only display read is the sanitised one in claimTitleFor,
and both callers of claimBodyVisible sanitise — with DIFFERENT helpers, Block and
Blockquote, exactly as its comment predicts). The consequence of a violation is
not a wrong number, it is HTML on a page people stake money on. modrender.gno's
own note spells it out: sanitize.Block escapes CommonMark §4.6 block types 1-5
but NOT types 6 and 7, so a `<form>` or a `<table>` in a claim body is only
CONTAINED by a trailing blank line, and gnoweb runs no HTML sanitiser after the
realm. A new render surface that forgot to sanitise would be invisible to every
existing check: the corpus spot-checks one unsanitised symbol and nothing else.

A CENSUS, not a pattern, and for the same reason check-spend-paths is one: the
sanctioned readers are few and named, so the check that catches a NEW one is
"the set changed", which no regex over call sites can say. Adding a reader means
adding it here with a reason — which is the point.

FAILS CLOSED on a reader it does not recognise and on a census entry that has
gone missing, because the two failures need opposite fixes: an unknown reader is
a possible injection, a vanished entry is a gate that was deleted or renamed.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"

# Every sanctioned reader of a claim's raw title, and what it does with it.
# DISPLAY readers must sanitise; PARSE readers must not reach an output buffer.
TITLE_READERS = {
    ("modrender.gno", "claimTitleFor"): "display, via sanitize.InlineText",
    # Both verified as PARSE readers before being listed: each does
    # `p := parseModTitle(cs.title)` and stores the parse on meta.parses. Neither
    # touches an output buffer, so neither needs the display gate.
    ("meta.gno", "onClaimOpened"): "parse — parseModTitle reads the title as a command",
    ("meta.gno", "onTitleEdited"): "parse — re-parses a meta title edited in the window",
    ("claim.gno", "EditClaimTitle"): "write, not a read",
}

# The court's own two user-text fields. Same policy, separate gates:
# courtNameFor and courtDescFor. `c.name` matters twice over — modrender.gno's note
# says a whole-court purge is a legal-hold act and "rendering the raw name anywhere
# would leave the offending text on the directory and on every page of that court".
#
# NOTE ON THE RAW PUBLIC READ, recorded here because this is where somebody will
# look. CourtName returns `mustCourt(slug).name` unsanitised and that is sanctioned
# — sanitize/v0's rule is "sanitise once, at the point of output", and its own doc
# says "a court's parameters are not secret". But mustCourtName validates LENGTH
# ONLY: no alphabet, and no newline check, where mustCourtDesc refuses newlines with
# a stated reason that applies to the name just as well ("it renders inline beside a
# court name in list rows, where a newline forges a row"). kourtv2's own render is
# safe because InlineText folds. The consumer that is NOT is realm/r/ccwrap, which
# builds a GRC20 token name as "Wrapped " + CourtName(slug) — raw user text crossing
# into another realm's display field. Left alone deliberately: tightening
# mustCourtName now would refuse names live courts may already hold, which is a
# migration question, and by the sanitise-at-output rule the fix belongs at ccwrap's
# output rather than at this realm's input.
COURT_TEXT_READERS = {
    ("modrender.gno", "courtNameFor"): "display gate, via sanitize.InlineText",
    ("modrender.gno", "courtDescFor"): "display gate, via sanitize.InlineText",
    ("court.gno", "CourtName"): "raw public read — consumers sanitise at their own output",
    ("court.gno", "SetCourtDesc"): "write, not a read",
}

# Every caller of claimBodyVisible, which returns RAW body text, and the helper
# each one is required to apply. They deliberately differ.
BODY_CALLERS = {
    ("modrender.gno", "claimBodyFor"): "sanitize.Block",
    ("modrender.gno", "claimBodyQuoted"): "sanitize.Blockquote",
}

FUNC = re.compile(r"^func (?:\([^)]*\)\s*)?(\w+)")


def functions(path):
    """(name, body) for every top-level func in a .gno file, in order."""
    out, name, buf = [], None, []
    for line in open(path, encoding="utf-8"):
        m = FUNC.match(line)
        if m:
            if name:
                out.append((name, "".join(buf)))
            name, buf = m.group(1), [line]
        elif name:
            buf.append(line)
    if name:
        out.append((name, "".join(buf)))
    return out


def main():
    repolock.refuse_if_held("check-render-text")

    bad, seen_title, seen_body, seen_court = [], set(), set(), set()
    for path in sorted(REALM.glob("*.gno")):
        if path.name.endswith("_test.gno"):
            continue
        for fn, body in functions(path):
            key = (path.name, fn)
            if re.search(r"\bcs\.title\b|\bclm\.title\b", body):
                seen_title.add(key)
                if key not in TITLE_READERS:
                    bad.append("%s/%s reads a claim's raw title and is not in "
                               "TITLE_READERS. If it DISPLAYS the title it must go "
                               "through claimTitleFor; if it parses it, add it here "
                               "with that reason." % key)
            if re.search(r"\bc\.(?:name|desc)\b|mustCourt\([^)]*\)\.(?:name|desc)\b", body):
                seen_court.add(key)
                if key not in COURT_TEXT_READERS:
                    bad.append("%s/%s reads the court's raw name or description and is "
                               "not in COURT_TEXT_READERS. If it DISPLAYS the field it "
                               "must go through courtNameFor or courtDescFor." % key)
            if "claimBodyVisible(" in body and fn != "claimBodyVisible":
                seen_body.add(key)
                want = BODY_CALLERS.get(key)
                if want is None:
                    bad.append("%s/%s calls claimBodyVisible, which returns RAW body "
                               "text, and is not in BODY_CALLERS. Add it with the "
                               "sanitize helper its output context needs." % key)
                elif want not in body:
                    bad.append("%s/%s calls claimBodyVisible but does not apply %s — "
                               "raw body text reaches its output" % (key + (want,)))

    for key in sorted(set(TITLE_READERS) - seen_title):
        bad.append("%s/%s is in TITLE_READERS but no longer reads the title — the "
                   "gate moved or the entry is stale" % key)
    for key in sorted(set(COURT_TEXT_READERS) - seen_court):
        bad.append("%s/%s is in COURT_TEXT_READERS but no longer reads c.name or "
                   "c.desc — the gate moved or the entry is stale" % key)
    for key in sorted(set(BODY_CALLERS) - seen_body):
        bad.append("%s/%s is in BODY_CALLERS but no longer calls claimBodyVisible — "
                   "the gate moved or the entry is stale" % key)

    if not seen_title or not seen_body:
        print("check-render-text: found no title readers or no body callers at all, "
              "so this check is measuring nothing. The gates were renamed.",
              file=sys.stderr)
        return 1

    if bad:
        print("check-render-text: user text is reaching the page outside its gate.\n",
              file=sys.stderr)
        for b in bad:
            print("  %s" % b, file=sys.stderr)
        print("\nmodrender.gno's own note is the reason this matters: sanitize.Block "
              "escapes CommonMark block types 1-5 but not 6 and 7, so a <form> or a "
              "<table> is only CONTAINED, and gnoweb runs no HTML sanitiser after the "
              "realm.", file=sys.stderr)
        return 1

    print("check-render-text: %d title reader(s), %d court-text reader(s) and %d body "
          "caller(s), each routed through its own gate."
          % (len(seen_title), len(seen_court), len(seen_body)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
