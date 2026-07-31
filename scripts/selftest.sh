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

exit $FAILED
