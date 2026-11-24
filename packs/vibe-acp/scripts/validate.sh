#!/bin/sh
# Pre-release validation for the vibe-acp pack (packs/vibe-acp).
# Used by the root scripts/validate.sh dispatcher (which .github/workflows call);
# also runnable directly: sh packs/vibe-acp/scripts/validate.sh
# Requires: sh, git (prereq), node >= 22.18 for the provider unit tests (TS type stripping).
set -eu
PACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$PACK_DIR/../.." && pwd)
cd "$PACK_DIR"

echo "== pack.conf syntax =="
sh -n pack.conf
echo "ok: sh -n pack.conf"

echo "== JSON files parse (package.json x2, snippets/opencode.jsonc) =="
node - <<'NODE'
const { readFileSync } = require("node:fs")
const files = [
  "plugins/vibe-acp/package.json",
  "plugins/vibe-acp/provider/package.json",
  "snippets/opencode.jsonc",
]
for (const file of files) {
  const text = readFileSync(file, "utf8")
  // the snippet is JSONC — strip // comments before parsing
  const stripped = file.endsWith(".jsonc") ? text.replace(/^\s*\/\/.*$/gm, "") : text
  const parsed = JSON.parse(stripped)
  if (typeof parsed !== "object" || parsed === null) throw new Error(`${file}: not an object`)
}
console.log("ok: " + files.join(", "))
NODE

echo "== plugin path references resolve =="
[ -f plugins/vibe-acp/index.ts ] || { echo "FAIL: plugins/vibe-acp/index.ts missing" >&2; exit 1; }
[ -f plugins/vibe-acp/provider/src/index.ts ] || { echo "FAIL: provider entry missing" >&2; exit 1; }
grep -q '"./provider/src/index.ts"\|./provider/src/index.ts' plugins/vibe-acp/index.ts \
  || { echo "FAIL: plugin does not reference ./provider/src/index.ts" >&2; exit 1; }
node -e '
const pkg = require("./plugins/vibe-acp/package.json");
const path = require("node:path");
for (const [sub, target] of Object.entries(pkg.exports ?? {})) {
  if (!require("node:fs").existsSync(path.join("plugins/vibe-acp", target)))
    throw new Error(`plugins/vibe-acp exports ${sub} -> ${target} missing`);
}
const prov = require("./plugins/vibe-acp/provider/package.json");
for (const target of Object.values(prov.exports ?? {})) {
  if (!require("node:fs").existsSync(path.join("plugins/vibe-acp/provider", target)))
    throw new Error(`provider exports -> ${target} missing`);
}
console.log("ok: exports resolve");
'
grep -q 'export function create' plugins/vibe-acp/provider/src/index.ts \
  || { echo "FAIL: provider package has no create* export (the aisdk: bridge requires one)" >&2; exit 1; }
echo "ok: provider exports a create* factory for the aisdk: bridge"

echo "== provider unit tests (node --test, strips TS types) =="
node --version
(cd plugins/vibe-acp/provider && node --test test/*.test.ts)
echo "ok: provider unit tests green"

echo "== throwaway install (--source --dest) =="
install_tmp=$(mktemp -d)
trap 'rm -rf "$install_tmp"' EXIT
sh "$REPO/install.sh" --source --dest "$install_tmp/cfg" vibe-acp >/dev/null
for f in plugins/vibe-acp/index.ts plugins/vibe-acp/package.json \
         plugins/vibe-acp/provider/package.json plugins/vibe-acp/provider/src/index.ts \
         plugins/vibe-acp/provider/src/client.ts \
         agent-packs.vibe-acp.manifest agent-packs.vibe-acp.version; do
  [ -e "$install_tmp/cfg/$f" ] || { echo "FAIL: installed cfg missing $f" >&2; exit 1; }
done
if [ -e "$install_tmp/cfg/snippets" ]; then
  echo "FAIL: snippets/ must be ship-only, not installed" >&2; exit 1
fi
grep -q 'plugins/vibe-acp/provider/src/index.ts' "$install_tmp/cfg/agent-packs.vibe-acp.manifest" \
  || { echo "FAIL: manifest does not list the provider entry" >&2; exit 1; }
echo "ok: payload + meta files installed, snippets/ not installed"

echo "== reinstall cleans stale files via the manifest =="
echo "stale" > "$install_tmp/cfg/plugins/vibe-acp/STALE-FILE.txt"
echo "plugins/vibe-acp/STALE-FILE.txt" >> "$install_tmp/cfg/agent-packs.vibe-acp.manifest"
sh "$REPO/install.sh" --source --dest "$install_tmp/cfg" vibe-acp >/dev/null
if [ -e "$install_tmp/cfg/plugins/vibe-acp/STALE-FILE.txt" ]; then
  echo "FAIL: stale file not cleaned on reinstall" >&2; exit 1
fi
echo "ok: stale file removed on reinstall"

echo "== --no-plugin skips the plugins payload =="
sh "$REPO/install.sh" --source --dest "$install_tmp/cfg2" --no-plugin vibe-acp >/dev/null
if [ -e "$install_tmp/cfg2/plugins" ]; then
  echo "FAIL: --no-plugin still installed plugins/" >&2; exit 1
fi
[ -e "$install_tmp/cfg2/agent-packs.vibe-acp.manifest" ] || { echo "FAIL: meta files missing with --no-plugin" >&2; exit 1; }
echo "ok: --no-plugin skips plugins/"

echo "== --list shows the pack =="
sh "$REPO/install.sh" --source --list | grep -q 'vibe-acp' || { echo "FAIL: --list lacks vibe-acp" >&2; exit 1; }
echo "ok: --list shows vibe-acp"

echo "== vibe-acp pack validation passed =="
