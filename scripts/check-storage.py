#!/usr/bin/env python3
"""Check what the filetests cost, so a gas regression fails the ordinary test run.

`gno test -v` reports the storage each filetest wrote, per realm:

    --- PASS: ./z_write_filetest.gno (... storage: gno.land/r/kourt/govern:+6328b)

That is the same number a chain charges a deposit for, available without a node
and on every `make realm-test`. Everything else measuring gas in this repo needs
a gnodev, takes seventy seconds, and is therefore run by hand and occasionally.

Two kinds of claim are checked.

The read filetest must write NOTHING. It exercises the whole read surface from
outside the package and its storage line must be absent entirely — not small,
absent. A read that starts writing is the defect this guards against, and it
has a specific shape here: settle running inside State and Render. The
transitions it computes are thrown away with the query, so the only visible
symptom is slots that never come back, months later, under load.

The writing filetests must stay under a ceiling. Ceilings rather than exact
figures, because a byte or two moves whenever a string in the realm changes and
a test that fails on that gets deleted rather than read. These are set well
above what they cost today and well below anything that would count as a
regression.

    python3 scripts/check-storage.py
"""

import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gnoroot
import repolock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Every realm that has filetests, with what each is allowed to write.
#
# This was one realm hardcoded, which is how kourtv2 came to have no filetest at
# all and therefore no guard against the defect below — while govern had one
# from the beginning. check-isolation had the identical drift in the same week
# (it swept 151 of 388 tests), so realms_with_filetests() now cross-checks this
# list against the tree: a realm that grows a filetest without a budget fails
# here rather than going quietly unwatched.
P = "examples/gno.land/p/kourt"
TARGETS = [
    {
        "src": os.path.join(REPO, "realm/r/govern"),
        "dest": "examples/gno.land/r/kourt/govern",
        "deps": ["checkpoint", "grc20votes", "governor"],
        # filetest -> ceiling in bytes written to the realm, or None for
        # "must write nothing at all".
        "budgets": {
            "z_use_filetest.gno": None,
            "z_offer_filetest.gno": 4_000,
            "z_write_filetest.gno": 12_000,
        },
    },
    {
        "src": os.path.join(REPO, "realm/r/kourtv2"),
        "dest": "examples/gno.land/r/kourt/kourtv2",
        # WHAT KOURTV2 ACTUALLY IMPORTS. cshares and tickbook were here too, and
        # the import graph says only the V1 court uses those — V1 is not a target
        # here, so both were copied into every run for nothing. mutate.py reached
        # the same conclusion for its own staging and records it there: "v0.57
        # claimed the realm-test set's seven were all needed; that was wrong".
        # The Makefile's realm-test still names seven and is right to: it stages
        # the UNION for five realms, kourtv1 among them.
        "deps": ["checkpoint", "grc20votes", "governor", "twap", "curve"],
        # None, and it holds today: the whole read surface — directory, coin,
        # curve, moderation, election, strips, franchise and both render routes
        # — writes zero bytes. Worth stating because two reads in this realm HAD
        # started writing (five election reads via ensureMod; ensureClaimMod
        # ahead of the m-of-n gating it) and both were caught by hand, not here.
        "budgets": {
            "z_read_filetest.gno": None,
            # The test clock's arming path, from a fresh deploy. It reads two
            # scalars and is then refused, so it must write nothing at all —
            # a latch that allocated on a REFUSED arm would be a way to make a
            # realm pay for strangers' attempts.
            "z_testclock_filetest.gno": None,
            # The mod-log events, which needed a WRITING filetest: an event is
            # only observable through the `Events:` directive, and to emit one
            # you have to perform the act. A court, a folder, and three verbs
            # cost 50,194b measured, so the ceiling is 60,000 — headroom for a
            # fourth verb without hiding a court that got twice as expensive to
            # start. This is the only filetest here allowed to write at all, and
            # the two above stay at None precisely so that stays visible.
            "z_events_filetest.gno": 60_000,
        },
    },
    {
        "src": os.path.join(REPO, "realm/r/ccwrap"),
        "dest": "examples/gno.land/r/kourt/ccwrap",
        # ccwrap had NO filetest, and so no guard against a read that allocates —
        # the same drift this registry's comment above describes about kourtv2.
        # The coverage check below catches a realm whose filetest has no budget;
        # a realm with no filetest at all was invisible to it, and ccwrap was
        # that realm with six exported reads and two render routes.
        "deps": ["checkpoint", "grc20votes", "governor", "twap", "curve"],
        "realm_deps": ["kourtv2"],
        "budgets": {
            # None, and measured: enabled/wrappable/token-key/wrap-room and the
            # front page write zero bytes. WrappedSupply and Render(slug) are NOT
            # in it — both go through mustWrapped and need a wrap to exist, and
            # enabling one is a write, so a None file cannot reach them.
            "z_read_filetest.gno": None,
        },
    },
]


# EVERY realm/r/* must be budgeted above or exempted HERE, with the reason in the
# open. The coverage check below catches a realm whose FILETEST carries no budget —
# and a realm with NO FILETEST AT ALL was invisible to it, which is how ccwrap sat
# unwatched with six exported reads and two render routes. Fixing ccwrap by writing
# it a filetest closed one instance and taught this guard nothing; the enumeration
# that found it was also wrong, because it read this list instead of the directory
# and missed realm/r/offerer entirely. So the directory is the authority now, and a
# new realm fails here until somebody either budgets it or writes down why not.
EXEMPT = {
    "kourtv1": "behaviourally frozen — V1 takes no new coverage by owner decision",
    "offerer": "a demo realm offering one kind to govern; its whole exported read "
               "surface is Greeted(), two package scalars that cannot allocate",
}


def realms_with_filetests():
    """Every realm/r/* that has filetests, so an unbudgeted one cannot hide."""
    out = set()
    rdir = os.path.join(REPO, "realm/r")
    for name in sorted(os.listdir(rdir)):
        d = os.path.join(rdir, name)
        if os.path.isdir(d) and any(f.startswith("z_") and f.endswith("_filetest.gno")
                                    for f in os.listdir(d)):
            out.add(d)
    return out


def stage(root, target):
    """This realm plus the p/ packages and realms it imports, at their on-chain paths."""
    pairs = [(os.path.join(REPO, "realm/p", d), f"{P}/{d}/v0") for d in target["deps"]]
    # A realm that imports ANOTHER REALM needs it staged too — ccwrap imports
    # kourtv2. Kept separate from "deps" because those resolve under realm/p and
    # carry a /v0 path suffix, and a realm does neither.
    for r in target.get("realm_deps", ()):
        pairs.append((os.path.join(REPO, "realm/r", r), f"examples/gno.land/r/kourt/{r}"))
    pairs.append((target["src"], target["dest"]))
    gnoroot.stage(root, pairs)


def main():
    # Stages the realms out of the working tree, so a selftest rewriting them
    # would be measured as this guard's own storage finding.
    repolock.refuse_if_held("check-storage")
    if not gnoroot.real_root():
        if os.environ.get("REQUIRE_GNO"):
            print("check-storage: gno not installed", file=sys.stderr)
            return 1
        print("check-storage: gno not installed - skipping")
        return 0

    # Coverage first: a realm that has filetests and no budget entry is the
    # drift this file was reorganised to prevent, and it must fail loudly.
    bad = 0
    covered = {t["src"] for t in TARGETS}
    for d in sorted(realms_with_filetests() - covered):
        print(f"UNWATCHED {os.path.relpath(d, REPO)} has filetests and no TARGETS "
              f"entry — its cost is unbudgeted. Add one.")
        bad += 1

    # And every realm is accounted for one way or the other. A realm with no
    # filetest never reaches the loop above, so without this a new one is watched
    # by nothing and says nothing about it.
    rdir = os.path.join(REPO, "realm", "r")
    for name in sorted(os.listdir(rdir)):
        d = os.path.join(rdir, name)
        if not os.path.isdir(d) or d in covered or name in EXEMPT:
            continue
        print(f"UNBUDGETED realm/r/{name} has no TARGETS entry and no EXEMPT "
              f"reason. Give it a filetest and a budget, or exempt it and say why.")
        bad += 1

    # ONE private GNOROOT for the whole run, and therefore NO LOCK. This runner
    # used to stage into the shared root without taking the lock the others took,
    # and it ends by removing all of p/kourt — so a concurrent runner's staged
    # packages were deletable by a guard that only wanted to measure a filetest's
    # storage. A per-run shadow removes the shared tree, and with it the race.
    with gnoroot.shadow("check-storage") as root:
        env = {**os.environ, "GNOROOT": root}
        for target in TARGETS:
            realm = os.path.basename(target["dest"])
            stage(root, target)
            base = os.path.join(root, target["dest"])
            r = subprocess.run(["gno", "test", "-v", "."], cwd=base,
                               capture_output=True, text=True, env=env)
            out = r.stdout + r.stderr
            shutil.rmtree(base, ignore_errors=True)
            shutil.rmtree(os.path.join(root, P), ignore_errors=True)

            if r.returncode != 0:
                print(f"check-storage: {realm}'s suite does not pass, so its costs "
                      f"mean nothing. Fix the tests first.", file=sys.stderr)
                # AND SAY WHICH TEST, because this refusal used to end here. It
                # already has the output — it ran with -v — and threw it away, so
                # the only way to learn what broke was to stage the realm again by
                # hand and re-run a suite that takes over a minute. The failure is
                # not this guard's finding, but the lines that name it are free.
                named = [ln.strip() for ln in out.split("\n")
                         if "--- FAIL" in ln or ln.startswith("panic:")
                         or ln.startswith("failed:")]
                for ln in named[:6]:
                    print("  %s" % ln[:150], file=sys.stderr)
                if not named:
                    print("  (the suite named no failing test — last lines:)",
                          file=sys.stderr)
                    for ln in [x for x in out.strip().split("\n") if x.strip()][-4:]:
                        print("  %s" % ln.strip()[:150], file=sys.stderr)
                return 1

            seen = {}
            for line in out.split("\n"):
                m = re.search(r"(z_\w+_filetest\.gno).*?\(", line)
                if not m or "PASS" not in line:
                    continue
                w = re.search(re.escape(target["dest"].split("examples/")[1]) + r":\+(\d+)b", line)
                seen[m.group(1)] = int(w.group(1)) if w else 0

            budgets = target["budgets"]
            for name, budget in budgets.items():
                if name not in seen:
                    print(f"MISSING {realm}/{name} did not run, so its cost was not checked")
                    bad += 1
                    continue
                got = seen[name]
                if budget is None:
                    if got != 0:
                        print(f"WROTE   {realm}/{name} wrote {got}b to the realm and must "
                              f"write nothing at all — a read has started writing")
                        bad += 1
                    else:
                        print(f"ok      {realm}/{name:<24} wrote nothing")
                elif got > budget:
                    print(f"OVER    {realm}/{name} wrote {got}b against a ceiling of {budget}b")
                    bad += 1
                else:
                    print(f"ok      {realm}/{name:<24} {got}b (ceiling {budget}b)")

            for name in sorted(set(seen) - set(budgets)):
                print(f"UNKNOWN {realm}/{name} has no budget. Add one, or its cost "
                      f"is unwatched.")
                bad += 1

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
