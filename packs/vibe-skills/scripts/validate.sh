#!/bin/sh
# Validation for the vibe-skills pack (packs/vibe-skills).
# Run by the root scripts/validate.sh dispatcher (CI on every PR); also directly:
#   sh packs/vibe-skills/scripts/validate.sh
# Requires: sh + python3 (stdlib only). No ruby/node needed.
set -eu
PACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$PACK_DIR/../.." && pwd)
cd "$PACK_DIR"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required but not found" >&2; exit 1; }

echo "== installer smoke test: install the pack into a throwaway dest =="
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sh "$REPO/install.sh" --source --dest "$tmp/vibe-home" vibe-skills >/dev/null
for f in skills/init-agents-md/SKILL.md agent-packs.vibe-skills.manifest agent-packs.vibe-skills.version; do
  [ -e "$tmp/vibe-home/$f" ] || { echo "FAIL: installed dest is missing $f" >&2; exit 1; }
done
# scripts/ and docs/ are repo-only: they must NOT be installed
[ ! -e "$tmp/vibe-home/scripts" ] || { echo "FAIL: scripts/ must not be installed" >&2; exit 1; }
[ ! -e "$tmp/vibe-home/docs" ] || { echo "FAIL: docs/ must not be installed" >&2; exit 1; }
echo "ok: install.sh installs skills/ + meta files only (no scripts/ or docs/)"

echo "== --list shows the pack =="
if ! sh "$REPO/install.sh" --source --list | grep -q 'vibe-skills'; then
  echo "FAIL: install.sh --list does not list the vibe-skills pack" >&2
  exit 1
fi
echo "ok: --list shows vibe-skills"

echo "== skill frontmatter (skills/*/SKILL.md) =="
python3 - skills <<'PY'
import re
import sys
from pathlib import Path

skills_root = Path(sys.argv[1])
failures = []
seen = {}
dirs = sorted(d for d in skills_root.iterdir() if d.is_dir())
if not dirs:
    failures.append(f"{skills_root}: no skill directories")
for d in dirs:
    skill_md = d / "SKILL.md"
    if not skill_md.is_file():
        failures.append(f"{d.name}: missing SKILL.md")
        continue
    text = skill_md.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        failures.append(f"{d.name}/SKILL.md: no YAML frontmatter block")
        continue
    fm = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        kv = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not kv:
            failures.append(f"{d.name}/SKILL.md: unparsable frontmatter line: {line!r}")
            continue
        fm[kv.group(1)] = kv.group(2).strip().strip('"').strip("'")
    name = fm.get("name", "")
    desc = fm.get("description", "")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", name) or len(name) > 64:
        failures.append(f"{d.name}/SKILL.md: invalid name {name!r} (want ^[a-z0-9]+(-[a-z0-9]+)*$, <=64 chars)")
    if name != d.name:
        failures.append(f"{d.name}/SKILL.md: frontmatter name {name!r} != directory name {d.name!r}")
    if not desc or len(desc) > 1024:
        failures.append(f"{d.name}/SKILL.md: description is required and must be <=1024 chars")
    if name in seen:
        failures.append(f"{d.name}/SKILL.md: duplicate skill name {name!r} (also in {seen[name]})")
    seen[name] = d.name
for f in failures:
    print("FAIL:", f, file=sys.stderr)
sys.exit(1 if failures else 0)
PY
echo "ok: all skills/*/SKILL.md valid"

echo "== publish-to-cloud.py compiles and plans (dry-run, no network) =="
python3 -m py_compile scripts/publish-to-cloud.py
python3 scripts/publish-to-cloud.py >/dev/null 2>&1
echo "ok: publish-to-cloud.py compiles and dry-runs (no network, no API key)"

echo "== vibe-skills validation passed =="
