#!/bin/bash
# Bakes a loaded config's language packs, plugins, and site settings into a
# branch's Moodle source checkout / install snapshot, ahead of that branch's
# bundle build. Assumes oer_load_config (common.sh) has already run and
# exported LANGPACKS, BAKE_PLUGINS_<bundle-branch>, PLUGIN_ZIP_*,
# PLUGIN_SHA256_*, SITE_SETTING_*, SITE_FILTER_*, TRIAL_DEFAULT_LANG.
#
# Usage: scripts/bake.sh <MOODLE_BRANCH>
#   e.g. scripts/bake.sh MOODLE_502_STABLE
#   GIT_REF, if set, must be the SAME ref the subsequent bundle build will
#   use for this branch — see the settings-baking section below for why.
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
#     they also live under the webroot, not in a git-tracked path;
#   - site settings are baked directly into the install snapshot's SQLite
#     file, proven end-to-end in dev-docs/oer-platform/discoveries/
#     2026-07-31-baking-settings-into-the-install-snapshot.md — see that
#     section below for the mechanism and its cache-fingerprint hazard.
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

# --- Site settings ----------------------------------------------------------
# Three sources, one set of install.sq3 rows (SANDBOX-CONFIG-DESIGN.md
# "Settings baking" / Task 1's decision — proven end-to-end in
# dev-docs/oer-platform/discoveries/2026-07-31-baking-settings-into-the-install-snapshot.md):
#   SITE_SETTING_<name>=<value>  -> a core mdl_config row
#   SITE_FILTER_<name>=on|off    -> the filter's mdl_filter_active row at
#                                    system context (filter state goes
#                                    through filter_set_global_state(), not
#                                    set_config() — why the file spells the
#                                    two prefixes differently)
#   TRIAL_DEFAULT_LANG=<code>    -> the 'lang' config row (the trial's
#                                    default language) — without this the
#                                    key is parsed and then silently
#                                    ignored, worse than not having it
#
# Field/line delimiters use real control characters (not literal backslash
# sequences fed through printf %b) so a value is never re-interpreted for
# escape sequences it happens to contain; a stray delimiter inside a value
# still fails closed (bake-settings.php aborts the whole batch on a
# malformed line) rather than silently misassigning a field.
FIELDSEP=$'\x1f'
SETTINGS_LINES=""
for name in "${!SITE_SETTING_@}"; do
  SETTINGS_LINES="${SETTINGS_LINES}SETTING${FIELDSEP}${name#SITE_SETTING_}${FIELDSEP}${!name}"$'\n'
done
for name in "${!SITE_FILTER_@}"; do
  SETTINGS_LINES="${SETTINGS_LINES}FILTER${FIELDSEP}${name#SITE_FILTER_}${FIELDSEP}${!name}"$'\n'
done
if [ -n "${TRIAL_DEFAULT_LANG:-}" ]; then
  SETTINGS_LINES="${SETTINGS_LINES}LANG${FIELDSEP}${TRIAL_DEFAULT_LANG}"$'\n'
fi

if [ -n "$SETTINGS_LINES" ]; then
  echo "== Baking site settings into the install snapshot for $BRANCH ==" >&2
  require_cmd "$PHP_BIN"

  # Replicate build-moodle-bundle.sh's own pre-snapshot pipeline (source
  # fetch already happened above) so the commit/patches/scripts state — and
  # therefore the SNAPSHOT_FINGERPRINT computed below — is identical to what
  # that script will compute when it runs later in this same install.
  "$PLAYGROUND_DIR/scripts/patch-moodle-source.sh" "$MOODLE_DIR" "$BRANCH"

  if [ -f "$MOODLE_DIR/composer.json" ] && [ -f "$WEBROOT/version.php" ] \
    && { [ ! -f "$MOODLE_DIR/vendor/autoload.php" ] || [ "$MOODLE_DIR/composer.lock" -nt "$MOODLE_DIR/vendor/autoload.php" ]; }; then
    require_cmd composer
    echo "Installing Composer runtime dependencies (Moodle 5.1+)" >&2
    (cd "$MOODLE_DIR" && composer install --no-dev --prefer-dist --classmap-authoritative --no-interaction --no-progress)
  fi

  COMPONENT_CACHE_DIR="$MOODLE_DIR/.playground"
  mkdir -p "$COMPONENT_CACHE_DIR"
  "$PHP_BIN" "$PLAYGROUND_DIR/scripts/generate-component-cache.php" "$MOODLE_DIR" "$COMPONENT_CACHE_DIR/core_component.php" "/www/moodle"

  SNAPSHOT_SCRATCH="$TMPDL/snapshot-scratch"
  mkdir -p "$SNAPSHOT_SCRATCH"
  PHP_BIN="$PHP_BIN" "$PLAYGROUND_DIR/scripts/generate-install-snapshot.sh" "$MOODLE_DIR" "$SNAPSHOT_SCRATCH"

  echo "== Applying settings to $SNAPSHOT_SCRATCH/install.sq3 ==" >&2
  printf '%s' "$SETTINGS_LINES" | "$PHP_BIN" "$SCRIPT_DIR/bake-settings.php" "$SNAPSHOT_SCRATCH/install.sq3"

  # Compute the fingerprint EXACTLY as build-moodle-bundle.sh does
  # (playground/scripts/build-moodle-bundle.sh's snapshot-caching section),
  # so the later `npm run bundle` for this branch finds THIS edited snapshot
  # as a cache HIT instead of silently regenerating a settings-less one —
  # the documented hazard this whole mechanism rests on (see the discovery
  # doc). This is a literal copy of that algorithm: there is no function to
  # import from a shell script, so if upstream ever changes it, this must be
  # updated to match, or the cache-hit silently stops happening.
  MOODLE_COMMIT=$(git -C "$MOODLE_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
  SCRIPTS_HASH=$(cat \
    "$PLAYGROUND_DIR/scripts/generate-install-snapshot.sh" \
    "$PLAYGROUND_DIR/scripts/patch-moodle-source.sh" \
    "$PLAYGROUND_DIR/scripts/generate-component-cache.php" \
    2>/dev/null | shasum -a 256 | cut -d' ' -f1)
  PATCHES_HASH=$(find "$PLAYGROUND_DIR/patches" -type f 2>/dev/null | sort | xargs cat 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
  SNAPSHOT_FINGERPRINT="${MOODLE_COMMIT}-$(printf '%.16s' "$SCRIPTS_HASH")-$(printf '%.16s' "$PATCHES_HASH")"

  SNAPSHOT_CACHE_DIR="$PLAYGROUND_DIR/.cache/snapshots"
  rm -rf "${SNAPSHOT_CACHE_DIR:?}/$BRANCH"
  mkdir -p "$SNAPSHOT_CACHE_DIR/$BRANCH/$SNAPSHOT_FINGERPRINT"
  cp "$SNAPSHOT_SCRATCH/install.sq3" "$SNAPSHOT_CACHE_DIR/$BRANCH/$SNAPSHOT_FINGERPRINT/install.sq3"
  cp "$SNAPSHOT_SCRATCH/localcache.zip" "$SNAPSHOT_CACHE_DIR/$BRANCH/$SNAPSHOT_FINGERPRINT/localcache.zip"
  echo "Settings-baked snapshot cached at fingerprint $SNAPSHOT_FINGERPRINT" >&2
elif [ -n "$PLUGIN_SPECS" ]; then
  echo "== Clearing the snapshot cache for $BRANCH (plugin injected, no settings to bake) ==" >&2
  # The build's own snapshot-fingerprint does NOT account for our webroot
  # plugin injection, so a stale cached snapshot from a prior plugin-less
  # build would otherwise be reused silently and this whole exercise would
  # be a no-op. Force a real rebuild — same reasoning as
  # build-bundle-with-plugins.sh. This branch is only reached when there are
  # no settings to bake: with settings, the block above already placed a
  # fresh, correctly-fingerprinted (and plugin-inclusive, since injection
  # above already happened) snapshot at the cache path directly.
  rm -rf "$PLAYGROUND_DIR/.cache/snapshots/$BRANCH"
else
  echo "== Nothing to bake into the install snapshot for $BRANCH; snapshot cache left untouched ==" >&2
  # Language packs alone don't touch install.sq3 (they live under the
  # webroot, not the DB), so there is nothing here that a cached snapshot
  # could be stale with respect to.
fi

echo "== Baked into $BRANCH: langpacks=[${LANGPACKS:-}] plugins=[${PLUGIN_SPECS:-}] settings=[$([ -n "$SETTINGS_LINES" ] && echo yes || echo no)] ==" >&2
