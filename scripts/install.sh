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

# A build failure halfway through a long run is easy to scroll past and
# mistake for a finished install (it happened — the result was an nginx
# alias pointing at a directory that was never deployed). Make the end
# state unmissable either way.
DEPLOY_DONE=0
on_exit() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "*****************************************************************" >&2
    if [ "$DEPLOY_DONE" -eq 1 ]; then
      echo "*** INSTALL FAILED (exit $status) AFTER the deploy step:" >&2
      echo "*** $DEPLOY_TARGET is deployed, but a later step (nginx) failed." >&2
    else
      echo "*** INSTALL FAILED (exit $status) — NOTHING WAS DEPLOYED." >&2
      echo "*** $DEPLOY_TARGET was not created or updated by this run." >&2
    fi
    echo "*** Fix the error above and re-run (the script is idempotent)." >&2
    echo "*****************************************************************" >&2
  fi
}
trap on_exit EXIT

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
# The bundle packer hard-requires Node's native zstd (node:zlib
# zstdCompressSync, added in Node 22.15; upstream CI builds on 24). Probe
# the capability itself — the same check upstream's packer performs —
# rather than trusting version numbers. Distro-packaged Node (e.g. Debian
# stable's 20.x) fails this even though it looks recent.
if ! node -e 'process.exit(typeof require("node:zlib").zstdCompressSync === "function" ? 0 : 1)' 2>/dev/null; then
  echo "ERROR: node $(node --version 2>/dev/null) has no native zstd support" >&2
  echo "       (node:zlib zstdCompressSync, added in Node 22.15). The" >&2
  echo "       playground bundle build hard-requires it; upstream CI builds" >&2
  echo "       on Node 24. Distro packages are often too old — install" >&2
  echo "       Node 24, e.g. via NodeSource:" >&2
  echo "         curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -" >&2
  echo "         sudo apt-get install -y nodejs" >&2
  echo "       then re-run this script." >&2
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
  # "Installed" is not "enabled": the package may already be present but the
  # module disabled for the CLI SAPI. phpenmod is idempotent and covers it.
  if ! "$PHP_BIN" -m | grep -qix sqlite3 && command -v phpenmod >/dev/null 2>&1; then
    $SUDO phpenmod -v "$PHP_MINOR" sqlite3 || $SUDO phpenmod sqlite3 || true
  fi
  if ! "$PHP_BIN" -m | grep -qix sqlite3; then
    echo "ERROR: the PHP CLI the script is using has no sqlite3 extension," >&2
    echo "       even after trying to install and enable it. Evidence:" >&2
    echo "         PHP_BIN: $PHP_BIN ($("$PHP_BIN" -v 2>/dev/null | head -1))" >&2
    echo "         modules: $("$PHP_BIN" -m 2>/dev/null | tr '\n' ' ')" >&2
    echo "       If several PHP versions are installed, the sqlite3 package" >&2
    echo "       may belong to a different one than this CLI — point PHP_BIN" >&2
    echo "       at the matching CLI and re-run, e.g.:" >&2
    echo "         PHP_BIN=/usr/bin/php8.4 $0" >&2
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
  echo "== Clone complete. Nothing was built or deployed (--clone-only). =="
  exit 0
fi

# The php-worker esbuild bundle (several PHP-WASM runtimes + sourcemaps) is
# memory-hungry; on a small server the OOM killer takes esbuild down and the
# only symptom is "Error: The service was stopped". Warn ahead of time.
if [ -r /proc/meminfo ]; then
  AVAIL_KB=$(awk '/^MemAvailable:/ {a=$2} /^SwapFree:/ {s=$2} END {print a+s}' /proc/meminfo)
  if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt 4194304 ]; then
    echo "WARNING: only $((AVAIL_KB / 1024)) MiB memory+swap available. The" >&2
    echo "         php-worker bundle build has been OOM-killed on small" >&2
    echo "         servers (symptom: esbuild 'The service was stopped')." >&2
    echo "         If the build dies, add swap and re-run, e.g.:" >&2
    echo "           fallocate -l 4G /swapfile && chmod 600 /swapfile" >&2
    echo "           mkswap /swapfile && swapon /swapfile" >&2
  fi
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
  echo "== Build complete. NOT deployed (--build-only) — run scripts/deploy.sh next. =="
  exit 0
fi

"$SCRIPT_DIR/deploy.sh"
DEPLOY_DONE=1

if [ "$INSTALL_NGINX" -eq 1 ]; then
  "$SCRIPT_DIR/nginx-try-conf.sh" --install
else
  echo "== nginx configuration for $TRY_LOCATION (not installed — pass --install-nginx, or add it yourself) =="
  "$SCRIPT_DIR/nginx-try-conf.sh"
fi

echo "== Install complete: DEPLOYED to $DEPLOY_TARGET =="
