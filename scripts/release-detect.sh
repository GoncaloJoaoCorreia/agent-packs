#!/bin/sh
# scripts/release-detect.sh — classify the diff baseline..HEAD into changed packs (G-113 M2).
#
# Env:  REPO_ROOT (default: repo root of this script), BASELINE (default: latest v* tag;
#       no baseline and no tags -> whole history)
# Out:  prints "release=1" plus "packs=<space-separated names|all>" (+ "infra=1") when the
#       diff touches pack payloads or infra paths; prints only "release=0" for a docs-only
#       diff (no release).
set -eu
REPO_ROOT=${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$REPO_ROOT"
# shellcheck disable=SC1091
. "$(dirname "$0")/release-lib.sh"

baseline=${BASELINE:-}
if [ -z "$baseline" ]; then
  baseline=$(ap_latest_tag "$REPO_ROOT")
fi
if [ -n "$baseline" ]; then
  range="$baseline..HEAD"
else
  range="HEAD"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# classify every changed path against every pack (payload paths) + infra paths
git diff --name-only "$range" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  for conf in packs/*/pack.conf; do
    [ -f "$conf" ] || continue
    pack=$(basename "$(dirname "$conf")")
    case "$(ap_classify_path "$p" "$pack")" in
      pack)  echo "PACK $pack" ;;
      infra) echo "INFRA" ;;
    esac
  done
done | LC_ALL=C sort -u > "$tmp"

packs=""
infra=0
while IFS= read -r line; do
  case "$line" in
    "PACK "*) packs="$packs ${line#PACK }" ;;
    INFRA) infra=1 ;;
  esac
done < "$tmp"

if [ "$infra" = "1" ]; then
  # infra change -> every pack is re-released
  packs=" all"
fi
if [ -z "$packs" ]; then
  echo "release=0"
else
  echo "release=1"
  # shellcheck disable=SC2086
  echo "packs=$(printf '%s\n' $packs | LC_ALL=C sort -u | tr '\n' ' ')"
  echo "infra=$infra"
fi
