# oer-sandbox

Deployment kit for the OER Exchange platform's "Try it" sandbox — a
same-origin static deployment of [Moodle Playground](https://github.com/ateeducacion/moodle-playground)
(in-browser Moodle via PHP-WASM). No server-side trial execution, no
Podman fleet — see `dev-docs/oer-platform/DESIGN.md` §4 and
`SANDBOX-COMPARISON.md`/`SANDBOX-UPGRADES.md` for the full design and
rationale.

This repo does **not** vendor the playground source. It pins a commit of
the reference clone at `/vagrant/moodle-dev/oer-platform/moodle-playground/`
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
cd /vagrant/moodle-dev/oer-platform/moodle-playground
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

## Status (2026-07-18)

Deployed and verified at the HTTP/infrastructure level:

- Static assets (bundles, manifests, `sw.bundle.js`, shell) serve correctly
  under `https://vagrant.wisecat.net/try/` (curl-verified, all 200s).
- The Service Worker registers with the correct scope
  (`https://vagrant.wisecat.net/try/`) and the shell → remote.html → nested
  runtime iframe chain resolves to the correct scoped path
  (`/try/playground/<scope>/php83-moodle52/my/`), confirmed in a real
  headless Chromium session (Playwright).
- The Exchange's `sandbox_launch.php` produces a correctly-formed launch
  URL end-to-end over real HTTP: signed download URL, base64-encoded
  blueprint (`installMoodle` → `login` → `restoreCourse` →
  `landingPage`), verified by decoding the redirect Location header.

**Not yet verified: the actual in-browser WASM boot completing.** In
automated (headless, Playwright-driven) testing this session, the shell
never reached its "ready" state (`#address-input` enabled) — the
`assets/manifests/MOODLE_502_STABLE.json` fetch inside the nested runtime
iframe consistently failed with `net::ERR_ABORTED`, even though the same
URL serves a valid 200 via plain `curl`, and even after waiting 4 minutes.
This is exactly the class of issue upstream's own test suite flags as a
known limitation of automated/headless nested-iframe testing (their
`admin-flows.spec.mjs` is explicitly skipped in CI for this reason — "flaky
under CI resource contention — run it locally"). It has **not** been ruled
out as a real deployment defect (vs. a headless-automation artifact) —
that determination, and a real-browser manual click-through, is the
**fidelity spike** already flagged as a required gate in
`SANDBOX-COMPARISON.md` §4 / `TASKLIST.md` before this option is considered
production-validated. Next step: open `https://vagrant.wisecat.net/try/`
in an actual desktop browser (not headless automation) and observe whether
the same manifest-fetch failure reproduces.

## License

GPL-3.0-or-later, matching the upstream `moodle-playground` project.
