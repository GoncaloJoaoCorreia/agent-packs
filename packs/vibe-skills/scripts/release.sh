#!/bin/sh
# packs/vibe-skills/scripts/release.sh — pack-owned release builder for the vibe-skills pack.
# Run by .github/workflows/release.yml (G-113 M2) as:
#   REPO_ROOT=<checkout> OUT_DIR=<artifacts dir> [MISTRAL_API_KEY=...] sh packs/vibe-skills/scripts/release.sh
# Builds $OUT_DIR/packs/vibe-skills.tar.gz (payload + pack.conf + install.sh + vendored
# install-lib.sh) and $OUT_DIR/vibe-skills.meta.json {version, description, asset, sha256},
# then publishes the skills to the Mistral cloud registry (skipped with a warning when
# MISTRAL_API_KEY is unset). Shared mechanics: scripts/release-lib.sh (ap_release_pack).
set -eu
PACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
: "${REPO_ROOT:?release.sh: REPO_ROOT unset}"
: "${OUT_DIR:?release.sh: OUT_DIR unset}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/release-lib.sh"
ap_release_pack "$(basename "$PACK_DIR")" "$REPO_ROOT" "$OUT_DIR"

# cloud publish (only runs when this pack changed — release.yml only calls this script then)
if [ -n "${MISTRAL_API_KEY:-}" ]; then
  MISTRAL_API_KEY="$MISTRAL_API_KEY" python3 "$PACK_DIR/scripts/publish-to-cloud.py" --apply
else
  echo "warning: MISTRAL_API_KEY is not set — skipping cloud publish of vibe-skills" >&2
fi
