#!/usr/bin/env python3
"""The one implementation of the staging lock, for every runner that stages.

Every runner — realm-test, check-isolation, mutate — stages the realms into the
SAME $GNOROOT/examples/gno.land/{p,r}/cryptocourt and removes that tree when it
finishes. The location cannot be parameterized: the import paths baked into the
sources are what make `gno test` resolve a sibling package there at all. So two
concurrent runners delete each other's tree mid-run, and the loser reports a
phantom build failure in code that is fine — a "c.mod undefined" that never
existed, a `make isolation-test` failure with no cause, a mutation the harness
scores INVALID because it could not build what it never had. mkdir is atomic, so
it is the lock.

This lived as three hand-copied loops, one per runner. That is the arrangement
that let check-isolation's realm lists drift out of step with the Makefile's for
an entire development cycle, so it is not repeated here: the runners call this,
and the Makefile shells out to it.

Two things the copies got wrong, both now fixed here.

FIRST, they waited ten minutes and then told the operator to "remove it if it is
stale" — a guess, handed to a human, about the one piece of state whose deletion
while live re-creates the exact race the lock exists to prevent. The holder now
records who it is, so a waiter can KNOW. A lock whose owner process is gone is
reclaimed automatically and reported; a lock whose owner is alive is waited on,
by name.

SECOND, ten minutes was shorter than the longest legitimate hold. The isolation
sweep runs every test in its own process — 390 of them, a quarter of an hour —
so the ceiling that was meant to catch a dead holder had started firing on a
live one instead. Waiting is now bounded well above any real run, because a
false "it is stale" is far more expensive than a slow one: it costs a green
suite, and it invites the deletion.

    python3 scripts/stagelock.py acquire --label realm-test --pid $$
    python3 scripts/stagelock.py release
"""

import argparse
import contextlib
import os
import shutil
import sys
import time

# Well above the longest legitimate hold (the isolation sweep, ~15 minutes) and
# still short enough that a hung run does not block a tree forever.
WAIT_SECONDS = 2700


def path(root):
    return os.path.join(root, "examples/gno.land/.cryptocourt-stage.lock")


def _owner(lock):
    """(pid, started, label) of the holder, or None if it did not say.

    None is the honest answer for a lock written by an older runner, or one
    caught between mkdir and the write. Every caller treats it as ALIVE — an
    unidentified holder is never reclaimed.
    """
    try:
        with open(os.path.join(lock, "owner")) as f:
            pid, started, label = f.read().split("\t", 2)
        return int(pid), float(started), label.strip()
    except (OSError, ValueError):
        return None


def _alive(pid):
    """Whether pid is still running.

    A pid we are not allowed to signal is somebody else's live process, so
    PermissionError means alive. Only ProcessLookupError means gone.
    """
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def _reclaim(lock, who, quiet):
    """Take a dead holder's lock away, or return False if somebody else did.

    Renaming first is what makes this safe to race: os.rename on a directory
    succeeds for exactly one caller, so the process that moves the lock aside is
    the only one that may then delete it. A waiter that removed the directory
    directly could instead delete the *new* lock of whoever reclaimed a moment
    earlier, which is the very deletion this module exists to stop.
    """
    stale = f"{lock}.stale.{os.getpid()}"
    try:
        os.rename(lock, stale)
    except OSError:
        return False
    shutil.rmtree(stale, ignore_errors=True)
    if not quiet:
        pid, started, label = who
        print(f"stagelock: reclaimed the lock from {label} (pid {pid}), which is "
              f"no longer running", file=sys.stderr)
    return True


def acquire(root, label, pid=None, wait=WAIT_SECONDS, quiet=False):
    lock = path(root)
    pid = os.getpid() if pid is None else pid
    announced = False
    deadline = time.monotonic() + wait
    while True:
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            pass
        who = _owner(lock)
        if who and not _alive(who[0]) and _reclaim(lock, who, quiet):
            continue
        if not announced and not quiet:
            # Say why we are sitting here. The copies waited in silence, so a
            # blocked `make` was indistinguishable from a hung one.
            if who:
                held = int(time.time() - who[1])
                print(f"stagelock: waiting for {who[2]} (pid {who[0]}) to finish "
                      f"staging, held {held // 60}m{held % 60:02d}s",
                      file=sys.stderr)
            else:
                print(f"stagelock: waiting for the staging lock at {lock}",
                      file=sys.stderr)
            announced = True
        if time.monotonic() >= deadline:
            who = _owner(lock)
            whose = (f"{who[2]} (pid {who[0]})" if who
                     else "an unidentified runner, which predates this script")
            print(f"stagelock: {lock} has been held by {whose} for "
                  f"{wait // 60} minutes and that process is still alive. It is "
                  f"not stale — find out what it is doing rather than removing "
                  f"the lock, which would let two runners delete each other's "
                  f"staged tree.", file=sys.stderr)
            raise SystemExit(1)
        time.sleep(1)
    with open(os.path.join(lock, "owner"), "w") as f:
        f.write(f"{pid}\t{time.time()}\t{label}")
    return lock


def release(root):
    shutil.rmtree(path(root), ignore_errors=True)


@contextlib.contextmanager
def held(root, label, wait=WAIT_SECONDS):
    acquire(root, label, wait=wait)
    try:
        yield
    finally:
        release(root)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["acquire", "release"])
    ap.add_argument("--root", default=None,
                    help="GNOROOT; asked of the gno toolchain when omitted")
    ap.add_argument("--label", default="unnamed",
                    help="what is holding it, quoted back to whoever waits")
    ap.add_argument("--pid", type=int, default=None,
                    help="the process whose liveness stands for the lock's; the "
                         "calling SHELL ($$) when a recipe holds it across "
                         "several commands, not this short-lived script")
    ap.add_argument("--wait", type=int, default=WAIT_SECONDS)
    a = ap.parse_args()

    root = a.root
    if not root:
        import subprocess
        try:
            root = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                                  text=True, timeout=30).stdout.strip()
        except (FileNotFoundError, subprocess.SubprocessError):
            root = ""
    if not root or not os.path.isdir(root):
        print("stagelock: no GNOROOT", file=sys.stderr)
        return 1

    if a.action == "acquire":
        acquire(root, a.label, pid=a.pid, wait=a.wait)
    else:
        release(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
