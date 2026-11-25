#!/bin/sh
# scripts/install-lib.sh — shared install mechanics for the pack-owned installers.
#
# Sourced (never executed) by every packs/<name>/install.sh. The root install.sh
# (orchestrator) invokes each pack installer as:
#   AGENT_PACKS_ROOT=<payload root> sh packs/<name>/install.sh check
#   AGENT_PACKS_ROOT=<payload root> sh packs/<name>/install.sh install <dest> <version> [--no-plugin]
# A pack installer finds this file via ${AGENT_PACKS_INSTALL_LIB:-$AGENT_PACKS_ROOT/scripts/install-lib.sh};
# release tarballs vendor a copy next to each pack installer (G-113 M2).
#
# Provided functions:
#   ap_check_prereqs <pack> <tool...>              hard-fail when a tool cannot run `--version`
#   ap_check_payload_dirs <pack-dir> <dir...>      hard-fail when a payload dir is missing
#   ap_stale_cleanup <manifest> <new-list> <dest> <managed-top...>
#   ap_install_pack <pack-dir> <dir...>            full install; config via AP_* variables:
#     AP_DEST AP_PREFIX AP_VERSION AP_MANAGED (required)
#     AP_LEGACY_MANIFEST AP_LEGACY_CLEANUP (optional)

# ap_check_prereqs <pack> <tool...> — every tool must execute `tool --version`
ap_check_prereqs() {
  _ap_pack=$1; shift
  for _ap_t in "$@"; do
    [ -n "$_ap_t" ] || continue
    if ! "$_ap_t" --version >/dev/null 2>&1; then
      echo "install: pack '$_ap_pack' requires $_ap_t, but it is missing or could not be executed" >&2
      echo "  install $_ap_t and re-run" >&2
      exit 1
    fi
  done
}

# ap_check_payload_dirs <pack-dir> <dir...> — every payload dir must exist under the pack dir
ap_check_payload_dirs() {
  _ap_dir=$1; shift
  for _ap_d in "$@"; do
    if [ ! -d "$_ap_dir/$_ap_d" ]; then
      echo "install: payload dir '$_ap_d' missing under $_ap_dir" >&2
      exit 1
    fi
  done
}

# ap_stale_cleanup <manifest> <new-list> <dest> <managed-top...> — remove previously
# installed files (under managed dirs only) that are no longer in <new-list>
ap_stale_cleanup() {
  _ap_manifest=$1; _ap_new=$2; _ap_dest=$3; shift 3
  [ -f "$_ap_manifest" ] || return 0
  _ap_n=0
  while IFS= read -r _ap_f; do
    case "$_ap_f" in
      *'/.agent/'*|*'__pycache__'*) continue ;;
    esac
    _ap_skip=1
    for _ap_top in "$@"; do
      case "$_ap_f" in "$_ap_top"/*) _ap_skip=0; break ;; esac
    done
    [ "$_ap_skip" = "1" ] && continue
    if ! grep -qxF "$_ap_f" "$_ap_new"; then
      rm -f "$_ap_dest/$_ap_f"
      _ap_n=$((_ap_n + 1))
    fi
  done < "$_ap_manifest"
  if [ "$_ap_n" -gt 0 ]; then
    echo "install: removed $_ap_n stale file(s) from a previous install"
  fi
  return 0
}

# ap_install_pack <pack-dir> <dir...> — copy the payload dirs into AP_DEST, strip
# .agent//__pycache__, chmod scripts, then write <AP_PREFIX>.manifest/.version with
# stale-file + legacy cleanup. AP_MANAGED lists the managed top-level dirs in the dest
# (the installed payload dirs) that stale cleanup is allowed to touch; it may be empty
# (e.g. --no-plugin on a plugins-only pack).
ap_install_pack() {
  _ap_src=$1; shift
  : "${AP_DEST:?ap_install_pack: AP_DEST unset}"
  : "${AP_PREFIX:?ap_install_pack: AP_PREFIX unset}"
  : "${AP_VERSION:?ap_install_pack: AP_VERSION unset}"
  if [ -z "${AP_MANAGED+x}" ]; then
    echo "ap_install_pack: AP_MANAGED unset" >&2
    exit 1
  fi

  mkdir -p "$AP_DEST"
  # copy payload dirs (-L dereferences symlinked placeholder agents like plan-thorough.md)
  for _ap_d in "$@"; do
    mkdir -p "$AP_DEST/$_ap_d"
    cp -RL "$_ap_src/$_ap_d/." "$AP_DEST/$_ap_d/"
  done

  # strip legacy .agent/ + bytecode dirs (OpenCode discovers agents/**/*.md recursively,
  # so an installed .agent/*.md would register as an agent) and make scripts executable
  for _ap_d in "$@"; do
    [ -d "$AP_DEST/$_ap_d" ] || continue
    find "$AP_DEST/$_ap_d" -type d \( -name .agent -o -name __pycache__ \) -prune -exec rm -rf {} +
    find "$AP_DEST/$_ap_d" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
  done

  # manifest of installed files (drives stale-file cleanup on reinstall) — built from
  # the SOURCE payload, NOT from the dest, so stale files left in the dest by older
  # installs are not listed here and get removed by ap_stale_cleanup below
  _ap_new="$AP_DEST/.${AP_PREFIX}.manifest.tmp"
  : > "$_ap_new"
  for _ap_d in "$@"; do
    (cd "$_ap_src/$_ap_d" && find -L . -type f ! -path '*/.agent/*' ! -path '*/__pycache__/*' | sed "s|^\./|$_ap_d/|") >> "$_ap_new"
  done
  LC_ALL=C sort -o "$_ap_new" "$_ap_new"

  # shellcheck disable=SC2086  # $AP_MANAGED is an intentional word list
  ap_stale_cleanup "$AP_DEST/${AP_PREFIX}.manifest" "$_ap_new" "$AP_DEST" $AP_MANAGED
  if [ -n "${AP_LEGACY_MANIFEST:-}" ]; then
    # shellcheck disable=SC2086
    ap_stale_cleanup "$AP_DEST/$AP_LEGACY_MANIFEST" "$_ap_new" "$AP_DEST" $AP_MANAGED
    rm -f "$AP_DEST/$AP_LEGACY_MANIFEST"
  fi
  # shellcheck disable=SC2086  # $AP_LEGACY_CLEANUP is an intentional word list
  for _ap_f in ${AP_LEGACY_CLEANUP:-}; do
    rm -f "$AP_DEST/$_ap_f"
  done

  mv "$_ap_new" "$AP_DEST/${AP_PREFIX}.manifest"
  printf '%s\n' "$AP_VERSION" > "$AP_DEST/${AP_PREFIX}.version"
}
