#!/bin/sh
# scripts/release-lib.sh — shared mechanics for the manifest release pipeline (G-113 M2).
#
# Sourced (never executed) by scripts/release-detect.sh, scripts/assemble-manifest.py's
# shell callers, and every packs/<name>/scripts/release.sh. Pure functions are unit-tested
# by scripts/validate.sh.
#
# Provided:
#   ap_classify_path <path> <pack>     -> pack | infra | docs | other
#   ap_bump_of_message <msg>           -> major | minor | patch | none   (conventional commit)
#   ap_highest_bump <a> <b>            -> the higher of two bumps
#   ap_semver_bump <vX.Y.Z> <bump>     -> bumped version
#   ap_pack_bump <pack> <range>        -> highest bump among commits in <range> touching <pack>
#   ap_latest_tag <repo-root>          -> latest v* tag (or empty)
#   ap_release_pack <pack> <repo> <out>-> build packs/<pack>.tar.gz + <pack>.meta.json in <out>

# ap_classify_path <path> <pack> — how a changed path affects <pack>:
#   pack  = the pack's shipped payload (packs/<pack>/** minus repo-only files)
#   infra = shared installer/release paths -> bumps EVERY pack
#   docs  = repo-only or root docs -> no release
#   other = another pack's paths
ap_classify_path() {
  _ap_p=$1; _ap_pack=$2
  case "$_ap_p" in
    "packs/$_ap_pack/"*)
      case "$_ap_p" in
        "packs/$_ap_pack/docs/"*|"packs/$_ap_pack/scripts/"*|"packs/$_ap_pack/README.md"|"packs/$_ap_pack/AGENTS.md")
          echo docs ;;
        *) echo pack ;;
      esac
      ;;
    install.sh|scripts|scripts/*|packs/README.md|.github|.github/*) echo infra ;;
    packs/*) echo other ;;
    *) echo docs ;;
  esac
}

# ap_bump_of_message <full commit message> — conventional-commit classification.
# feat -> minor, fix -> patch, `!` / BREAKING CHANGE: -> major, anything else -> none
# (a path-changed commit with no prefix is a patch — applied by the caller).
ap_bump_of_message() {
  _ap_msg=$1
  case "$_ap_msg" in
    *"BREAKING CHANGE:"*) echo major; return ;;
  esac
  _ap_subj=$(printf '%s' "$_ap_msg" | head -n 1)
  case "$_ap_subj" in
    *\!*) echo major ;;
    feat:*|feat\(*:*) echo minor ;;
    fix:*|fix\(*:*) echo patch ;;
    *) echo none ;;
  esac
}

# ap_highest_bump <a> <b> — major > minor > patch > none
ap_highest_bump() {
  case "$1$2" in
    *major*) echo major ;;
    *minor*) echo minor ;;
    *patch*) echo patch ;;
    *) echo none ;;
  esac
}

# ap_semver_bump <vX.Y.Z> <major|minor|patch>
ap_semver_bump() {
  _ap_v=${1#v}; _ap_bump=$2
  _ap_oldifs=$IFS; IFS=.
  # shellcheck disable=SC2086  # intentional word splitting on '.'
  set -- $_ap_v
  IFS=$_ap_oldifs
  _ap_maj=${1:-0}; _ap_min=${2:-0}; _ap_pat=${3:-0}
  case "$_ap_bump" in
    major) echo "v$((_ap_maj + 1)).0.0" ;;
    minor) echo "v$_ap_maj.$((_ap_min + 1)).0" ;;
    *)     echo "v$_ap_maj.$_ap_min.$((_ap_pat + 1))" ;;
  esac
}

# ap_latest_tag <repo-root> — latest v* tag, normalized to vX.Y.Z (empty when no tags)
ap_latest_tag() {
  git -C "$1" tag -l 'v*' 2>/dev/null | sort -V | tail -n 1
}

# ap_pack_bump <pack> <range> — highest bump among commits in <range> whose changed paths
# touch <pack> (payload) or infra. Prints major|minor|patch|none.
ap_pack_bump() {
  _ap_pack=$1; _ap_range=$2
  _ap_best=none
  for _ap_c in $(git log --format=%H "$_ap_range"); do
    _ap_touched=0
    while IFS= read -r _ap_p; do
      [ -n "$_ap_p" ] || continue
      _ap_cls=$(ap_classify_path "$_ap_p" "$_ap_pack")
      if [ "$_ap_cls" = "pack" ] || [ "$_ap_cls" = "infra" ]; then
        _ap_touched=1
        break
      fi
    done <<_ap_EOF
$(git diff-tree --no-commit-id --name-only -r "$_ap_c")
_ap_EOF
    if [ "$_ap_touched" = "1" ]; then
      _ap_b=$(ap_bump_of_message "$(git log -1 --format=%B "$_ap_c")")
      if [ "$_ap_b" = "none" ]; then _ap_b="patch"; fi   # path-changed without prefix -> patch
      _ap_best=$(ap_highest_bump "$_ap_best" "$_ap_b")
    fi
  done
  echo "$_ap_best"
}

# ap_release_pack <pack> <repo-root> <out-dir> — compute the pack version from
# conventional commits since the latest v* tag, build packs/<pack>.tar.gz (top-level
# <pack>/ with payload + pack.conf + install.sh + vendored install-lib.sh, repo-only
# files stripped), and write <pack>.meta.json {version, description, asset, sha256}.
ap_release_pack() {
  _ap_pack=$1; _ap_repo=$2; _ap_out=$3
  _ap_dir="$_ap_repo/packs/$_ap_pack"
  [ -d "$_ap_dir" ] || { echo "ap_release_pack: no pack dir $_ap_dir" >&2; exit 1; }

  _ap_seed=$(ap_latest_tag "$_ap_repo")
  [ -n "$_ap_seed" ] || _ap_seed="v0.0.0"
  if [ -n "$_ap_seed" ] && [ "$_ap_seed" != "v0.0.0" ]; then
    _ap_range="$_ap_seed..HEAD"
  else
    _ap_range="HEAD"
  fi
  _ap_bump=$(ap_pack_bump "$_ap_pack" "$_ap_range")
  if [ "$_ap_bump" = "none" ]; then _ap_bump="patch"; fi
  _ap_version=$(ap_semver_bump "$_ap_seed" "$_ap_bump")

  _ap_stage=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now — $PACK name is fixed by the caller
  trap "rm -rf '$_ap_stage'" EXIT
  mkdir -p "$_ap_stage/$_ap_pack" "$_ap_out/packs"
  # payload = everything in the pack dir except repo-only scripts/ docs/ README.md AGENTS.md
  (cd "$_ap_dir" && find . -mindepth 1 -maxdepth 1 \
     ! -name scripts ! -name docs ! -name README.md ! -name AGENTS.md \
     -exec cp -RL {} "$_ap_stage/$_ap_pack/" \;)
  # vendored shared mechanics, next to the pack's install.sh
  cp -RL "$_ap_repo/scripts/install-lib.sh" "$_ap_stage/$_ap_pack/install-lib.sh"
  # strip plugin test dirs + bytecode caches from the payload
  find "$_ap_stage/$_ap_pack" -type d -path '*/plugins/*' -name test -prune -exec rm -rf {} +
  find "$_ap_stage/$_ap_pack" -type d \( -name .agent -o -name __pycache__ -o -name node_modules \) -prune -exec rm -rf {} +
  tar -czf "$_ap_out/packs/$_ap_pack.tar.gz" -C "$_ap_stage" "$_ap_pack"

  if command -v sha256sum >/dev/null 2>&1; then
    _ap_sha=$(sha256sum "$_ap_out/packs/$_ap_pack.tar.gz" | awk '{print $1}')
  else
    _ap_sha=$(shasum -a 256 "$_ap_out/packs/$_ap_pack.tar.gz" | awk '{print $1}')
  fi
  _ap_desc=$(
    (
      unset PACK_DESCRIPTION
      # shellcheck disable=SC1090,SC1091
      . "$_ap_dir/pack.conf"
      printf '%s' "${PACK_DESCRIPTION:-}"
    )
  )
  python3 - "$_ap_out/$_ap_pack.meta.json" "$_ap_version" "$_ap_desc" "packs/$_ap_pack.tar.gz" "$_ap_sha" <<'PY'
import json, sys
out, version, desc, asset, sha = sys.argv[1:6]
with open(out, "w", encoding="utf-8") as f:
    json.dump({"version": version, "description": desc, "asset": asset, "sha256": sha},
              f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")
PY
  echo "pack $_ap_pack: version $_ap_version (bump $_ap_bump from seed $_ap_seed) -> $_ap_out/packs/$_ap_pack.tar.gz"
}
