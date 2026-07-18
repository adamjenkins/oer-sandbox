# oer-sandbox

Deployment kit for the OER Exchange platform's "Try it" sandbox — a
same-origin static deployment of [Moodle Playground](https://github.com/ateeducacion/moodle-playground)
(in-browser Moodle via PHP-WASM). No server-side trial execution, no
Podman fleet — see `dev-docs/oer-platform/DESIGN.md` §4 and
`SANDBOX-COMPARISON.md`/`SANDBOX-UPGRADES.md` for the full design and
rationale.

This repo does **not** vendor the playground source. It pins a commit of
the reference clone at `/vagrant/moodle-dev/reference-clones/moodle-playground/`
(see that repo's own git log for the exact commit deployed) and provides:

- `scripts/deploy.sh` — assembles the built static tree (bundles, worker,
  shell) and rsyncs it to `/srv/oer-sandbox/try/`, which the Exchange's
  nginx vhost serves at `/try/` (see HARNESS.md §2c).

## Building the bundles

From the `moodle-playground` clone (PHP 8.4 works fine here despite the
Makefile's `check-php` target insisting on 8.3 — that check is CI-parity
only, not a real constraint; `php8.4-sqlite3` and `zip` must be installed
for snapshot generation and packing):

```bash
cd /vagrant/moodle-dev/reference-clones/moodle-playground
npm install
npm run build:version
npm run build-worker
PHP_BIN=/usr/bin/php8.4 BRANCH=MOODLE_502_STABLE GIT_REF=v5.2.0 npm run bundle
PHP_BIN=/usr/bin/php8.4 BRANCH=MOODLE_500_STABLE npm run bundle
```

Then deploy:

```bash
bash /vagrant/moodle-dev/oer-platform/oer-sandbox/scripts/deploy.sh
```

## Status (2026-07-19)

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
