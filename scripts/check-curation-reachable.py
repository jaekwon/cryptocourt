#!/usr/bin/env python3
"""A curation entrypoint the product cannot invoke is not shipped.

WHY THIS EXISTS, and it is a count rather than a worry. A sweep of every crossing
entrypoint in r/kourtv2 against the two shipped web files found 78 entrypoints
and 33 the overlay names. Most of the gap is legitimate — the test clock, the
global DAO, token transfers and maintenance pokes are not a curator's business
and belong to other surfaces, if any. But the curation surface was not:

    CreateFolderIn  MoveFolder  RetireFolder  RestoreFolder  MoveItemInFolder
    OrderFolders  AddAssociation  RemoveAssociation  SetCourtDesc

Nine entrypoints, every one of them built in this programme, none reachable from
the page whose own prose said "on-chain folders nest, reorder, retire and carry a
readable description; associations between claims are on chain too". The realm
could do it, the page said so, and the curator had no button.

The worst of them was OpenClaimP. A claim body was asked for by name, shipped to
chain, rendered by the claim page — and could not be WRITTEN, because the two
"Open a claim" buttons still called OpenClaim and no other path offered the
field. The feature was readable and unreachable at the same time.

SCOPE, deliberately narrow. Only folders.gno and association.gno: the curation
surface, where "a moderator does this from the site" is the whole point, and
where an unreachable entrypoint is a bug rather than a design choice. Widening
this to all 78 would need a policy for each, and a guard whose exemption list is
longer than its findings teaches people to add exemptions.

    python3 scripts/check-curation-reachable.py
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The curator-and-author surface: filing, staking, answering, and the filing
# system. Widened from folders+argument once those were clean, because the same
# gap turned up in claim.gno (OpenClaimP, EditClaimTitle) and court.gno
# (StartCourtP) — a "P" variant that says one more thing, reachable by nobody.
#
# moderation.gno is deliberately OUT. Thirteen of its sixteen entrypoints are
# global-DAO and purge acts — GlobalHide, TransferGlobalAdmin, PurgeCourt — which
# belong to an admin surface this overlay does not have. Listing them here would
# mean thirteen exemptions against three findings, and a guard whose exemption
# list dwarfs its findings teaches people to write exemptions.
SOURCES = [os.path.join(ROOT, "realm", "r", "kourtv2", f) for f in
           ("folders.gno", "association.gno", "supersede.gno", "claim.gno",
            "court.gno", "stake.gno", "answer.gno")]
PAGES = [os.path.join(ROOT, "web", "index.html"),
         os.path.join(ROOT, "web", "chat.js")]

# Offered nowhere on purpose. Each needs a reason, or this becomes the place
# unreachable features go to be forgotten.
EXEMPT = {
    "PurgeFolder": "destructive and m-of-n: it erases a folder's name and "
                   "description behind a category code, and the page's on-chain "
                   "section is framed as the bond-free single-signer acts. It "
                   "belongs with the other purge paths, wherever those land.",
    "OpenClaim": "superseded in the UI by OpenClaimP, which is the same "
                 "entrypoint with a body — and a body is optional, so the P form "
                 "covers every call the plain one made. It stays in the realm "
                 "because every filetest, txtar and scenario in the tree uses it.",
    "OpenClaimPM": "the chain half of claim media landed before the product half, "
                 "which is the gap this guard exists to name — and the gap is "
                 "real, not an oversight. Media cannot be offered by the three "
                 "affordances the page has: a $help link, a CLI command and a "
                 "one-click sign all take arguments that already exist, and none "
                 "of them can accept a dropped file. It needs the composer in "
                 "docs/CLAIM_MEDIA.md §2, which is the next step. THIS ENTRY "
                 "COMES OUT WHEN THE COMPOSER LANDS — it is the 'entry, then a "
                 "button, then no entry' shape this list is supposed to have, "
                 "and an exemption still here once a person can attach an image "
                 "is a bug in the list, not a policy.",
    "SetAssociationBondDefault": "a REALM-ADMIN act, not a curator's: it sets the "
                 "default every court inherits, and belongs with the global DAO "
                 "verbs this guard's header already calls a legitimate gap. It is "
                 "the ONE association verb still exempt — the other six shipped "
                 "exempt with the note \"no UI yet\" and the curate page's "
                 "Relations panel now has a control for each, so their exemptions "
                 "came back out. That is the shape this list is supposed to have: "
                 "an entry, then a button, then no entry.",
}

ENTRY = re.compile(r"^func ([A-Z]\w*)\(cur realm", re.M)

found = set()
for f in SOURCES:
    if not os.path.exists(f):
        sys.exit("check-curation-reachable: %s is missing" % f)
    found |= set(ENTRY.findall(io.open(f, encoding="utf-8").read()))

page = ""
for f in PAGES:
    if not os.path.exists(f):
        sys.exit("check-curation-reachable: %s is missing" % f)
    page += io.open(f, encoding="utf-8").read()

missing = []
for name in sorted(found):
    if name in EXEMPT:
        continue
    # Named as a quoted string, which is how btn() and every tx builder take it.
    # Looser than checking for a btn() call on purpose: a future page may reach
    # an entrypoint some other way, and this guard is about REACHABILITY, not
    # about which widget does it.
    if not re.search(r"""['"]%s['"]""" % re.escape(name), page):
        missing.append(name)

if missing:
    print("check-curation-reachable: the realm can do this and the product "
          "cannot ask for it", file=sys.stderr)
    for name in missing:
        print("  %-22s named by neither shipped web file" % name, file=sys.stderr)
    print("  Add it to the curate page, or exempt it in this guard with a "
          "reason.", file=sys.stderr)

# ---------------------------------------------------------------------------
# AND THE ARGUMENTS, because naming an entrypoint is not the same as calling it
# correctly. btn() renders a transaction form from an object literal whose KEYS
# become the parameter names in the link:
#
#     btn("Order folders", "OrderFolders", {courtSlug: ..., parentID: ..., ids: ...})
#     func OrderFolders(cur realm, courtSlug string, parentID uint64, ids string)
#
# Rename a realm parameter and every button still passing the old name goes on
# rendering a form that looks right and prefills the wrong field — or none. That
# is a break across the realm/web boundary that NEITHER side tests: the realm's
# suite does not know buttons exist, and the web harnesses do not know what a
# signature says. It is the same seam the reachability half above is about, one
# step further in.
#
# Order is compared too, not just the set. gnoweb matches by name so a reordering
# is harmless today, but a button whose arguments are in a different order from
# the function it calls is a reader's trap, and the cost of holding the line is
# nothing while it already holds.
ALLSRC = "".join(io.open(f, encoding="utf-8").read()
                 for f in sorted(glob.glob(os.path.join(ROOT, "realm", "r", "kourtv2", "*.gno")))
                 if not f.endswith("_test.gno"))
BTN = re.compile(r'btn\(\s*"(?:[^"\\]|\\.)*"\s*,\s*"(\w+)"\s*,\s*\{([^}]*)\}')


def realm_params(fn):
    """Parameter names of a crossing function, after `cur realm`, or None."""
    m = re.search(r"^func %s\(cur realm(?:,\s*)?([^)]*)\)" % re.escape(fn), ALLSRC, re.M)
    if not m:
        return None
    raw = m.group(1).strip()
    if not raw:
        return []
    # `slug, name string` declares two parameters sharing one type: the names
    # before the typed one belong to it, so they cannot be read left to right.
    out, pending = [], []
    for part in raw.split(","):
        toks = part.strip().split()
        if len(toks) == 1:
            pending.append(toks[0])
        else:
            out += pending + [toks[0]]
            pending = []
    return out + pending


mismatch, buttons = [], 0
for fn, argsrc in BTN.findall(page):
    buttons += 1
    keys = re.findall(r"(\w+)\s*:", argsrc)
    p = realm_params(fn)
    if p is None:
        mismatch.append((fn, keys, "no such crossing function in r/kourtv2"))
    elif keys != p:
        mismatch.append((fn, keys, p))

if mismatch:
    print("check-curation-reachable: a button's arguments do not match the "
          "function it calls", file=sys.stderr)
    for fn, keys, want in mismatch:
        print("  %-22s button %s  vs  realm %s" % (fn, keys, want), file=sys.stderr)
    print("  The form is built from these names. A stale one prefills the wrong "
          "field, or none.", file=sys.stderr)

if missing or mismatch:
    sys.exit(1)

if len(found) < 20 or buttons < 20:
    sys.exit("check-curation-reachable: %d entrypoint(s) and %d button(s) — the "
             "scan matched too little to be real, which is a broken guard rather "
             "than a clean tree" % (len(found), buttons))

print("check-curation-reachable: %d curation entrypoint(s) all reachable from the "
      "product (%d exempt with a reason), and %d button(s) whose arguments match "
      "the functions they call." % (len(found), len(EXEMPT), buttons))
