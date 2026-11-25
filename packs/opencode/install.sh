#!/bin/sh
# packs/opencode/install.sh — pack-owned installer for the opencode pack.
#
# Invoked by the root install.sh (orchestrator) as:
#   AGENT_PACKS_ROOT=<payload root> sh packs/opencode/install.sh check
#   AGENT_PACKS_ROOT=<payload root> sh packs/opencode/install.sh install <dest> <version> [--no-plugin]
#
# Shared mechanics come from install-lib.sh, found via $AGENT_PACKS_INSTALL_LIB, else the
# copy vendored next to this script inside a release tarball ($AGENT_PACKS_ROOT/install-lib.sh),
# else the repo checkout's scripts/install-lib.sh. Pack metadata comes from pack.conf.
set -eu
unset CDPATH

PACK_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -z "${AGENT_PACKS_ROOT:-}" ]; then
  echo "pack install.sh: AGENT_PACKS_ROOT is unset — invoke via the root install.sh" >&2
  exit 1
fi
if [ -n "${AGENT_PACKS_INSTALL_LIB:-}" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$AGENT_PACKS_INSTALL_LIB"
elif [ -f "$AGENT_PACKS_ROOT/install-lib.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$AGENT_PACKS_ROOT/install-lib.sh"
else
  # shellcheck disable=SC1090,SC1091
  . "$AGENT_PACKS_ROOT/scripts/install-lib.sh"
fi
# shellcheck disable=SC1090,SC1091
. "$PACK_DIR/pack.conf"  # metadata only: PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PREREQS PACK_LEGACY_*

# payload dirs copied to the dest root (copy-based on purpose; 'plugins' is skipped by
# --no-plugin). snippets/ ships in the release tarball but is NOT installed.
PACK_PAYLOAD_DIRS="agents commands plugins agent-scripts skills"

# optional warnings, printed by `check` before anything is installed (never fail)
pack_extra_checks() {
  # optional: a forge CLI is only needed by the driver's pr phase (it degrades
  # gracefully without one)
  if ! command -v gh >/dev/null 2>&1 && ! command -v glab >/dev/null 2>&1 \
     && ! command -v forgejo-cli >/dev/null 2>&1 && ! command -v fj >/dev/null 2>&1; then
    echo "install: note: no forge CLI (gh/glab/forgejo-cli) found — optional; the driver's pr phase will skip pushing/opening the PR without one" >&2
  fi
  # optional: the driver reads Linear issues through the linear-project MCP server —
  # warn (never fail) when it is not configured at user level; a repo-level
  # opencode.jsonc also works at runtime
  user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  if ! grep -qs 'linear-project\|mcp\.linear\.app' "$user_cfg/opencode.json" "$user_cfg/opencode.jsonc" 2>/dev/null; then
    echo "install: warning: no Linear MCP server (linear-project) in your user-level OpenCode config ($user_cfg/opencode.json / opencode.jsonc)" >&2
    echo "  the driver needs it to read Linear issues — add it to your user-level or repo-level opencode config:" >&2
    echo '  { "mcp": { "linear-project": { "type": "remote", "url": "https://mcp.linear.app/mcp", "enabled": true } } }' >&2
  fi
}

# printed after a successful install of this pack
pack_next_steps() {
  cat <<'EOF'

Next steps:
  1. Add '.plan/' to the .gitignore of every repo you run /driver in (ready-made line in snippets/gitignore.txt)
  2. Get started from a repo root in OpenCode: /driver ABC-123
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
