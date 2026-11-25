#!/bin/sh
# packs/vibe-bridge/scripts/release.sh — pack-owned release builder for the vibe-bridge pack.
# Run by .github/workflows/release.yml (G-113 M2) as:
#   REPO_ROOT=<checkout> OUT_DIR=<artifacts dir> sh packs/vibe-bridge/scripts/release.sh
# Builds $OUT_DIR/packs/vibe-bridge.tar.gz (payload + pack.conf + install.sh + vendored
# install-lib.sh) and $OUT_DIR/vibe-bridge.meta.json {version, description, asset, sha256}.
# Shared mechanics: scripts/release-lib.sh (ap_release_pack).
set -eu
PACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
: "${REPO_ROOT:?release.sh: REPO_ROOT unset}"
: "${OUT_DIR:?release.sh: OUT_DIR unset}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/release-lib.sh"
ap_release_pack "$(basename "$PACK_DIR")" "$REPO_ROOT" "$OUT_DIR"
