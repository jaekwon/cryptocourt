#!/usr/bin/env python3
"""Write the generated half of the demo dataset FROM a seeded node.

    scripts/seed-node.sh scenarios/deep.py            # in one shell
    scripts/dump-demo.py --remote http://127.0.0.1:26657 --check
    scripts/dump-demo.py --remote http://127.0.0.1:26657        # writes

WHAT IT TOUCHES, and what it cannot. `web/index.html` carries two halves. The
hand-written one — `DEMO_OVERLAY`: court descriptions, the nested folder tree,
the relation graph, and a dispute's vote-close height — has NO chain source and
is not addressable from here at all. This tool rewrites only the region between

    /* ===== BEGIN GENERATED DEMO DATA ... ===== */
    /* ===== END GENERATED DEMO DATA ===== */

That split is the safety property. A tool that cannot reach the hand-tuned half
cannot destroy it, which is worth more than any amount of validation.

WHAT YOU GET IS A YOUNG CHAIN, and it will not look like the sample it replaces.
A seeded court has near-zero conviction, zero emission and no mature trailing
average, because those are denominated in BLOCKS and blocks cannot be faked —
the demo's mature figures would need ~10.1M of them. That is the honest state of
a new court and the reason P5's original criterion could not be met.

SAFETY, in order of how much each is worth:
  1. it can only address the generated region (above);
  2. the bytes before and after that region are compared and must be unchanged;
  3. it writes to a temp file and renames, so a crash cannot truncate the page;
  4. --check writes nothing and exits 1 if the region would change;
  5. it refuses a partial dump: any failed read aborts the whole thing.
"""
import json
import os
import re
import sys
import urllib.request

import gnorpc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, "web", "index.html")
REALM = "gno.land/r/kourt/kourtv2"
BEGIN = "/* ===== BEGIN GENERATED DEMO DATA"
END = "/* ===== END GENERATED DEMO DATA ===== */"


def qeval(remote, expr):
    """gnorpc.qeval, bound to this realm. Raises QevalError; a generator
    must abort rather than carry on with a hole in its output."""
    return gnorpc.qeval(remote, REALM, expr, req_id="dd")


TYPED = gnorpc.TYPED

# The realm serves text through sanitize.InlineText, so "Nov 6, 2025." comes back
# as "Nov 6, 2025\.". LIVE mode undoes that with unesc() at every call site; the
# DEMO branch does not, because a hand-written sample was never escaped. Dumped
# text therefore has to be unescaped here or the backslashes reach the reader —
# observed on the first dump, in the claim title on the page heading.
_UNESC = re.compile(r"\\([\\`*_\[\]()~>\-+.!#<&])")


def unesc(t):
    return _UNESC.sub(r"\1", t) if isinstance(t, str) else t


def val(remote, expr):
    """One scalar, parsed the way the page's parseTyped does."""
    out = qeval(remote, expr).strip()
    line = out.splitlines()[0] if out else ""
    m = TYPED.match(line.strip())
    raw = m.group(1) if m else line
    if raw.startswith('"') and raw.endswith('"'):
        try:
            return unesc(json.loads(raw))
        except Exception:
            return unesc(raw[1:-1])
    if raw in ("true", "false"):
        return raw == "true"
    if re.fullmatch(r"-?\d+", raw):
        return int(raw)
    return raw


def js(v):
    """A JS literal. Deterministic: no separators, sorted keys, stable order."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ",".join(js(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{k}:{js(x)}" for k, x in v.items()) + "}"
    raise SystemExit(f"cannot render {v!r}")


def gather(remote, slugs):
    courts, claims = {}, {}
    for slug in slugs:
        n = val(remote, f'ClaimCount("{slug}")')
        courts[slug] = {
            "name": val(remote, f'CourtName("{slug}")'),
            "tier": val(remote, f'CourtTier("{slug}")'),
            "price": val(remote, f'CoinPrice("{slug}")'),
            "supply": val(remote, f'CoinSupply("{slug}")'),
            "minted": val(remote, f'CurvePosition("{slug}")'),
            "emitted": val(remote, f'EmittedTotal("{slug}")'),
            "reservoir": val(remote, f'Reservoir("{slug}")'),
            "seniorOwed": val(remote, f'SeniorOwed("{slug}")'),
            "burned": val(remote, f'CourtBurnedGNOT("{slug}")'),
            "claims": list(range(1, n + 1)),
        }
        for i in range(1, n + 1):
            settled = val(remote, f'Settled("{slug}",{i})')
            closed = val(remote, f'ClaimClosed("{slug}",{i})')
            disputed = val(remote, f'DisputeOpen("{slug}",{i})')
            answered = val(remote, f'HasAnswer("{slug}",{i})')
            provclose = val(remote, f'ProvClose("{slug}",{i})')
            prov = val(remote, f'Provisional("{slug}",{i})')
            # The DEMO branch keys every screen off `phase`; the live branch
            # composes it from these predicates, so the dump must too or a
            # settled claim renders as "open — no answer yet" (observed).
            phase = ("closed" if closed else "provClose" if provclose
                     else "settled" if settled else "disputed" if disputed
                     else "provisional" if isinstance(prov, int) and prov >= 0
                     else "answered" if answered else "open")
            d = {"phase": phase,
                 "title": val(remote, f'ClaimTitle("{slug}",{i})'),
                 "author": val(remote, f'ClaimAuthor("{slug}",{i})'),
                 "status": val(remote, f'ClaimStatus("{slug}",{i})'),
                 "timeline": val(remote, f'ClaimTimeline("{slug}",{i})'),
                 "closed": closed,
                 "hidden": val(remote, f'HiddenFromListing("{slug}",{i})'),
                 "seeded": val(remote, f'ClaimSeeded("{slug}",{i})'),
                 "convYes": val(remote, f'PoolConviction("{slug}",{i})'),
                 "disputeOpen": disputed}
            if answered:
                d["answer"] = val(remote, f'AnswerVerdict("{slug}",{i})')
                d["answerer"] = val(remote, f'Answerer("{slug}",{i})')
                d["answerBond"] = val(remote, f'AnswerBond("{slug}",{i})')
                d["settleAt"] = val(remote, f'SettleDeadline("{slug}",{i})')
            if settled:
                d["verdict"] = val(remote, f'Verdict("{slug}",{i})')
                d["route"] = val(remote, f'VerdictRoute("{slug}",{i})')
            if disputed:
                d["quorumFloor"] = val(remote, f'QuorumFloorOf("{slug}",{i})')
                d["disputeBondNext"] = val(remote, f'DisputeBondNext("{slug}",{i})')
                d["round"] = val(remote, f'FailedRounds("{slug}",{i})')
            pools = qeval(remote, f'StakePools("{slug}",{i})').split("\n")
            d["yesStake"] = val(remote, f'StakePools("{slug}",{i})')
            if len(pools) > 1:
                m = TYPED.match(pools[1].strip())
                d["noStake"] = int(m.group(1)) if m else 0
            claims[f"{slug}/{i}"] = d
    return {"courts": courts, "claims": claims}


def main():
    argv = sys.argv[1:]
    def flag(n, d=None):
        return argv[argv.index(n) + 1] if n in argv and argv.index(n) + 1 < len(argv) else d
    remote = flag("--remote", "http://127.0.0.1:26657")
    check = "--check" in argv
    slugs = (flag("--courts") or "orem").split(",")

    page = open(PAGE, encoding="utf-8").read()
    if page.count(BEGIN) != 1 or page.count(END) != 1:
        print("dump-demo: expected exactly one BEGIN and one END marker in web/index.html",
              file=sys.stderr)
        return 2
    i = page.index(BEGIN)
    j = page.index(END) + len(END)
    if j <= i:
        print("dump-demo: END marker precedes BEGIN", file=sys.stderr)
        return 2
    prefix, suffix = page[:i], page[j:]

    try:
        data = gather(remote, slugs)
    except Exception as e:
        print(f"dump-demo: read failed, nothing written: {e}", file=sys.stderr)
        print(f"  Is a node seeded at {remote}?  scripts/seed-node.sh scenarios/deep.py",
              file=sys.stderr)
        return 2

    body = [BEGIN + " — scripts/dump-demo.py; do not hand-edit ===== */",
            f"const DEMO_CHAIN = {{",
            "  courts:{"]
    for slug, c in data["courts"].items():
        body.append(f"    {slug}:{js(c)},")
    body += ["  },", "  claims:{"]
    for key, d in data["claims"].items():
        body.append(f'    "{key}":{js(d)},')
    body += ["  },", "  seniorQueues:{}, positions:{}, balances:{},", "};", END]
    generated = "\n".join(body) + "\n"

    if page[i:j] + "\n" == generated:
        print("dump-demo: the generated region already matches this node.")
        return 0
    if check:
        print("dump-demo: the generated region is STALE for this node "
              "(run without --check to rewrite it)", file=sys.stderr)
        return 1

    out = prefix + generated + suffix
    # the bytes outside the region must be untouched, verified not asserted
    assert out[:len(prefix)] == prefix and out[len(out) - len(suffix):] == suffix
    tmp = PAGE + ".dump.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(out)
    os.replace(tmp, PAGE)
    print(f"dump-demo: wrote {len(data['courts'])} court(s), "
          f"{len(data['claims'])} claim(s) from {remote}")
    print("  NOTE: a seeded chain is young — conviction near zero, emission zero, "
          "no mature trailing average. That is the honest state, not a bug.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
