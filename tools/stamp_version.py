#!/usr/bin/env python3
"""
Tag a KIOU.app bundle's Info.plist so a "patched" install is visually
distinguishable from the stock one.

Run after extracting the source IPA in the patched-ipa flow; this tweaks
only CFBundleShortVersionString and is idempotent (re-runs with the same
inputs leave an already-stamped value alone; re-runs after editing the
source `patch_unity.py` re-stamp with a fresh content hash).

    1.0.1                       -> 1.0.1-patched.<sha7>
    1.0.1-patched.<old>         -> 1.0.1-patched.<new>   (re-stamp on hash change)
    1.0.1-patched.<sha7> (same) -> 1.0.1-patched.<sha7>  (no-op)

Without --tag-from the suffix is just "-patched" with no hash.

CFBundleVersion (the integer build number) is left alone. ldid / zsign /
Sideloadly all do plain-string comparisons on the build number when
deciding "is this an upgrade", and any non-digit suffix there has caused
flaky reinstall behaviour in the past. Keep that one boring.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import sys

SUFFIX_BASE = "-patched"
KEY = "CFBundleShortVersionString"

# Strips any prior "-patched" or "-patched.<7 hex>" suffix so re-runs always
# rebase from the original version string before applying the current hash.
_SUFFIX_RE = re.compile(re.escape(SUFFIX_BASE) + r"(?:\.[0-9a-f]{7})?$")


def short_hash(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()[:7]


def main() -> int:
    parser = argparse.ArgumentParser(description="KIOU.app Info.plist version stamper")
    parser.add_argument("plist", help="Path to Info.plist inside the staged KIOU.app")
    parser.add_argument(
        "--tag-from",
        metavar="FILE",
        help="Append .<sha7> derived from the contents of FILE (e.g. tools/patch_unity.py) "
             "so the version flips whenever the patch script changes.",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Report what would change without writing.",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.plist):
        print(f"error: not a file: {args.plist}", file=sys.stderr)
        return 2

    if args.tag_from:
        if not os.path.isfile(args.tag_from):
            print(f"error: --tag-from file missing: {args.tag_from}", file=sys.stderr)
            return 2
        suffix = f"{SUFFIX_BASE}.{short_hash(args.tag_from)}"
    else:
        suffix = SUFFIX_BASE

    with open(args.plist, "rb") as f:
        pl = plistlib.load(f)
        fmt = plistlib.FMT_BINARY  # Apple ships binary; preserve format.

    cur = pl.get(KEY)
    if not isinstance(cur, str):
        print(f"error: {KEY} missing or not a string in {args.plist}", file=sys.stderr)
        return 2

    # Strip any prior stamp so we can compare against the pristine version
    # and re-stamp cleanly. Without this, "1.0.1-patched.aaa" + new hash
    # "bbb" would produce "1.0.1-patched.aaa-patched.bbb".
    base = _SUFFIX_RE.sub("", cur)
    new = base + suffix
    tag = f"{KEY}: {cur!r} -> {new!r}"

    if cur == new:
        print(f"  SKIP   {KEY}={cur!r} (already stamped)")
        return 0

    if args.verify_only:
        print(f"  OK     {tag} (would stamp)")
        return 0

    pl[KEY] = new
    with open(args.plist, "wb") as f:
        plistlib.dump(pl, f, fmt=fmt)
    print(f"  STAMP  {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
