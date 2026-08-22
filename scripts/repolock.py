#!/usr/bin/env python3
"""An advisory lock for the one runner that mutates the WORKING TREE.

Every other runner stages into its own GNOROOT shadow (scripts/gnoroot.py), so
they are safe to run concurrently and routinely are. selftest-checks.py is the
exception and cannot be made to follow: its whole job is to break a guard and
watch it complain, and the guards read the repository's own sources. So it edits
those sources in place, one at a time, restoring each afterwards.

That is fine alone and invisible in parallel. Running `make check` beside a
selftest produced this, and it looks exactly like a real defect:

    2 citation(s) need attention.
    UNUSED gnovm/pkg/gnolang/store.go  'NoProseSaysThis'
    UNCITED nobody_cited_this.gno is named in realm/r/govern/errors.gno

Both are selftest's own controls, caught mid-mutation by a reader that had no way
to know. A FALSE FAILURE IN A DIFFERENT GATE IS THE WORST KIND: it names a file
you did not touch, for a reason that is not true, and the natural response is to
go fix the citation that was never wrong.

So the mutating runner announces itself, and the readers refuse rather than
report. A refusal that says "someone is rewriting the tree" costs one re-run; a
phantom citation error costs a diagnosis.

RE-ENTRANCY. selftest INVOKES the readers as its controls, so it must not lock
itself out. It exports its pid, children inherit that through the environment,
and a reader whose inherited pid matches the holder proceeds normally.
"""

import os
import sys
import tempfile

LOCK = os.path.join(tempfile.gettempdir(), "kourt-worktree-mutating.lock")
ENV = "KOURT_WORKTREE_OWNER"


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def holder():
    """The live pid rewriting the tree, or None. Clears a stale lock in passing."""
    try:
        with open(LOCK) as f:
            pid = int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return None
    if not _alive(pid):
        # The holder died mid-run. Leaving this behind would refuse every reader
        # forever, which is a worse failure than the one being prevented.
        try:
            os.unlink(LOCK)
        except FileNotFoundError:
            pass
        return None
    return pid


class hold:
    """Announce that this process is rewriting the working tree."""

    def __enter__(self):
        pid = os.getpid()
        with open(LOCK, "w") as f:
            f.write(str(pid))
        os.environ[ENV] = str(pid)
        return self

    def __exit__(self, *exc):
        try:
            os.unlink(LOCK)
        except FileNotFoundError:
            pass
        return False


def refuse_if_held(who):
    """Exit 1 with a legible reason if another process is rewriting the tree.

    Called at the top of every guard that reads the repository's own sources. The
    exit is deliberate: continuing would report the holder's deliberate breakage
    as this guard's finding.
    """
    pid = holder()
    if pid is None or str(pid) == os.environ.get(ENV):
        return
    print(f"{who}: process {pid} is rewriting the working tree (a selftest run, "
          f"or somebody arming a guard by hand through `repolock.py hold`, breaks "
          f"guards on purpose and restores them). Reading the sources now would "
          f"report ITS mutation as MY finding. Re-run when it is done, or run the "
          f"two one at a time.", file=sys.stderr)
    sys.exit(1)


# A CLI, because the two callers that most need this lock cannot import it.
#
#   * `make realm-test` is a shell recipe. Every PYTHON guard in it already calls
#     refuse_if_held, and the recipe around them did not — so a reader that was
#     careful about check-citations went on to copy realm/r/*/*.gno into a
#     GNOROOT with no such scruple. That is not hypothetical: two consecutive
#     `make check` runs failed on tests nobody had touched, one in argument_test
#     and one in argumentcaps_test, because the copy caught a break that another
#     session had armed by hand and restored moments later. Neither reproduced.
#     A false failure in a different gate is the worst kind, and this file's own
#     docstring says so.
#
#   * arming a guard BY HAND — break it, run the suite, put it back — is the
#     exact thing this lock is for, and it was only reachable by importing the
#     module, which a person at a terminal will not do. `hold --` wraps any
#     command, so the announcement costs one prefix:
#
#         python3 scripts/repolock.py hold -- sh -c 'edit; gno test .; restore'
#
def _main(argv):
    if len(argv) >= 2 and argv[0] == "check":
        refuse_if_held(argv[1])
        return 0
    if argv and argv[0] == "status":
        pid = holder()
        print("no one is rewriting the tree" if pid is None
              else "process %d is rewriting the tree" % pid)
        return 0
    if argv and argv[0] == "hold":
        rest = argv[1:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        if not rest:
            print("repolock: hold needs a command, e.g.\n"
                  "  python3 scripts/repolock.py hold -- gno test .", file=sys.stderr)
            return 2
        import subprocess
        with hold():
            # Not check=True: the command's own exit code is the answer, and a
            # failing armed run is the NORMAL outcome of arming a guard.
            return subprocess.run(rest).returncode
    print(__doc__.strip().split("\n")[0] + "\n\n"
          "  python3 scripts/repolock.py status\n"
          "  python3 scripts/repolock.py check <who>\n"
          "  python3 scripts/repolock.py hold -- <command...>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
