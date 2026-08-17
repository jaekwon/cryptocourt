#!/usr/bin/env python3
"""Check that the govern realm's citations still say what it claims they say.

realm/r/govern argues for its design by pointing at the gno tree: storage
deposit is charged per object, MsgCall.Args is []string, a bptree must not be
modified during iteration. Those citations are the evidence. Without them the
design reads as taste, and a reader who checks one and finds it wrong has no
reason to trust the rest.

They were written as file:line, and they rotted within days of being written.
MsgCall.Args moved from line 102 to 108 because six lines were added above it,
and exposed_tellers.gno was renamed to tellers.gno while CallerTeller stayed
put on line 11. Neither claim became false. Both addresses did.

So the citations are file + ANCHOR now, and the anchor is a regex matched
anywhere in the file. An anchor survives every edit above it, which is what
actually happens to a file, and fails only when the thing itself moves or is
renamed — which is real news and worth a build break. The reader greps for the
same string the checker does.

Three questions:

  1. Does every cited anchor still match in the cited file?
  2. Is every manifest entry actually cited in the prose? (A stale entry that
     checks nothing passes forever.)
  3. Has anyone written a new file:line citation? Those rot silently, which is
     the whole reason this file exists.

Needs a gno checkout. Skips cleanly without one unless REQUIRE_GNO is set, on
the same reasoning as the Makefile's realm-test: a silent skip must never be
mistaken for a real run.

    python3 scripts/check-citations.py
"""

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repolock

# Every tree that belongs to this design: the realm, the package the checkpoint
# machinery moved into, and the example realm that extends it. The last makes no
# citations today and is listed so that the first one somebody adds is watched
# rather than discovered.
# A citation that migrated with the code it explains is still a citation, and
# the point of the second check below is that every row is quoted SOMEWHERE.
# DESIGN.md lives in docs/ rather than beside the realm it describes, because
# ReadMemPackage publishes whatever is in the directory — a design record left
# there is deployed on chain, and this one is a quarter of the govern realm's
# deploy. It still quotes the gno tree, so it still has to be checked.
#
# The court realms and their packages are listed on this file's OWN stated
# principle — "listed so that the first one somebody adds is watched rather
# than discovered". They were not listed before, and the omission is the same
# shape as the one check 4 below names: a guard whose coverage is opt-in. It is
# how check-isolation came to sweep 151 of 388 tests without anybody noticing.
# They make no line-number citations today; that is the point of adding them
# now rather than after the first one rots.
SRC = ["realm/r/govern", "realm/p/checkpoint", "realm/p/grc20votes",
       "realm/p/governor", "realm/r/offerer", "docs/DESIGN.md",
       "realm/r/kourtv1", "realm/r/kourtv2", "realm/p/twap",
       "realm/p/cshares", "realm/p/tickbook", "realm/p/curve"]

# (path under GNOROOT, anchor regex, the literal the prose quotes, the claim)
#
# The third field is not the second with the escapes taken out. The anchor is
# matched against the gno tree, the quote against this realm's own prose, and
# they differ wherever the prose names a thing more briefly than its
# declaration does. Keeping them apart is what lets the check run in both
# directions: an anchor that stops matching means the fact moved, and a quote
# that appears nowhere means the row is checking a citation nobody makes.
CITATIONS = [
    ("examples/gno.land/r/demo/defi/grc20reg/grc20reg.gno",
     r"func Register\(cur realm, token \*grc20\.Token",
     "grc20reg.Register",
     "registering a token hands over the concrete *Token, which is the transfer path"),
    ("gnovm/tests/stdlibs/testing/context_testing.gno",
     r"func SetHeight\(height int64\)",
     "testing.SetHeight",
     "the height setter that does NOT reset the caller context, unlike SkipHeights"),
    ("gnovm/tests/files/zrealm_cur_persist_closure.gno",
     r"cannot persist realm value: realm values are ephemeral",
     "zrealm_cur_persist_closure.gno",
     "the filetest showing a closure that captures cur is refused at finalize"),
    ("gno.land/pkg/sdk/vm/params.go",
     r'storagePriceDefault\s+= "100ugnot"',
     "100ugnot",
     "the storage price is 100ugnot a byte by default"),
    ("gno.land/pkg/sdk/vm/params.go",
     r'StoragePrice\s+string\s+`json:"storage_price"',
     "storage_price",
     "and it is a chain PARAMETER, which is why bytes are recorded and not fees"),
    ("gno.land/pkg/sdk/vm/keeper.go",
     r"func \(vm \*VMKeeper\) refundStorageDeposit",
     "refundStorageDeposit",
     "freed storage is refunded, which is why Settle is worth calling"),
    ("gno.land/pkg/sdk/vm/keeper.go",
     r"receiver := caller",
     "receiver := caller",
     "the refund goes to whoever sent the transaction, not to whoever paid"),
    ("tm2/pkg/bft/consensus/config/config.go",
     r"TimeoutCommit:\s+5000 \* time\.Millisecond",
     "TimeoutCommit", "a default gno chain waits five seconds after a commit"),
    ("tm2/pkg/bft/consensus/config/config.go",
     r"CreateEmptyBlocks:\s+true",
     "CreateEmptyBlocks", "blocks are produced with no traffic, so the cadence does not depend on load"),
    ("examples/gno.land/p/nt/commondao/v0/doc.gno",
     r"set of addresses with equal voting power",
     "a set of addresses with equal voting power",
     "commondao's electorate is a council, not a token balance with history"),
    ("examples/gno.land/p/nt/commondao/v0/commondao.gno",
     r"func \(dao \*CommonDAO\) Propose\(creator address, kind string, args any\)",
     "Propose(creator address, kind string, args any)",
     "commondao takes proposal arguments as an interface, which MsgCall cannot carry"),
    ("examples/gno.land/p/nt/commondao/v0/doc.gno",
     r"managing a DAO's kind set through governance is the consuming realm's",
     "managing a DAO's kind set through governance is the consuming realm's job",
     "commondao ships no governance meta-kinds, so adopt/retire/rules stay ours"),
    ("gnovm/pkg/gnolang/store.go",
     r"LastObjectSize", "LastObjectSize",
     "deposit is charged on the delta of an object's encoded size"),
    ("gnovm/pkg/gnolang/realm.go",
     r"cannot persist function or method from the private realm",
     "cannot persist function or method from the private realm",
     "the save walk refuses a func from an ephemeral package"),
    ("gnovm/pkg/gnolang/realm.go",
     r"func \(rlm \*Realm\) MarkDirty", "MarkDirty",
     "a write marks the whole object dirty, not the field"),
    ("gnovm/pkg/gnolang/op_assign.go",
     r"m\.Realm\.DidUpdate", "m.Realm.DidUpdate",
     "assignment is what triggers the dirty mark"),
    ("gnovm/pkg/gnolang/preprocess.go",
     r"crossing function literal \(realm first argument\) declared in non-realm package",
     "crossing function literal",
     "a p/ package cannot declare a crossing function"),
    ("gnovm/pkg/gnolang/uverse.go",
     r"errPersistRealm", "errPersistRealm",
     "a realm value is ephemeral and cannot be persisted"),
    ("gnovm/tests/stdlibs/testing/context_testing.gno",
     r"func SkipHeights", "SkipHeights",
     "SkipHeights resets the caller context"),
    ("gnovm/tests/stdlibs/testing/context_testing.gno",
     r"count\*5", "count*5",
     "the only block cadence anything in the gno tree states: five seconds"),
    ("gno.land/pkg/sdk/vm/msgs.go",
     r"Args\s+\[\]string", "MsgCall.Args",
     "a transaction's arguments are strings"),
    ("gno.land/pkg/sdk/vm/convert.go",
     r"func convertArgToGno", "convertArgToGno",
     "the string-to-gno conversion every transaction argument goes through"),
    ("gno.land/pkg/sdk/vm/convert.go",
     r"unexpected type in contract arg",
     "unexpected type in contract arg",
     "a struct, interface, pointer or func panics, so such an entrypoint is uncallable"),
    ("gno.land/pkg/sdk/vm/convert.go",
     r"gno\.BaseOf\(argT\)",
     "BaseOf",
     "it converts on the BASE type, which is why a named scalar like address works"),
    ("examples/gno.land/p/nt/bptree/v0/tree.gno",
     r"must not be modified during iteration",
     "must not be modified during iteration",
     "why sweep collects then acts"),
    ("examples/gno.land/p/nt/bptree/v0/tree.gno",
     r"ReverseIterate calls cb", "ReverseIterate calls cb",
     "[start, end] descending with end inclusive: the floor query"),
    ("examples/gno.land/p/nt/commondao/v0/commondao.gno",
     r"func \(dao \*CommonDAO\) Execute", "func (dao *CommonDAO) Execute",
     "gno's own DAO runs a stored func after the vote"),
    ("examples/gno.land/p/nt/commondao/v0/proposal.gno",
     r"ProposalKind interface", "ProposalKind",
     "a named factory registered per DAO: the analog of a function selector"),
    ("examples/gno.land/p/nt/commondao/v0/proposal.gno",
     r"Executor\(\) ExecFunc", "Executor() ExecFunc",
     "a proposal definition can carry a function"),
    ("examples/gno.land/p/demo/tokens/grc20/types.gno",
     r"IsCanonicalTeller", "IsCanonicalTeller",
     "every consumer must reject a non-canonical Teller"),
    ("examples/gno.land/p/demo/tokens/grc20/types.gno",
     r'TransferEvent\s+= "Transfer"', "TransferEvent",
     "the event names this realm emits verbatim"),
    ("examples/gno.land/p/demo/tokens/grc20/token.gno",
     r"led\.balances\.Remove", "led.balances.Remove",
     "the stock ledger drops a holder at zero; this one keeps the record"),
    ("examples/gno.land/p/demo/tokens/grc20/token.gno",
     r"chain\.Emit", "chain.Emit",
     "and emits there, which is why the event names had to match"),
    ("examples/gno.land/p/demo/tokens/grc20/tellers.gno",
     r"func \(tok \*Token\) CallerTeller", "CallerTeller",
     "the stock token hands out a caller-bound teller"),
]


def gnoroot():
    try:
        out = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                             text=True, timeout=30)
    except (FileNotFoundError, subprocess.SubprocessError):
        return None
    root = out.stdout.strip()
    return root if root and os.path.isdir(root) else None


def sources():
    out = []
    for root in SRC:
        if os.path.isfile(root):
            out.append(root)
            continue
        for d, _, fs in os.walk(root):
            out += [os.path.join(d, f) for f in fs
                    if f.endswith((".gno", ".md"))]
    return out


def main():
    repolock.refuse_if_held("check-citations")
    files = sources()
    if not files:
        print(f"check-citations: no sources under {SRC}", file=sys.stderr)
        return 1
    # Comment markers and wrapping are stripped before the quote is looked
    # for, because a quote that happens to straddle a line break is still a
    # citation. Without this the check fires on where gofmt put the newline,
    # which is not a fact about anything.
    raw = "\n".join(open(f).read() for f in files)
    prose = " ".join(re.sub(r"^\s*(//|#)", " ", raw, flags=re.M).split())

    root = gnoroot()
    if root is None:
        if os.environ.get("REQUIRE_GNO"):
            print("check-citations: gno not installed", file=sys.stderr)
            return 1
        print("check-citations: gno not installed - skipping")
        return 0

    bad = 0

    # 1. Does the cited anchor still match?
    # 2. Is the citation actually made? Both asked per entry so a failure
    #    names one row rather than a count.
    for path, anchor, quote, claim in CITATIONS:
        full = os.path.join(root, path)
        if not os.path.isfile(full):
            print(f"GONE   {path}\n       cited for: {claim}")
            bad += 1
            continue
        body = open(full, encoding="utf-8", errors="replace").read()
        if not re.search(anchor, body):
            print(f"MOVED  {path}  /{anchor}/\n       cited for: {claim}")
            bad += 1
            continue
        if quote not in prose:
            print(f"UNUSED {path}  {quote!r}\n"
                  f"       nothing in {'/'.join(SRC)} quotes it. Drop the row or make the claim.")
            bad += 1

    # 3. A new file:line citation. It reads as precise and rots on the next
    #    edit above it, which is exactly how the two this file was written for
    #    went wrong.
    for f in files:
        for i, line in enumerate(open(f), 1):
            for m in re.finditer(r"[\w./-]+\.gn?o:\d+(?:-\d+)?", line):
                # No exemption for files in this repo, tempting as one is: a
                # realm's own files move with it, so a citation between two
                # files in scope looks safe. It is not — a line number rots
                # whether or not you are able to fix it afterwards — and the
                # exemption would blind this to exactly that case.
                print(f"{f}:{i}: line-number citation {m.group()!r}\n"
                      f"       Cite the file and an anchor instead. Line numbers rot.")
                bad += 1

    # 4. A gno-tree file NAMED in the prose with no row of its own.
    #
    #    Checks 1 and 2 run between the manifest and the tree: every row must
    #    still match, and every row must still be quoted. Neither can see a
    #    claim that was never given a row — so a comment could name a file in
    #    the gno tree, rest an argument on it, and be exempt from the guard by
    #    the act of not having been registered. That is the same shape as
    #    check-citations exempting its own scope, and as a budget for a filetest
    #    nobody wrote: a guard whose coverage is opt-in.
    #
    #    Local basenames are skipped because the realm's own files travel with
    #    it; a rename breaks the build long before it misleads anybody.
    #
    #    Scope: FILENAMES. A package-qualified symbol like `grc20reg.Register`
    #    is not a filename and is not caught here. There were four of those in
    #    the prose when this was written and all four are cited, audited by
    #    hand — automating it means guessing which package names are external,
    #    and a guard that cries wolf gets switched off faster than one with a
    #    known edge. Re-run the audit if that list grows:
    #      grep -rho '`[a-z][a-z0-9_]*\.[A-Z][A-Za-z0-9_]*`' realm/ | sort -u
    local = {os.path.basename(f) for f in files}
    cited_names = {os.path.basename(path) for path, _, _, _ in CITATIONS}
    seen = set()
    for f in files:
        for m in re.findall(r"`([\w.-]+\.gn?o)`", open(f).read()):
            if m in local or m in cited_names or m in seen:
                continue
            seen.add(m)
            print(f"UNCITED {m} is named in {f} and has no row.\n"
                  f"        Add one, or the claim it carries is unguarded.")
            bad += 1

    if bad:
        print(f"\n{bad} citation(s) need attention.", file=sys.stderr)
        return 1
    print(f"check-citations: {len(CITATIONS)} citations still hold.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
