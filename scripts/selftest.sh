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
mkdir -p "$FAKE/src/runtime" "$FAKE/src/blueprint/steps"
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

check "--list names both patched files" \
  "src/blueprint/steps/moodle-restore.js
src/runtime/config-template.js" \
  "$(node "$SCRIPT_DIR/patch-playground.mjs" --list)"

write_fake_anchor 1
write_fake_budget_anchor
node "$SCRIPT_DIR/patch-playground.mjs" "$FAKE" >/dev/null 2>&1
check "patch applies" "0" "$?"

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

exit $FAILED
