# oer-sandbox

Deployment kit for the OER Exchange platform's "Try it" sandbox — a
same-origin static deployment of [Moodle Playground](https://github.com/ateeducacion/moodle-playground)
(in-browser Moodle via PHP-WASM). No server-side trial execution, no
Podman fleet — see `dev-docs/oer-platform/DESIGN.md` §4 and
`SANDBOX-COMPARISON.md`/`SANDBOX-UPGRADES.md` for the full design and
rationale.

This repo does **not** vendor the playground source. `scripts/install.sh`
clones Moodle Playground itself at a pinned commit and builds it; nothing
here assumes a clone already exists somewhere on disk. The scripts run on
any machine — every path and version is an environment variable with a
sane default (see `scripts/common.sh`).

## Installing on a fresh machine

```bash
git clone <this-repo> oer-sandbox
oer-sandbox/scripts/install.sh
```

That clones the playground (`PLAYGROUND_REPO` at `PLAYGROUND_REF`, into
the gitignored `playground/` inside this repo), builds the service
worker, shell, and the `MOODLE_502_STABLE` (pinned `v5.2.0`) +
`MOODLE_500_STABLE` bundles, rsyncs the static tree to
`/srv/oer-sandbox/try/`, and prints the nginx `location` block for
`/try/`. `--clone-only` / `--build-only` stop early; `--install-nginx`
additionally writes the block to `/etc/nginx/snippets/oer-sandbox-try.conf`
(you still add the `include` line to your vhost's `server {}` yourself —
the script never edits a vhost).

`install.sh` also installs the software the build needs, idempotently:
each of `git`, `rsync`, `zip`, `node`+`npm`, and a PHP CLI with the
`sqlite3` extension (install-snapshot generation) is probed first and
apt-installed only if missing, so a machine that already has everything
is never touched and a re-run only fills gaps. On a non-apt system the
script instead lists the missing packages and exits. Node older than 20
is refused (upstream's CI builds on Node 24). PHP 8.4 works fine despite
the playground Makefile's `check-php` target insisting on 8.3 — that
check is CI-parity only, not a real constraint, which is why the scripts
call `npm run bundle` directly instead of going through `make`.

Overridable settings (full list in `scripts/common.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `PLAYGROUND_REPO` | `https://github.com/ateeducacion/moodle-playground.git` | Playground git URL |
| `PLAYGROUND_REF` | see "Source pin" below | Commit/tag to build from |
| `PLAYGROUND_DIR` | `<this repo>/playground` | Clone location (reuse an existing clone by pointing this at it) |
| `BUNDLES` | `MOODLE_502_STABLE:v5.2.0 MOODLE_500_STABLE` | `BRANCH[:GIT_REF]` specs |
| `DEPLOY_TARGET` | `/srv/oer-sandbox/try` | Where the static tree is rsynced |
| `TRY_LOCATION` | `/try/` | URL path nginx serves it at |
| `WEB_OWNER` | `www-data:www-data` | Ownership of the deployed tree (empty = skip chown) |
| `PHP_BIN` | `php` from `PATH` | PHP CLI for snapshot generation |

To rebuild/redeploy later, rerun `install.sh` (an existing clone is
fetched, not re-cloned) or run `scripts/deploy.sh` alone if the bundles
are already built.

### Source pin

`PLAYGROUND_REF` defaults to `2707585fd78849e33f6f663cb81655de88a96513`
(upstream `main` as of 2026-07-27). The live-verified deployment (see
Status below) was built at `8d9c59b`; the `8d9c59b..2707585` diff was
assessed 2026-07-27 as dependency housekeeping only (php-wasm
3.1.44→3.1.45, biome, concurrently, GH Actions). Bump the pin
deliberately, after checking the upstream diff — not by pointing it at
`main`.

## nginx

`scripts/nginx-try-conf.sh` prints the `location ^~ /try/ { ... }` block
(paths substituted from the environment); `--install` writes it to
`/etc/nginx/snippets/oer-sandbox-try.conf`. Either way it must be
included **inside** the `server {}` block that serves the site, before
any PHP handling — the `^~` modifier is what stops a same-vhost Moodle's
PHP regex locations from capturing `/try/*` requests.

## Status (2026-07-19; scripts reworked 2026-07-31)

**2026-07-31**: the scripts were made machine-portable (self-cloning
install, parameterized paths, generated nginx config, idempotent
prerequisite installation). Verified that day: `install.sh --clone-only`
against upstream GitHub (fresh clone and re-run/fetch, pinned commit
resolves), the nginx output with default and overridden paths, and
`deploy.sh`'s rsync/excludes and its refuses-unbuilt-clone guard, all
against scratch directories. **Not yet verified**: a full fresh
`npm install` + bundle build driven by the new wrapper (the build
commands themselves are unchanged from the sequence last exercised
end-to-end on 2026-07-19), and the prerequisite auto-install path on a
machine that is actually missing packages — the probe/skip half of its
logic is what was exercised. The section below predates the rework.

Deployed and verified end-to-end, including the actual in-browser WASM boot:

- Static assets (bundles, manifests, `sw.bundle.js`, shell) serve correctly
  under `https://vagrant.wisecat.net/try/` (curl-verified, all 200s).
- The Service Worker registers with the correct scope and the shell →
  remote.html → nested runtime iframe chain resolves correctly, confirmed
  in a real headless Chromium session (Playwright).
- The Exchange's `sandbox_launch.php` produces a correctly-formed launch
  URL end-to-end over real HTTP: signed download URL, base64-encoded
  blueprint (`installMoodle` → `login` → `restoreCourse` →
  `landingPage`), verified by decoding the redirect Location header.
- **The in-browser boot itself now completes** — verified live,
  2026-07-18, in a real (non-headless-flagged) Chromium/Playwright session:
  progress reaches 100% with the status line "Moodle bootstrapped for PHP
  8.3 + Moodle 5.2.x" in under 10 seconds, already logged in with the
  shared resource restored. An earlier session on the same day did hit the
  `net::ERR_ABORTED` manifest-fetch failure described in prior revisions of
  this file (a known class of flakiness under headless/CI resource
  contention, per upstream's own test suite skipping the equivalent
  scenario in CI) — it did not reproduce on retry and is not currently
  understood to be a deployment defect. If it recurs, retry once before
  assuming something is broken.
- **Third-party plugins installed at trial *runtime* are still not
  reliable — but a plugin can now be baked into the bundle at *build*
  time instead, which fully works.** Originally found live, 2026-07-19,
  with `mod_quizquest`: even after fixing a real bug in the Exchange's
  blueprint-building code (`installMoodlePlugin` never told the sandbox
  which plugin type/name to install), the plugin's *files* would install
  into the WASM instance at runtime while its *database* installation
  (tables, capabilities, full registration) did not reliably complete —
  Moodle's own `upgrade_noncore()` running inside the booted WASM PHP
  instance is the fragile step, not anything in this repo or in the
  plugin itself (`mod_quizquest` installs cleanly via the normal
  `admin/cli/upgrade.php` path on two real, non-WASM MariaDB sites this
  same session). Full trace in
  `dev-docs/oer-platform/discoveries/2026-07-19-sandbox-thirdparty-plugin-db-install-limitation.md`.

  **The real fix**: `scripts/build-bundle-with-plugins.sh` injects a
  plugin's source into the Moodle checkout *before* the bundle's baseline
  `install.sq3` snapshot is generated — that snapshot is produced by
  Moodle's real, native CLI installer running on ordinary (non-WASM) PHP
  on the build machine, the exact same reliable path that installs every
  core table. A plugin baked in this way never touches the fragile
  runtime upgrade path at all. Verified three independent ways for
  `mod_quizquest` on the deployed `5.2` bundle: direct sqlite3 inspection
  of the snapshot (all 5 `mdl_quizquest*` tables present, a real
  `config_plugins` version row), a fresh boot's own `admin/plugins.php`
  showing "Enabled" with an Uninstall action (not "Additional / To be
  installed"), and a full live Try-it round trip on a whole-course
  resource completing end-to-end with the restored course, quiz, and both
  Quiz Quest activities all present and clickable.

  **Remaining caveat** (unrelated to the plugin-install fix): a
  **single-activity** `mod_quizquest` share still fails inside the
  sandbox — this is the sandbox-specific manifestation of `mod_quizquest`'s
  own already-documented question-category relocation limitation (see
  WALKTHROUGH.md Part 4), not a plugin-install problem; the plugin is
  confirmed fully installed either way. Share the whole course if you
  want a Quiz Quest activity to Try It cleanly.

  **Adding another baked-in plugin later**: run
  `BRANCH=MOODLE_502_STABLE scripts/build-bundle-with-plugins.sh
  mod:yourplugin:/path/to/its/repo`, then add an entry to
  `local_oerexchange`'s `playground::BAKED_IN_PLUGINS` for that branch —
  but only *after* verifying it actually works live (all three checks
  above), the same discipline that caught this fix not actually working
  the first time it was attempted.

## Acknowledgments

This sandbox is a thin deployment wrapper — all of the actual hard work of
running Moodle inside a browser is somebody else's, and it deserves credit:

- **[Moodle Playground](https://github.com/ateeducacion/moodle-playground)**
  (also home to the Playground.com family for Omeka S and eXeLearning) is
  the project this deploys. All in-browser Moodle boot, blueprint
  provisioning, and service-worker/bundle machinery is theirs — we only
  build and rsync their static output to `/try/`. Live demo and docs at
  [moodle-playground.com](https://moodle-playground.com/).
- Moodle Playground itself runs on
  **[WordPress Playground](https://github.com/WordPress/wordpress-playground)**'s
  `@php-wasm/web` PHP-in-WebAssembly runtime — the foundational piece that
  makes any of this possible in a browser tab at all.
- **[Moodle™](https://moodle.org)** is a registered trademark of Moodle Pty
  Ltd; used here (as upstream also does) to refer to the LMS this sandbox
  runs, not to imply endorsement.

## License

GPL-3.0-or-later, matching the upstream `moodle-playground` project.
