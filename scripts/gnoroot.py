#!/usr/bin/env python3
"""Give a runner its own GNOROOT, so staging cannot collide with anything.

Every gno-based runner here stages the realms into
$GNOROOT/examples/gno.land/{p,r}/cryptocourt and removes that tree afterwards.
The path cannot be changed: the import paths baked into the sources are what make
`gno test` resolve a sibling package there at all. So the tree was shared by five
runners across every worktree on the machine — realm-test, check-isolation,
mutate, check-storage and the txtar TestMain — each of them ending with an rm -rf
of a directory the others might be reading. That produced a "c.mod undefined"
build failure in code that was fine, an outright `make isolation-test` failure,
and mutation rows scored INVALID because the mutant could not build what it no
longer had.

The lock that came before this made it CORRECT by making it serial. This makes it
PARALLEL, which is what was actually wanted: two worktrees can now run their
suites at the same time, and neither can see the other.

# How

GNOROOT is honoured from the environment, so the runner gets a shadow of it:
every top-level entry SYMLINKED, except `examples`, which is a real copy. Only
the examples tree needs to be real — gno's package discovery walks it and does
not follow symlinks, which is the whole reason a symlink farm alone does not work
— and it is 14MB, about half a second. Everything expensive (gnovm, tm2, the
stdlibs) stays a symlink and is never copied.

What this does NOT do is rewrite import paths, which was the other way to get
per-worktree staging and a bad trade: the code under test would then differ
textually from the code that is committed, and a test suite that proves things
about slightly different source is worth much less.

    root=$(python3 scripts/gnoroot.py build --label realm-test)
    ...
    python3 scripts/gnoroot.py remove --path "$root"
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

# Every shadow lives under this one directory and its name starts with this
# prefix. remove() refuses anything else, because it deletes a tree recursively
# and the trees it deletes are full of symlinks INTO a real gno checkout. A
# wrong path here would be expensive in a way no test would catch.
BASE = os.path.join(tempfile.gettempdir(), "cryptocourt-gnoroot")
PREFIX = "root-"


def real_root():
    try:
        r = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                           text=True, timeout=30).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        return ""
    return r if r and os.path.isdir(r) else ""


def build(real, label, pid=None):
    """Shadow `real` and return the new root's path.

    Keyed by worktree, label and pid: the worktree so two checkouts never share,
    the pid so two runs in ONE checkout do not either. Nothing is reused between
    runs — a stale copy of examples/ would silently test against yesterday's
    tree, which costs more than the half second it saves.
    """
    pid = os.getpid() if pid is None else pid
    # The worktree name, so a listing of BASE says whose each root is.
    who = os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    root = os.path.join(BASE, f"{PREFIX}{who}-{label}-{pid}")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    for name in os.listdir(real):
        if name == "examples":
            continue
        os.symlink(os.path.join(real, name), os.path.join(root, name))
    src = os.path.join(real, "examples")
    dst = os.path.join(root, "examples")
    # cp -Rc clones on APFS, so this is near-free where it is supported; -R alone
    # is the fallback and still only takes about half a second for 14MB.
    if subprocess.run(["cp", "-Rc", src, dst], capture_output=True).returncode != 0:
        shutil.copytree(src, dst, symlinks=True)
    # A staged realm must never be able to reach the REAL tree's copy of itself.
    for kind in ("p", "r"):
        shutil.rmtree(os.path.join(dst, "gno.land", kind, "cryptocourt"),
                      ignore_errors=True)
    return root


def remove(path):
    """Delete a shadow root, refusing anything that is not one.

    shutil.rmtree does not descend symlinked directories — it unlinks them — so
    the symlinks into the real checkout are removed and their targets are not
    touched. The guard above is for the case where `path` is not a shadow at all.
    """
    p = os.path.abspath(path)
    if os.path.dirname(p) != BASE or not os.path.basename(p).startswith(PREFIX):
        print(f"gnoroot: refusing to remove {p}: not a shadow root under {BASE}",
              file=sys.stderr)
        return 1
    shutil.rmtree(p, ignore_errors=True)
    return 0


class shadow:
    """Context manager for the python runners: `with shadow("mutate") as root:`."""

    def __init__(self, label, real=None):
        self.label = label
        self.real = real
        self.path = None

    def __enter__(self):
        self.path = build(self.real or real_root(), self.label)
        return self.path

    def __exit__(self, *exc):
        remove(self.path)
        return False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=["build", "remove"])
    ap.add_argument("--root", default=None, help="the real GNOROOT to shadow")
    ap.add_argument("--label", default="unnamed")
    ap.add_argument("--pid", type=int, default=None,
                    help="name the root after this pid rather than this script's, "
                         "so a shell holding it across several commands owns it")
    ap.add_argument("--path", default=None, help="the shadow root to remove")
    a = ap.parse_args()

    if a.action == "remove":
        if not a.path:
            print("gnoroot: remove needs --path", file=sys.stderr)
            return 1
        return remove(a.path)

    real = a.root or real_root()
    if not real:
        print("gnoroot: no GNOROOT", file=sys.stderr)
        return 1
    print(build(real, a.label, pid=a.pid))
    return 0


if __name__ == "__main__":
    sys.exit(main())
