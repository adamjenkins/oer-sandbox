#!/bin/bash
# Installs the "Try it" sandbox from scratch on any machine: installs the
# required software (idempotently — only what is missing), clones Moodle
# Playground itself (no pre-existing clone needed), builds the service
# worker, shell and Moodle bundles, deploys the static tree, and provides
# the nginx configuration for serving it.
#
# Usage:
#   scripts/install.sh                  # clone + build + deploy, print nginx conf
#   scripts/install.sh --clone-only     # stop after the clone/checkout
#   scripts/install.sh --build-only     # clone + build, no deploy/nginx
#   scripts/install.sh --install-nginx  # also write the nginx snippet to
#                                       # /etc/nginx/snippets/ (still needs a
#                                       # manual include in the vhost)
#
# All paths/versions are environment-overridable — see scripts/common.sh.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

CLONE_ONLY=0
BUILD_ONLY=0
INSTALL_NGINX=0
for arg in "$@"; do
  case "$arg" in
    --clone-only) CLONE_ONLY=1 ;;
    --build-only) BUILD_ONLY=1 ;;
    --install-nginx) INSTALL_NGINX=1 ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# Installs missing prerequisite software. Idempotent: every package is
# guarded by a command/extension probe, so a machine that already has
# everything is never touched and a re-run only fills gaps.
APT_UPDATED=0
apt_install() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: '$*' is missing and this system has no apt-get to install it" >&2
    echo "       with. Install the equivalents of these Debian packages" >&2
    echo "       yourself, then re-run:" >&2
    echo "       git rsync zip nodejs npm php-cli php-sqlite3" >&2
    exit 1
  fi
  if [ "$APT_UPDATED" -eq 0 ]; then
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

echo "== Installing missing prerequisite software =="
command -v git   >/dev/null 2>&1 || apt_install git
command -v rsync >/dev/null 2>&1 || apt_install rsync
command -v zip   >/dev/null 2>&1 || apt_install zip
command -v node  >/dev/null 2>&1 || apt_install nodejs
command -v npm   >/dev/null 2>&1 || apt_install npm
# Upstream's own CI builds on Node 24; anything older than 20 (today's
# oldest distro-packaged Node on Debian stable) is untested territory.
NODE_MAJOR="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])')"
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "ERROR: node $(node --version) is too old — the playground build" >&2
  echo "       tooling is developed against Node 24 (its CI version)." >&2
  echo "       Install Node 20+ (distro package, nvm, or NodeSource) and" >&2
  echo "       re-run." >&2
  exit 1
fi
if [ -z "$PHP_BIN" ] || ! command -v "$PHP_BIN" >/dev/null 2>&1; then
  apt_install php-cli
  PHP_BIN="$(command -v php)"
fi
if ! "$PHP_BIN" -m | grep -qix sqlite3; then
  # The bundles' baseline install snapshot is generated with this CLI and
  # needs sqlite3. Match the extension package to the CLI's own version
  # (php8.4-sqlite3, ...), falling back to the distro default.
  PHP_MINOR="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')"
  apt_install "php${PHP_MINOR}-sqlite3" || apt_install php-sqlite3
  if ! "$PHP_BIN" -m | grep -qix sqlite3; then
    echo "ERROR: $PHP_BIN still lacks the sqlite3 extension after installing" >&2
    echo "       it. If PHP_BIN points outside the distro's PHP, install the" >&2
    echo "       matching sqlite3 extension yourself and re-run." >&2
    exit 1
  fi
fi

echo "== Cloning Moodle Playground =="
if [ ! -d "$PLAYGROUND_DIR/.git" ]; then
  git clone "$PLAYGROUND_REPO" "$PLAYGROUND_DIR"
else
  echo "Existing clone at $PLAYGROUND_DIR — fetching instead of cloning"
  git -C "$PLAYGROUND_DIR" fetch origin
fi
git -C "$PLAYGROUND_DIR" -c advice.detachedHead=false checkout --detach "$PLAYGROUND_REF"
echo "Checked out: $(git -C "$PLAYGROUND_DIR" log --oneline --no-decorate -1)"

if [ "$CLONE_ONLY" -eq 1 ]; then
  exit 0
fi

echo "== Building the service worker and shell =="
# npm run bundle is called directly rather than through the playground
# Makefile: its check-php target insists on PHP 8.3, which is CI parity
# only, not a real constraint (8.4 builds fine).
(cd "$PLAYGROUND_DIR" && npm install && npm run build:version && npm run build-worker)

for spec in $BUNDLES; do
  branch="${spec%%:*}"
  ref="${spec#*:}"
  if [ "$ref" = "$spec" ]; then
    ref=""
  fi
  echo "== Building bundle: $branch${ref:+ (pinned to $ref)} =="
  (cd "$PLAYGROUND_DIR" && env BRANCH="$branch" PHP_BIN="$PHP_BIN" ${ref:+GIT_REF="$ref"} npm run bundle)
done

if [ "$BUILD_ONLY" -eq 1 ]; then
  exit 0
fi

"$SCRIPT_DIR/deploy.sh"

if [ "$INSTALL_NGINX" -eq 1 ]; then
  "$SCRIPT_DIR/nginx-try-conf.sh" --install
else
  echo "== nginx configuration for $TRY_LOCATION (not installed — pass --install-nginx, or add it yourself) =="
  "$SCRIPT_DIR/nginx-try-conf.sh"
fi
