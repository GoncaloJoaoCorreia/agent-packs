#!/bin/sh
# packs/vibe-acp/install.sh — pack-owned installer for the vibe-acp pack.
#
# Invoked by the root install.sh (orchestrator) as:
#   AGENT_PACKS_ROOT=<payload root> sh packs/vibe-acp/install.sh check
#   AGENT_PACKS_ROOT=<payload root> sh packs/vibe-acp/install.sh install <dest> <version> [--no-plugin]
#
# Shared mechanics come from scripts/install-lib.sh, found via
# ${AGENT_PACKS_INSTALL_LIB:-$AGENT_PACKS_ROOT/scripts/install-lib.sh} (release tarballs
# vendor a copy next to this script — G-113 M2). Pack metadata comes from pack.conf.
set -eu
unset CDPATH

PACK_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -z "${AGENT_PACKS_ROOT:-}" ]; then
  echo "pack install.sh: AGENT_PACKS_ROOT is unset — invoke via the root install.sh" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${AGENT_PACKS_INSTALL_LIB:-$AGENT_PACKS_ROOT/scripts/install-lib.sh}"
# shellcheck disable=SC1090,SC1091
. "$PACK_DIR/pack.conf"  # metadata only: PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PREREQS PACK_LEGACY_*

# payload dirs copied to the dest root (copy-based on purpose; 'plugins' is skipped by
# --no-plugin). OpenCode auto-discovers <config>/plugins/vibe-acp/ — no config edit
# needed. snippets/ ships in the release tarball but is NOT installed.
PACK_PAYLOAD_DIRS="plugins"

# optional warnings, printed by `check` before anything is installed (never fail)
pack_extra_checks() {
  if ! command -v vibe-acp >/dev/null 2>&1 && ! command -v vibe >/dev/null 2>&1; then
    echo "install: warning: no Mistral Vibe CLI (vibe-acp / vibe) on PATH — the 'vibe' provider stays disabled until one is installed and signed in (vibe-acp --setup)" >&2
  fi
  if ! command -v node >/dev/null 2>&1 && ! command -v bun >/dev/null 2>&1; then
    echo "install: warning: no node/bun runtime visible — OpenCode itself provides the runtime, this is informational only" >&2
  fi
}

# printed after a successful install of this pack
pack_next_steps() {
  cat <<'EOF'

Next steps:
  1. Sign in once with the Vibe CLI: vibe-acp --setup   (or /connect → "Sign in with Vibe CLI" in OpenCode)
  2. In OpenCode run /models and pick a vibe/<model> — models are discovered from the CLI automatically
  3. Select it with "model": "vibe/<model>" (see snippets/opencode.jsonc in this repo)
  Note: Mistral's consumer ToS §3(g) forbids integrating Vibe with third-party products without
  prior written authorization — personal use via ACP is fine; get Mistral's OK before distributing.
EOF
}

mode=${1:-}
case "$mode" in
  check)
    # shellcheck disable=SC2086  # $PACK_PREREQS is an intentional word list
    ap_check_prereqs "$PACK_NAME" ${PACK_PREREQS:-}
    # shellcheck disable=SC2086  # $PACK_PAYLOAD_DIRS is an intentional word list
    ap_check_payload_dirs "$PACK_DIR" $PACK_PAYLOAD_DIRS
    pack_extra_checks
    ;;
  install)
    dest=${2:?pack install.sh: install needs <dest> <version> [--no-plugin]}
    version=${3:?pack install.sh: install needs <dest> <version> [--no-plugin]}
    no_plugin=0
    if [ "${4:-}" = "--no-plugin" ]; then no_plugin=1; fi
    inst=""
    # shellcheck disable=SC2086  # $PACK_PAYLOAD_DIRS is an intentional word list
    for d in $PACK_PAYLOAD_DIRS; do
      if [ "$d" = "plugins" ] && [ "$no_plugin" = "1" ]; then continue; fi
      inst="$inst $d"
    done
    # AP_* config for ap_install_pack (in install-lib.sh)
    # shellcheck disable=SC2034
    AP_DEST=$dest
    # shellcheck disable=SC2034
    AP_PREFIX=$PACK_META_PREFIX
    # shellcheck disable=SC2034
    AP_VERSION=$version
    # shellcheck disable=SC2034
    AP_MANAGED=$inst
    # shellcheck disable=SC2034
    AP_LEGACY_MANIFEST=${PACK_LEGACY_MANIFEST:-}
    # shellcheck disable=SC2034
    AP_LEGACY_CLEANUP=${PACK_LEGACY_CLEANUP:-}
    # shellcheck disable=SC2086  # $inst is an intentional word list
    ap_install_pack "$PACK_DIR" $inst
    components=""
    # shellcheck disable=SC2086  # $inst is an intentional word list
    for d in $inst; do components="$components $d/"; done
    echo "Installed pack '$PACK_NAME' $version -> $dest"
    echo "  components:$components"
    pack_next_steps
    ;;
  *)
    echo "pack install.sh: usage: install.sh check | install <dest> <version> [--no-plugin]" >&2
    exit 2
    ;;
esac
