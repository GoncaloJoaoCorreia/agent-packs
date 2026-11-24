#!/bin/sh
# agent-packs installer — one self-contained script, multiple harness packs.
#
#   source  (default inside a local checkout): the script sits next to .git/ and packs/,
#           so it installs by COPYING from the checkout. Nothing is built or compiled.
#
#   release (standalone, e.g. `curl -fsSL <raw-url>/install.sh | sh`): downloads the
#           latest GitHub release payload (agent-packs.tar.gz + SHA256SUMS from
#           releases/latest/download/), verifies the checksum, and installs from that.
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
#   --no-plugin skip every pack's plugins/ payload dir (and remove a previously installed
#               copy via the manifest cleanup)
#
# Release payload: agent-packs.tar.gz with one top-level agent-packs/ dir containing
# packs/ shared/ install.sh LICENSE. Only the selected packs are installed. Each pack is
# described by packs/<name>/pack.conf — see packs/README.md for the contract.
#
# Per selected pack the installer:
#   - hard-fails on any missing PACK_PREREQS tool
#   - copies each PACK_PAYLOAD dir from packs/<name>/ to the dest root (COPY-based on
#     purpose, cp -RL: OpenCode's discovery does not follow symlinked agent files)
#   - composes each PACK_COMPOSE entry "src:dst" (src relative to the payload root,
#     dst relative to the dest root), e.g. shared/agent-scripts:agent-scripts
#   - strips .agent/ and __pycache__/ from everything installed (OpenCode discovers
#     agents/**/*.md recursively — an installed .agent/*.md would register as an agent)
#   - writes <PACK_META_PREFIX>.version + <PACK_META_PREFIX>.manifest into the dest; the
#     manifest drives stale-file cleanup on reinstall and also processes the legacy
#     PACK_LEGACY_MANIFEST once (pre-rename opencode-agents.manifest), then removes it
# Packs may define pack_extra_checks() (warnings) and pack_next_steps() (hints) hooks in
# pack.conf.
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

Release payload: ${TARBALL} + SHA256SUMS from releases/latest/download/.
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
  if ! curl -fsSL "$RELEASE_BASE/$TARBALL" -o "$TMP/$TARBALL" 2>/dev/null \
     || ! curl -fsSL "$RELEASE_BASE/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    echo "install.sh: could not download the latest release payload from $RELEASE_BASE" >&2
    echo "  (no release published yet, or a network problem) — see https://github.com/$REPO/releases" >&2
    exit 1
  fi
  echo "downloaded latest release payload ($TARBALL)"
  version=$(curl -fsSL "$API_LATEST" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || version="latest"
  echo "verifying checksum"
  # shellcheck disable=SC2086  # SHA_CHECK intentionally unquoted (two words)
  if ! (cd "$TMP" && $SHA_CHECK SHA256SUMS); then
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

# ---- pack discovery + selection ----------------------------------------------

list_pack_names() {
  for conf in "$ROOT"/packs/*/pack.conf; do
    [ -f "$conf" ] || continue
    basename "$(dirname "$conf")"
  done | LC_ALL=C sort
}

pack_description() { # $1 = pack name — sourced in a subshell so nothing leaks
  (
    unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PAYLOAD
    # shellcheck disable=SC1090
    . "$ROOT/packs/$1/pack.conf" 2>/dev/null || true
    printf '%s' "${PACK_DESCRIPTION:-}"
  )
}

load_pack() { # $1 = pack name — sources pack.conf and validates the required keys
  conf="$ROOT/packs/$1/pack.conf"
  if [ ! -f "$conf" ]; then
    echo "install.sh: no pack.conf for pack '$1' (looked in $conf)" >&2
    return 1
  fi
  unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PAYLOAD \
        PACK_SHIP_ONLY PACK_COMPOSE PACK_PREREQS PACK_LEGACY_MANIFEST PACK_LEGACY_CLEANUP
  pack_extra_checks() { :; }   # hooks may be (re)defined by pack.conf
  pack_next_steps() { :; }
  # shellcheck disable=SC1090
  . "$conf"
  for v in PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PAYLOAD; do
    eval "val=\${$v:-}"
    if [ -z "$val" ]; then
      echo "install.sh: $conf: missing required key $v" >&2
      return 1
    fi
  done
  if [ "$PACK_NAME" != "$1" ]; then
    echo "install.sh: $conf: PACK_NAME '$PACK_NAME' does not match pack dir '$1'" >&2
    return 1
  fi
  return 0
}

ALL_PACKS=$(list_pack_names)
if [ -z "$ALL_PACKS" ]; then
  echo "install.sh: no packs found (no packs/*/pack.conf under $ROOT)" >&2
  exit 1
fi

DEFAULT_PACK=$(printf '%s\n' "$ALL_PACKS" | head -n 1)
if printf '%s\n' "$ALL_PACKS" | grep -qx opencode; then
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
            p=$(printf '%s\n' "$ALL_PACKS" | awk -v n="$tok" 'NR==n')
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

# ---- per-pack prereq + warning pass (fail before touching any dest) ----------

for p in $PACKS; do
  load_pack "$p" || exit 1
  for t in ${PACK_PREREQS:-}; do
    if ! "$t" --version >/dev/null 2>&1; then
      echo "install.sh: pack '$p' requires $t, but it is missing or could not be executed" >&2
      echo "  install $t and re-run" >&2
      exit 1
    fi
  done
  pack_extra_checks
done

# ---- install ------------------------------------------------------------------

# stale_cleanup <manifest> <dest> <managed-top-dirs...> — remove previously installed
# files (under managed dirs only) that are no longer in $new_list
stale_cleanup() {
  manifest="$1"; dest="$2"; shift 2
  [ -f "$manifest" ] || return 0
  n=0
  while IFS= read -r f; do
    case "$f" in
      *"/.agent/"*|*"__pycache__"*) continue ;;
    esac
    skip=1
    for top in "$@"; do
      case "$f" in "$top"/*) skip=0; break ;; esac
    done
    [ "$skip" = "1" ] && continue
    if ! grep -qxF "$f" "$new_list"; then
      rm -f "$dest/$f"
      n=$((n + 1))
    fi
  done < "$manifest"
  [ "$n" -gt 0 ] && echo "install.sh: removed $n stale file(s) from a previous install"
  return 0
}

# install_pack <pack> <dest> <version> — pack.conf must already be loaded
install_pack() {
  pack="$1"; dest="$2"; version="$3"

  inst=""
  for d in $PACK_PAYLOAD; do
    if [ ! -d "$ROOT/packs/$pack/$d" ]; then
      echo "install.sh: pack '$pack': PACK_PAYLOAD dir '$d' missing under packs/$pack/" >&2
      exit 1
    fi
    if [ "$d" = "plugins" ] && [ "$INSTALL_PLUGIN" = "0" ]; then
      continue
    fi
    inst="$inst $d"
  done

  comp=""
  for e in ${PACK_COMPOSE:-}; do
    src=${e%%:*}; dst=${e#*:}
    if [ -z "$src" ] || [ -z "$dst" ] || [ "$src" = "$e" ]; then
      echo "install.sh: pack '$pack': bad PACK_COMPOSE entry '$e' (want src:dst)" >&2
      exit 1
    fi
    if [ ! -d "$ROOT/$src" ]; then
      echo "install.sh: pack '$pack': PACK_COMPOSE source '$src' missing in the payload root" >&2
      exit 1
    fi
    comp="$comp $e"
  done

  # managed top-level dirs in the dest = installed payload dirs + compose dst roots
  managed=""
  for d in $inst; do
    managed="$managed $d"
  done
  for e in $comp; do
    top=${e#*:}; top=${top%%/*}
    case " $managed " in *" $top "*) ;; *) managed="$managed $top" ;; esac
  done

  mkdir -p "$dest"
  new_list="$dest/.${PACK_META_PREFIX}.manifest.tmp"
  old_manifest="$dest/${PACK_META_PREFIX}.manifest"

  # copy payload dirs (-L dereferences symlinked placeholder agents like plan-thorough.md)
  for d in $inst; do
    mkdir -p "$dest/$d"
    cp -RL "$ROOT/packs/$pack/$d/." "$dest/$d/"
  done
  # compose shared dirs into their dest paths
  for e in $comp; do
    src=${e%%:*}; dst=${e#*:}
    mkdir -p "$dest/$dst"
    cp -RL "$ROOT/$src/." "$dest/$dst/"
  done

  # strip legacy .agent/ + bytecode dirs (OpenCode discovers agents/**/*.md recursively,
  # so an installed .agent/*.md would register as an agent) and make scripts executable
  find_dirs=""
  for top in $managed; do
    [ -d "$dest/$top" ] || continue
    find_dirs="$find_dirs $top"
    find "$dest/$top" -type d \( -name .agent -o -name __pycache__ \) -prune -exec rm -rf {} +
    find "$dest/$top" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  done

  # manifest of installed files (drives stale-file cleanup on reinstall) — built from
  # the SOURCE payload, NOT from the dest, so stale files left in the dest by older
  # installs are not listed here and get removed by stale_cleanup below
  : > "$new_list"
  # shellcheck disable=SC2086  # $inst is an intentional word list
  for d in $inst; do
    (cd "$ROOT/packs/$pack/$d" && find -L . -type f ! -path '*/.agent/*' ! -path '*/__pycache__/*' | sed "s|^\./|$d/|") >> "$new_list"
  done
  # shellcheck disable=SC2086  # $comp is an intentional word list
  for e in $comp; do
    src=${e%%:*}; dst=${e#*:}
    (cd "$ROOT/$src" && find -L . -type f ! -path '*/.agent/*' ! -path '*/__pycache__/*' | sed "s|^\./|$dst/|") >> "$new_list"
  done
  LC_ALL=C sort -o "$new_list" "$new_list"

  # shellcheck disable=SC2086  # $managed is an intentional word list
  stale_cleanup "$old_manifest" "$dest" $managed
  if [ -n "${PACK_LEGACY_MANIFEST:-}" ]; then
    # shellcheck disable=SC2086
    stale_cleanup "$dest/$PACK_LEGACY_MANIFEST" "$dest" $managed
    rm -f "$dest/$PACK_LEGACY_MANIFEST"
  fi
  for f in ${PACK_LEGACY_CLEANUP:-}; do
    rm -f "$dest/$f"
  done

  mv "$new_list" "$old_manifest"
  printf '%s\n' "$version" > "$dest/${PACK_META_PREFIX}.version"

  components=""
  for d in $inst; do components="$components $d/"; done
  for e in $comp; do components="$components ${e#*:}/ (from ${e%%:*})"; done
  echo "Installed pack '$pack' $version -> $dest"
  echo "  components:$components"
  SUMMARY="$SUMMARY
  $pack $version -> $dest"
  pack_next_steps
}

SUMMARY=""
for p in $PACKS; do
  load_pack "$p" || exit 1
  pdest="${DEST:-$PACK_DEFAULT_DEST}"
  install_pack "$p" "$pdest" "$version"
done

echo
echo "Done — installed packs:$SUMMARY"
