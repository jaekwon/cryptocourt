#!/usr/bin/env python3
"""Every control() arm's plant must still apply — checked statically.

`check-guards-armed.py` states the division of labour in its own header: "this
says REGISTERED, selftest says BROKEN CONTROL". This file is the other half of
that sentence, and it exists for exactly the reason that one does.

A control arm works by planting `find` -> `replace` in a file and requiring the
guard to complain. If `find` no longer appears in that file, the plant is a no-op:
the guard is run against an unmodified tree, says nothing, and selftest reports it
as SILENT — an arm that proves nothing, wearing the same green as one that works.
selftest calls that BROKEN CONTROL and catches it, but only when selftest runs,
and selftest rewrites repository files in place so it must run alone. In practice
that means periodically. check-guards-armed was written because an unarmed guard
"sits in the tree until somebody remembers"; a rotted plant sits there the same
way, and this repo has already lost SIX arms at once to it — the anchor was the
corpus's `"[\\n {\\n"` head, the corpus was re-serialised at a different indent,
and every one of those arms silently stopped testing anything.

WHAT THIS DOES NOT DO, so the boundary is clear: it does not run an arm, does not
touch a file, and cannot tell you an arm's `want` string is still the right one.
It answers one question — would the plant apply? — which is the failure mode that
rots on its own, without anybody editing the arm. A `want` that goes stale needs
the guard's output to change, which is a deliberate edit somebody is looking at.

RESOLVED STATICALLY WITH `ast`, NOT A REGEX, and that was not the first attempt.
The call sites use five shapes — a literal, a module constant (`ELSEWHERE`), an
f-string (`f"{GOVERN}/clock_test.gno"`), `os.path.join(REPO, ...)`, and one
deliberate concatenation (`'PATHS = "scripts/check-pa' + 'ths.py"'`, built that
way so this file's own text does not contain the literal the arm renames — its
comment says "Do not tidy the concatenation away"). A regex over the source
resolved 113 of 116; evaluating the AST against the module's own constants
resolves all 116.

FAIL CLOSED ON WHAT IT CANNOT READ. An unresolvable call site is a failure, not a
skip. The alternative is worse in the specific way this repo keeps rediscovering:
a refactor that moves a plant's path behind a helper would silently drop it out of
coverage, and the guard would go on printing a smaller number as though it were
the whole story.
"""

import ast
import os
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF = os.path.join(REPO, "scripts", "selftest-checks.py")


def build(tree, consts):
    """Evaluate the module's string constants, two passes for forward refs."""
    for _ in range(2):
        for node in tree.body:
            if (isinstance(node, ast.Assign) and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name)):
                v = ev(node.value, consts)
                if v is not None:
                    consts[node.targets[0].id] = v
    return consts


def ev(node, consts):
    """The small expression forms the arms actually use. None means unresolved."""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else None
    if isinstance(node, ast.Name):
        return consts.get(node.id)
    if isinstance(node, ast.JoinedStr):
        out = ""
        for v in node.values:
            s = ev(v.value, consts) if isinstance(v, ast.FormattedValue) else ev(v, consts)
            if s is None:
                return None
            out += str(s)
        return out
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = ev(node.left, consts), ev(node.right, consts)
        return None if left is None or right is None else left + right
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        if node.func.attr == "join":
            parts = [ev(a, consts) for a in node.args]
            return None if any(p is None for p in parts) else os.path.join(*parts)
        if node.func.attr == "replace":
            base = ev(node.func.value, consts)
            args = [ev(a, consts) for a in node.args]
            if base is not None and len(args) == 2 and None not in args:
                return base.replace(args[0], args[1])
    return None


def main():
    repolock.refuse_if_held("check-control-anchors")

    src = open(SELF, encoding="utf-8").read()
    tree = ast.parse(src)
    consts = build(tree, {"REPO": REPO})

    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and isinstance(n.func, ast.Name) and n.func.id == "control"]
    if not calls:
        print("check-control-anchors: no control() call sites found in "
              "selftest-checks.py, so this check is measuring nothing. The helper "
              "was renamed, or the arms moved.", file=sys.stderr)
        return 1

    bad, files = [], set()
    for c in calls:
        label = ev(c.args[0], consts) if c.args else None
        name = label or "<line %d>" % c.lineno
        if len(c.args) < 3:
            bad.append((c.lineno, name, "fewer than three positional arguments — "
                                        "this script cannot tell which file it plants in"))
            continue
        path, find = ev(c.args[1], consts), ev(c.args[2], consts)
        if path is None or find is None:
            which = "path" if path is None else "find"
            bad.append((c.lineno, name, "its %s is not statically resolvable, so "
                                        "nothing here can say the plant applies" % which))
            continue
        full = path if os.path.isabs(path) else os.path.join(REPO, path)
        if not os.path.isfile(full):
            bad.append((c.lineno, name, "plants into %s, which does not exist" % path))
            continue
        n = open(full, encoding="utf-8", errors="replace").read().count(find)
        if n != 1:
            bad.append((c.lineno, name,
                        "its anchor matches %dx in %s — the plant is a no-op, so the "
                        "arm runs the guard against an unmodified tree and proves "
                        "nothing" % (n, path)))
            continue
        files.add(path)

    if bad:
        print("check-control-anchors: %d control arm(s) cannot plant what they "
              "claim.\n" % len(bad), file=sys.stderr)
        for lineno, name, why in bad:
            print("  selftest-checks.py:%d  %s\n      %s" % (lineno, name, why),
                  file=sys.stderr)
        print("\nA control arm whose plant does not apply is the failure this repo "
              "calls BROKEN CONTROL: selftest runs the guard against an unmodified "
              "tree, the guard correctly says nothing, and the arm is reported as "
              "SILENT. Six arms were lost this way at once when the corpus was "
              "re-serialised at a different indent.", file=sys.stderr)
        return 1

    print("check-control-anchors: %d control arm(s) across %d file(s), every plant "
          "matches exactly once." % (len(calls), len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
