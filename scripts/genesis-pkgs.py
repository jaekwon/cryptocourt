#!/usr/bin/env python3
"""Stage the package closure a genesis needs, prod sources only.

WHY THIS EXISTS. `gnogenesis txs add packages` sorts and type-checks the packages
it is given IN ONE INVOCATION, and it cannot see packages already written into
the genesis file. Adding them in batches — deps, then p/, then the realm — fails
every time with "missing dependency 'gno.land/p/nt/ufmt/v0' for package
'.../uassert/v0'", even when ufmt was added by the previous call. So the whole
closure has to be handed over at once, which means computing it.

AND TESTS ARE NOT PART OF IT. Copying *_test.gno drags their imports into the
dependency set — `p/nt/testutils/v0` appeared as a genesis dependency of
grc20votes purely through its test file. Excluding tests fixes that and is also
what belongs on a chain: kourtv2 is 2.1MB with tests and 780KB without.

Usage:
    genesis-pkgs.py <staging-dir> [--root gno.land/r/kourt/kourtv2] [--gno GNOROOT]
"""
import argparse
import glob
import os
import re
import shutil
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# An import is only an import inside the import block. A bare regex over the file
# also matches prose: grc20votes' doc comment contains the string
# "gno.land/r/you/realm.SYMBOL", which is not a package and does not resolve.
IMPORT_BLOCK = re.compile(r'^import\s*\(([^)]*)\)', re.M | re.S)
IMPORT_ONE = re.compile(r'^import\s+(?:\w+\s+)?"(gno\.land/[\w./-]+)"', re.M)
QUOTED = re.compile(r'"(gno\.land/[\w./-]+)"')


def source_dir(mod, gnoroot):
    """Where a module path's source lives, or None if this tree does not carry it."""
    if mod.startswith("gno.land/p/kourt/"):
        return os.path.join(REPO, "realm/p", mod.split("/")[3])
    if mod.startswith("gno.land/r/kourt/"):
        return os.path.join(REPO, "realm/r", mod.split("/")[3])
    p = os.path.join(gnoroot, "examples", mod)
    return p if os.path.isdir(p) else None


def stage(mod, src, dst_root):
    dst = os.path.join(dst_root, mod.replace("/", "_"))
    os.makedirs(dst, exist_ok=True)
    for f in glob.glob(os.path.join(src, "*.gno")):
        if f.endswith(("_test.gno", "_filetest.gno")):
            continue
        shutil.copy(f, dst)
    mod_file = os.path.join(src, "gnomod.toml")
    if os.path.exists(mod_file):
        shutil.copy(mod_file, dst)
    return dst


def imports_of(pkg_dir):
    out = set()
    for f in glob.glob(os.path.join(pkg_dir, "*.gno")):
        s = open(f, encoding="utf-8", errors="replace").read()
        for block in IMPORT_BLOCK.findall(s):
            out.update(QUOTED.findall(block))
        out.update(IMPORT_ONE.findall(s))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("staging")
    ap.add_argument("--root", action="append", default=None,
                    help="module path to close over (repeatable)")
    ap.add_argument("--gno", default=os.environ.get("GNOROOT", ""),
                    help="a gno checkout, for the examples/ packages")
    args = ap.parse_args()
    roots = args.root or ["gno.land/r/kourt/kourtv2"]
    if not args.gno or not os.path.isdir(os.path.join(args.gno, "examples")):
        sys.exit("genesis-pkgs: --gno must point at a gno checkout with examples/")

    shutil.rmtree(args.staging, ignore_errors=True)
    os.makedirs(args.staging, exist_ok=True)

    done, missing, queue = set(), set(), list(roots)
    while queue:
        mod = queue.pop()
        if mod in done or mod in missing:
            continue
        src = source_dir(mod, args.gno)
        if src is None or not os.path.isdir(src):
            missing.add(mod)
            continue
        done.add(mod)
        queue.extend(imports_of(stage(mod, src, args.staging)))

    if missing:
        # Fail loudly: a package silently left out of genesis is a chain that
        # boots and then cannot run the realm.
        sys.exit("genesis-pkgs: unresolved imports: " + ", ".join(sorted(missing)))

    total = sum(os.path.getsize(f) for f in glob.glob(os.path.join(args.staging, "*/*.gno")))
    print(f"genesis-pkgs: {len(done)} packages, {total:,} bytes (prod only)")
    for m in sorted(done):
        print("  " + m)


if __name__ == "__main__":
    main()
