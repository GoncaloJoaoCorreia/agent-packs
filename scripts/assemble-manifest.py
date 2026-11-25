#!/usr/bin/env python3
"""Assemble manifest.json for a manifest release (G-113 M2).

Usage:
  assemble-manifest.py --out manifest.json --release vX.Y.Z --artifacts DIR \
      --changed "opencode vibe-acp" [--prev-manifest prev.json]

For every pack in --changed, reads DIR/<name>.meta.json ({version, description, asset,
sha256}) written by packs/<name>/scripts/release.sh. For every other pack discovered under
packs/*/pack.conf, carries the entry over from --prev-manifest (unchanged packs keep their
previous version + asset, which the workflow re-uploads from the previous release so every
release is self-contained). Without --prev-manifest, only the changed packs are listed.

Output schema:
  {"schema": 1, "release": "<tag>", "packs": {"<name>": {"asset", "description", "sha256",
   "version"}}}
"""
import argparse
import json
import os
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--release", required=True)
    ap.add_argument("--artifacts", required=True, help="dir with <pack>.meta.json + packs/<pack>.tar.gz")
    ap.add_argument("--changed", default="", help="space-separated changed pack names")
    ap.add_argument("--prev-manifest", default=None)
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    changed = args.changed.split()
    packs = {}

    prev = {}
    if args.prev_manifest:
        with open(args.prev_manifest, encoding="utf-8") as f:
            prev = json.load(f).get("packs", {})

    # every pack known to the repo
    all_packs = sorted(
        d for d in os.listdir(os.path.join(args.repo_root, "packs"))
        if os.path.isfile(os.path.join(args.repo_root, "packs", d, "pack.conf"))
    )

    for name in all_packs:
        if name in changed:
            frag = os.path.join(args.artifacts, f"{name}.meta.json")
            if not os.path.isfile(frag):
                print(f"FAIL: changed pack {name!r} has no meta fragment {frag}", file=sys.stderr)
                return 1
            with open(frag, encoding="utf-8") as f:
                packs[name] = json.load(f)
        elif name in prev:
            packs[name] = prev[name]
        # else: no previous entry and not changed -> not in this release

    for name in changed:
        if name not in packs:
            print(f"FAIL: changed pack {name!r} is not a known pack", file=sys.stderr)
            return 1

    manifest = {"schema": 1, "release": args.release, "packs": packs}
    with open(args.out, "w", encoding="utf-8") as f:
        # ensure_ascii=False keeps descriptions readable (the installer's awk parser
        # prints raw field values, so escaped \uXXXX would show up in --list)
        json.dump(manifest, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(f"manifest: release {args.release}, packs: {', '.join(sorted(packs)) or '(none)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
