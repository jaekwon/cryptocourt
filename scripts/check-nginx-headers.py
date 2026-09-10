#!/usr/bin/env python3
"""A security header nginx never sends is not a security header.

nginx's add_header inherits from the enclosing level ONLY while the current
level declares none of its own. Declare one add_header inside a location and
every inherited one vanishes from that location — silently, with no warning
from `nginx -t`, and visible only by asking the running host what it sent.

WHAT THIS COST, measured on kourt.xyz rather than reasoned about. The server
block set three headers: a Content-Security-Policy, nosniff and a referrer
policy. Three locations then declared a Cache-Control of their own:

  /index.html      kept nosniff and referrer-policy, LOST the CSP
  /chat.js         kept nosniff and referrer-policy, LOST the CSP
  /embed/covid/1   declared Cache-Control alone, LOST ALL THREE
  /favicon.ico     kept all three — it declares no add_header
  /api/chat/diag   kept all three — it declares no add_header

so the two responses on the whole host still carrying a policy were an icon and
a JSON body. The document that executes every line of script and renders public
prose had none, and the embed route — built to be rendered inside somebody
else's page — had no nosniff either.

WHY IT SURVIVED A GUARD LOOKING RIGHT AT IT. check-media-hosts proves the
policy's img-src, media-src and connect-src agree with the realm's allowlist and
the composer's. It reads the FIRST add_header Content-Security-Policy it finds
and checks its contents. A correct policy in a location that never sends it
passes that perfectly. Contents and delivery are two questions, and only one was
being asked. This asks the other one.

THE FIX WAS NOT REPETITION, and that is worth saying because repetition was
tried first. Repeating the policy into each declaring location works and passes
this guard — and it broke two things that need the policy to be unique:
selftest's control arms plant into it and refuse an anchor matching more than
once, and check-media-hosts validates only the first copy. Four copies is a
policy that quietly stops being checked. So the three headers live in ONE file,
`include`d at every level that has to declare them.

WHAT THIS ENFORCES, then:

  1. The snippet declares every security header. It is the only home for them.
  2. The server level includes the snippet.
  3. Every location that declares ANY add_header also includes it. That is
     nginx's inheritance rule, restated as an assertion.
  4. No location declares a security header inline. Inline is how the drift
     started; there is one home, and this keeps it the only one.
  5. setup.sh installs the snippet at exactly the path nginx.conf includes.
     An include of a missing file is a hard `nginx -t` failure, and setup.sh
     runs its remote half under `bash -seu`, so it aborts before the reload —
     it cannot half-apply. This arm is what keeps that true.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NGINX = os.path.join(ROOT, "deploy", "nginx.conf")
SNIPPET = os.path.join(ROOT, "deploy", "nginx-security-headers.conf")
SETUP = os.path.join(ROOT, "deploy", "setup.sh")

# The headers this guard is about. A Cache-Control differing per location is the
# POINT of those blocks, so it is not a security header and not required here.
SECURITY = ("Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy")

ADD = re.compile(r"^\s*add_header\s+(\S+)\s+(.*?);\s*$")
LOC = re.compile(r"^\s*location\s+(.*?)\s*\{")
INC = re.compile(r"^\s*include\s+(\S+);\s*$")


def parse(path):
    """Server-level directives, and each location block's.

    A hand-rolled brace walk rather than a real nginx parser: this file is one
    server block with flat locations, and a dependency-free check is one that
    still runs in five years. Comments are stripped first — the policy value
    contains no '#', and every '#' in this file starts a comment.
    """
    server = {"headers": {}, "includes": [], "name": "server", "line": 0}
    locs, stack = [], []
    for n, raw in enumerate(open(path), 1):
        line = raw.split("#", 1)[0]
        if not line.strip():
            continue
        m = LOC.match(line)
        if m:
            stack.append({"name": m.group(1), "line": n, "headers": {}, "includes": []})
            continue
        m = ADD.match(line)
        if m:
            name, value = m.group(1), m.group(2).strip()
            # `always` is a flag on the directive, not part of the value.
            if value.endswith(" always"):
                value = value[: -len(" always")].strip()
            (stack[-1] if stack else server)["headers"][name] = (value.strip('"'), n)
            continue
        m = INC.match(line)
        if m:
            (stack[-1] if stack else server)["includes"].append((m.group(1), n))
            continue
        for _ in range(line.count("}")):
            if stack:
                locs.append(stack.pop())
        # A nested block inside a location (none today) must not be mistaken for
        # the location itself closing.
        for _ in range(line.count("{")):
            if stack:
                stack.append(stack[-1])
    return server, locs


def headers_in(path):
    out = {}
    for n, raw in enumerate(open(path), 1):
        m = ADD.match(raw.split("#", 1)[0])
        if m:
            out[m.group(1)] = n
    return out


def main():
    # THE GUARD'S OWN LIST IS PINNED, spelled out a second time on purpose.
    # Emptying SECURITY disarms every assertion below and the script still exits
    # 0 — measured, in this file's own ablation: `SECURITY = ()` printed "all 0
    # server-level security header(s)" and passed. An expectation written in
    # terms of the constant under test moves with it, so these three names are
    # literals here, which is the one arm a future deletion cannot take with it.
    for name in ("Content-Security-Policy", "X-Content-Type-Options", "Referrer-Policy"):
        if name not in SECURITY:
            sys.exit(
                "check-nginx-headers: %s was removed from SECURITY, which silently "
                "switches this guard off rather than failing. If a header is "
                "genuinely no longer wanted, delete it from the config and from "
                "this list in the same commit, and say why." % name
            )

    bad = []

    # RULE 1. The snippet is the only home for these headers.
    if not os.path.exists(SNIPPET):
        sys.exit("check-nginx-headers: %s is missing" % os.path.relpath(SNIPPET, ROOT))
    snippet_headers = headers_in(SNIPPET)
    absent = [h for h in SECURITY if h not in snippet_headers]
    if absent:
        sys.exit(
            "check-nginx-headers: the snippet declares no "
            + ", ".join(absent)
            + " — this guard is measuring nothing. If the headers moved, point it "
            "at their new home rather than deleting the check."
        )

    server, locs = parse(NGINX)
    want = os.path.basename(SNIPPET).replace("nginx-", "kourt-")
    included = [(p, n) for p, n in server["includes"] if p.endswith(want)]

    # RULE 2.
    if not included:
        bad.append(
            "  the server block does not include the security headers\n"
            "    nothing on this host would carry a Content-Security-Policy."
        )
    path_used = included[0][0] if included else None

    # RULES 3 and 4.
    declaring = [l for l in locs if l["headers"]]
    if not declaring:
        sys.exit(
            "check-nginx-headers: no location declares an add_header, so nginx's "
            "inheritance rule cannot bite and this guard proves nothing. The file "
            "shape changed; re-read it."
        )
    for loc in declaring:
        if not any(p.endswith(want) for p, _ in loc["includes"]):
            bad.append(
                "  location %s (line %d) declares %s but does not include the "
                "security headers\n    nginx drops every inherited add_header from "
                "a level that declares one of its own, so this location sends none "
                "of %s."
                % (
                    loc["name"],
                    loc["line"],
                    ", ".join(sorted(loc["headers"])),
                    ", ".join(SECURITY),
                )
            )
        for h in SECURITY:
            if h in loc["headers"]:
                bad.append(
                    "  location %s declares %s inline at line %d\n"
                    "    there is one home for it: %s. An inline copy is how this "
                    "drifted in the first place."
                    % (loc["name"], h, loc["headers"][h][1], os.path.relpath(SNIPPET, ROOT))
                )
    for h in SECURITY:
        if h in server["headers"]:
            bad.append(
                "  the server block declares %s inline at line %d, instead of "
                "including it\n    two homes for one policy is the drift this "
                "guard exists to refuse." % (h, server["headers"][h][1])
            )

    # RULE 5. The include names an absolute path on the server; setup.sh is what
    # puts a file there. A config that includes a file nothing installs is a
    # server that will not start.
    if path_used:
        setup = open(SETUP).read()
        if path_used not in setup:
            bad.append(
                "  nginx.conf includes %s but deploy/setup.sh never installs it\n"
                "    nginx refuses to start on a missing include, so this would "
                "take the site down at the next setup rather than degrade."
                % path_used
            )

    if bad:
        sys.exit(
            "check-nginx-headers: a header declared but never delivered\n"
            + "\n".join(bad)
            + "\n\nMeasured on the live host, not read off the file: curl -I the "
            "route and look for the header before deciding this is wrong."
        )

    print(
        "check-nginx-headers: %d security header(s) in one file, included by the "
        "server block and by all %d location(s) that declare an add_header of "
        "their own; setup.sh installs it at %s."
        % (len(SECURITY), len(declaring), path_used)
    )


if __name__ == "__main__":
    main()
