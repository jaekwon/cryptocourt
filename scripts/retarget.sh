#!/usr/bin/env bash
# Build a deploy-ready copy of the realm and its libraries under a chosen
# namespace.
#
# WHY THIS IS A SCRIPT AND NOT AN EDIT. A Gno import path is a compile-time
# literal: `gno.land/p/kourt/curve/v0` cannot be parameterised at deploy time.
# gnomod.toml's [[replace]] looks like the answer and is not — it redirects an
# import to a LOCAL path for development and makes addpkg fail on-chain, so it
# must be stripped before deploying. That leaves rewriting the literals, and a
# rewrite done by hand is a rewrite done differently each time.
#
# The repo keeps ONE canonical path (gno.land/{p,r}/kourt/...). This writes a
# retargeted tree beside it; nothing in the working copy is touched.
#
#   scripts/retarget.sh g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6   # own-address
#   scripts/retarget.sh kourt                                      # the name, once held
#
# ON PEARL THE NAMESPACE MUST BE THE ADDRESS. Namespace enforcement is on there
# and the public registrar only sells names matching nym-[a-z]{5,13}\d{3}, so
# `kourt` cannot be registered — but r/<your-g1address>/* is authorized on every
# chain with no registration at all.
set -euo pipefail

NS="${1:-}"
# THE KEY NAME IS AN ARGUMENT so the printed commands paste and run. They
# ended in a literal <yourkey>, and zsh reads < and > as redirections — so
# pasting one produced "zsh: parse error" rather than anything about a key.
# A placeholder that cannot survive a copy-paste is worse than none.
KEY="${2:-YOURKEY}"
[ -n "$NS" ] || { echo "usage: $0 <namespace> [keyname]   (a g1… address, or a registered name)" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/build/$NS}"

# THE FIVE THE REALM ACTUALLY IMPORTS, in dependency order — checkpoint before
# grc20votes before governor, because addpkg type-checks against what is already
# on chain and a missing import is a failed deploy rather than a warning.
# cshares and tickbook are in realm/p/ and are imported by nothing here; they are
# not deployed, so they cost no storage deposit and cannot fail.
LIBS=(checkpoint curve twap grc20votes governor)
REALM_SRC="realm/r/kourtv2"
REALM_DST="kourt"     # the v0 name goes; the path is <ns>/kourt

rm -rf "$OUT"; mkdir -p "$OUT/p" "$OUT/r"
for l in "${LIBS[@]}"; do cp -R "$ROOT/realm/p/$l" "$OUT/p/$l"; done
cp -R "$ROOT/$REALM_SRC" "$OUT/r/$REALM_DST"

# TESTS DO NOT SHIP. Whether addpkg uploads *_test.gno is not something to leave
# to the toolchain's mood: they are not part of the contract, they would cost
# storage deposit to keep on chain, and they are the only files here that name
# paths this rewrite deliberately does not touch — the `// PKGPATH:` directives
# of sibling filetest packages, and NewCodeRealm("…/notacourt"), which is meant
# to be a realm this one does NOT own and would be wrong to retarget.
find "$OUT" -type f \( -name '*_test.gno' -o -name '*_filetest.gno' \) -delete

# Every literal, in sources AND in each gnomod.toml `module` line. The realm's
# two self-path constants (metaRealmPath, burnSinkPath) are the same string and
# are rewritten by the same pass — they feed chain.PackageAddress(), so a path
# that does not match where the realm actually lives derives an escrow address
# nobody controls.
find "$OUT" -type f \( -name '*.gno' -o -name '*.toml' -o -name '*.md' \) -print0 |
  xargs -0 sed -i '' \
    -e "s|gno\.land/p/kourt/|gno.land/p/$NS/|g" \
    -e "s|gno\.land/r/kourt/kourtv2|gno.land/r/$NS/$REALM_DST|g"

# AND THE PACKAGE CLAUSE, because gno requires it to match the LAST path element:
#   package name "kourtv2" does not match path element "kourt"
#     (code=gnoPackageNameMismatchError)
# An earlier version of this script left it alone, reasoning that a package name
# is a Go identifier and a g1 address is not a legal one — true of the NAMESPACE
# segment, irrelevant to the last element, and `gno lint` said so immediately.
# The libraries are unaffected: their paths end in /v0 and gno matches against
# the element before the version.
find "$OUT/r/$REALM_DST" -name '*.gno' -print0 |
  xargs -0 sed -i '' -e "s|^package kourtv2$|package $REALM_DST|"
# A WORKSPACE, so the tree resolves against itself. Without gnowork.toml each
# directory is in single-package mode: it resolves stdlib and its own files, and
# an import of a sibling is looked for in $GNOHOME/pkg/mod — so `gno lint` tries
# to DOWNLOAD gno.land/p/<ns>/checkpoint/v0 from a chain that does not have it
# yet and fails on a package sitting in the next directory. The toolchain matches
# by the declared `module` path, not by directory name, which is why this works
# with the layout as copied.
# It is a local build artifact and is not deployed — addpkg uploads one package
# directory at a time and never sees this file.
: > "$OUT/gnowork.toml"

echo "built $OUT"
echo
echo "deploy in this order (dependencies first):"
for l in "${LIBS[@]}"; do
  echo "  gnokey maketx addpkg -pkgdir $OUT/p/$l -pkgpath gno.land/p/$NS/$l/v0 \\"
  echo "    -gas-fee 1000000ugnot -gas-wanted 20000000 -broadcast -chainid pearl-1 \\"
  echo "    -remote https://rpc.pearl.testnets.gno.land:443 $KEY"
done
echo "  gnokey maketx addpkg -pkgdir $OUT/r/$REALM_DST -pkgpath gno.land/r/$NS/$REALM_DST \\"
echo "    -gas-fee 1000000ugnot -gas-wanted 200000000 -broadcast -chainid pearl-1 \\"
echo "    -remote https://rpc.pearl.testnets.gno.land:443 $KEY"
