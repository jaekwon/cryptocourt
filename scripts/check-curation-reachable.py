#!/usr/bin/env python3
"""A curation entrypoint the product cannot invoke is not shipped.

WHY THIS EXISTS, and it is a count rather than a worry. A sweep of every crossing
entrypoint in r/kourtv2 against the two shipped web files found 78 entrypoints
and 33 the overlay names. Most of the gap is legitimate — the test clock, the
global DAO, token transfers and maintenance pokes are not a curator's business
and belong to other surfaces, if any. But the curation surface was not:

    CreateFolderIn  MoveFolder  RetireFolder  RestoreFolder  MoveItemInFolder
    OrderFolders  AddArgument  RemoveArgument  SetCourtDesc

Nine entrypoints, every one of them built in this programme, none reachable from
the page whose own prose said "on-chain folders nest, reorder, retire and carry a
readable description; argument edges between claims are on chain too". The realm
could do it, the page said so, and the curator had no button.

The worst of them was OpenClaimP. A claim body was asked for by name, shipped to
chain, rendered by the claim page — and could not be WRITTEN, because the two
"Open a claim" buttons still called OpenClaim and no other path offered the
field. The feature was readable and unreachable at the same time.

SCOPE, deliberately narrow. Only folders.gno and argument.gno: the curation
surface, where "a moderator does this from the site" is the whole point, and
where an unreachable entrypoint is a bug rather than a design choice. Widening
this to all 78 would need a policy for each, and a guard whose exemption list is
longer than its findings teaches people to add exemptions.

    python3 scripts/check-curation-reachable.py
"""
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
           ("folders.gno", "argument.gno", "claim.gno", "court.gno",
            "stake.gno", "answer.gno")]
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
    sys.exit(1)

if len(found) < 20:
    sys.exit("check-curation-reachable: only %d entrypoint(s) found in the "
             "curation sources — the scan matched too little to be real, which "
             "is a broken guard rather than a clean tree" % len(found))

print("check-curation-reachable: %d curation entrypoint(s), all reachable from "
      "the product (%d exempt with a reason)." % (len(found), len(EXEMPT)))
