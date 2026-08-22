#!/usr/bin/env python3
"""Give a runner its own GNOROOT, so staging cannot collide with anything.

Every gno-based runner here stages the realms into
$GNOROOT/examples/gno.land/{p,r}/kourt and removes that tree afterwards. The path
follows the import paths baked into the sources — they are what make `gno test`
resolve a sibling package there at all, so it moved when they did in the
2026-08-16 rename. STAGED below still accepts the pre-rename org name as well,
and the reason is in the comment above it: a tree left behind under the old name
must stay removable. So the tree was shared by five
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
— and it is a few tens of MB, on the order of a second, once per run. Everything
expensive (gnovm, tm2, the stdlibs) stays a symlink and is never copied.

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


def reap(quiet=True):
    """Remove shadow roots whose owning process is gone.

    A killed run leaves its root behind — harmless, since nothing reads it, but 14MB
    a time and nobody's job to clear. The owner's pid is in the name, so the next
    build can tell a live root from an abandoned one and take only the latter. Live
    roots are never touched: two runs in parallel is the point of this module.
    """
    if not os.path.isdir(BASE):
        return 0
    n = 0
    for name in os.listdir(BASE):
        if not name.startswith(PREFIX):
            continue
        tail = name.rsplit("-", 1)[-1]
        if not tail.isdigit():
            continue
        try:
            os.kill(int(tail), 0)
            continue  # alive, or ours
        except ProcessLookupError:
            pass
        except OSError:
            continue  # somebody else's live process
        shutil.rmtree(os.path.join(BASE, name), ignore_errors=True)
        n += 1
    if n and not quiet:
        print(f"gnoroot: reaped {n} shadow root(s) left by runs that did not finish",
              file=sys.stderr)
    return n


def build(real, label, pid=None):
    """Shadow `real` and return the new root's path.

    Keyed by worktree, label and pid: the worktree so two checkouts never share,
    the pid so two runs in ONE checkout do not either. Nothing is reused between
    runs — a stale copy of examples/ would silently test against yesterday's
    tree, which costs more than the half second it saves.
    """
    # SAY WHAT WENT WRONG. real_root() returns "" for every way of not finding a
    # toolchain — gno absent from PATH, or `gno env GNOROOT` naming a directory
    # that is not there — and without this the empty string travelled down to
    # os.listdir("") and surfaced as:
    #
    #     FileNotFoundError: [Errno 2] No such file or directory: ''
    #
    # which names no file, no cause and no fix. That is not hypothetical: `gno
    # env GNOROOT` is CWD-DEPENDENT, so running any of these scripts from a git
    # worktree outside the checkout answers with a path derived from the
    # worktree's own prefix, which does not exist — and mutate.py died twice on
    # that traceback before anybody thought to run the command by hand.
    if not real or not os.path.isdir(real):
        raise SystemExit(
            "gnoroot: no gno toolchain to shadow (GNOROOT=%r). `gno env GNOROOT` "
            "resolves against the CURRENT DIRECTORY, so running this from a git "
            "worktree or any path outside the checkout can answer with a "
            "directory that does not exist. Set GNOROOT explicitly, or run from "
            "the repository." % (real,))
    pid = os.getpid() if pid is None else pid
    reap()  # clear anything a killed run left, before adding one more
    # The worktree name, so a listing of BASE says whose each root is.
    who = os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    root = os.path.join(BASE, f"{PREFIX}{who}-{label}-{pid}")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(root)
    for name in os.listdir(real):
        # `examples` is copied below. `.git` is deliberately absent rather than
        # symlinked: nothing here needs it, and a symlink would mean any tool that
        # ran git inside a shadow was operating on the real checkout's index.
        # Removal is already safe either way — rmtree unlinks symlinks instead of
        # descending them, which the self-test pins — but a link that cannot be
        # followed by accident is better than one that merely is not.
        if name in ("examples", ".git"):
            continue
        os.symlink(os.path.join(real, name), os.path.join(root, name))
    src = os.path.join(real, "examples")
    dst = os.path.join(root, "examples")
    shutil.copytree(src, dst, symlinks=True, ignore=_skip_staging)
    return root


# Directory names another runner stages into, skipped while copying examples/.
#
# Two reasons, and the second is the one that bites. A staged realm must not be
# able to reach the real tree's copy of itself. And these are the only VOLATILE
# directories in examples/: a runner in another worktree — or an older version of
# this tooling, or the renamed checkout, which stages `kourt` — may be part way
# through its own rm -rf while this copy walks the tree, and a file that vanishes
# mid-copy would fail the build with an error about a path nobody asked for. Not
# copying them at all is both the correct result and the robust one.
STAGED = ("cryptocourt", "kourt")


def _skip_staging(directory, names):
    parts = directory.replace(os.sep, "/").split("/")
    if len(parts) >= 2 and parts[-2] == "gno.land" and parts[-1] in ("p", "r"):
        return {n for n in names if n in STAGED}
    return set()


def stage(root, pairs):
    """Copy each (source dir, destination rel-path) pair into a shadow root.

    THIS LOOP EXISTED THREE TIMES — check-storage, check-isolation and mutate —
    byte-identical apart from the loop variable, and each computed its own pairs:
    a realm plus its p/ deps, every realm the Makefile names, or both trees. The
    pairs are the part that legitimately differs. The copy was not.

    The line that made it worth merging is the filter. `.gno` or `gnomod.toml`
    was written out in all three, so a fourth kind of file that has to be staged
    — another manifest, a testdata dir — would have been added to one and missed
    by two, and the symptom would be a guard measuring a package built from an
    incomplete copy. That is the same drift check-mutation-anchors already
    imports PKGS from mutate.py to avoid, rather than restating it.

    It lives here because this module already owns the shadow root's lifecycle
    and what is deliberately NOT symlinked into it (STAGED, _skip_staging).
    Staging packages into one is the same concern from the other end.
    """
    for src, rel in pairs:
        dst = os.path.join(root, rel)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for f in os.listdir(src):
            if f.endswith(".gno") or f == "gnomod.toml":
                shutil.copy(os.path.join(src, f), dst)


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
