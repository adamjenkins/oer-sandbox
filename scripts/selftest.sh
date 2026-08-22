#!/bin/bash
# Self-tests for the config parser. Run: scripts/selftest.sh
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name: expected '$expected', got '$actual'" >&2
    FAILED=1
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/good.conf" <<'EOF'
# a comment
OER_CONFIG_STAMP=cfg-7f3a91b0c2d4
LANGPACKS=ja fr
SITE_SETTING_filterall=1
BAKE_PLUGINS_MOODLE_502_STABLE=mod:quizquest
EOF

( source "$SCRIPT_DIR/common.sh"; oer_load_config "$TMP/good.conf"; echo "$OER_CONFIG_STAMP" ) >"$TMP/out" 2>&1
check "stamp is parsed" "cfg-7f3a91b0c2d4" "$(cat "$TMP/out")"

( source "$SCRIPT_DIR/common.sh"; oer_load_config "$TMP/good.conf"; echo "$LANGPACKS" ) >"$TMP/out" 2>&1
check "multi-value key is parsed" "ja fr" "$(cat "$TMP/out")"

printf 'LANGPACK=ja\n' >"$TMP/typo.conf"
( source "$SCRIPT_DIR/common.sh"; oer_load_config "$TMP/typo.conf" ) >"$TMP/out" 2>&1
check "unknown key fails" "1" "$?"
grep -q "LANGPACKS" "$TMP/out" && echo "ok   - did-you-mean names the right key" \
  || { echo "FAIL - no did-you-mean" >&2; FAILED=1; }

printf 'LANGPACKS=ja\n' >"$TMP/evil.conf"
printf 'LANGPACKS=$(touch %s/pwned)\n' "$TMP" >"$TMP/evil.conf"
( source "$SCRIPT_DIR/common.sh"; oer_load_config "$TMP/evil.conf" ) >/dev/null 2>&1
[ ! -f "$TMP/pwned" ] && echo "ok   - values are not executed" \
  || { echo "FAIL - a value was executed" >&2; FAILED=1; }

( source "$SCRIPT_DIR/common.sh"; oer_load_config "$TMP/missing.conf" ) >/dev/null 2>&1
check "missing file fails" "1" "$?"

# A branch-keyed key embeds the allowlist's moodlebranch value verbatim
# (e.g. "5.2" — see bake.sh's oer_branch_to_bundle comment), and a literal
# "." is not legal in a bash identifier. Found empirically running bake.sh
# against a real generated config, not assumed — guard against a regression.
printf 'BAKE_PLUGINS_5.2=mod:quizquest\n' >"$TMP/dotted.conf"
( source "$SCRIPT_DIR/common.sh"
  oer_load_config "$TMP/dotted.conf"
  varname="$(oer_varname "BAKE_PLUGINS_5.2")"
  echo "${!varname}"
) >"$TMP/out" 2>"$TMP/err"
check "dotted branch key is parsed" "mod:quizquest" "$(cat "$TMP/out")"
[ -s "$TMP/err" ] && { echo "FAIL - dotted branch key: stderr was: $(cat "$TMP/err")" >&2; FAILED=1; }

# --- patch-playground.mjs ----------------------------------------------------
# This is a build gate: if it ever stops matching upstream it must FAIL the
# build, not quietly skip the patch. Exercise the failure path with a known-bad
# input as well as the success path, so "the patcher printed nothing" can never
# be mistaken for "the patch applied".
FAKE="$TMP/fake-playground"
mkdir -p "$FAKE/src/runtime" "$FAKE/src/blueprint/steps" "$FAKE/scripts"
write_fake_anchor() {
  local copies="${1:-1}" i
  : >"$FAKE/src/runtime/config-template.js"
  for ((i = 0; i < copies; i++)); do
    printf "if (!property_exists(\$CFG, 'langmenu')) {\n    \$CFG->langmenu = 0;\n}\n" \
      >>"$FAKE/src/runtime/config-template.js"
  done
}
write_fake_budget_anchor() {
  printf 'const MAX_BROWSER_BACKUP_BYTES = 50 * 1024 * 1024;\n' \
    >"$FAKE/src/blueprint/steps/moodle-restore.js"
}
# The DSN is spelled out because the patch anchors on it verbatim — if
# upstream rotates it, the real build fails loudly and this fixture must too.
write_fake_sentry_config() {
  printf '{\n  "name": "fake",\n  "sentry": {\n    "dsn": "https://e6dac7d88c3dae67f635103541a10d66@o4510456164712448.ingest.de.sentry.io/4511915755962448"\n  },\n  "other": true\n}\n' \
    >"$FAKE/playground.config.json"
}

# The h5p-srcdoc edit inserts a hunk into the playground's own Moodle-source
# patcher, so the fixture carries the two things that hunk needs: the anchor it
# is inserted before, and the $PUB prefix detection it relies on.
write_fake_patch_moodle_source() {
  cat >"$FAKE/scripts/patch-moodle-source.sh" <<'SH'
#!/bin/sh
set -eu
SOURCE_DIR=${1:-}
BRANCH=${2:-}
if [ -f "$SOURCE_DIR/public/lib/setup.php" ]; then
  PUB="public/"
else
  PUB=""
fi
BRANCH_PATCH_DIR=""

# Apply per-branch patches (file copies from patches/$BRANCH/)
if [ -n "$BRANCH_PATCH_DIR" ]; then
  echo "would apply branch patches" >&2
fi
SH
}

# The upstream h5p.js text the hunk anchors on, byte-identical in the 5.0 and
# 5.2 bundles and on the live Exchange (sha256 6c28621e8e23…, checked
# 2026-08-21). A fixture rather than the real file so the test states the
# anchor it depends on.
write_fake_h5p_source() {
  local root="$1" pub="$2" dir
  dir="$root/${pub}h5p/h5plib/v128/joubel/core/js"
  mkdir -p "$dir"
  cat >"$dir/h5p.js" <<'JS'
  H5P.jQuery('iframe.h5p-iframe:not(.h5p-initialized)', target).each(function () {
    const iframe = this;
    const $iframe = H5P.jQuery(iframe);

    const writeDocument = function () {
      iframe.contentDocument.open();
      iframe.contentDocument.write('<!doctype html><html class="h5p-iframe" lang="' + contentLanguage + '"><head>' + H5P.getHeadTags(contentId) + '</head><body><div class="h5p-content" data-content-id="' + contentId + '"/></body></html>');
      iframe.contentDocument.close();
    };

    $iframe.addClass('h5p-initialized')
  });
JS
}

check "--list names all four patched files" \
  "src/blueprint/steps/moodle-restore.js
src/runtime/config-template.js
playground.config.json
scripts/patch-moodle-source.sh" \
  "$(node "$SCRIPT_DIR/patch-playground.mjs" --list)"

write_fake_anchor 1
write_fake_budget_anchor
write_fake_sentry_config
write_fake_patch_moodle_source
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "patch applies" "0" "$?"

# --- h5p srcdoc hunk ---------------------------------------------------------
# Not just "the hunk is present": run the PATCHED patcher against a Moodle
# source fixture and assert what the browser would actually get. Chromium does
# not give a document.write()-built about:blank frame the parent's service
# worker, and in this sandbox the SW is the web server — so document.write here
# is a blank H5P in every engine except Firefox.
grep -q 'OER-SANDBOX PATCH: h5p srcdoc' "$FAKE/scripts/patch-moodle-source.sh" \
  && echo "ok   - the h5p srcdoc hunk reached patch-moodle-source.sh" \
  || { echo "FAIL - h5p srcdoc hunk missing" >&2; FAILED=1; }

for pub in "" "public/"; do
  label="${pub:-no-public}"
  SRC="$TMP/fakesrc-${label//\//}"
  rm -rf "$SRC"
  mkdir -p "$SRC/${pub}lib"
  [ -n "$pub" ] && printf 'x\n' >"$SRC/public/lib/setup.php"
  write_fake_h5p_source "$SRC" "$pub"
  H5PJS="$SRC/${pub}h5p/h5plib/v128/joubel/core/js/h5p.js"

  sh "$FAKE/scripts/patch-moodle-source.sh" "$SRC" MOODLE_500_STABLE >/dev/null 2>&1
  check "patched patcher runs against a ${label} tree" "0" "$?"

  grep -q 'iframe.srcdoc = h5pHtml;' "$H5PJS" \
    && echo "ok   - h5p.js builds the frame with srcdoc (${label})" \
    || { echo "FAIL - h5p.js still has no srcdoc path (${label})" >&2; FAILED=1; }
  grep -q "test(navigator.userAgent)" "$H5PJS" \
    && echo "ok   - Firefox keeps the document.write path (${label})" \
    || { echo "FAIL - Firefox fallback missing (${label})" >&2; FAILED=1; }
  # Without this guard the contentDocument===null branch loops forever: it binds
  # writeDocument to the frame's load event with .on(), and assigning srcdoc
  # fires load (document.write does not).
  grep -q 'iframe.h5pSrcdocWritten = true;' "$H5PJS" \
    && echo "ok   - srcdoc path carries its re-entry guard (${label})" \
    || { echo "FAIL - srcdoc re-entry guard missing (${label})" >&2; FAILED=1; }
  # The head-tag URLs must be scoped to the runtime explicitly. Without this the
  # service worker can only route them by guessing the scope from the Referer of
  # an about:srcdoc document — which is exactly the 404 reported from a real
  # Chrome while the headless harness passed.
  grep -qF 'var scopedBase = appBase + scopeMatch[0]' "$H5PJS" \
    && echo "ok   - head tags are rewritten to the scoped runtime path (${label})" \
    || { echo "FAIL - scope rewrite missing from h5p.js (${label})" >&2; FAILED=1; }
  # PARSE the result, do not just grep it. The patch text travels through a JS
  # template literal and then a python heredoc, and a template literal EATS
  # backslashes: a regex written /\/playground\// in the patch reached the
  # bundle as //playground// — grep-level checks all passed and a syntactically
  # broken h5p.js shipped to the live sandbox (2026-08-21).
  if command -v node >/dev/null 2>&1; then
    node --check "$H5PJS" >/dev/null 2>&1 \
      && echo "ok   - patched h5p.js still parses as JavaScript (${label})" \
      || { echo "FAIL - patched h5p.js is not valid JavaScript (${label})" >&2; FAILED=1; }
  fi
  grep -q 'scopeMatch.index' "$H5PJS" \
    && echo "ok   - scope is derived from this document's own URL (${label})" \
    || { echo "FAIL - scope derivation missing (${label})" >&2; FAILED=1; }
  # The write path must survive for Firefox, but must no longer be the only one.
  grep -q 'iframe.contentDocument.write(h5pHtml);' "$H5PJS" \
    && echo "ok   - the document.write fallback is intact (${label})" \
    || { echo "FAIL - document.write fallback lost (${label})" >&2; FAILED=1; }

  sh "$FAKE/scripts/patch-moodle-source.sh" "$SRC" MOODLE_500_STABLE >/dev/null 2>&1
  check "h5p hunk is idempotent (${label})" "0" "$?"
  COUNT=$(grep -c 'iframe.srcdoc = h5pHtml;' "$H5PJS")
  check "h5p hunk applied exactly once (${label})" "1" "$COUNT"
done

# --- h5p div embedding -------------------------------------------------------
# The srcdoc path only helps where the browser gives a srcdoc frame its parent's
# service worker; Chromium below ~135 (e.g. Vivaldi 6.8 / Chromium 126) does not,
# and there the assets 404. Div embedding removes the nested document entirely.
# These fixtures carry the three upstream anchors the hunk needs.
write_fake_h5p_div_sources() {
  local root="$1" pub="$2"
  mkdir -p "$root/${pub}h5p/h5plib/v128/joubel/core" "$root/${pub}h5p/classes" "$root/${pub}h5p/js"
  cat >"$root/${pub}h5p/h5plib/v128/joubel/core/h5p.classes.php" <<'PHP'
<?php
class H5PCore {
  public static function determineEmbedType($contentEmbedType, $libraryEmbedTypes) {
    // Detect content embed type
    $embedType = strpos(strtolower($contentEmbedType), 'div') !== FALSE ? 'div' : 'iframe';
    return $embedType;
  }
}
PHP
  cat >"$root/${pub}h5p/classes/player.php" <<'PHP'
<?php
class player {
    private $jsrequires = [];
    private $cssrequires = [];
    private function get_assets(): array {
        // Get core assets.
        $settings = [];
        $isexternal = false;
        $url = '/x.js';
        if ($this->embedtype === 'div') {
            foreach ([] as $script) {
                $this->jsrequires[] = new \moodle_url($isexternal ? $url : $CFG->wwwroot . $url);
            }
            foreach ([] as $style) {
                $this->cssrequires[] = new \moodle_url($isexternal ? $url : $CFG->wwwroot . $url);
            }
        }
        return $settings;
    }
}
PHP
  mkdir -p "$root/${pub}h5p/h5plib/v128/joubel/core/styles"
  # The appended rule must land in the CORE stylesheet; the hunk refuses to touch
  # a file that does not carry this marker selector.
  cat >"$root/${pub}h5p/h5plib/v128/joubel/core/styles/h5p.css" <<'CSS'
.h5p-iframe-wrapper { width: auto; height: auto; }
CSS
  cat >"$root/${pub}h5p/js/embed.js" <<'JS'
document.onreadystatechange = async() => {
    // Check for H5P iFrame.
    var iFrame = document.querySelector('.h5p-iframe');
    if (!iFrame || !iFrame.contentWindow) {
        return;
    }
    var H5P = await getH5PObject(iFrame);
};
JS
}

for pub in "" "public/"; do
  label="${pub:-no-public}"
  DSRC="$TMP/divsrc-${label//\//}"
  rm -rf "$DSRC"
  mkdir -p "$DSRC/${pub}lib"
  [ -n "$pub" ] && printf 'x\n' >"$DSRC/public/lib/setup.php"
  write_fake_h5p_source "$DSRC" "$pub"
  write_fake_h5p_div_sources "$DSRC" "$pub"

  sh "$FAKE/scripts/patch-moodle-source.sh" "$DSRC" MOODLE_500_STABLE >/dev/null 2>&1
  check "div hunk runs against a ${label} tree" "0" "$?"

  grep -qF "return 'div';" "$DSRC/${pub}h5p/h5plib/v128/joubel/core/h5p.classes.php" \
    && echo "ok   - determineEmbedType forced to div (${label})" \
    || { echo "FAIL - embed type not forced to div (${label})" >&2; FAILED=1; }
  grep -qF 'requires->js(new \moodle_url' "$DSRC/${pub}h5p/classes/player.php" \
    && echo "ok   - div branch actually loads its scripts (${label})" \
    || { echo "FAIL - div branch still only collects unused URLs (${label})" >&2; FAILED=1; }
  grep -qF 'global $CFG, $PAGE;' "$DSRC/${pub}h5p/classes/player.php" \
    && echo "ok   - get_assets declares the globals it uses (${label})" \
    || { echo "FAIL - missing global declaration in get_assets (${label})" >&2; FAILED=1; }
  grep -qF 'contentWindow: window, contentDocument: document' "$DSRC/${pub}h5p/js/embed.js" \
    && echo "ok   - embed.js falls back to the in-document shim (${label})" \
    || { echo "FAIL - embed.js div shim missing (${label})" >&2; FAILED=1; }
  # H5P positions the YouTube iframe by assigning to player.g, a minified YT
  # internal; when that breaks the iframe flows below its aspect-ratio box and is
  # clipped — audio, no picture. The CSS rule restores it regardless.
  grep -qF '.h5p-video-wrapper iframe' "$DSRC/${pub}h5p/h5plib/v128/joubel/core/styles/h5p.css" \
    && echo "ok   - video iframe positioning rule appended to h5p.css (${label})" \
    || { echo "FAIL - video iframe positioning rule missing (${label})" >&2; FAILED=1; }
  COUNT=$(grep -cF 'OER-SANDBOX PATCH: h5p video iframe position' "$DSRC/${pub}h5p/h5plib/v128/joubel/core/styles/h5p.css")
  check "video CSS appended exactly once (${label})" "1" "$COUNT"

  # Parse every file the hunk rewrites — grep cannot see a mangled transform.
  if command -v php >/dev/null 2>&1; then
    php -l "$DSRC/${pub}h5p/classes/player.php" >/dev/null 2>&1 \
      && echo "ok   - patched player.php is valid PHP (${label})" \
      || { echo "FAIL - patched player.php is not valid PHP (${label})" >&2; FAILED=1; }
    php -l "$DSRC/${pub}h5p/h5plib/v128/joubel/core/h5p.classes.php" >/dev/null 2>&1 \
      && echo "ok   - patched h5p.classes.php is valid PHP (${label})" \
      || { echo "FAIL - patched h5p.classes.php is not valid PHP (${label})" >&2; FAILED=1; }
  fi
  if command -v node >/dev/null 2>&1; then
    node --check "$DSRC/${pub}h5p/js/embed.js" >/dev/null 2>&1 \
      && echo "ok   - patched embed.js parses (${label})" \
      || { echo "FAIL - patched embed.js is not valid JavaScript (${label})" >&2; FAILED=1; }
  fi
done

# A known-bad input must FAIL, or this whole section proves nothing: an
# upstream h5p.js refactor has to stop the build, not ship a blank-H5P sandbox.
SRC="$TMP/fakesrc-refactored"
rm -rf "$SRC"
write_fake_h5p_source "$SRC" ""
printf 'upstream refactored writeDocument away\n' \
  >"$SRC/h5p/h5plib/v128/joubel/core/js/h5p.js"
sh "$FAKE/scripts/patch-moodle-source.sh" "$SRC" MOODLE_500_STABLE >"$TMP/out" 2>&1
check "an h5p.js without the anchor fails the build" "1" "$?"
grep -qi 'h5p' "$TMP/out" \
  && echo "ok   - the failure names h5p" \
  || { echo "FAIL - failure message does not mention h5p" >&2; FAILED=1; }

# A tree with no H5P at all is not an error — some branches may not ship it.
SRC="$TMP/fakesrc-noh5p"
rm -rf "$SRC"; mkdir -p "$SRC/lib"
sh "$FAKE/scripts/patch-moodle-source.sh" "$SRC" MOODLE_500_STABLE >/dev/null 2>&1
check "a tree without h5plib is not an error" "0" "$?"

grep -q 'sentryDisabled' "$FAKE/playground.config.json" \
  && echo "ok   - patched config carries the sentry-stripped marker" \
  || { echo "FAIL - sentry-stripped marker missing" >&2; FAILED=1; }
grep -q 'ingest.de.sentry.io' "$FAKE/playground.config.json" \
  && { echo "FAIL - the sentry DSN survived the patch" >&2; FAILED=1; } \
  || echo "ok   - the sentry DSN is gone"

grep -q 'const MAX_BROWSER_BACKUP_BYTES = 384 \* 1024 \* 1024;' \
  "$FAKE/src/blueprint/steps/moodle-restore.js" \
  && echo "ok   - fast-download budget raised to the default 384 MiB" \
  || { echo "FAIL - budget not raised" >&2; FAILED=1; }

# The value is configurable, and a build must be able to choose it — a wrong
# number here is a memory ceiling on every visitor's browser, so it is worth a
# test rather than a comment.
write_fake_budget_anchor
OER_FAST_DOWNLOAD_MAX_MB=128 node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "budget honours OER_FAST_DOWNLOAD_MAX_MB" "0" "$?"
grep -q 'const MAX_BROWSER_BACKUP_BYTES = 128 \* 1024 \* 1024;' \
  "$FAKE/src/blueprint/steps/moodle-restore.js" \
  && echo "ok   - configured budget applied" \
  || { echo "FAIL - configured budget ignored" >&2; FAILED=1; }

# Re-running with a DIFFERENT budget against an already-patched clone must not
# silently keep the old number: the anchor is gone, so without this check the
# generic "anchor missing" failure would send the reader hunting for an
# upstream change that never happened.
OER_FAST_DOWNLOAD_MAX_MB=256 node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >"$TMP/out" 2>&1
check "a different budget on a patched clone fails the build" "1" "$?"
grep -q "DIFFERENT value" "$TMP/out" \
  && echo "ok   - failure names the real problem" \
  || { echo "FAIL - unhelpful failure message for a re-patch" >&2; FAILED=1; }

OER_FAST_DOWNLOAD_MAX_MB=not-a-number node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "a non-numeric budget fails the build" "1" "$?"

write_fake_anchor 1
write_fake_budget_anchor
write_fake_sentry_config
write_fake_patch_moodle_source
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "patch re-applies to a restored clone" "0" "$?"
grep -q 'OER-SANDBOX PATCH: langmenu' "$FAKE/src/runtime/config-template.js" \
  && echo "ok   - patched file carries the marker" \
  || { echo "FAIL - marker missing after patch" >&2; FAILED=1; }
grep -q '\$CFG->langmenu = 0;' "$FAKE/src/runtime/config-template.js" \
  && { echo "FAIL - the forcing assignment survived the patch" >&2; FAILED=1; } \
  || echo "ok   - the forcing assignment is gone"

node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "patch is idempotent" "0" "$?"

printf 'upstream refactored this away\n' >"$FAKE/src/runtime/config-template.js"
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >"$TMP/out" 2>&1
check "missing anchor fails the build" "1" "$?"
grep -q "expected exactly 1" "$TMP/out" \
  && echo "ok   - failure explains what to fix" \
  || { echo "FAIL - unhelpful failure message" >&2; FAILED=1; }

write_fake_anchor 2
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "ambiguous anchor fails the build" "1" "$?"

rm -f "$FAKE/src/runtime/config-template.js"
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "missing file fails the build" "1" "$?"

# --- source-tree sweeps ------------------------------------------------------
# The Moodle source tree is a persistent CACHE between builds, so a plugin or
# language pack an earlier run injected survives every later run — including
# runs whose config no longer names it (fetch-moodle-source.sh does
# `git reset --hard`, which never removes untracked files). That silently bakes
# a de-configured plugin into every later bundle, and, when the plugin cannot
# install on the branch, fails the build with an error naming a plugin that is
# nowhere in the config. Both sweeps below exist to make the config the truth.
#
# Real instances this guards against (2026-08-19): mod_attendance, a 5.1-only
# build, kept failing MOODLE_500_STABLE after being deleted from the allowlist;
# and mod_quizquest, marked bake=0, was installed and visible in a freshly
# baked MOODLE_502_STABLE snapshot.
SRC="$TMP/fake-moodle"
mkdir -p "$SRC/mod/quiz" "$SRC/local" "$SRC/lib/dml" "$SRC/.playground"

write_version_php() {
  mkdir -p "$1"
  printf '<?php\n$plugin->component = %s;\n$plugin->version = 2026010100;\n' "'$2'" >"$1/version.php"
}

# A tracked core plugin, so the sweep has something it must NOT touch.
write_version_php "$SRC/mod/quiz" "mod_quiz"
git -C "$SRC" init -q
git -C "$SRC" add -A
git -C "$SRC" -c user.name=t -c user.email=t@example.invalid commit -qm "core"

# Injected by earlier runs: one the config still wants, one it no longer does.
write_version_php "$SRC/mod/attendance" "mod_attendance"
write_version_php "$SRC/local/accessibility" "local_accessibility"
# Untracked, but not a plugin: the playground's own scratch dir and a patch
# file patch-moodle-source.sh writes. Neither may be swept.
printf 'scratch\n' >"$SRC/.playground/marker"
printf '<?php // patched driver\n' >"$SRC/lib/dml/sqlite3_pdo_moodle_database.php"

( source "$SCRIPT_DIR/common.sh"
  oer_sweep_unconfigured_plugins "$SRC" "$SRC" "local/accessibility"
) >"$TMP/out" 2>&1

[ ! -d "$SRC/mod/attendance" ] \
  && echo "ok   - de-configured plugin is swept" \
  || { echo "FAIL - mod/attendance survived the sweep" >&2; FAILED=1; }
[ -d "$SRC/local/accessibility" ] \
  && echo "ok   - configured plugin is kept" \
  || { echo "FAIL - local/accessibility was swept but is in the config" >&2; FAILED=1; }
[ -f "$SRC/mod/quiz/version.php" ] \
  && echo "ok   - tracked core plugin is kept" \
  || { echo "FAIL - a tracked core plugin was deleted" >&2; FAILED=1; }
[ -f "$SRC/.playground/marker" ] \
  && echo "ok   - untracked non-plugin directory is kept" \
  || { echo "FAIL - .playground was deleted" >&2; FAILED=1; }
[ -f "$SRC/lib/dml/sqlite3_pdo_moodle_database.php" ] \
  && echo "ok   - untracked patch file is kept" \
  || { echo "FAIL - a patch file was deleted" >&2; FAILED=1; }
grep -q "mod_attendance" "$TMP/out" \
  && echo "ok   - the sweep says what it removed" \
  || { echo "FAIL - sweep removed a plugin without naming it" >&2; FAILED=1; }

# A source tree that is not a git checkout must be left alone, not guessed at.
NOGIT="$TMP/not-a-checkout"
write_version_php "$NOGIT/mod/attendance" "mod_attendance"
( source "$SCRIPT_DIR/common.sh"; oer_sweep_unconfigured_plugins "$NOGIT" "$NOGIT" ) >"$TMP/out" 2>&1
check "non-git source tree does not fail the bake" "0" "$?"
[ -d "$NOGIT/mod/attendance" ] \
  && echo "ok   - non-git source tree is left untouched" \
  || { echo "FAIL - swept a tree whose provenance could not be established" >&2; FAILED=1; }

# Language packs live in a directory bake.sh owns outright, so no git is needed.
mkdir -p "$SRC/oer-baked-lang/ja" "$SRC/oer-baked-lang/fr"
printf '<?php\n' >"$SRC/oer-baked-lang/ja/langconfig.php"
printf '<?php\n' >"$SRC/oer-baked-lang/fr/langconfig.php"
( source "$SCRIPT_DIR/common.sh"; oer_sweep_unconfigured_langpacks "$SRC" "ja" ) >/dev/null 2>&1
[ -d "$SRC/oer-baked-lang/ja" ] \
  && echo "ok   - configured langpack is kept" \
  || { echo "FAIL - ja was swept but is in the config" >&2; FAILED=1; }
[ ! -d "$SRC/oer-baked-lang/fr" ] \
  && echo "ok   - de-configured langpack is swept" \
  || { echo "FAIL - fr survived the sweep" >&2; FAILED=1; }

# Both sweeps report how many directories they removed, on stdout (their
# narration goes to stderr). bake.sh needs the plugin count: a swept plugin is
# registered in the branch's install snapshot, so a snapshot cached before the
# sweep still contains it and must not be reused. Nothing else in the script
# would notice — the branch that leaves the snapshot cache untouched is reached
# precisely when there is neither a plugin nor a setting to bake.
write_version_php "$SRC/mod/oldplugin" "mod_oldplugin"
COUNT=$( source "$SCRIPT_DIR/common.sh"
         oer_sweep_unconfigured_plugins "$SRC" "$SRC" "local/accessibility" 2>/dev/null )
check "sweep reports how many plugins it removed" "1" "$COUNT"

COUNT=$( source "$SCRIPT_DIR/common.sh"
         oer_sweep_unconfigured_plugins "$SRC" "$SRC" "local/accessibility" 2>/dev/null )
check "sweep reports zero when it removes nothing" "0" "$COUNT"

mkdir -p "$SRC/oer-baked-lang/de"
COUNT=$( source "$SCRIPT_DIR/common.sh"; oer_sweep_unconfigured_langpacks "$SRC" "ja" 2>/dev/null )
check "langpack sweep reports how many it removed" "1" "$COUNT"

# --- bake-settings.php -------------------------------------------------------
# What it writes into the snapshot has to be a state Moodle actually uses.
# Core defines exactly three (lib/filterlib.php): TEXTFILTER_ON = 1,
# TEXTFILTER_OFF = -1 (available but off, so a course can switch it back on),
# and TEXTFILTER_DISABLED = -9999 (not available anywhere). "off" in a sandbox
# config means the latter — which is also what the Exchange's boot-time
# fallback writes through filter_set_global_state(), so the baked and
# boot-time paths must not disagree about the same input.
PHP="${PHP_BIN:-php}"
if ! "$PHP" -m 2>/dev/null | grep -qi pdo_sqlite; then
  echo "skip - bake-settings.php tests (no pdo_sqlite in $PHP)" >&2
else
  SNAP="$TMP/install.sq3"
  "$PHP" -r '
    $db = new PDO("sqlite:" . $argv[1]);
    $db->exec("CREATE TABLE mdl_config (id INTEGER PRIMARY KEY, name TEXT, value TEXT)");
    $db->exec("CREATE TABLE mdl_filter_active (id INTEGER PRIMARY KEY, filter TEXT, contextid INTEGER, active INTEGER, sortorder INTEGER)");
    $db->exec("INSERT INTO mdl_filter_active (filter, contextid, active, sortorder) VALUES (\"displayh5p\", 1, 1, 1)");
  ' "$SNAP"

  US=$'\x1f'
  printf 'FILTER%sdisplayh5p%soff\nFILTER%smultilang%son\nSETTING%slangmenu%s1\n' \
    "$US" "$US" "$US" "$US" "$US" "$US" | "$PHP" "$SCRIPT_DIR/bake-settings.php" "$SNAP" >/dev/null 2>&1

  read_state() {
    "$PHP" -r '
      $db = new PDO("sqlite:" . $argv[1]);
      $st = $db->prepare("SELECT active FROM mdl_filter_active WHERE filter = :f AND contextid = 1");
      $st->execute(["f" => $argv[2]]);
      $v = $st->fetchColumn();
      echo $v === false ? "none" : $v;
    ' "$SNAP" "$1"
  }
  check "a filter switched off is stored as TEXTFILTER_DISABLED" "-9999" "$(read_state displayh5p)"
  check "a filter switched on is stored as TEXTFILTER_ON" "1" "$(read_state multilang)"

  SETTINGVALUE=$("$PHP" -r '
    $db = new PDO("sqlite:" . $argv[1]);
    $st = $db->prepare("SELECT value FROM mdl_config WHERE name = :n");
    $st->execute(["n" => "langmenu"]);
    $v = $st->fetchColumn();
    echo $v === false ? "none" : $v;
  ' "$SNAP")
  check "a site setting is stored as a core config row" "1" "$SETTINGVALUE"
fi

exit $FAILED
