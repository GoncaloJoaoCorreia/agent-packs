#!/bin/sh
# Repo-wide validation dispatcher for agent-packs.
# Runs: installer syntax (root install.sh, scripts/install-lib.sh, every
# packs/*/install.sh), the pack contract (pack.conf metadata keys + pack-owned
# install.sh), a source-mode smoke install of every pack into a mktemp dest, the
# opencode pack's agent-scripts test suite, then every pack's own
# scripts/validate*.sh (e.g. the opencode pack's validate.sh + validate-driver-viz.sh).
# Used by .github/workflows/test.yml and release.yml; also runnable locally:
#   ./scripts/validate.sh
# Requires: sh, python3, git (agent-scripts tests), ruby for the pack validators.
# The shellcheck pass is optional (skipped when the tool is absent).
set -eu
cd "$(dirname "$0")/.."

echo "== installer syntax: install.sh + install-lib.sh + validate.sh + packs/*/install.sh =="
sh -n install.sh
sh -n scripts/install-lib.sh
sh -n scripts/validate.sh
for s in packs/*/install.sh; do
  [ -f "$s" ] || continue
  sh -n "$s"
done
echo "ok: sh -n install.sh scripts/install-lib.sh scripts/validate.sh packs/*/install.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh scripts/install-lib.sh scripts/validate.sh packs/*/install.sh
  echo "ok: shellcheck install.sh scripts/install-lib.sh scripts/validate.sh packs/*/install.sh"
else
  echo "skip: shellcheck not installed"
fi

echo "== pack contract: pack.conf metadata-only + pack-owned install.sh =="
fail=0
for conf in packs/*/pack.conf; do
  [ -f "$conf" ] || continue
  pack=$(basename "$(dirname "$conf")")
  if ! (
    unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PREREQS \
          PACK_LEGACY_MANIFEST PACK_LEGACY_CLEANUP PACK_PAYLOAD PACK_SHIP_ONLY PACK_COMPOSE
    # shellcheck disable=SC1090
    . "$conf"
    for v in PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX; do
      eval "val=\${$v:-}"
      [ -n "$val" ] || { echo "FAIL: $conf: missing required key $v" >&2; exit 1; }
    done
    [ "$PACK_NAME" = "$pack" ] || { echo "FAIL: $conf: PACK_NAME '$PACK_NAME' != pack dir '$pack'" >&2; exit 1; }
    for v in PACK_PAYLOAD PACK_SHIP_ONLY PACK_COMPOSE; do
      eval "val=\${$v:-}"
      [ -z "$val" ] || { echo "FAIL: $conf: removed key $v is still set — payload dirs live in packs/$pack/install.sh (PACK_PAYLOAD_DIRS)" >&2; exit 1; }
    done
  ); then
    fail=1
  fi
  if [ ! -f "packs/$pack/install.sh" ]; then
    echo "FAIL: packs/$pack/install.sh missing (the pack-owned installer)" >&2
    fail=1
    continue
  fi
  grep -q '^PACK_PAYLOAD_DIRS=' "packs/$pack/install.sh" \
    || { echo "FAIL: packs/$pack/install.sh: no PACK_PAYLOAD_DIRS declaration" >&2; fail=1; }
done
[ "$fail" = "0" ] || { echo "FAIL: pack contract" >&2; exit 1; }
echo "ok: all packs/*/pack.conf metadata-only, every pack has install.sh + PACK_PAYLOAD_DIRS"

echo "== source-mode smoke install of every pack into a mktemp dest =="
smoke_tmp=$(mktemp -d)
trap 'rm -rf "$smoke_tmp"' EXIT
for conf in packs/*/pack.conf; do
  [ -f "$conf" ] || continue
  pack=$(basename "$(dirname "$conf")")
  dest="$smoke_tmp/$pack"
  sh install.sh --source --dest "$dest" "$pack" >/dev/null
  prefix=$(
    (
      unset PACK_META_PREFIX
      # shellcheck disable=SC1090
      . "$conf"
      printf '%s' "${PACK_META_PREFIX:-}"
    )
  )
  [ -n "$prefix" ] || { echo "FAIL: $conf: no PACK_META_PREFIX" >&2; exit 1; }
  [ -f "$dest/$prefix.manifest" ] || { echo "FAIL: $pack: $dest/$prefix.manifest missing after smoke install" >&2; exit 1; }
  [ -s "$dest/$prefix.manifest" ] || { echo "FAIL: $pack: $dest/$prefix.manifest is empty" >&2; exit 1; }
  [ -f "$dest/$prefix.version" ] || { echo "FAIL: $pack: $dest/$prefix.version missing after smoke install" >&2; exit 1; }
  echo "ok: $pack -> $dest ($prefix.manifest + $prefix.version written)"
done

echo "== opencode pack agent-scripts tests =="
sh packs/opencode/agent-scripts/tests/run-tests.sh

echo "== per-pack validators =="
for v in packs/*/scripts/validate*.sh; do
  [ -f "$v" ] || continue
  pack=$(basename "$(dirname "$(dirname "$v")")")
  echo "-- pack '$pack': $v"
  sh "$v"
done

echo "== all validations passed =="
