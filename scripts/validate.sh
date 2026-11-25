#!/bin/sh
# Repo-wide validation dispatcher for agent-packs.
# Runs: installer + release-pipeline script syntax (root install.sh,
# scripts/install-lib.sh, scripts/release-lib.sh, scripts/release-detect.sh, every
# packs/*/install.sh, every packs/*/scripts/release.sh), the pack contract (pack.conf
# metadata keys + pack-owned install.sh), a source-mode smoke install of every pack into
# a mktemp dest, release-lib unit tests, an assemble-manifest.py unit test, an OFFLINE
# release-mode installer E2E against a file:// fake release base, the opencode pack's
# agent-scripts test suite, then every pack's own scripts/validate*.sh (e.g. the opencode
# pack's validate.sh + validate-driver-viz.sh).
# Used by .github/workflows/test.yml and release.yml; also runnable locally:
#   ./scripts/validate.sh
# Requires: sh, python3, git (agent-scripts tests), ruby for the pack validators.
# The shellcheck pass is optional (skipped when the tool is absent).
set -eu
cd "$(dirname "$0")/.."

echo "== installer + release-pipeline syntax =="
sh -n install.sh
sh -n scripts/install-lib.sh
sh -n scripts/validate.sh
sh -n scripts/release-lib.sh
sh -n scripts/release-detect.sh
for s in packs/*/install.sh packs/*/scripts/release.sh; do
  [ -f "$s" ] || continue
  sh -n "$s"
done
python3 -m py_compile scripts/assemble-manifest.py
echo "ok: sh -n install.sh scripts/*.sh packs/*/install.sh packs/*/scripts/release.sh + py_compile assemble-manifest.py"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck install.sh scripts/install-lib.sh scripts/validate.sh scripts/release-lib.sh \
    scripts/release-detect.sh packs/*/install.sh packs/*/scripts/release.sh
  echo "ok: shellcheck on all installer + release scripts"
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

echo "== non-interactive contract: no TTY + no pack args -> exit 2 (no silent default) =="
# stdout redirected to /dev/null so [ -t 1 ] is false even on an interactive terminal
if sh install.sh --source </dev/null >/dev/null 2>"$smoke_tmp/notty.err"; then
  echo "FAIL: no-TTY no-args install.sh --source should exit non-zero" >&2
  exit 1
fi
grep -q 'no TTY and no pack arguments' "$smoke_tmp/notty.err" \
  || { echo "FAIL: missing the clear no-TTY message:" >&2; cat "$smoke_tmp/notty.err" >&2; exit 1; }
echo "ok: no-TTY no-args exits 2 with a clear message"
if sh install.sh --source --plain </dev/null >/dev/null 2>&1; then
  echo "FAIL: no-TTY no-args --plain should exit non-zero" >&2
  exit 1
fi
echo "ok: --plain with no TTY + no args also exits 2"
sh install.sh --source --plain --dest "$smoke_tmp/plain-cfg" opencode >/dev/null 2>&1 \
  || { echo "FAIL: --plain with explicit pack args must install non-interactively" >&2; exit 1; }
[ -f "$smoke_tmp/plain-cfg/agent-packs.opencode.manifest" ] \
  || { echo "FAIL: --plain args install missing meta files" >&2; exit 1; }
echo "ok: --plain with pack args installs non-interactively"

echo "== TUI picker smoke (pty via script(1), skipped when unavailable) =="
if command -v script >/dev/null 2>&1; then
  printf ' \r' | script -q /dev/null sh install.sh --source --dest "$smoke_tmp/tui-cfg" >/dev/null 2>&1
  [ -f "$smoke_tmp/tui-cfg/agent-packs.opencode.manifest" ] \
    || { echo "FAIL: TUI space+enter did not install the selected (first) pack" >&2; exit 1; }
  echo "ok: TUI toggle+confirm installs the selected pack"
  rc=0
  printf 'q' | script -q /dev/null sh install.sh --source --dest "$smoke_tmp/tui-abort" >/dev/null 2>&1 || rc=$?
  [ "$rc" = "2" ] || { echo "FAIL: TUI q-abort should exit 2 (got $rc)" >&2; exit 1; }
  [ ! -e "$smoke_tmp/tui-abort/agent-packs.opencode.manifest" ] \
    || { echo "FAIL: TUI q-abort must not install anything" >&2; exit 1; }
  echo "ok: TUI q aborts with exit 2 and installs nothing"
else
  echo "skip: script(1) not available"
fi

echo "== release-lib unit tests (path classification + conventional-commit bumps) =="
# shellcheck disable=SC1091
. scripts/release-lib.sh
rl_fail=0
rl_check() { # <desc> <got> <want>
  if [ "$2" = "$3" ]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: got [$2] want [$3]" >&2
    rl_fail=1
  fi
}
rl_check "classify payload path"   "$(ap_classify_path packs/opencode/agents/driver.md opencode)" pack
rl_check "classify pack scripts/"  "$(ap_classify_path packs/opencode/scripts/validate.sh opencode)" docs
rl_check "classify pack docs/"     "$(ap_classify_path packs/opencode/docs/x.md opencode)" docs
rl_check "classify pack README"    "$(ap_classify_path packs/opencode/README.md opencode)" docs
rl_check "classify other pack"     "$(ap_classify_path packs/vibe-acp/plugins/x.ts opencode)" other
rl_check "classify infra install"  "$(ap_classify_path install.sh opencode)" infra
rl_check "classify infra scripts"  "$(ap_classify_path scripts/validate.sh opencode)" infra
rl_check "classify infra workflow" "$(ap_classify_path .github/workflows/test.yml opencode)" infra
rl_check "classify packs/README"   "$(ap_classify_path packs/README.md opencode)" infra
rl_check "classify root docs"      "$(ap_classify_path README.md opencode)" docs
rl_check "bump feat"               "$(ap_bump_of_message 'feat(opencode): add x')" minor
rl_check "bump feat bare"          "$(ap_bump_of_message 'feat: add x')" minor
rl_check "bump fix"                "$(ap_bump_of_message 'fix(vibe-acp): repair y')" patch
rl_check "bump bang"               "$(ap_bump_of_message 'feat!: drop z')" major
rl_check "bump scope bang"         "$(ap_bump_of_message 'fix(core)!: drop z')" major
rl_check "bump BREAKING footer"    "$(ap_bump_of_message 'refactor: x

BREAKING CHANGE: y')" major
rl_check "bump chore"              "$(ap_bump_of_message 'chore: tidy')" none
rl_check "highest minor>patch"     "$(ap_highest_bump minor patch)" minor
rl_check "highest major>minor"     "$(ap_highest_bump major minor)" major
rl_check "highest none"            "$(ap_highest_bump none none)" none
rl_check "semver patch"            "$(ap_semver_bump v2.1.1 patch)" v2.1.2
rl_check "semver minor"            "$(ap_semver_bump v2.1.1 minor)" v2.2.0
rl_check "semver major"            "$(ap_semver_bump 2.1.1 major)" v3.0.0
[ "$rl_fail" = "0" ] || { echo "FAIL: release-lib unit tests" >&2; exit 1; }
echo "ok: release-lib classification + bumps"

echo "== assemble-manifest.py unit test (changed + carried-over entries) =="
am_tmp="$smoke_tmp/assemble"
mkdir -p "$am_tmp/artifacts/packs" "$am_tmp/repo/packs/alpha" "$am_tmp/repo/packs/beta"
touch "$am_tmp/repo/packs/alpha/pack.conf" "$am_tmp/repo/packs/beta/pack.conf"
printf '%s\n' '{"version":"1.2.3","description":"alpha pack","asset":"packs/alpha.tar.gz","sha256":"deadbeef"}' > "$am_tmp/artifacts/alpha.meta.json"
printf '%s\n' '{"schema":1,"release":"v9.9.8","packs":{"beta":{"version":"0.1.0","description":"beta pack","asset":"packs/beta.tar.gz","sha256":"cafe"}}}' > "$am_tmp/prev.json"
python3 scripts/assemble-manifest.py --out "$am_tmp/manifest.json" --release v9.9.9 \
  --artifacts "$am_tmp/artifacts" --changed alpha --repo-root "$am_tmp/repo" \
  --prev-manifest "$am_tmp/prev.json" >/dev/null
python3 - "$am_tmp/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema"] == 1 and m["release"] == "v9.9.9", m
assert m["packs"]["alpha"]["version"] == "1.2.3", m
assert m["packs"]["beta"]["version"] == "0.1.0", m  # carried over from the previous release
print("ok: manifest merges changed + carried-over pack entries")
PY

echo "== release-mode installer E2E (offline, file:// fake release base) =="
e2e="$smoke_tmp/release-e2e"
mkdir -p "$e2e"
# build the opencode pack tarball + meta fragment with the REAL pack release script
REPO_ROOT="$PWD" OUT_DIR="$e2e/artifacts" sh packs/opencode/scripts/release.sh
python3 scripts/assemble-manifest.py --out "$e2e/artifacts/manifest.json" --release v9.9.9 \
  --artifacts "$e2e/artifacts" --changed opencode --repo-root "$PWD" >/dev/null
# lay out the fake release base (latest/download + download/<tag>) and fake releases API
mkdir -p "$e2e/rel/latest/download/packs" "$e2e/rel/download/v9.9.9/packs" "$e2e/api"
cp "$e2e/artifacts/manifest.json" "$e2e/rel/latest/download/manifest.json"
cp "$e2e/artifacts/manifest.json" "$e2e/rel/download/v9.9.9/manifest.json"
cp "$e2e/artifacts/packs/opencode.tar.gz" "$e2e/rel/latest/download/packs/"
cp "$e2e/artifacts/packs/opencode.tar.gz" "$e2e/rel/download/v9.9.9/packs/"
# an older release tag (v9.9.8) with the same tarball but an older pack version — used by
# the pinned and TUI version-cycling tests
mkdir -p "$e2e/rel/download/v9.9.8/packs"
sha_old=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packs"]["opencode"]["sha256"])' "$e2e/artifacts/manifest.json")
python3 - "$e2e/rel/download/v9.9.8/manifest.json" "$sha_old" <<'PY'
import json, sys
out, sha = sys.argv[1], sys.argv[2]
entry = {"asset": "packs/opencode.tar.gz", "description": "opencode pack",
         "sha256": sha, "version": "v2.1.1"}
json.dump({"schema": 1, "release": "v9.9.8", "packs": {"opencode": entry}},
          open(out, "w"), indent=2, sort_keys=True, ensure_ascii=False)
PY
cp "$e2e/artifacts/packs/opencode.tar.gz" "$e2e/rel/download/v9.9.8/packs/"
# pretty-printed like the real GitHub API (one "tag_name" per line — resolve_tag parses per line)
printf '%s\n' '[' '  {' '    "tag_name": "v9.9.9"' '  },' '  {' '    "tag_name": "v9.9.8"' '  }' ']' > "$e2e/api/releases"
# tarball hygiene: pack installer + vendored lib ship, repo-only scripts/ stripped
tar -tzf "$e2e/artifacts/packs/opencode.tar.gz" | grep -qxF opencode/install.sh \
  || { echo "FAIL: pack tarball missing opencode/install.sh" >&2; exit 1; }
tar -tzf "$e2e/artifacts/packs/opencode.tar.gz" | grep -qxF opencode/install-lib.sh \
  || { echo "FAIL: pack tarball missing vendored opencode/install-lib.sh" >&2; exit 1; }
tar -tzf "$e2e/artifacts/packs/opencode.tar.gz" | grep -qxF opencode/pack.conf \
  || { echo "FAIL: pack tarball missing opencode/pack.conf" >&2; exit 1; }
if tar -tzf "$e2e/artifacts/packs/opencode.tar.gz" | grep -Eq '(^|/)opencode/(scripts|docs)/|(^|/)opencode/(README|AGENTS)\.md|(^|/)plugins/[^/]+/test/|node_modules|(^|/)(\.agent|__pycache__)/'; then
  echo "FAIL: pack tarball carries repo-only paths" >&2
  exit 1
fi
echo "ok: pack tarball is payload-only with vendored install-lib.sh"
AGENT_PACKS_RELEASE_BASE="file://$e2e/rel" AGENT_PACKS_API="file://$e2e/api" \
  sh install.sh --release --dest "$e2e/cfg" opencode >/dev/null
want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["packs"]["opencode"]["version"])' "$e2e/rel/latest/download/manifest.json")
got=$(cat "$e2e/cfg/agent-packs.opencode.version")
[ "$got" = "$want" ] || { echo "FAIL: release-mode install version '$got' != manifest '$want'" >&2; exit 1; }
[ -f "$e2e/cfg/agents/driver.md" ] || { echo "FAIL: release-mode install missing agents/driver.md" >&2; exit 1; }
[ -f "$e2e/cfg/agent-packs.opencode.manifest" ] || { echo "FAIL: release-mode install missing manifest" >&2; exit 1; }
echo "ok: install.sh --release installs opencode $want from the fake latest release"
AGENT_PACKS_RELEASE_BASE="file://$e2e/rel" AGENT_PACKS_API="file://$e2e/api" \
  sh install.sh --release --list | grep -q "opencode $want" \
  || { echo "FAIL: --release --list does not show opencode $want" >&2; exit 1; }
echo "ok: --release --list shows packs with versions"
AGENT_PACKS_RELEASE_BASE="file://$e2e/rel" AGENT_PACKS_API="file://$e2e/api" \
  sh install.sh --release --dest "$e2e/cfg2" opencode@v9.9.9 >/dev/null
[ "$(cat "$e2e/cfg2/agent-packs.opencode.version")" = "$want" ] \
  || { echo "FAIL: opencode@v9.9.9 pinned install version mismatch" >&2; exit 1; }
echo "ok: pack@version pinned install resolves via the releases API + tag manifest"
if AGENT_PACKS_RELEASE_BASE="file://$e2e/rel" AGENT_PACKS_API="file://$e2e/api" \
   sh install.sh --release --dest "$e2e/cfg3" opencode@v0.0.1 >/dev/null 2>&1; then
  echo "FAIL: opencode@v0.0.1 (unknown version) should have failed" >&2
  exit 1
fi
echo "ok: unknown pack@version fails cleanly"
if sh install.sh --source --dest "$e2e/cfg4" opencode@1.0.0 >/dev/null 2>&1; then
  echo "FAIL: pack@version in --source mode should have failed" >&2
  exit 1
fi
echo "ok: pack@version rejected in --source mode"
if command -v script >/dev/null 2>&1; then
  # TUI in release mode: left-arrow cycles opencode @latest -> @v9.9.8, space toggles, enter
  printf '\033[D \r' | script -q /dev/null env \
    AGENT_PACKS_RELEASE_BASE="file://$e2e/rel" AGENT_PACKS_API="file://$e2e/api" \
    sh install.sh --release --dest "$e2e/cfg-tui" >/dev/null 2>&1 || true
  [ "$(cat "$e2e/cfg-tui/agent-packs.opencode.version" 2>/dev/null)" = "v2.1.1" ] \
    || { echo "FAIL: TUI version cycling did not pin opencode to the v9.9.8 release (version file: $(cat "$e2e/cfg-tui/agent-packs.opencode.version" 2>/dev/null))" >&2; exit 1; }
  echo "ok: TUI left/right cycles the pack version across manifest history (installed v2.1.1 from v9.9.8)"
else
  echo "skip: script(1) not available — TUI release-mode cycling not smoke-tested"
fi

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
