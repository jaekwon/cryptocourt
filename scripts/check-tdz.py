#!/usr/bin/env python3
"""A top-level const must not be built from one declared below it.

WHY THIS EXISTS, AND IT IS NOT HYPOTHETICAL. Twice in one week:

    const REF_SET_MARKS = [SET_MARK, SHUT_MARK];   // SET_MARK is 10k lines below
    const DEMO = { ..., franchise:{ [DEMO_ME]: 41_637_004 }, ... };   // 30 below

`const` hoists into the temporal dead zone but is not initialised until its own
line runs, so an initialiser that runs AT LOAD and names a later const throws
"Cannot access 'X' before initialization" — and takes the whole script with it.

WHAT MAKES IT WORTH A GUARD RATHER THAN CARE. Both were invisible to every source
harness, and for the same reason: a harness evaluates a SLICE of this file and
sets the names it needs as globals first, so the ordering the browser enforces is
exactly the thing a harness cannot see. Both reached a deployed page. The first
was found by a browser check that happened to load the route; the second by
loading the page by hand. Nothing in `make check` would ever have said a word.

WHAT IS FLAGGED, AND WHAT IS DELIBERATELY NOT. Only initialisers that EVALUATE AT
LOAD. A reference from inside a function or arrow body is fine — by the time
anything calls it, every top-level const has run:

    const f = () => SET_MARK;        // fine, and the file is full of these
    const A = [SET_MARK];            // flagged
    const B = { k: [DEMO_ME] };      // flagged

So function and arrow bodies are cut out of the initialiser before it is read.
That is the whole of the cleverness here, and it is why this can run over a
twenty-thousand-line file without drowning the reader in noise.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = [ROOT / "web" / "index.html", ROOT / "web" / "chat.js"]

# A top-level declaration: `const NAME =` at column 0. Column 0 is the whole
# test — anything indented is inside something, and inside something is either a
# function body (lazy) or a block (its own scope).
DECL = re.compile(r"^(?:const|let)\s+([A-Za-z_$][\w$]*)\s*=", re.M)
IDENT = re.compile(r"[A-Za-z_$][\w$]*")

# Identifiers that are never a top-level const of ours; skipping them keeps the
# scan cheap and the message honest.
SKIP = {"true", "false", "null", "undefined", "new", "typeof", "return", "this",
        "function", "if", "else", "const", "let", "var", "of", "in", "await"}


def blank_text(src):
    """Blank string bodies and comments, keeping offsets and `${…}` interpolations.

    A guard that reads prose as code finds identifiers everywhere: the sample in
    this file is thousands of lines of court descriptions, and "DEMO" inside one
    of them was reported as a reference to the DEMO object.

    TEMPLATE INTERPOLATIONS STAY LIVE, and that is the one subtlety. `${X}` in a
    top-level template literal IS evaluated at load, so it is exactly the kind of
    reference this guard exists to catch — blanking the whole literal would hide
    the bug rather than the noise.
    """
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            for k in range(i, min(i + 2, n)):
                out[k] = " "
            i += 2
        elif c in "'\"":
            q, i = c, i + 1
            while i < n and src[i] != q:
                if src[i] == "\\":
                    out[i] = " "
                    i += 1
                if i < n and src[i] != "\n":
                    out[i] = " "
                i += 1
            i += 1
        elif c == "`":
            i += 1
            while i < n and src[i] != "`":
                if src[i] == "\\":
                    out[i] = " "
                    i += 1
                    if i < n:
                        out[i] = " "
                    i += 1
                    continue
                if src[i] == "$" and i + 1 < n and src[i + 1] == "{":
                    depth = 0                     # leave the interpolation alone
                    while i < n:
                        if src[i] == "{":
                            depth += 1
                        elif src[i] == "}":
                            depth -= 1
                            if depth == 0:
                                i += 1
                                break
                        i += 1
                    continue
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            i += 1
        else:
            i += 1
    return "".join(out)


def strip_lazy(src):
    """Blank out function and arrow bodies, leaving offsets intact.

    Offsets have to survive because the caller reports a line number, so bodies
    are overwritten with spaces rather than removed. Newlines are kept so line
    numbers still land.

    ARROWS ARE FOUND BY THEIR `=>` AND FUNCTIONS BY THEIR KEYWORD, then the body
    is taken as the braced block that follows — or, for a concise arrow body, to
    the end of the expression. A concise body cannot be found reliably without a
    parser, so the conservative thing happens instead: from `=>` to the end of
    the enclosing initialiser is blanked. That can only ever HIDE a reference,
    never invent one, which is the safe direction for a guard whose false
    positives cost a reader's afternoon.
    """
    out = list(src)
    for m in re.finditer(r"=>|\bfunction\b", src):
        i = m.end()
        while i < len(src) and src[i] in " \t\n":
            i += 1
        # ONLY `function` HAS ITS PARAMETERS AFTER THE KEYWORD. An arrow's are
        # BEFORE the `=>`, so a `(` following one opens a parenthesised BODY —
        # `(slug, id) => (DEMO.claims[…]||{}).board`. Consuming it as parameters
        # left the body unblanked and the guard reported that line as a bug on a
        # clean tree, which is the failure mode that gets a guard switched off.
        if m.group(0) == "function" and i < len(src) and src[i] == "(":
            depth = 0
            while i < len(src):
                if src[i] == "(":
                    depth += 1
                elif src[i] == ")":
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            while i < len(src) and src[i] in " \t\n":
                i += 1
        if i < len(src) and src[i] == "{":            # a braced body: blank it
            depth, j = 0, i
            while j < len(src):
                if src[j] == "{":
                    depth += 1
                elif src[j] == "}":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            end = j
        else:
            # A CONCISE ARROW BODY, BOUNDED. The first version ran this to the end
            # of the FILE, and since the file is full of arrows the first one
            # blanked everything after it — the guard then reported clean on both
            # of the bugs it was written for. Measured that way before it was
            # fixed, which is the only reason it is not still wrong.
            # The end of `x => expr` is the first comma or semicolon at the
            # arrow's own depth, or the bracket that closes the thing it sits in.
            depth, j = 0, i
            while j < len(src):
                c = src[j]
                if c in "([{":
                    depth += 1
                elif c in ")]}":
                    if depth == 0:
                        break
                    depth -= 1
                elif c in ",;" and depth == 0:
                    break
                j += 1
            end = j
        for k in range(i, min(end, len(src))):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def initialiser(src, eq):
    """The text from `=` to the end of that declaration.

    Bracket-matched rather than scanned to the next `;`, because the sample data
    is a single object literal thousands of lines long with semicolons inside it.
    """
    i, depth = eq, 0
    while i < len(src):
        c = src[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth <= 0:
            return src[eq:i]
        i += 1
    return src[eq:]


def main():
    bad = []
    scanned = 0
    for path in FILES:
        if not path.exists():
            continue
        src = path.read_text(encoding="utf8")
        decls = {}
        for m in DECL.finditer(src):
            decls.setdefault(m.group(1), m.start())
        scanned += len(decls)
        lazy = strip_lazy(blank_text(src))
        for m in DECL.finditer(src):
            name, at = m.group(1), m.start()
            body = initialiser(lazy, m.end())
            for ref in IDENT.finditer(body):
                r = ref.group(0)
                if r in SKIP or r == name or r not in decls:
                    continue
                if decls[r] > at:                      # declared BELOW this one
                    line = src.count("\n", 0, at) + 1
                    rline = src.count("\n", 0, decls[r]) + 1
                    bad.append((path.name, line, name, r, rline))
                    break
    if bad:
        print("check-tdz: %d top-level const(s) built from a name declared below:"
              % len(bad))
        for fname, line, name, ref, rline in bad:
            print("  %s:%d  `%s` reads `%s`, which is declared at line %d"
                  % (fname, line, name, ref, rline))
        print("\n  This throws \"Cannot access '%s' before initialization\" on load"
              % bad[0][3])
        print("  and takes the whole script with it. No source harness can see it:")
        print("  a harness evaluates a slice and sets the names it needs as globals")
        print("  first, so the ordering the browser enforces is the one thing it")
        print("  cannot test. Move the declaration, or read the name inside a")
        print("  function body where it is evaluated after everything has run.")
        return 1
    print("check-tdz: %d top-level declaration(s) across %d file(s); every one is "
          "built only from names declared above it." % (scanned, len(FILES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
