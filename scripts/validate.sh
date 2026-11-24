#!/bin/sh
# Repo-wide validation dispatcher for agent-packs.
# Runs: root install.sh syntax, pack.conf sanity for every pack, the shared agent-scripts
# test suite, then every pack's own scripts/validate*.sh (e.g. the opencode pack's
# validate.sh + validate-driver-viz.sh).
# Used by .github/workflows/test.yml and release.yml; also runnable locally:
#   ./scripts/validate.sh
# Requires: sh, python3, git (shared agent-scripts tests), ruby for the pack validators.
# shellcheck is optional (skipped if absent).
set -eu
cd "$(dirname "$0")/.."

echo "== install.sh syntax =="
sh -n install.sh
echo "ok: sh -n install.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh
  echo "ok: shellcheck install.sh"
else
  echo "skip: shellcheck not installed"
fi

echo "== pack.conf sanity =="
fail=0
for conf in packs/*/pack.conf; do
  [ -f "$conf" ] || continue
  pack=$(basename "$(dirname "$conf")")
  if ! (
    unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PAYLOAD \
          PACK_SHIP_ONLY PACK_COMPOSE PACK_PREREQS PACK_LEGACY_MANIFEST PACK_LEGACY_CLEANUP
    # shellcheck disable=SC1090
    . "$conf"
    for v in PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PAYLOAD; do
      eval "val=\${$v:-}"
      [ -n "$val" ] || { echo "FAIL: $conf: missing required key $v" >&2; exit 1; }
    done
    [ "$PACK_NAME" = "$pack" ] || { echo "FAIL: $conf: PACK_NAME '$PACK_NAME' != pack dir '$pack'" >&2; exit 1; }
    for d in $PACK_PAYLOAD ${PACK_SHIP_ONLY:-}; do
      [ -d "packs/$pack/$d" ] || { echo "FAIL: $conf: payload dir packs/$pack/$d missing" >&2; exit 1; }
    done
    for e in ${PACK_COMPOSE:-}; do
      src=${e%%:*}; dst=${e#*:}
      { [ -n "$src" ] && [ -n "$dst" ] && [ "$src" != "$e" ]; } || { echo "FAIL: $conf: bad PACK_COMPOSE entry '$e' (want src:dst)" >&2; exit 1; }
      [ -d "$src" ] || { echo "FAIL: $conf: PACK_COMPOSE source '$src' missing in repo root" >&2; exit 1; }
    done
  ); then
    fail=1
  fi
done
[ "$fail" = "0" ] || { echo "FAIL: pack.conf sanity" >&2; exit 1; }
echo "ok: all packs/*/pack.conf valid"

echo "== shared agent-scripts tests =="
sh shared/agent-scripts/tests/run-tests.sh

echo "== per-pack validators =="
for v in packs/*/scripts/validate*.sh; do
  [ -f "$v" ] || continue
  pack=$(basename "$(dirname "$(dirname "$v")")")
  echo "-- pack '$pack': $v"
  sh "$v"
done

echo "== all validations passed =="
