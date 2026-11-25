#!/bin/sh
# agent-packs installer — ORCHESTRATOR. Each pack owns its install logic in
# packs/<name>/install.sh (shared mechanics in scripts/install-lib.sh); this script
# handles mode detection, pack discovery/selection, and dispatch to the pack
# installers, ending with a per-pack OK/FAILED summary.
#
#   source  (default inside a local checkout): the script sits next to .git/ and packs/,
#           so it installs by COPYING from the checkout. Nothing is built or compiled.
#
#   release (standalone, e.g. `curl -fsSL <raw-url>/install.sh | sh`): downloads the
#           latest GitHub release payload (agent-packs.tar.gz + its .sha256 checksum from
#           releases/latest/download/; falls back to SHA256SUMS), verifies the checksum,
#           and installs from that.
#
# Usage: install.sh [PACK ...] [--source|--release] [--dest DIR] [--no-plugin] [--list] [-h|--help]
#
#   PACK ...    packs to install, by name (described by packs/<name>/pack.conf), or "all".
#               Default: interactive multi-select when a TTY is available; otherwise the
#               default pack ("opencode" when present, else the first pack alphabetically).
#               NOTE: with `curl ... | sh`, stdin is the script itself, so the prompt reads
#               from /dev/tty — in CI (no TTY) the default pack is installed silently.
#   --list      list the available packs and exit
#   --source    install from the local checkout this script lives in (auto-detected when
#               .git/ and packs/ sit next to the script)
#   --release   download + checksum-verify the latest release payload (default when run
#               standalone, e.g. via curl | sh)
#   --dest DIR  install target — only allowed with a single pack; every pack otherwise
#               installs into its own PACK_DEFAULT_DEST
#   --no-plugin skip every pack's plugins/ payload dir
#
# Release payload: agent-packs.tar.gz with one top-level agent-packs/ dir containing
# packs/ install.sh scripts/install-lib.sh LICENSE. Only the selected packs are installed.
# Each pack is described by packs/<name>/pack.conf (metadata) and installed by
# packs/<name>/install.sh — see packs/README.md for the contract.
#
# Dispatch: for each selected pack this script runs, with AGENT_PACKS_ROOT=<payload root>:
#   sh packs/<name>/install.sh check                                   # prereqs + warnings,
#                                                                      # before any dest is touched
#   sh packs/<name>/install.sh install <dest> <version> [--no-plugin]  # the actual install
# The pack installer writes <PACK_META_PREFIX>.version + <PACK_META_PREFIX>.manifest into
# the dest; the manifest drives stale-file cleanup on reinstall and also processes the
# legacy PACK_LEGACY_MANIFEST once, then removes it.
set -eu
unset CDPATH  # keep `cd` output clean when resolving SCRIPT_DIR below

REPO="GoncaloJoaoCorreia/agent-packs"
RELEASE_BASE="https://github.com/${REPO}/releases/latest/download"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
TARBALL="agent-packs.tar.gz"

MODE="auto"
DEST=""            # empty = per-pack PACK_DEFAULT_DEST
INSTALL_PLUGIN=1
DO_LIST=0
PACKS=""           # selected pack names, space-separated

usage() {
  cat <<EOF
agent-packs installer — installs harness packs (see packs/README.md)

Usage: install.sh [PACK ...] [--source|--release] [--dest DIR] [--no-plugin] [--list] [-h|--help]

  PACK ...    pack names to install, or "all". Default: interactive multi-select on a
              TTY (reads /dev/tty, so it works with \`curl ... | sh\`), else the default
              pack ("opencode" when present, else the first pack). In CI/no-TTY, pass
              pack names explicitly.
  --list      list available packs and exit
  --source    install from the local checkout this script lives in (auto-detected
              when .git/ and packs/ sit next to the script)
  --release   download + checksum-verify the latest release payload, then install from
              it (default when run standalone, e.g. via curl | sh)
  --dest DIR  install target (single pack only; default: the pack's PACK_DEFAULT_DEST)
  --no-plugin skip each pack's plugins/ payload dir

Release payload: ${TARBALL} + ${TARBALL}.sha256 from releases/latest/download/
(the release also carries a legacy opencode-agents.tar.gz + SHA256SUMS for pre-rename
installers still served from the old raw URL — this script ignores them).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --source)    MODE="source" ;;
    --release)   MODE="release" ;;
    --dest)      DEST="${2:?install.sh: --dest needs a DIR}"; shift ;;
    --no-plugin) INSTALL_PLUGIN=0 ;;
    --list)      DO_LIST=1 ;;
    -h|--help)   usage; exit 0 ;;
    -*) echo "install.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *)  PACKS="${PACKS:+$PACKS }$1" ;;
  esac
  shift
done

# When piped (`curl ... | sh`), $0 is "sh" — not a file — so auto-detect falls to release mode.
SCRIPT_DIR=""
if [ -f "$0" ]; then
  SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
fi
if [ "$MODE" = "auto" ]; then
  if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/.git" ] && [ -d "$SCRIPT_DIR/packs" ]; then
    MODE="source"
  else
    MODE="release"
  fi
fi

# release mode needs curl + a sha256 tool before any download (fail fast)
if [ "$MODE" = "release" ]; then
  command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is required in release mode" >&2; exit 1; }
fi
if command -v shasum >/dev/null 2>&1; then
  SHA_CHECK="shasum -a 256 -c"     # macOS
elif command -v sha256sum >/dev/null 2>&1; then
  SHA_CHECK="sha256sum -c"          # Linux
else
  echo "install.sh: need shasum (macOS) or sha256sum (Linux) for checksum verification" >&2
  exit 1
fi

if [ "$MODE" = "release" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM
  # Public repo: the plain download URLs work unauthenticated — no gh/token needed.
  if ! curl -fsSL "$RELEASE_BASE/$TARBALL" -o "$TMP/$TARBALL" 2>/dev/null; then
    echo "install.sh: could not download the latest release payload from $RELEASE_BASE" >&2
    echo "  (no release published yet, or a network problem) — see https://github.com/$REPO/releases" >&2
    exit 1
  fi
  echo "downloaded latest release payload ($TARBALL)"
  version=$(curl -fsSL "$API_LATEST" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || version="latest"
  echo "verifying checksum"
  # prefer the dedicated <tarball>.sha256; fall back to the release's SHA256SUMS
  # (older releases only carry that, listing just the main tarball)
  if curl -fsSL "$RELEASE_BASE/$TARBALL.sha256" -o "$TMP/$TARBALL.sha256" 2>/dev/null; then
    :
  elif curl -fsSL "$RELEASE_BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null \
     && grep -F "$TARBALL" "$TMP/SHA256SUMS" > "$TMP/$TARBALL.sha256"; then
    :
  else
    echo "install.sh: could not download a checksum for $TARBALL from $RELEASE_BASE" >&2
    exit 1
  fi
  # shellcheck disable=SC2086  # SHA_CHECK intentionally unquoted (two words)
  if ! (cd "$TMP" && $SHA_CHECK "$TARBALL.sha256"); then
    echo "install.sh: checksum verification FAILED — refusing to install" >&2
    exit 1
  fi
  tar -xzf "$TMP/$TARBALL" -C "$TMP"
  ROOT="$TMP/agent-packs"
  if [ ! -d "$ROOT/packs" ]; then
    echo "install.sh: tarball does not contain a packs/ directory" >&2
    exit 1
  fi
else
  if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR/packs" ]; then
    echo "install.sh: --source but no packs/ next to $0" >&2
    exit 1
  fi
  ROOT="$SCRIPT_DIR"
  version="unknown"
  if [ -d "$ROOT/.git" ] && command -v git >/dev/null 2>&1; then
    version=$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || echo unknown)
  fi
fi

# payload root for the pack installers (they source $AGENT_PACKS_ROOT/scripts/install-lib.sh
# unless AGENT_PACKS_INSTALL_LIB overrides it)
export AGENT_PACKS_ROOT="$ROOT"

# ---- pack discovery + selection ----------------------------------------------

list_pack_names() {
  for conf in "$ROOT"/packs/*/pack.conf; do
    [ -f "$conf" ] || continue
    basename "$(dirname "$conf")"
  done | LC_ALL=C sort
}

# pack_conf_value <pack> <var> — read one metadata key from a pack.conf in a subshell
# (so nothing leaks into this shell; PACK_DEFAULT_DEST expands with the current env)
pack_conf_value() {
  (
    unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PREREQS \
          PACK_LEGACY_MANIFEST PACK_LEGACY_CLEANUP
    # shellcheck disable=SC1090
    . "$ROOT/packs/$1/pack.conf" 2>/dev/null || true
    eval "printf '%s' \"\${$2:-}\""
  )
}

pack_description() { pack_conf_value "$1" PACK_DESCRIPTION; }
pack_default_dest() { pack_conf_value "$1" PACK_DEFAULT_DEST; }

# space-separated word list (a newline-separated list breaks the " $ALL_PACKS " membership
# test below once more than one pack exists)
ALL_PACKS=$(list_pack_names | tr '\n' ' ')
if [ -z "$ALL_PACKS" ]; then
  echo "install.sh: no packs found (no packs/*/pack.conf under $ROOT)" >&2
  exit 1
fi

# shellcheck disable=SC2086  # $ALL_PACKS is an intentional word list
DEFAULT_PACK=$(printf '%s\n' $ALL_PACKS | head -n 1)
# shellcheck disable=SC2086
if printf '%s\n' $ALL_PACKS | grep -qx opencode; then
  DEFAULT_PACK="opencode"
fi

if [ "$DO_LIST" = "1" ]; then
  echo "Available packs:"
  for p in $ALL_PACKS; do
    printf '  %s — %s\n' "$p" "$(pack_description "$p")"
  done
  exit 0
fi

select_packs_interactive() {
  echo "Available packs:"
  i=0
  for p in $ALL_PACKS; do
    i=$((i + 1))
    printf '  %d) %s — %s\n' "$i" "$p" "$(pack_description "$p")"
  done
  tries=0
  while :; do
    printf 'Select packs to install (numbers separated by spaces, or "all") [default: %s]: ' "$DEFAULT_PACK" > /dev/tty
    if ! IFS= read -r answer < /dev/tty; then
      echo > /dev/tty
      PACKS="$DEFAULT_PACK"
      return
    fi
    if [ -z "$answer" ]; then
      PACKS="$DEFAULT_PACK"
      return
    fi
    sel=""
    ok=1
    for tok in $(printf '%s' "$answer" | tr ',' ' '); do
      case "$tok" in
        all) sel="$ALL_PACKS" ;;
        ''|*[!0-9]*) ok=0 ;;
        *)
          if [ "$tok" -ge 1 ] && [ "$tok" -le "$i" ]; then
            # shellcheck disable=SC2086  # $ALL_PACKS is an intentional word list
            p=$(printf '%s\n' $ALL_PACKS | awk -v n="$tok" 'NR==n')
            sel="$sel $p"
          else
            ok=0
          fi
          ;;
      esac
    done
    if [ "$ok" = "1" ] && [ -n "$sel" ]; then
      # shellcheck disable=SC2086  # $sel is an intentional word list
      PACKS=$(printf '%s\n' $sel | LC_ALL=C sort -u | tr '\n' ' ')
      return
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
      echo "install.sh: invalid selection — pass pack names explicitly (see --list)" >&2
      exit 2
    fi
    echo "invalid selection: $answer" > /dev/tty
  done
}

if [ -z "$PACKS" ]; then
  if [ -r /dev/tty ] && [ -t 1 ]; then
    select_packs_interactive
  else
    PACKS="$DEFAULT_PACK"
    echo "install.sh: no pack given and no TTY — installing default pack '$DEFAULT_PACK' (pass PACK names or 'all'; --list shows the options)"
  fi
fi

# expand "all", dedupe, validate names
newpacks=""
for p in $PACKS; do
  if [ "$p" = "all" ]; then
    newpacks="$newpacks $ALL_PACKS"
  else
    newpacks="$newpacks $p"
  fi
done
# shellcheck disable=SC2086  # $newpacks is an intentional word list
PACKS=$(printf '%s\n' $newpacks | LC_ALL=C sort -u | tr '\n' ' ')
for p in $PACKS; do
  case " $ALL_PACKS " in
    *" $p "*) ;;
    *) echo "install.sh: unknown pack '$p' — available: $ALL_PACKS" >&2; exit 2 ;;
  esac
done

# --dest is only meaningful for a single pack
# shellcheck disable=SC2086  # $PACKS is an intentional word list
set -- $PACKS
if [ -n "$DEST" ] && [ $# -gt 1 ]; then
  echo "install.sh: --dest DIR can only be used with a single pack (each pack otherwise uses its PACK_DEFAULT_DEST)" >&2
  exit 2
fi

# ---- preflight: every selected pack's `check` (prereqs, payload dirs, warnings) ----
# before any dest is touched

for p in $PACKS; do
  sh "$ROOT/packs/$p/install.sh" check
done

# ---- install: dispatch to each pack's own installer ----------------------------

rc=0
SUMMARY=""
for p in $PACKS; do
  pdest="${DEST:-$(pack_default_dest "$p")}"
  np=""
  if [ "$INSTALL_PLUGIN" = "0" ]; then np="--no-plugin"; fi
  # shellcheck disable=SC2086  # $np is an intentional word list (empty or --no-plugin)
  if sh "$ROOT/packs/$p/install.sh" install "$pdest" "$version" $np; then
    SUMMARY="$SUMMARY
  OK     $p $version -> $pdest"
  else
    SUMMARY="$SUMMARY
  FAILED $p -> $pdest"
    rc=1
  fi
done

echo
echo "Done — per-pack summary:$SUMMARY"
if [ "$rc" -ne 0 ]; then
  echo "install.sh: at least one pack failed to install" >&2
  exit 1
fi
