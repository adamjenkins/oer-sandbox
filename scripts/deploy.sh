#!/bin/bash
# Deploys the built Moodle Playground static tree to DEPLOY_TARGET, which
# nginx serves at TRY_LOCATION (see nginx-try-conf.sh). rsync only, never
# symlink. Paths are environment-overridable — see scripts/common.sh.
# See dev-docs/oer-platform/DESIGN.md §4 and SANDBOX-UPGRADES.md.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

require_cmd rsync

if [ ! -f "$PLAYGROUND_DIR/index.html" ]; then
  echo "ERROR: no playground checkout at $PLAYGROUND_DIR — run install.sh first" >&2
  exit 1
fi
# The build artifacts are gitignored upstream, so a fresh clone that was
# never built would deploy a broken shell without this check.
if [ ! -f "$PLAYGROUND_DIR/sw.bundle.js" ] || ! ls "$PLAYGROUND_DIR"/assets/manifests/*.json >/dev/null 2>&1; then
  echo "ERROR: $PLAYGROUND_DIR has no built service worker or bundle manifests" >&2
  echo "       (sw.bundle.js, assets/manifests/*.json) — run install.sh first" >&2
  exit 1
fi

echo "== Assembling static site tree from ${PLAYGROUND_DIR} =="
$SUDO mkdir -p "${DEPLOY_TARGET}"
$SUDO rsync -a --delete "${PLAYGROUND_DIR}/" "${DEPLOY_TARGET}/" \
  --exclude ".git/" \
  --exclude ".github/" \
  --exclude ".cache/" \
  --exclude "docs/" \
  --exclude "node_modules/" \
  --exclude "tests/" \
  --exclude ".agents/"

if [ -n "$WEB_OWNER" ]; then
  $SUDO chown -R "$WEB_OWNER" "${DEPLOY_TARGET}"
fi

echo "== Done. Static bundle deployed to ${DEPLOY_TARGET} =="
echo "   Serve it with the nginx location block from scripts/nginx-try-conf.sh."
