#!/usr/bin/env python3
"""The claim page's amounts wear the court's mark instead of the letters "CC".

Idempotent, anchored string replacements — same shape and same reason as
scratchpad/apply-rawmd.py. Three Claude sessions share this working tree and
web/index.html gets written wholesale every few minutes; a surgical edit that
takes twenty minutes to make takes one command to put back.

Run from the repo root:  python3 scratchpad/apply-ccmark.py
"""
import sys, pathlib

F = pathlib.Path("web/index.html")
src = F.read_text()
applied, already = [], []


def sub(name, old, new, done_marker):
    global src
    if done_marker in src:
        already.append(name); return
    if src.count(old) != 1:
        print(f"ANCHOR {'MISSING' if old not in src else 'AMBIGUOUS'} for {name!r} "
              f"({src.count(old)} matches) — the file moved under this patch", file=sys.stderr)
        sys.exit(2)
    src = src.replace(old, new, 1); applied.append(name)


# ---- the two unit renderers ------------------------------------------------
sub(
    "ccPlain wears the mark",
    'function ccPlain(n){ return ccFig(n)+" CC"; }',
    '''/* AND THE UNIT IS THE COURT'S MARK, NOT THE LETTERS "CC".
   The paragraph above is the reasoning that put "CC" here, and it holds for
   everything except the last two characters: a claim page has already named its
   court three ways, so the unit does not need to be REPEATED per figure — which
   is why ccFig has no micro mode and why a row says its unit once. What that
   argument never justified was spelling the one surviving unit as an initialism.
   "0.0001 CC" beside tiles wearing the gold bar reads as a different quantity in
   a different currency; it is the same coin, drawn two ways on one page.
   So the unit is said ONCE, as it always was, and said in the product's own
   mark: 0.0001 [Kourt] COVID.
   THE SLUG IS OPTIONAL and the fallback is the old text. A caller with no court
   in hand has nothing to draw a mark from, and "CC" is still the right word for
   an amount of court coin in the abstract.
   THIS EMITS MARKUP, exactly as cc() does — ccSymHtml returns spans. A caller
   that escapes its input or slices the symbol back off wants ccText, and the
   comment on ccText says so. */
function ccPlain(n, slug){ return ccFig(n)+" "+(slug? ccSymHtml(slug) : "CC"); }''',
    "function ccPlain(n, slug)",
)
sub(
    "ccRow wears the mark",
    '''function ccRow(parts){
  return parts.map(([l, n]) => `${l} ${ccFig(n)}`).join(" · ") + " CC";
}''',
    '''function ccRow(parts, slug){
  return parts.map(([l, n]) => `${l} ${ccFig(n)}`).join(" · ") + " " + (slug? ccSymHtml(slug) : "CC");
}''',
    "function ccRow(parts, slug)",
)

# ---- every caller hands over the court it is already showing ---------------
for name, old, new in [
    ("stake bar, YES side",
     '${ccPlain(y)}</span><span class="n">', '${ccPlain(y, slug)}</span><span class="n">'),
    ("stake bar, NO side",
     '${ccPlain(n)}</span>', '${ccPlain(n, slug)}</span>'),
    ("chart chip: next dispute bond",
     '`next dispute bond ${ccPlain(d.disputeBondNext)}`', '`next dispute bond ${ccPlain(d.disputeBondNext, slug)}`'),
    ("rewards drawn",
     '''              + ccPlain(((d.draw&&d.draw.w)||0) + ((d.draw&&d.draw.a)||0)
                        + ((d.draw&&d.draw.ans)||0))''',
     '''              + ccPlain(((d.draw&&d.draw.w)||0) + ((d.draw&&d.draw.a)||0)
                        + ((d.draw&&d.draw.ans)||0), slug)'''),
    ("voter pool left",
     '${ccPlain(d.draw.carrot)}</span></div>', '${ccPlain(d.draw.carrot, slug)}</span></div>'),
    ("reward to open",
     '+ ccPlain(d.quote.w + d.quote.a + d.quote.ans)', '+ ccPlain(d.quote.w + d.quote.a + d.quote.ans, slug)'),
    ("dispute bond, in prose",
     '" The next dispute bond is "+ccPlain(d.disputeBondNext)+"', '" The next dispute bond is "+ccPlain(d.disputeBondNext, slug)+"'),
    ("the reward pools row",
     'ccRow([["accuracy",d.draw.w],["author",d.draw.a],["answerer",d.draw.ans],["voters",d.draw.carrot]])',
     'ccRow([["accuracy",d.draw.w],["author",d.draw.a],["answerer",d.draw.ans],["voters",d.draw.carrot]], slug)'),
]:
    sub(name, old, new, new)

# ---- two functions that never needed the court until now -------------------
# resolutionLadder prints the dispute bond and timelineFold is its only caller,
# which in turn is called from the claim route where slug has always been in
# scope. Threaded rather than reached for globally: the ladder is also rendered
# bare in a second layout, and a global would make that one lie about its court.
for name, old, new in [
    ("resolutionLadder takes a slug",
     "function resolutionLadder(d, nowH, tl, narrow, bare){", "function resolutionLadder(d, nowH, tl, narrow, bare, slug){"),
    ("timelineFold takes a slug",
     "function timelineFold(d, rH, tl, narrow){", "function timelineFold(d, rH, tl, narrow, slug){"),
    ("...and passes it on",
     "const ladder = resolutionLadder(d, rH, tl, narrow);", "const ladder = resolutionLadder(d, rH, tl, narrow, undefined, slug);"),
    ("...and the claim route hands it in",
     "timelineFold(d, (tline&&tline.now&&tline.now.h!=null)?tline.now.h:seriesH, tline, !!sideCol)",
     "timelineFold(d, (tline&&tline.now&&tline.now.h!=null)?tline.now.h:seriesH, tline, !!sideCol, slug)"),
]:
    sub(name, old, new, new)

if applied:
    F.write_text(src)
print("applied: " + (", ".join(applied) or "nothing"))
print("already in place: " + (", ".join(already) or "nothing"))
