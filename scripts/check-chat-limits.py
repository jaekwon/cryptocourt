#!/usr/bin/env python3
"""The chat limits are written twice, in two languages. Hold them together.

internal/chat/sanitize.go is the authority — it is what actually refuses a
message — and web/chat.js restates the same three numbers so the input can stop
typing before a round trip:

    MaxBodyRunes    = 400        CHATLIMITS.body    = 400
    MaxMonikerRunes = 24         CHATLIMITS.moniker = 24
    MaxInputBytes   = 4096       CHATLIMITS.bytes   = 4096

THIS ADDS A CHECK RATHER THAN REMOVING A COPY, which is the wrong direction for
a sweep that prefers deletions, so the reason is worth stating: the copy cannot
be removed. web/README.md promises the overlay is "no build, no dependencies,
just share the file", so chat.js cannot import a Go constant, and there is no
generation step to make one from the other. The duplication is a consequence of
a promise the product makes. What is available is to stop it drifting.

AND IT HAS DRIFTED. chat_render.js asserted that the moniker input's `maxlength`
equalled the server's limit, and that stopped being true when the limit moved to
counting LETTERS while the attribute stayed a looser paste bound. The assertion
was wrong for two commits and nothing said so — it was found only when four chat
harnesses were run for the first time in a while (c001f3e). A number restated in
a second language is the same hazard doc.gno's numbers were, and
check-docnumbers is the precedent for holding them together rather than hoping.

WHAT THIS DOES NOT CHECK. Only that the numbers match. Whether 400 runes is the
right bound, whether the client counts the same UNITS the server does — chat.js
deliberately sets the `maxlength` attribute to CHATLIMITS.moniker * 4, because
the attribute counts UTF-16 units and the server counts runes, and an Arabic
name of 24 runes needs more than 24 units to be typeable — none of that is here.
That multiplier is exactly the kind of intended divergence a stricter check would
flag as a defect, which is why this compares the declared limits and not their
uses.

    python3 scripts/check-chat-limits.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GO = os.path.join(ROOT, "internal", "chat", "sanitize.go")
JS = os.path.join(ROOT, "web", "chat.js")

# Go: `MaxBodyRunes    = 400` inside a const block.
GO_CONST = re.compile(r"^\s*(Max\w+)\s*=\s*(\d+)", re.M)
# JS: `const CHATLIMITS = {body: 400, moniker: 24, bytes: 4096};`
JS_LIMITS = re.compile(r"const CHATLIMITS\s*=\s*\{([^}]*)\}")

PAIRS = [("MaxBodyRunes", "body"), ("MaxMonikerRunes", "moniker"),
         ("MaxInputBytes", "bytes")]

for p in (GO, JS):
    if not os.path.exists(p):
        sys.exit("check-chat-limits: %s is missing" % p)

go = dict((m.group(1), int(m.group(2))) for m in GO_CONST.finditer(
    io.open(GO, encoding="utf-8").read()))
m = JS_LIMITS.search(io.open(JS, encoding="utf-8").read())
if not m:
    sys.exit("check-chat-limits: no `const CHATLIMITS = {...}` in web/chat.js — "
             "the scan has lost its anchor and would pass having compared "
             "nothing, which is worse than not checking")
js = dict((k.strip(), int(v)) for k, v in re.findall(r"(\w+)\s*:\s*(\d+)", m.group(1)))

bad, checked = [], 0
for goname, jsname in PAIRS:
    if goname not in go:
        bad.append("%s is not declared in internal/chat/sanitize.go — it was "
                   "renamed or removed, and chat.js still restates its value"
                   % goname)
        continue
    if jsname not in js:
        bad.append("CHATLIMITS.%s is missing from web/chat.js, but the server "
                   "still enforces %s = %d" % (jsname, goname, go[goname]))
        continue
    checked += 1
    if go[goname] != js[jsname]:
        bad.append("%s = %d in the server, CHATLIMITS.%s = %d in the client — "
                   "the input stops at one bound and the server refuses at "
                   "another" % (goname, go[goname], jsname, js[jsname]))

if bad:
    print("check-chat-limits: the client and the server disagree about a limit",
          file=sys.stderr)
    for b in bad:
        print("  " + b, file=sys.stderr)
    print("  internal/chat/sanitize.go is the authority: it is what refuses a "
          "message. web/chat.js restates it so typing stops early.", file=sys.stderr)
    sys.exit(1)

if checked != len(PAIRS):
    sys.exit("check-chat-limits: compared only %d of %d limits — a partial "
             "comparison reported as a clean one is the failure this exists to "
             "prevent" % (checked, len(PAIRS)))

print("check-chat-limits: %d limit(s) agree between internal/chat/sanitize.go "
      "and web/chat.js (%s)." % (checked, ", ".join(
          "%s=%d" % (j, js[j]) for _, j in PAIRS)))
