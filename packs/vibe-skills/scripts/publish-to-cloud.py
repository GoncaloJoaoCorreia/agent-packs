#!/usr/bin/env python3
"""Publish the vibe-skills pack's skills to the Mistral registry (cloud Vibe).

Single source of truth: packs/vibe-skills/skills/<name>/ (Agent Skills format).
This script pushes each skill directory to the beta Skills API on api.mistral.ai
(POST /v2/skills, POST /v2/skills/{id}/versions), so the same skills are available
in cloud Vibe: share the skill with the workspace in Studio and click
"Publish to Vibe" to expose it in Vibe Work (chat.mistral.ai) and cloud sessions.
The local Vibe CLI can pull them back as registry skills
(experimental_enable_registry_skills = true, /skills -> Shared tab).

Runs in the manual Release workflow (.github/workflows/release.yml, needs the
MISTRAL_API_KEY secret) and can also be run by hand. Existing registry skills are
found by name via the API (each published version carries the "agent-packs" alias),
so the script works from a fresh checkout; scripts/cloud-manifest.json is only a
local cache of name -> {id, version}. Requires MISTRAL_API_KEY (or --api-key).
Dry-run by default; --apply writes. Stdlib only.

Usage:
  python3 packs/vibe-skills/scripts/publish-to-cloud.py            # plan only, no network
  python3 packs/vibe-skills/scripts/publish-to-cloud.py --apply    # create/update
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

PACK_DIR = Path(__file__).resolve().parent.parent
SKILLS_DIR = PACK_DIR / "skills"
MANIFEST_PATH = PACK_DIR / "scripts" / "cloud-manifest.json"
DEFAULT_SERVER = "https://api.mistral.ai"
DEFAULT_ALIAS = "agent-packs"
EXECUTABLE_SUFFIXES = {".sh", ".py", ".mjs", ".js", ".ts", ".bash"}


def parse_skill(skill_dir: Path) -> dict:
    """Build the API payload for one skill directory (Agent Skills -> registry)."""
    skill_md = skill_dir / "SKILL.md"
    text = skill_md.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n?(.*)$", text, re.S)
    if not m:
        raise ValueError(f"{skill_md}: no YAML frontmatter block")
    fm: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        kv = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if kv:
            fm[kv.group(1)] = kv.group(2).strip().strip('"').strip("'")
    name = fm.get("name", "")
    description = fm.get("description", "")
    if name != skill_dir.name:
        raise ValueError(f"{skill_md}: frontmatter name {name!r} != directory {skill_dir.name!r}")
    if not description:
        raise ValueError(f"{skill_md}: missing description")
    assets: dict[str, dict] = {}
    for f in sorted(p for p in skill_dir.rglob("*") if p.is_file() and p.name != "SKILL.md"):
        rel = f.relative_to(skill_dir).as_posix()
        raw = f.read_bytes()
        entry: dict = {"isExecutable": f.suffix in EXECUTABLE_SUFFIXES or os.access(f, os.X_OK)}
        try:
            entry["textContent"] = raw.decode("utf-8")
        except UnicodeDecodeError:
            entry["rawContent"] = base64.b64encode(raw).decode("ascii")
        assets[rel] = entry
    return {
        "name": name,
        "definition": {"description": description, "body": m.group(2).strip(), "assets": assets},
    }


def api(server: str, api_key: str, method: str, path: str, payload: dict | None = None) -> dict:
    url = f"{server}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {api_key}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read()
    return json.loads(body) if body else {}


def list_all_skills(server: str, api_key: str) -> list[dict]:
    """Paginate GET /v2/skills; returns the raw skill entries (name/id/aliases)."""
    out: list[dict] = []
    token = None
    while True:
        q = "/v2/skills?pageSize=100"
        if token:
            q += f"&pageToken={token}"
        res = api(server, api_key, "GET", q)
        out.extend(res.get("data", []))
        token = res.get("nextPageToken")
        if not token:
            return out


def find_registry_id(server: str, api_key: str, alias: str, name: str, manifest: dict) -> str | None:
    """Resolve the registry skill id for `name`: manifest fast path (verified via
    the API), then a name match over the full skill list (preferring entries that
    carry our alias). None = not published yet."""
    entry = manifest.get(name)
    if entry:
        try:
            got = api(server, api_key, "GET", f"/v2/skills/{entry['id']}")
            if got.get("name") == name:
                return entry["id"]
        except urllib.error.HTTPError:
            pass  # stale manifest entry — fall through to the list lookup
    matches = [s for s in list_all_skills(server, api_key) if s.get("name") == name]
    if not matches:
        return None
    preferred = [s for s in matches if alias in (s.get("aliases") or [])]
    pool = preferred or matches
    if len(pool) > 1:
        ids = ", ".join(s["id"] for s in pool)
        raise RuntimeError(f"skill {name!r} matches multiple registry ids ({ids}) — resolve manually")
    return pool[0]["id"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="actually create/update registry skills (default: dry-run)")
    ap.add_argument("--dry-run", action="store_true", help="plan only (default)")
    ap.add_argument("--api-key", default=os.environ.get("MISTRAL_API_KEY", ""), help="Mistral API key (default: $MISTRAL_API_KEY)")
    ap.add_argument("--server", default=DEFAULT_SERVER, help=f"API base URL (default: {DEFAULT_SERVER})")
    ap.add_argument("--alias", default=DEFAULT_ALIAS, help=f"alias stamped on every published version (default: {DEFAULT_ALIAS})")
    ap.add_argument("--sharing-scope", default="workspace", choices=["private", "workspace"],
                    help="sharingScope for newly created skills (default: workspace)")
    args = ap.parse_args()

    skills = [parse_skill(d) for d in sorted(SKILLS_DIR.iterdir()) if d.is_dir()]
    if not skills:
        print("no skills found under", SKILLS_DIR, file=sys.stderr)
        return 1

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8")) if MANIFEST_PATH.exists() else {}

    if not args.apply:
        print("dry-run (pass --apply to publish); MISTRAL_API_KEY is", "set" if args.api_key else "NOT set")
        for s in skills:
            entry = manifest.get(s["name"])
            state = f"registry id {entry['id']} v{entry.get('version', '?')} -> new version" if entry else "new registry skill (or found by name via API)"
            print(f"  {s['name']}: {state} ({len(s['definition']['assets'])} assets)")
        print("then in Studio: Share with workspace + 'Publish to Vibe' on each skill's page")
        return 0
    if not args.api_key:
        print("FAIL: --apply needs an API key (--api-key or MISTRAL_API_KEY)", file=sys.stderr)
        return 1

    changed = False
    for s in skills:
        name = s["name"]
        skill_id = find_registry_id(args.server, args.api_key, args.alias, name, manifest)
        if skill_id:
            res = api(args.server, args.api_key, "POST", f"/v2/skills/{skill_id}/versions",
                      {"definition": s["definition"], "aliases": [args.alias],
                       "notes": "published from agent-packs packs/vibe-skills"})
            version, dedup = res.get("version"), res.get("deduplicated", False)
            print(f"  {name}: registry {skill_id} v{version}" + (" (unchanged, deduplicated)" if dedup else " (new version)"))
            manifest[name] = {"id": skill_id, "version": version}
            changed = True
        else:
            res = api(args.server, args.api_key, "POST", "/v2/skills",
                      {"name": name, "definition": s["definition"], "sharingScope": args.sharing_scope,
                       "aliases": [args.alias], "notes": "published from agent-packs packs/vibe-skills"})
            manifest[name] = {"id": res["id"], "version": res.get("version", 1)}
            print(f"  {name}: created registry skill {res['id']} v{res.get('version', 1)} (sharingScope={args.sharing_scope})")
            changed = True

    if changed:
        MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"updated {MANIFEST_PATH} (local cache; the API is the source of truth)")
    print("done. Next: in Studio, Share each skill with the workspace and click 'Publish to Vibe';")
    print("local CLI can pull them via experimental_enable_registry_skills = true + /skills Shared tab.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
