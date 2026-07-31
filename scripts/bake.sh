#!/bin/bash
# Bakes a loaded config's language packs and plugins into a branch's Moodle
# source checkout, ahead of that branch's bundle build. Assumes
# oer_load_config (common.sh) has already run and exported LANGPACKS,
# BAKE_PLUGINS_<bundle-branch>, PLUGIN_ZIP_*, PLUGIN_SHA256_*.
#
# Usage: scripts/bake.sh <MOODLE_BRANCH>
#   e.g. scripts/bake.sh MOODLE_502_STABLE
#
# Mirrors build-bundle-with-plugins.sh:52-103 for source fetching, the 5.1+
# public/ webroot detection, plugin injection, and the snapshot-cache clear
# — that script is the proven precedent for baking into the install
# snapshot's source tree; read it first, its comments explain why each step
# exists. What is different here:
#   - plugins arrive as a ZIP URL + sha256 (the Exchange's
#     allowlist_file.php), not an already-checked-out source directory, so
#     this script downloads, verifies the checksum, and unzips before
#     injecting — a checksum that is never compared is worse than none;
#   - language packs are baked the same way (download, unzip, inject) since
#     they also live under the webroot, not in a git-tracked path.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

BRANCH="${1:?Usage: $0 <MOODLE_BRANCH>}"

if [ ! -d "$PLAYGROUND_DIR/.git" ]; then
  echo "ERROR: no playground checkout at $PLAYGROUND_DIR — run install.sh first" >&2
  exit 1
fi
require_cmd curl
require_cmd unzip
require_cmd rsync

# The allowlist's moodlebranch column stores "5.2"-style strings (major.minor
# only), NOT the "MOODLE_502_STABLE" bundle-branch string this script is
# invoked with — confirmed against the real code, not the plan's example:
# moodle-local_oerexchange/classes/local/allowlist_manager.php's
# is_valid_branch() accepts only /^\d+\.\d+$/, and the live allowlist row
# used to test this script has moodlebranch = "5.2". config::render()
# (moodle-local_oerexchange/classes/local/sandbox/config.php) groups and
# emits BAKE_PLUGINS_<moodlebranch>=... keyed on that raw stored value, so
# this script must derive the same "5.2" form from its own MOODLE_BRANCH
# argument to find the matching keys. This mirrors playground.php's own
# branch_to_bundle() (classes/local/sandbox/playground.php:55-61).
oer_branch_to_bundle() {
  local branch="$1"
  if [[ "$branch" =~ ^MOODLE_([0-9])([0-9]{2})_STABLE$ ]]; then
    printf '%s.%s' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
  fi
}
BUNDLE_BRANCH="$(oer_branch_to_bundle "$BRANCH")"

echo "== Fetching/updating Moodle source for $BRANCH ==" >&2
MOODLE_DIR=$("$PLAYGROUND_DIR/scripts/fetch-moodle-source.sh" "$BRANCH")
echo "Source at: $MOODLE_DIR" >&2

# Moodle 5.1+ nests the docroot under public/.
if [ -d "$MOODLE_DIR/public" ]; then
  WEBROOT="$MOODLE_DIR/public"
else
  WEBROOT="$MOODLE_DIR"
fi

TMPDL=$(mktemp -d)
cleanup_tmpdl() { rm -rf "$TMPDL"; }
trap cleanup_tmpdl EXIT

# --- Language packs ---------------------------------------------------------
# download.moodle.org's langpack directories are keyed by Moodle series
# (e.g. "5.2"), the same form as BUNDLE_BRANCH above.
for code in ${LANGPACKS:-}; do
  if ! [[ "$code" =~ ^[a-z][a-z0-9_]*$ ]]; then
    echo "ERROR: invalid language pack code '$code'" >&2
    exit 1
  fi
  if [ -z "$BUNDLE_BRANCH" ]; then
    echo "ERROR: cannot derive a Moodle series from branch '$BRANCH' to fetch langpack '$code'" >&2
    exit 1
  fi
  echo "== Baking language pack: $code (series $BUNDLE_BRANCH) ==" >&2
  LANGZIP="$TMPDL/lang-$code.zip"
  curl -fL "https://download.moodle.org/download.php/direct/langpack/$BUNDLE_BRANCH/$code.zip" -o "$LANGZIP"
  LANGDIR="$TMPDL/lang-$code"
  rm -rf "$LANGDIR"
  mkdir -p "$LANGDIR"
  unzip -q "$LANGZIP" -d "$LANGDIR"
  TARGET="$WEBROOT/oer-baked-lang/$code"
  rm -rf "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  # The pack zip's top-level entry is normally "<code>/"; normalize so
  # oer-baked-lang/<code>/langconfig.php exists regardless of the zip's
  # exact internal layout.
  if [ -d "$LANGDIR/$code" ]; then
    mv "$LANGDIR/$code" "$TARGET"
  else
    mv "$LANGDIR" "$TARGET"
  fi
  if [ ! -f "$TARGET/langconfig.php" ]; then
    echo "ERROR: baked language pack '$code' has no langconfig.php at $TARGET" >&2
    exit 1
  fi
done

# --- Plugins -----------------------------------------------------------------
# oer_varname (common.sh) mirrors the sanitization oer_load_config applied
# when storing this key — BUNDLE_BRANCH's dot ("5.2") is not legal in a bash
# identifier, so both sides must transform it the same way.
PLUGIN_SPECS_VAR="$(oer_varname "BAKE_PLUGINS_${BUNDLE_BRANCH}")"
PLUGIN_SPECS="${!PLUGIN_SPECS_VAR:-}"
for SPEC in $PLUGIN_SPECS; do
  PLUGIN_TYPE="${SPEC%%:*}"
  PLUGIN_NAME="${SPEC#*:}"
  if [ -z "$PLUGIN_TYPE" ] || [ -z "$PLUGIN_NAME" ] || [ "$PLUGIN_TYPE" = "$SPEC" ]; then
    echo "ERROR: invalid plugin spec '$SPEC' in $PLUGIN_SPECS_VAR - expected type:name" >&2
    exit 1
  fi

  SUFFIX="${PLUGIN_TYPE}_${PLUGIN_NAME}_${BUNDLE_BRANCH}"
  ZIPVAR="$(oer_varname "PLUGIN_ZIP_${SUFFIX}")"
  SHAVAR="$(oer_varname "PLUGIN_SHA256_${SUFFIX}")"
  PLUGIN_URL="${!ZIPVAR:-}"
  PLUGIN_SHA="${!SHAVAR:-}"
  if [ -z "$PLUGIN_URL" ] || [ -z "$PLUGIN_SHA" ]; then
    echo "ERROR: $PLUGIN_SPECS_VAR names $SPEC but $ZIPVAR / $SHAVAR is missing from the config" >&2
    exit 1
  fi

  # Moodle's own plugin-type-to-directory map (the ones this platform is
  # likely to ever need baked in) — same map as build-bundle-with-plugins.sh.
  case "$PLUGIN_TYPE" in
    mod) TYPE_DIR="mod" ;;
    block) TYPE_DIR="blocks" ;;
    local) TYPE_DIR="local" ;;
    *)
      echo "ERROR: unknown plugin type '$PLUGIN_TYPE' - add its directory to the case statement in this script" >&2
      exit 1
      ;;
  esac

  echo "== Downloading plugin $PLUGIN_TYPE:$PLUGIN_NAME from $PLUGIN_URL ==" >&2
  PLUGIN_ZIP="$TMPDL/plugin-$PLUGIN_TYPE-$PLUGIN_NAME.zip"
  curl -fL "$PLUGIN_URL" -o "$PLUGIN_ZIP"

  ACTUAL_SHA=$(sha256sum "$PLUGIN_ZIP" | cut -d' ' -f1)
  if [ "$ACTUAL_SHA" != "$PLUGIN_SHA" ]; then
    echo "ERROR: sha256 mismatch for $PLUGIN_TYPE:$PLUGIN_NAME — refusing to inject an unverified plugin" >&2
    echo "       expected: $PLUGIN_SHA" >&2
    echo "       actual:   $ACTUAL_SHA" >&2
    exit 1
  fi
  echo "sha256 verified: $ACTUAL_SHA" >&2

  PLUGIN_SRC="$TMPDL/plugin-src-$PLUGIN_TYPE-$PLUGIN_NAME"
  rm -rf "$PLUGIN_SRC"
  mkdir -p "$PLUGIN_SRC"
  unzip -q "$PLUGIN_ZIP" -d "$PLUGIN_SRC"
  # allowlist_file.php mirrors the plugin's own repo zip, which typically
  # has a single top-level directory (moodle-mod_quizquest-main/ or
  # similar); descend into it if that's the only entry, so files land
  # directly under mod/quizquest/, not mod/quizquest/moodle-mod_quizquest-main/.
  ENTRY_COUNT=$(find "$PLUGIN_SRC" -mindepth 1 -maxdepth 1 | wc -l)
  if [ "$ENTRY_COUNT" -eq 1 ]; then
    INNER=$(find "$PLUGIN_SRC" -mindepth 1 -maxdepth 1 -type d)
    [ -n "$INNER" ] && PLUGIN_SRC="$INNER"
  fi

  TARGET_DIR="$WEBROOT/$TYPE_DIR/$PLUGIN_NAME"
  echo "== Injecting $PLUGIN_TYPE $PLUGIN_NAME -> $TARGET_DIR ==" >&2
  rm -rf "$TARGET_DIR"
  mkdir -p "$TARGET_DIR"
  rsync -a --exclude=.git "$PLUGIN_SRC/" "$TARGET_DIR/"
done

echo "== Clearing the snapshot cache for $BRANCH ==" >&2
# The build's own snapshot-fingerprint (Moodle source commit + build-script
# hash + patches-dir hash) does NOT account for our webroot injections, so a
# stale cached snapshot from a prior (pack/plugin-less) build would
# otherwise be reused silently and this whole exercise would be a no-op.
# Force a real rebuild — same reasoning as build-bundle-with-plugins.sh.
rm -rf "$PLAYGROUND_DIR/.cache/snapshots/$BRANCH"

echo "== Baked into $BRANCH: langpacks=[${LANGPACKS:-}] plugins=[${PLUGIN_SPECS:-}] ==" >&2
