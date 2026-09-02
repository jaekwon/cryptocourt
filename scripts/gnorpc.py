"""One vm/qeval client, for the scripts that read a live chain.

WHY THIS FILE EXISTS. check-live-reads.py and dump-demo.py each hand-rolled the
same client: the same base64 payload, the same abci_query body with
`"height": "0", "prove": false`, the same Content-Type, the same 20-second
timeout, the same walk down result.response then ResponseBase, the same Data
fallback, the same base64 decode with errors="replace" -- and the same TYPED
regex sitting beside it, byte for byte.

THEY HAD ALREADY DRIFTED, which is the argument. check-live-reads grew a branch
for "the node answered with neither an Error nor a Data field" and dump-demo did
not, so dump-demo died on base64.b64decode(None) with a TypeError about
bytes-like objects -- a stack trace about base64 for what is actually "the node
answered nothing". Fixed in one copy in 3b92b84; this removes the second copy so
the next improvement cannot land in only one of them.

NOT the same call as the five guards that share an import preamble. That is
boilerplate -- `import io, os, re, sys` and a ROOT -- and those guards are
standalone on purpose, so a shared lib would trade seven lines of noise for an
import dependency in each. This is BEHAVIOUR, with error semantics, and
behaviour is what drifts.

IT RAISES. The two callers want opposite things -- a guard reports and keeps
going, a generator must abort -- and one of those is expressible in terms of the
other while the reverse is not: check-live-reads catches and returns
(None, message), which no amount of returning could give dump-demo. So the
shared function raises and the guard adapts.

Importable with a bare `import gnorpc` from either script: sys.path[0] is the
script's own directory under `python3 scripts/X.py`, so neither stops being
independently runnable and nothing has to be packaged.
"""
import base64
import json
import re
import urllib.request

# The realm's own answer format: `(value type)` per line. Both callers parse it.
TYPED = re.compile(r"^\((.*)\s+([A-Za-z0-9_./\[\]]+)\)$", re.S)


class QevalError(RuntimeError):
    """A read that did not come back with a value.

    One type for all three ways it can fail -- transport, the realm's own
    refusal, and an answer carrying no Data -- because every caller so far
    treats them the same way, and a caller that needs to tell them apart can
    read the message rather than have three exception classes imposed on it.
    """


def qeval(remote, realm, expr, timeout=20, req_id="gnorpc"):
    """Evaluate `realm.expr` on the node at `remote`; return its text.

    Raises QevalError with a message fit to print. Messages are collapsed to one
    line and truncated to 140 characters: these land in a guard's stderr next to
    the probe that failed, and a multi-line panic pushes the useful line off the
    top of the screen.
    """
    # BOTH DIRECTIONS ARE BASE64 -- the same thing the overlay's own abci() does.
    # Sending the expression raw comes back "illegal base64 data".
    payload = base64.b64encode(f"{realm}.{expr}".encode()).decode()
    body = json.dumps({"jsonrpc": "2.0", "id": req_id, "method": "abci_query",
                       "params": {"path": "vm/qeval", "data": payload,
                                  "height": "0", "prove": False}}).encode()
    req = urllib.request.Request(remote, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        j = json.loads(r.read())
    if j.get("error"):
        raise QevalError(str(j["error"].get("message") or j["error"])[:140])
    r = (j.get("result") or {}).get("response") or {}
    # TWO PLACES FOR THE SAME FIELD, and it has to be both: the node nests the
    # payload under ResponseBase on some versions and hoists it on others, so a
    # client reading only one of them reports an empty answer against half the
    # chains it can reach.
    rb = r.get("ResponseBase") or {}
    err = r.get("Error") or rb.get("Error")
    if err:
        log = r.get("Log") or rb.get("Log") or str(err)
        raise QevalError(" ".join(str(log).split())[:140])
    data = r.get("Data") if r.get("Data") is not None else rb.get("Data")
    # NO Data AND NO Error is a real answer shape. Without this the decode below
    # raises "TypeError: argument should be a bytes-like object or ASCII string,
    # not 'NoneType'" -- base64's complaint about what is really "the node
    # answered nothing". This is the branch the two copies disagreed about.
    if data is None:
        raise QevalError("no Data in response")
    return base64.b64decode(data).decode("utf-8", "replace")
