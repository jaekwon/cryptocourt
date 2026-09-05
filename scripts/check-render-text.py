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
    # PARSE, and the parse OUTLIVES the call, which is why this one took looking
    # at rather than pattern-matching against the two above. AffirmSet reads
    # `cs.title` through parseSetTitle to get a set's name, and that name is then
    # STORED as the folder's name — so unlike meta.gno's parses, which end on
    # meta.parses and are never shown, this text does reach a page.
    # It reaches it through the folder-name pipeline, which has its own display
    # gate: every site that writes a folder name to an output buffer sanitises —
    # render.gno:782, 825, 835 and 857, each `sanitize.InlineText(f.name)`. That
    # gate is not AffirmSet's to keep, because CreateFolder has fed the same
    # pipeline with moderator-typed names since before governed sets existed; a
    # hole there would be a hole for both.
    # The name also rides the SetAffirmed event. An event is not a render buffer
    # and no gnoweb page is built from one, but an indexer that prints it owes
    # its readers the same escaping any other chain string does.
    ("governedset.gno", "AffirmSet"): "parse — parseSetTitle reads the title as a set name; "
                                      "the name it yields is displayed only through the "
                                      "folder-name pipeline, which sanitises at every render site",
    # The narrowest reader in the census: it parses and throws the parse away.
    # `_, ok := parseSetTitle(cs.title)` — the name is discarded on the spot and
    # a bool comes back, so no character of the title survives the call.
    ("governedset.gno", "IsSetClaim"): "parse — discards it; returns only whether the title parses",
}

# The court's own two user-text fields. Same policy, separate gates:
# courtNameFor and courtDescFor. `c.name` matters twice over — modrender.gno's note
# says a whole-court purge is a legal-hold act and "rendering the raw name anywhere
# would leave the offending text on the directory and on every page of that court".
#
# NOTE ON THE RAW PUBLIC READ, recorded here because this is where somebody will
# look. The length-only validation below is NOT a new observation — render_test.gno's
# TestNoUserStringOpensStructureOnAnyPage says it in its own header ("NEITHER is
# validated at the door: StartCourt stores `name` unchecked and OpenClaim stores
# `title` the same way") and pins the consequence on every page. What is new here is
# only the CONSUMER, at the end of this note. CourtName returns `mustCourt(slug).name` unsanitised and that is sanctioned
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

# A FOURTH FAMILY, and the one this check was blind to. A board comment is
# attacker-controlled multi-line text, arriving in far greater volume than titles
# or bodies and on the same money-bearing pages — and `r.text` matched none of the
# three regexes above, so the whole surface could have reached markdown unescaped
# with this check reporting green.
#
# boardTextVisible is the display gate and applies sanitize.Block (the STRICT
# variant, which escapes the doc-spoof markers BlockRich preserves). boardTextFor
# is the WIRE gate: it returns raw text to a client that sanitises for its own
# context, exactly as claimBodyVisible does, so it is listed as a raw reader
# rather than required to escape.
BOARD_TEXT_READERS = {
    ("board.gno", "boardTextVisible"): "sanitize.Block",
    ("board.gno", "boardTextFor"): None,   # the wire read: raw by contract

    # PurgeBoardRow does not read the text, it DESTROYS it (`r.text = ""`). It is
    # listed rather than excluded by a smarter regex because an assignment-only
    # exemption would also excuse a real read on the right-hand side, and because
    # a census that names the one verb allowed to touch these bytes outside the
    # two gates is worth more than one that cannot see it at all.
    ("boardlegal.gno", "PurgeBoardRow"): None,

    # PurgeBoardRange is the batched form of the same destruction — same
    # `r.text = ""`, up to maxBatchRows at a time. Listed for the reason its
    # single-row twin is: an assignment-only exemption in the regex would also
    # excuse a real read on the right-hand side.
    ("boardlegal.gno", "PurgeBoardRange"): None,
}

# ---------------------------------------------------------------- foreign --
#
# THE SCOPE ABOVE IS kourtv2 ONLY, AND THAT IS WHERE THE HOLE WAS. CourtName is
# sanctioned to return raw text on the rule that "consumers sanitise at their own
# output" — and nothing checked that any consumer did. The note above even named
# the consumer, r/ccwrap, and left it: the reasoning was that tightening
# mustCourtName would refuse names live courts may already hold. That is still
# right, and it is not a reason for the OUTPUT to stay unsanitised.
#
# What was actually there: mustCourtName validates length only, 1..100 characters,
# where mustCourtDesc beside it walks the string and refuses newlines. ccwrap's
# Enable built the wrapped token's name as `"Wrapped " + kourtv2.CourtName(slug)`
# and its Render wrote that name into an H1 with `ufmt.Sprintf("# %s\n\n"...)`.
# So any address that could call StartCourt could put headings, list rows and raw
# HTML on ccwrap's page, and gnoweb runs no sanitiser after a realm.
#
# Four realms have a Render: govern delegates to the engine, kourtv1 is frozen and
# reads none of kourtv2's text, kourtv2 is censused above. ccwrap was the whole of
# the uncovered surface — and the reason to spend a census on ONE site is that rows
# cannot say "a second consumer appeared". A row asserts a test notices when this
# call site changes; only the set can notice a new one.
RAW_TEXT_READ = re.compile(r"\bkourtv2\.(?:CourtName|CourtDesc|ClaimTitle)\(")

# Functions outside kourtv2 that read its raw user text, and why each is allowed.
FOREIGN_TEXT_READERS = {
    ("ccwrap", "ccwrap.gno", "Enable"):
        "stores the raw name as the token's own name — DATA, not output. Escaping "
        "here would put backslashes into the string every wallet, explorer and pool "
        "displays; sanitise/v0's rule is sanitise once, at the point of output.",
}

# A token's name is user text by the time it is read back, so writing it to a page
# is an output context like any other. One site today, and it must name its helper.
NAME_DISPLAY = re.compile(r"\.GetName\(\)")
FOREIGN_NAME_DISPLAY = {
    ("ccwrap", "ccwrap.gno", "Render"): "sanitize.InlineText",
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
    seen_board = set()
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
            if re.search(r"\br\.text\b", body):
                seen_board.add(key)
                if key not in BOARD_TEXT_READERS:
                    bad.append("%s/%s reads a board comment's raw text and is not in "
                               "BOARD_TEXT_READERS. If it DISPLAYS the comment it must "
                               "go through boardTextVisible; if it hands it to a client "
                               "that sanitises for its own context, add it here with "
                               "that reason." % key)
                else:
                    want = BOARD_TEXT_READERS[key]
                    if want is not None and want not in body:
                        bad.append("%s/%s is the board display gate but does not apply "
                                   "%s — raw comment text reaches the page"
                                   % (key + (want,)))
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
    for key in sorted(set(BOARD_TEXT_READERS) - seen_board):
        bad.append("%s/%s is in BOARD_TEXT_READERS but no longer reads a comment's raw "
                   "text — the gate moved or the entry is stale" % key)
    for key in sorted(set(BODY_CALLERS) - seen_body):
        bad.append("%s/%s is in BODY_CALLERS but no longer calls claimBodyVisible — "
                   "the gate moved or the entry is stale" % key)

    # And the same census over every OTHER realm, which is where ccwrap was.
    seen_fread, seen_fshow = set(), set()
    for rdir in sorted(p for p in (ROOT / "realm" / "r").iterdir()
                       if p.is_dir() and p.name != "kourtv2"):
        for path in sorted(rdir.glob("*.gno")):
            if path.name.endswith(("_test.gno", "_filetest.gno")):
                continue
            for fn, body in functions(path):
                key = (rdir.name, path.name, fn)
                if RAW_TEXT_READ.search(body):
                    seen_fread.add(key)
                    if key not in FOREIGN_TEXT_READERS:
                        bad.append("%s/%s/%s reads kourtv2's RAW user text from "
                                   "another realm and is not in FOREIGN_TEXT_READERS. "
                                   "If it displays that text it must sanitise at its "
                                   "own output; if it stores it, add it here with that "
                                   "reason." % key)
                if NAME_DISPLAY.search(body):
                    seen_fshow.add(key)
                    want = FOREIGN_NAME_DISPLAY.get(key)
                    if want is None:
                        bad.append("%s/%s/%s writes a token's name to its output and "
                                   "is not in FOREIGN_NAME_DISPLAY. A wrapped token's "
                                   "name carries the court name it was derived from, "
                                   "so it is user text." % key)
                    elif want not in body:
                        bad.append("%s/%s/%s writes a token's name to its output "
                                   "without applying %s — raw court text reaches the "
                                   "page" % (key + (want,)))
    for key in sorted(set(FOREIGN_TEXT_READERS) - seen_fread):
        bad.append("%s/%s/%s is in FOREIGN_TEXT_READERS but no longer reads kourtv2's "
                   "raw text — the reader moved or the entry is stale" % key)
    for key in sorted(set(FOREIGN_NAME_DISPLAY) - seen_fshow):
        bad.append("%s/%s/%s is in FOREIGN_NAME_DISPLAY but no longer writes a token "
                   "name — the gate moved or the entry is stale" % key)

    if not seen_title or not seen_body or not seen_board:
        print("check-render-text: found no title readers, no body callers, or no board "
              "text readers at all, so this check is measuring nothing. The gates were "
              "renamed.", file=sys.stderr)
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

    print("check-render-text: %d title reader(s), %d court-text reader(s), %d body "
          "caller(s) and %d board-text reader(s) in kourtv2, plus %d foreign reader(s) "
          "of its raw text and %d foreign token-name display(s) — each routed through "
          "its own gate."
          % (len(seen_title), len(seen_court), len(seen_body), len(seen_board),
             len(seen_fread), len(seen_fshow)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
