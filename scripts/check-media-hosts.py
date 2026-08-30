#!/usr/bin/env python3
"""The hosts a claim's evidence may live on are written down THREE times, and
all three have to agree.

  realm/r/kourtv2/media.gno   refuses to STORE a mirror on any other host
  web/media.js                refuses to OFFER one, in front of the person
  deploy/nginx.conf           the browser refuses to LOAD one, via img-src

Each copy exists for a reason none of the others can serve. The realm's is the
only one an attacker cannot edit. The overlay's is the only one that can say so
while the author can still choose another host. The CSP is the only one the
browser obeys.

WHAT DRIFT LOOKS LIKE, and why it is silent. Add a host to the realm and forget
the CSP: the claim files, the page renders an <img>, the browser refuses it, and
the realm gets NO signal — the author sees a broken image and no error anywhere.
Add it to the CSP and forget the realm: the composer offers a host the chain then
refuses, after the person has written their claim. Neither shows up in any test
that does not compare the files, which is what this does.

gnoweb's own cspImgHost is the upstream of all three and lives in another repo,
so it cannot be checked here. When it moves, this guard is what makes updating
every copy a single visible edit rather than three separate ones somebody
remembers.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GNO = os.path.join(ROOT, "realm", "r", "kourtv2", "media.gno")
JS = os.path.join(ROOT, "web", "media.js")
NGINX = os.path.join(ROOT, "deploy", "nginx.conf")


def go_list(src, name):
    m = re.search(r"var\s+" + name + r"\s*=\s*\[\]string\{(.*?)\}", src, re.S)
    if not m:
        sys.exit(f"check-media-hosts: {name} not found in media.gno")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def js_list(src, name):
    m = re.search(r"const\s+" + name + r"\s*=\s*\[(.*?)\]", src, re.S)
    if not m:
        sys.exit(f"check-media-hosts: {name} not found in media.js")
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def main():
    gno = open(GNO).read()
    js = open(JS).read()
    nginx = open(NGINX).read()

    # THE DEFAULTS, not the live lists. The allowlist is an admin parameter now
    # (owner ruling, CLAIM_MEDIA §10.1), so what a running realm allows is on
    # chain and can differ from any file. What this guard can still hold — and
    # what matters — is that the three copies which SHIP agree: the realm's
    # defaults, the overlay's fallback, and the page's own CSP. A host added on
    # chain without a matching CSP change is the admin's to get right, and
    # SetMediaHosts says so in as many words.
    gno_exact = go_list(gno, "defaultMediaHostsExact")
    gno_suffix = go_list(gno, "defaultMediaHostSuffixes")
    js_exact = js_list(js, "MEDIA_HOSTS_EXACT")
    js_suffix = js_list(js, "MEDIA_HOST_SUFFIXES")

    problems = []
    if gno_exact != js_exact:
        problems.append("  exact hosts: realm-only %s, overlay-only %s" % (
            sorted(gno_exact - js_exact) or "-", sorted(js_exact - gno_exact) or "-"))
    if gno_suffix != js_suffix:
        problems.append("  host suffixes: realm-only %s, overlay-only %s" % (
            sorted(gno_suffix - js_suffix) or "-", sorted(js_suffix - gno_suffix) or "-"))

    # The CSP writes a suffix as a wildcard label: ".imgur.com" -> "*.imgur.com".
    #
    # Read the DIRECTIVE, not the first mention of it: "img-src" also appears in
    # the comment above the header, and matching that found a list with no hosts
    # in it and reported every host missing. The header is the quoted string in
    # add_header Content-Security-Policy.
    header = re.search(r'add_header\s+Content-Security-Policy\s+"([^"]*)"', nginx)
    if not header:
        sys.exit("check-media-hosts: no Content-Security-Policy header in nginx.conf")
    policy = header.group(1)
    csp = re.search(r"img-src([^;]*)", policy)
    if not csp:
        sys.exit("check-media-hosts: no img-src directive in nginx.conf")
    served = set(re.findall(r"https://(\S+)", csp.group(1)))
    want = gno_exact | {"*" + s for s in gno_suffix}
    missing = sorted(want - served)
    if missing:
        problems.append(
            "  the page's img-src is missing %s — the realm would store a mirror "
            "there that the browser then refuses to load, with no signal to "
            "either side" % missing)

    # media-src has to carry the same hosts as img-src. The realm validates a
    # video exhibit's URL against the SAME allowlist, so a host the chain will
    # store and the browser will not play means an exhibit that is filed and
    # unwatchable — with no signal to either side, which is this guard's whole
    # subject.
    msrc = re.search(r"media-src([^;]*)", policy)
    if not msrc:
        problems.append(
            "  no media-src in nginx.conf: it falls back to default-src 'self', "
            "so a video exhibit is filed and cannot be played")
    else:
        vmissing = sorted(want - set(re.findall(r"https://(\S+)", msrc.group(1))))
        if vmissing:
            problems.append(
                "  the page's media-src is missing %s — the realm would store a "
                "video there that the browser then refuses to play" % vmissing)

    # connect-src has to be SET. Without it the directive falls back to
    # default-src 'self', and the node this page reads lives on another origin,
    # so every chain read is refused by the page's own policy. That was true in
    # this file for a while and nothing caught it.
    if "connect-src" not in policy:
        problems.append(
            "  no connect-src in nginx.conf: it falls back to default-src 'self' "
            "and the overlay cannot reach an RPC node on any other origin")

    # The archive is served from 'self'; without the route nothing answers the
    # address gnoweb's markdown points every reader at.
    if "location /m " not in nginx and "location /m\n" not in nginx and "location /m{" not in nginx:
        problems.append(
            "  no /m location in nginx.conf: the archive is unreachable and every "
            "exhibit on every claim page is a broken image")

    # THE WIRE FORMAT HAS A FIFTH IMPLEMENTATION. scenario.py builds the same
    # eight fields web/media.js builds and realm/r/kourtv2 parses, so a demo can
    # seed evidence — and a scenario that wrote them differently would seed a
    # demo the product could not have produced, which is the one thing a demo
    # must never do.
    #
    # The realm's own suite pins these two strings as clientImageLine and
    # clientVideoLine, and the overlay's suite asserts it still builds them.
    # This is the third holder.
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "scenario_mod", os.path.join(ROOT, "scripts", "scenario.py"))
    mod = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        pass
    want_img = ("img|1111111111111111111111111111111111111111111111111111111111111111|"
                "image/webp|800|600|90210|the memo|https://i.imgur.com/abc.webp")
    want_vid = "vid|||0|0|0|the hearing|https://i.imgur.com/v.mp4"
    got_img = mod.media_arg([{"sha256": "1" * 64, "mime": "image/webp", "w": 800,
                              "h": 600, "bytes": 90210, "caption": "the memo",
                              "mirrors": ["https://i.imgur.com/abc.webp"]}])
    got_vid = mod.media_arg([{"kind": "vid", "caption": "the hearing",
                              "mirrors": ["https://i.imgur.com/v.mp4"]}])
    if got_img != want_img:
        problems.append("  scenario.py builds an image line the realm does not "
                        "parse:\n    got  %s\n    want %s" % (got_img, want_img))
    if got_vid != want_vid:
        problems.append("  scenario.py builds a video line the realm does not "
                        "parse:\n    got  %s\n    want %s" % (got_vid, want_vid))
    # And the strings above must still be the ones the realm suite holds.
    # EVERY PLACE THIS EXACT LINE LIVES, and there are more than the comment
    # above counted. Each holder is a separate program that has to agree with the
    # others about eight fields and one separator; each was written to the spec
    # and checked against the spec, which proves the spec is self-consistent and
    # nothing about whether they agree with each other.
    #
    # The txtar is the one that mattered most and was pinned least. It files a
    # claim carrying this argument against a REAL node, so it is the proof that
    # the realm accepts what the composer builds — and it held its own hand-typed
    # copy. Change the field order, update web/media.js and its suite together,
    # and the txtar would go on proving the realm accepts the OLD format while
    # every suite stayed green and the client and the chain had diverged.
    # Two of the holders build their copy by concatenation rather than writing it
    # as one literal — the realm suite splits after the hash, the overlay suite
    # uses "1".repeat(64) — so for those the TAIL is what is compared. Everything
    # after the hash is where the field order and the separator live, which is
    # exactly what drift would move.
    tail = want_img.split("|", 2)[2]
    holders = [
        (os.path.join("gnoland", "testdata", "kourtv2_media.txtar"), want_img,
         "the image line it files against a real node"),
        (os.path.join("realm", "r", "kourtv2", "media_test.gno"), want_vid,
         "the video line"),
        (os.path.join("realm", "r", "kourtv2", "media_test.gno"), tail,
         "the image line's fields"),
        (os.path.join("web", "tests", "media_test.js"), tail,
         "the image line's fields"),
    ]
    for rel, want, which in holders:
        if want not in open(os.path.join(ROOT, rel)).read():
            problems.append("  %s no longer carries %s:\n    want %s"
                            % (rel, which, want))

    if problems:
        print("check-media-hosts: the three copies of the media host list disagree.",
              file=sys.stderr)
        for p in problems:
            print(p, file=sys.stderr)
        return 1

    print("check-media-hosts: %d host(s) and %d suffix(es) agree across the realm, "
          "the overlay and the page CSP; /m is routed; and the five holders of "
          "the wire format — media.gno, media.js, scenario.py, the realm suite "
          "and the txtar — carry the same line."
          % (len(gno_exact), len(gno_suffix)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
