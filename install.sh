#!/bin/sh
# agent-packs installer — ORCHESTRATOR. Each pack owns its install logic in
# packs/<name>/install.sh (shared mechanics in scripts/install-lib.sh); this script
# handles mode detection, pack discovery/selection, and dispatch to the pack
# installers, ending with a per-pack OK/FAILED summary.
#
#   source  (default inside a local checkout): the script sits next to .git/ and packs/,
#           so it installs by COPYING from the checkout. Nothing is built or compiled.
#
#   release (standalone, e.g. `curl -fsSL <raw-url>/install.sh | sh`): fetches the latest
#           release's manifest.json from releases/latest/download/ (0 API calls), then per
#           selected pack downloads its packs/<name>.tar.gz from the release, verifies the
#           sha256 against the manifest entry, extracts, and dispatches to the pack's
#           vendored install.sh. PACK@<version> pins a release tag (1 paginated API call to
#           list releases + direct manifest downloads).
#
# Usage: install.sh [PACK[@VERSION] ...] [--source|--release] [--dest DIR] [--no-plugin] [--list] [-h|--help]
#
#   PACK ...    packs to install, by name, optionally pinned as PACK@<version> (release
#               mode only), or "all". Default: interactive multi-select when a TTY is
#               available; otherwise the default pack ("opencode" when present, else the
#               first pack alphabetically).
#               NOTE: with `curl ... | sh`, stdin is the script itself, so the prompt reads
#               from /dev/tty — in CI (no TTY) the default pack is installed silently.
#   --list      list the available packs (with versions in release mode) and exit
#   --source    install from the local checkout this script lives in (auto-detected when
#               .git/ and packs/ sit next to the script)
#   --release   install from the latest GitHub release (default when run standalone, e.g.
#               via curl | sh)
#   --dest DIR  install target — only allowed with a single pack; every pack otherwise
#               installs into its own PACK_DEFAULT_DEST
#   --no-plugin skip every pack's plugins/ payload dir
#
# Release payload: each GitHub release carries manifest.json ({schema, release, packs:
# {<name>: {version, description, asset, sha256}}}) plus one packs/<name>.tar.gz per pack
# (top-level <name>/ with payload + pack.conf + install.sh + vendored install-lib.sh).
# Each pack is described by packs/<name>/pack.conf (metadata) and installed by
# packs/<name>/install.sh — see packs/README.md for the contract.
#
# Dispatch: for each selected pack this script runs, with AGENT_PACKS_ROOT=<payload root>:
#   sh <payload-root>/<name>/install.sh check                          # prereqs + warnings,
#                                                                      # before any dest is touched
#   sh <payload-root>/<name>/install.sh install <dest> <version> [--no-plugin]
# The pack installer writes <PACK_META_PREFIX>.version + <PACK_META_PREFIX>.manifest into
# the dest; the manifest drives stale-file cleanup on reinstall and also processes the
# legacy PACK_LEGACY_MANIFEST once, then removes it.
set -eu
unset CDPATH  # keep `cd` output clean when resolving SCRIPT_DIR below

REPO="GoncaloJoaoCorreia/agent-packs"
# overridable for the offline self-tests in scripts/validate.sh (file:// bases)
RELEASE_BASE="${AGENT_PACKS_RELEASE_BASE:-https://github.com/${REPO}/releases}"
API_BASE="${AGENT_PACKS_API:-https://api.github.com/repos/${REPO}}"

MODE="auto"
DEST=""            # empty = per-pack PACK_DEFAULT_DEST
INSTALL_PLUGIN=1
DO_LIST=0
PACKS=""           # selected pack names, space-separated

usage() {
  cat <<EOF
agent-packs installer — installs harness packs (see packs/README.md)

Usage: install.sh [PACK ...] [--source|--release] [--dest DIR] [--no-plugin] [--list] [-h|--help]

  PACK ...    pack names to install, optionally pinned as PACK@<version> (release mode
              only), or "all". Default: interactive multi-select on a TTY (reads /dev/tty,
              so it works with \`curl ... | sh\`), else the default pack ("opencode" when
              present, else the first pack). In CI/no-TTY, pass pack names explicitly.
  --list      list available packs (with versions in release mode) and exit
  --source    install from the local checkout this script lives in (auto-detected
              when .git/ and packs/ sit next to the script)
  --release   install from the latest GitHub release (default when run standalone, e.g.
              via curl | sh)
  --dest DIR  install target (single pack only; default: the pack's PACK_DEFAULT_DEST)
  --no-plugin skip each pack's plugins/ payload dir

Release payload: manifest.json + packs/<name>.tar.gz per pack from releases/latest/download/
(or releases/download/<tag>/ for PACK@<version>).
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

# ---- manifest.json helpers (release mode) --------------------------------------
# The manifest layout is fixed (python json.dump indent=2, sort_keys=True — see
# scripts/assemble-manifest.py), so plain awk can parse it:
#   { "schema": 1, "release": "vX.Y.Z", "packs": { "<name>": { "asset": ..., ... } } }

# mf_packs <manifest.json> — print pack names, one per line
mf_packs() {
  awk '
    /"packs": *\{/ { inp=1; next }
    inp && /^  \}/ { inp=0; next }
    inp && match($0, /^    "[^"]+": *\{/) {
      s = substr($0, RSTART, RLENGTH); sub(/^    "/, "", s); sub(/": *\{$/, "", s)
      print s
    }' "$1"
}

# mf_get <manifest.json> <pack> <field> — print the field value ("" when absent)
mf_get() {
  awk -v want="$2" -v field="$3" '
    /"packs": *\{/ { inp=1; next }
    inp && /^  \}/ { inp=0; next }
    inp && match($0, /^    "[^"]+": *\{/) {
      cur = substr($0, RSTART, RLENGTH); sub(/^    "/, "", cur); sub(/": *\{$/, "", cur)
      next
    }
    inp && cur == want && match($0, /^      "[^"]+": *"/) {
      line = $0
      match(line, /"[^"]+"/)
      key = substr(line, RSTART + 1, RLENGTH - 2)
      if (key != field) next
      rest = substr(line, RSTART + RLENGTH)
      sub(/^ *: */, "", rest); sub(/^"/, "", rest); sub(/",? *$/, "", rest)
      print rest
      exit
    }' "$1"
}

# api_list_releases <page> — raw JSON array of releases (paginated list-releases API call)
api_list_releases() {
  url="$API_BASE/releases?per_page=100&page=$1"
  case "$url" in file://*) url="${url%%\?*}" ;; esac  # file:// test bases carry no query string
  curl -fsSL "$url" 2>/dev/null
}

# resolve_tag <version> — print the release tag matching a PACK@<version> pin (v optional)
resolve_tag() {
  case "$1" in v*) want="$1" ;; *) want="v$1" ;; esac
  page=1
  while [ "$page" -le 50 ]; do
    json=$(api_list_releases "$page") || return 1
    [ -n "$json" ] || return 1
    tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | grep -Fx "$want" | head -n 1)
    if [ -n "$tag" ]; then
      echo "$tag"
      return 0
    fi
    n=$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | wc -l | tr -d ' ')
    if [ "$n" -lt 100 ]; then return 1; fi
    page=$((page + 1))
  done
  return 1
}

if [ "$MODE" = "release" ]; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM
  # Public repo: the plain download URLs work unauthenticated — no gh/token needed.
  # The latest release's manifest.json drives everything (0 API calls for the latest flow).
  LATEST_MANIFEST="$TMP/manifest.latest.json"
  if ! curl -fsSL "$RELEASE_BASE/latest/download/manifest.json" -o "$LATEST_MANIFEST" 2>/dev/null; then
    echo "install.sh: the latest release has no manifest.json (pre-manifest release, or a network problem)" >&2
    echo "  use PACK@<version> from a manifest release, or --source from a checkout — see https://github.com/$REPO/releases" >&2
    exit 1
  fi
  XROOT="$TMP/x"   # extracted per-pack tarballs land here as $XROOT/<name>/
  mkdir -p "$XROOT" "$TMP/dl" "$TMP/sel"
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
  # payload root for the pack installers (they source $AGENT_PACKS_ROOT/scripts/install-lib.sh
  # unless AGENT_PACKS_INSTALL_LIB overrides it)
  export AGENT_PACKS_ROOT="$ROOT"
fi

# ---- pack discovery + selection ----------------------------------------------

list_pack_names() {
  for conf in "$ROOT"/packs/*/pack.conf; do
    [ -f "$conf" ] || continue
    basename "$(dirname "$conf")"
  done | LC_ALL=C sort
}

# pack_conf_value <pack> <var> — read one metadata key from a pack.conf in a subshell
# (so nothing leaks into this shell; PACK_DEFAULT_DEST expands with the current env).
# Release mode reads the pack.conf from the extracted tarball ($XROOT/<pack>/pack.conf).
pack_conf_value() {
  if [ "$MODE" = "release" ]; then
    conf="$XROOT/$1/pack.conf"
  else
    conf="$ROOT/packs/$1/pack.conf"
  fi
  (
    unset PACK_NAME PACK_DESCRIPTION PACK_DEFAULT_DEST PACK_META_PREFIX PACK_PREREQS \
          PACK_LEGACY_MANIFEST PACK_LEGACY_CLEANUP
    # shellcheck disable=SC1090
    . "$conf" 2>/dev/null || true
    eval "printf '%s' \"\${$2:-}\""
  )
}

pack_description() {
  if [ "$MODE" = "release" ]; then
    mf_get "$LATEST_MANIFEST" "$1" description
  else
    pack_conf_value "$1" PACK_DESCRIPTION
  fi
}
pack_default_dest() { pack_conf_value "$1" PACK_DEFAULT_DEST; }

# space-separated word list (a newline-separated list breaks the " $ALL_PACKS " membership
# test below once more than one pack exists)
if [ "$MODE" = "release" ]; then
  ALL_PACKS=$(mf_packs "$LATEST_MANIFEST" | tr '\n' ' ')
else
  ALL_PACKS=$(list_pack_names | tr '\n' ' ')
fi
if [ -z "$ALL_PACKS" ]; then
  if [ "$MODE" = "release" ]; then
    echo "install.sh: the latest release manifest lists no packs" >&2
  else
    echo "install.sh: no packs found (no packs/*/pack.conf under $ROOT)" >&2
  fi
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
    if [ "$MODE" = "release" ]; then
      printf '  %s %s — %s\n' "$p" "$(mf_get "$LATEST_MANIFEST" "$p" version)" "$(pack_description "$p")"
    else
      printf '  %s — %s\n' "$p" "$(pack_description "$p")"
    fi
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

# expand "all", dedupe, validate names (PACK@VERSION pins are release-mode only)
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
  name=$p
  case "$p" in *@*) name=${p%@*} ;; esac
  if [ "$MODE" != "release" ]; then
    case "$p" in
      *@*) echo "install.sh: PACK@VERSION ('$p') only works in --release mode" >&2; exit 2 ;;
    esac
  fi
  case " $ALL_PACKS " in
    *" $name "*) ;;
    *) echo "install.sh: unknown pack '$name' — available: $ALL_PACKS" >&2; exit 2 ;;
  esac
done

# --dest is only meaningful for a single pack
# shellcheck disable=SC2086  # $PACKS is an intentional word list
set -- $PACKS
if [ -n "$DEST" ] && [ $# -gt 1 ]; then
  echo "install.sh: --dest DIR can only be used with a single pack (each pack otherwise uses its PACK_DEFAULT_DEST)" >&2
  exit 2
fi

if [ "$MODE" = "release" ]; then
  # ---- release mode: resolve + download + verify + extract every selected pack,
  # then run each pack's `check` — all before any dest is touched
  for tok in $PACKS; do
    name=$tok; ver=""
    case "$tok" in *@*) name=${tok%@*}; ver=${tok#*@} ;; esac
    mf="$LATEST_MANIFEST"; tag=""
    if [ -n "$ver" ] && [ "$ver" != "latest" ]; then
      if ! tag=$(resolve_tag "$ver"); then
        echo "install.sh: no release found for version '$ver' (pack '$tok')" >&2
        exit 2
      fi
      mf="$TMP/manifest.$tag.json"
      if ! curl -fsSL "$RELEASE_BASE/download/$tag/manifest.json" -o "$mf" 2>/dev/null; then
        echo "install.sh: release $tag has no manifest.json" >&2
        exit 1
      fi
    fi
    asset=$(mf_get "$mf" "$name" asset)
    if [ -z "$asset" ]; then
      echo "install.sh: pack '$name' is not in the release manifest — available: $(mf_packs "$mf" | tr '\n' ' ')" >&2
      exit 2
    fi
    sha=$(mf_get "$mf" "$name" sha256)
    pver=$(mf_get "$mf" "$name" version)
    if [ -z "$sha" ] || [ -z "$pver" ]; then
      echo "install.sh: manifest entry for '$name' lacks sha256/version" >&2
      exit 1
    fi
    if [ -n "$tag" ]; then url="$RELEASE_BASE/download/$tag/$asset"; else url="$RELEASE_BASE/latest/download/$asset"; fi
    echo "downloading $name $pver ($asset)"
    if ! curl -fsSL "$url" -o "$TMP/dl/$name.tar.gz" 2>/dev/null; then
      echo "install.sh: could not download $url" >&2
      exit 1
    fi
    printf '%s  %s\n' "$sha" "$name.tar.gz" > "$TMP/dl/$name.sha256"
    # shellcheck disable=SC2086  # SHA_CHECK intentionally unquoted (two words)
    if ! (cd "$TMP/dl" && $SHA_CHECK "$name.sha256"); then
      echo "install.sh: checksum verification FAILED for $name — refusing to install" >&2
      exit 1
    fi
    if ! tar -xzf "$TMP/dl/$name.tar.gz" -C "$XROOT"; then
      echo "install.sh: could not extract $name.tar.gz" >&2
      exit 1
    fi
    if [ ! -f "$XROOT/$name/install.sh" ]; then
      echo "install.sh: $asset does not contain $name/install.sh" >&2
      exit 1
    fi
    printf '%s\n' "$pver" > "$TMP/sel/$name.version"
  done
  # preflight: prereqs + payload checks + warnings before any dest is touched
  for tok in $PACKS; do
    name=$tok; case "$tok" in *@*) name=${tok%@*} ;; esac
    AGENT_PACKS_ROOT="$XROOT/$name" sh "$XROOT/$name/install.sh" check
  done
  # install: dispatch to each pack's own (vendored) installer
  rc=0
  SUMMARY=""
  for tok in $PACKS; do
    name=$tok; case "$tok" in *@*) name=${tok%@*} ;; esac
    pver=$(cat "$TMP/sel/$name.version")
    pdest="${DEST:-$(pack_default_dest "$name")}"
    np=""
    if [ "$INSTALL_PLUGIN" = "0" ]; then np="--no-plugin"; fi
    # shellcheck disable=SC2086  # $np is an intentional word list (empty or --no-plugin)
    if AGENT_PACKS_ROOT="$XROOT/$name" sh "$XROOT/$name/install.sh" install "$pdest" "$pver" $np; then
      SUMMARY="$SUMMARY
  OK     $name $pver -> $pdest"
    else
      SUMMARY="$SUMMARY
  FAILED $name -> $pdest"
      rc=1
    fi
  done
  echo
  echo "Done — per-pack summary:$SUMMARY"
  if [ "$rc" -ne 0 ]; then
    echo "install.sh: at least one pack failed to install" >&2
    exit 1
  fi
  exit 0
fi

# ---- source mode: preflight + install -------------------------------------------

# preflight: every selected pack's `check` (prereqs, payload dirs, warnings) before any
# dest is touched
for p in $PACKS; do
  sh "$ROOT/packs/$p/install.sh" check
done

# install: dispatch to each pack's own installer
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
