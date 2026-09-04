#!/usr/bin/env python3
"""Walk every read the overlay makes in live mode against a running node.

WHY THIS EXISTS. The demo dataset cannot surface a whole class of defect,
because its courts are mature and its numbers were chosen by hand. A freshly
seeded chain is young, poor and sparse, and that is where the page breaks: the
curve's marginal price is integer-divided, so a court under 1,000 CC served a
price of exactly 0 and the page printed "0 µGNOT/unit" — the coin is free —
while the buy panel beside it quoted a real fractional price. Nothing in the
sample could have shown that.

So this asks the node every question the page asks, and reports anything that
does not come back in the shape the page will try to parse. It is a
CONFORMANCE check against a live node, not a unit test: run it against a node
seeded by scripts/seed-node.sh.

    scripts/check-live-reads.py [--remote http://127.0.0.1:26657] [--court orem]

It is deliberately NOT part of `make check` — that gate must not require a
running chain.
"""
import re
import sys
import urllib.request

import gnorpc

REALM = "gno.land/r/kourt/kourtv2"

# The reads the page issues, with the argument shapes it uses. `{c}` is the
# court slug, `{i}` a claim id, `{a}` an address.
#
# A third element is a GUARD: the read the page checks before issuing this one.
# Several realm reads ABORT rather than return a zero value — AnswerVerdict
# panics "no answer yet", QuorumFloorOf panics "that epoch has not been sealed
# yet" — and the page only calls them behind a predicate (claim.gno's own
# comment at web/index.html:597 says so). A harness that probed them
# unconditionally reported four false positives on its first run; asserting
# what the page does NOT do is how a conformance check turns into noise.
PROBES = [
    # court-level
    ("CourtCount", "()"), ("ListByTier", "(2)"), ("ListedCourtsBy", '("burned",0,5)'),
    ("CourtTier", '("{c}")'), ("CoinPrice", '("{c}")'), ("CoinSupply", '("{c}")'),
    ("CurvePosition", '("{c}")'), ("EmittedTotal", '("{c}")'),
    ("CourtBurnedGNOT", '("{c}")'), ("Reservoir", '("{c}")'), ("SeniorOwed", '("{c}")'),
    ("QueueLen", '("{c}")'), ("FolderCount", '("{c}")'),
    ("ClaimCount", '("{c}")'), ("CoinBalanceOf", '("{c}","{a}")'),
    # claim-level
    ("ClaimTitle", '("{c}",{i})'), ("ClaimStatus", '("{c}",{i})'),
    ("ClaimAuthor", '("{c}",{i})'), ("ClaimTimeline", '("{c}",{i})'),
    ("ClaimSeries", '("{c}",{i},"hourly")'), ("ClaimSeries", '("{c}",{i},"daily")'),
    ("StakePools", '("{c}",{i})'), ("PoolConviction", '("{c}",{i})'),
    ("HasAnswer", '("{c}",{i})'), ("AnswerVerdict", '("{c}",{i})', 'HasAnswer("{c}",{i})'),
    ("Answerer", '("{c}",{i})', 'HasAnswer("{c}",{i})'), ("AnswerBond", '("{c}",{i})', 'HasAnswer("{c}",{i})'),
    ("SettleDeadline", '("{c}",{i})'), ("EscrowUntil", '("{c}",{i})'),
    ("DisputeOpen", '("{c}",{i})'), ("DisputeBondNext", '("{c}",{i})'),
    ("FailedRounds", '("{c}",{i})'), ("QuorumFloorOf", '("{c}",{i})', 'DisputeOpen("{c}",{i})'),
    ("Provisional", '("{c}",{i})'), ("ProvClose", '("{c}",{i})'),
    ("Settled", '("{c}",{i})'), ("Verdict", '("{c}",{i})', 'Settled("{c}",{i})'),
    ("VerdictRoute", '("{c}",{i})', 'Settled("{c}",{i})'), ("RewardsOpened", '("{c}",{i})'),
    ("DrawSlices", '("{c}",{i})', 'RewardsOpened("{c}",{i})'),
    # QualityTier, FlagState and FlagBondNext went with the quality lane. Removed
    # here too, or this conformance check reports three failures forever against a
    # realm that is correct — and a checker that always fails is a checker nobody
    # reads. It found them still being called by the overlay first, which was the
    # real bug (efa5203); this is the other half of the same removal.
    ("ClaimClosed", '("{c}",{i})'), ("ClaimSeeded", '("{c}",{i})'),
    ("ClaimPurged", '("{c}",{i})'), ("HiddenFromListing", '("{c}",{i})'),
    ("TextRedacted", '("{c}",{i})'),
    ("TrailingOI", '("{c}",{i},120960)'), ("TrailingYes", '("{c}",{i},120960)'),
    # THE MAP AND THE FOLDERS. These were missing, and the map is built out of
    # them: FolderTree gives the shape, FolderItems the claims in each node, and
    # the two relation reads the edges between claims. A dead read here empties the
    # map rather than erroring visibly, which is the worst shape of failure — the
    # page looks like a court with nothing in it.
    ("FolderTree", '("{c}")'), ("FolderName", '("{c}",1)', 'FolderCount("{c}")'),
    ("FolderDesc", '("{c}",1)', 'FolderCount("{c}")'),
    ("FolderItems", '("{c}",1)', 'FolderCount("{c}")'),
    ("ClaimAssociations", '("{c}",{i})'), ("ClaimSupersedes", '("{c}",{i})'),
    # THE CLAIM'S OWN CONTENT, which the detail page cannot render without.
    ("ClaimBody", '("{c}",{i})'), ("ClaimMedia", '("{c}",{i})'),
    ("CourtDesc", '("{c}")'), ("DisputeVoteCloses", '("{c}",{i})'),
    ("AnswerRecord", '("{c}","{a}")'),
    # THE WALLET PATH. DisposableOf is the figure the realm enforces before a
    # bond, and the vote quote is what the ballot shows a holder; both are read
    # only when an address is known, which is why they sit behind no guard here —
    # the checker always has one.
    ("ClaimVoteWeightOf", '("{c}","{a}",{i})'), ("DisposableOf", '("{c}","{a}")'),
    ("CommitmentsOf", '("{c}","{a}")'), ("VoteLockedOf", '("{c}","{a}")'),
    ("StakeOf", '("{c}",{i},0,"{a}")'), ("ConvictionOf", '("{c}",{i},0,"{a}")'),
    ("PullState", '("{c}",{i},"{a}")'),
    # The clock reads are gone with the banner that made them: the overlay no
    # longer asks a node whether its dates were invented, so conformance has
    # nothing to check here. The entrypoints remain on chain for any client that
    # wants them.
]

# The page's own parser: `(value type)` per line.
TYPED = gnorpc.TYPED


def qeval(remote, expr):
    """(text, None) or (None, message) -- a guard reports and keeps going.

    The shared client raises, because raising is the shape that can be
    adapted into this one; returning could not have been adapted into a
    generator that must abort. So the adapting happens here.
    """
    try:
        return gnorpc.qeval(remote, REALM, expr, req_id="clr"), None
    except gnorpc.QevalError as e:
        return None, str(e)



def main():
    argv = sys.argv[1:]
    def flag(n, d):
        return argv[argv.index(n) + 1] if n in argv and argv.index(n) + 1 < len(argv) else d
    remote = flag("--remote", "http://127.0.0.1:26657")
    court = flag("--court", "orem")
    # The claim id is a knob because state lives on DIFFERENT claims: a seeded
    # node has one settled and one disputed, and probing only id 1 leaves the
    # dispute reads permanently "skipped" while a dispute is right there on id 2.
    claim = int(flag("--claim", "1"))
    addr = flag("--addr", "g1qpymzmpsf6hjfjfyx4qcs5x9c6cj4kvv98yn9m")

    # BEFORE touching the network: an empty or shrunken probe table would report
    # a clean scan having asked nothing, which is the vacuous pass this whole
    # family of checks keeps rediscovering. Checked first so the tripwire works
    # with no node at all, which is also what makes it testable in selftest.
    if len(PROBES) < 40:
        print(f"check-live-reads: only {len(PROBES)} probe(s) — the overlay issues "
              f"58 distinct reads, so this table has been gutted and a clean scan "
              f"would mean nothing.", file=sys.stderr)
        return 1

    try:
        head, err = qeval(remote, "CourtCount()")
    except Exception as e:
        print(f"check-live-reads: cannot reach {remote}: {e}", file=sys.stderr)
        print("  Seed one first:  scripts/seed-node.sh scenarios/smoke.py", file=sys.stderr)
        return 2
    if err:
        print(f"check-live-reads: {remote} answers, but not as this realm: {err}", file=sys.stderr)
        return 2

    bad, checked, skipped = [], 0, 0
    for probe in PROBES:
        name, shape = probe[0], probe[1]
        guard = probe[2] if len(probe) > 2 else None
        if guard:
            g, gerr = qeval(remote, guard.format(c=court, i=claim, a=addr))
            if gerr:
                bad.append((guard.format(c=court, i=claim, a=addr),
                            f"GUARD itself failed: {gerr}"))
                continue
            # A COUNT IS A GUARD TOO. This tested only for "true", so a guard like
            # FolderCount("covid") — which answers "(6 int)" — read as FALSE and the
            # probe behind it was silently SKIPPED. Three folder probes were added
            # with exactly that guard and none of them ever ran; the summary counted
            # them as skipped-on-purpose and reported a clean scan. Caught by an
            # ablation that broke FolderItems' argument type and was not detected.
            #
            # So: truthy is "true", or a non-zero number. A zero count means the
            # page would not issue the read either, which is the original intent.
            gv = (g or "").strip()
            m = re.match(r"^\((-?\d+)\s", gv)
            truthy = ("true" in gv) or (m is not None and int(m.group(1)) != 0)
            if not truthy:
                skipped += 1   # the page would not issue this read either
                continue
        expr = name + shape.format(c=court, i=claim, a=addr)
        try:
            out, err = qeval(remote, expr)
        except Exception as e:
            bad.append((expr, f"request failed: {e}"))
            continue
        checked += 1
        if err:
            bad.append((expr, f"chain error: {err}"))
            continue
        lines = [l for l in (out or "").strip().splitlines() if l.strip()]
        if not lines:
            bad.append((expr, "empty response — the page would render a blank"))
            continue
        for line in lines:
            if not TYPED.match(line.strip()):
                bad.append((expr, f"unparseable by the page's parseTyped: {line[:60]!r}"))
                break

    tail = f", {skipped} skipped (their guard is false, so the page skips them too)" if skipped else ""
    print(f"check-live-reads: {checked} live read(s) against {remote} "
          f"(court {court}, claim {claim}){tail}")
    if bad:
        print(f"  {len(bad)} did not answer in a shape the page can use:", file=sys.stderr)
        for expr, why in bad:
            print(f"    {expr}: {why}", file=sys.stderr)
        return 1
    print("  every read answered in the shape the overlay parses.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
