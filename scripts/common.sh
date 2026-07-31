# Shared configuration for the oer-sandbox scripts. Sourced, not executed.
#
# Every value can be overridden from the environment so the scripts run on
# any machine — nothing here may hardcode a path that exists only on one
# dev box.
#
#   PLAYGROUND_REPO  Git URL of Moodle Playground (upstream by default).
#   PLAYGROUND_REF   Commit/tag to check out. Pinned so a fresh install is
#                    reproducible; see README "Source pin" for what the
#                    default pin is and how it was chosen.
#   PLAYGROUND_DIR   Where the playground clone lives. Defaults to
#                    ./playground inside this repo (gitignored); point it
#                    at an existing clone to reuse one.
#   BUNDLES          Space-separated bundle specs, each BRANCH[:GIT_REF].
#   DEPLOY_TARGET    Directory the built static tree is rsynced to.
#   TRY_LOCATION     URL path nginx serves the sandbox at.
#   WEB_OWNER        user:group the deployed tree is chowned to; set it
#                    empty to skip the chown entirely.
#   PHP_BIN          PHP CLI used for install-snapshot generation (needs
#                    the sqlite3 extension).

OER_SANDBOX_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

PLAYGROUND_REPO="${PLAYGROUND_REPO:-https://github.com/ateeducacion/moodle-playground.git}"
PLAYGROUND_REF="${PLAYGROUND_REF:-2707585fd78849e33f6f663cb81655de88a96513}"
PLAYGROUND_DIR="${PLAYGROUND_DIR:-$OER_SANDBOX_ROOT/playground}"
BUNDLES="${BUNDLES:-MOODLE_502_STABLE:v5.2.0 MOODLE_500_STABLE}"
DEPLOY_TARGET="${DEPLOY_TARGET:-/srv/oer-sandbox/try}"
TRY_LOCATION="${TRY_LOCATION:-/try/}"
WEB_OWNER="${WEB_OWNER-www-data:www-data}"
PHP_BIN="${PHP_BIN:-$(command -v php || true)}"

# Run privileged steps directly when already root (containers, CI).
SUDO="sudo"
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
fi

# nginx needs the trailing slash on both the location and the alias.
case "$TRY_LOCATION" in
  */) ;;
  *) TRY_LOCATION="$TRY_LOCATION/" ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}
