#!/bin/bash
# Deploys the Moodle Playground static bundle (built from the pinned
# reference-clones/moodle-playground clone) to the Exchange's /try/ path.
# See dev-docs/oer-platform/DESIGN.md §4 and SANDBOX-UPGRADES.md.
set -euo pipefail

PLAYGROUND_SRC="/vagrant/moodle-dev/reference-clones/moodle-playground"
DEPLOY_TARGET="/srv/oer-sandbox/try"

echo "== Assembling static site tree from ${PLAYGROUND_SRC} =="
sudo mkdir -p "${DEPLOY_TARGET}"
sudo rsync -a --delete "${PLAYGROUND_SRC}/" "${DEPLOY_TARGET}/" \
  --exclude ".git/" \
  --exclude ".github/" \
  --exclude ".cache/" \
  --exclude "docs/" \
  --exclude "node_modules/" \
  --exclude "tests/" \
  --exclude ".agents/"

sudo chown -R www-data:www-data "${DEPLOY_TARGET}"

echo "== Done. Static bundle deployed to ${DEPLOY_TARGET} =="
echo "   Add/verify the nginx location block for /try/ (see HARNESS.md §2c)."
