#!/usr/bin/env node
// Applies oer-sandbox's own deltas to a freshly checked-out Moodle Playground
// clone, after install.sh checks out PLAYGROUND_REF and before anything is
// built from it.
//
// Why this exists at all: this repo deliberately does not vendor the playground
// source (see README), so an upstream default we need changed cannot simply be
// edited in a tracked file — it has to be re-applied to every clone. Keep the
// set of edits as small as possible and prefer configuration over patching;
// every entry here is a maintenance cost paid on each PLAYGROUND_REF bump.
//
// Node, not sed/perl: install.sh already hard-requires Node (the bundle packer
// needs its native zstd), and exact multi-line string matching is safer here
// than a regex that could match more than intended.
//
// Usage:
//   node scripts/patch-playground.mjs <playground-dir>   apply the edits
//   node scripts/patch-playground.mjs --list             print the files it edits
//
// --list exists so install.sh can restore exactly these paths before its
// `git checkout --detach`, without a blanket `git reset --hard` (PLAYGROUND_DIR
// may point at a clone the operator also works in).
//
// Every edit fails LOUDLY when its anchor text is absent: an upstream refactor
// must stop the build, never quietly produce a sandbox missing the change. It
// is idempotent — a marker string in the replacement makes re-running a no-op.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// How big a course backup may be and still take the playground's FAST
// download path. Upstream caps this at 50 MiB; see the edit below for what
// the cap actually does and why this deployment raises it. Override per build
// with OER_FAST_DOWNLOAD_MAX_MB=<megabytes>.
const FAST_DOWNLOAD_MAX_MB = Number(process.env.OER_FAST_DOWNLOAD_MAX_MB || 384);

if (!Number.isInteger(FAST_DOWNLOAD_MAX_MB) || FAST_DOWNLOAD_MAX_MB < 1) {
  process.stderr.write(
    `ERROR: OER_FAST_DOWNLOAD_MAX_MB must be a positive whole number of ` +
      `megabytes, got "${process.env.OER_FAST_DOWNLOAD_MAX_MB}"\n`,
  );
  process.exit(1);
}

const EDITS = [
  {
    file: "src/blueprint/steps/moodle-restore.js",
    what: `raise the fast-download budget to ${FAST_DOWNLOAD_MAX_MB} MiB`,
    // The value is part of the marker deliberately: re-running with a
    // DIFFERENT budget against an already-patched clone must not silently
    // keep the old one. It won't find its anchor either, and the mismatch
    // handler below explains what to do.
    marker: `OER-SANDBOX PATCH: fast-download budget ${FAST_DOWNLOAD_MAX_MB} MiB`,
    staleprefix: "OER-SANDBOX PATCH: fast-download budget",
    find: "const MAX_BROWSER_BACKUP_BYTES = 50 * 1024 * 1024;",
    replace: `// OER-SANDBOX PATCH: fast-download budget ${FAST_DOWNLOAD_MAX_MB} MiB
// (upstream: 50). This budget does NOT decide whether a backup can be
// restored — over it, handleRestoreCourse() falls back to downloading inside
// PHP over the tcpOverFetch bridge, which works but is ~35x slower AND
// reports no progress at all. Measured on the OER Exchange 2026-08-02: a
// 359 MB course booted fine on the fallback path, in 4 min 15 s, of which
// 3 min 54 s was that silent download. Raising the budget puts real course
// backups back on the native fetch, which streams at full speed and publishes
// a percentage as it goes.
//
// The cost, and why this is a per-deployment number rather than a bigger
// constant upstream: the fast path buffers the whole file in a JS chunk array
// and then copies it into one Uint8Array before writing it into MEMFS, so
// peak memory is roughly 3x the file size. At ${FAST_DOWNLOAD_MAX_MB} MiB that is comfortable
// on a desktop and unreasonable on a phone. Lower it for a deployment whose
// visitors are mostly on small devices:
//   OER_FAST_DOWNLOAD_MAX_MB=128 scripts/install.sh --config ...
// The real fix is to stream chunks straight into MEMFS (no 2x buffer, progress
// at any size); this patch is the cheap half of it.
const MAX_BROWSER_BACKUP_BYTES = ${FAST_DOWNLOAD_MAX_MB} * 1024 * 1024;`,
  },
  {
    file: "src/runtime/config-template.js",
    what: "stop config.php forcing langmenu off",
    marker: "OER-SANDBOX PATCH: langmenu",
    find: `if (!property_exists($CFG, 'langmenu')) {
    $CFG->langmenu = 0;
}
`,
    replace: `// OER-SANDBOX PATCH: langmenu is deliberately NOT set here. Upstream pinned
// $CFG->langmenu = 0 to hide the language switcher, but anything assigned in
// config.php becomes a FORCED setting — lib/setup.php captures the whole $CFG
// into $CFG->config_php_settings, and get_config() returns the forced value in
// preference to the database row. That silently overrode the langmenu row an
// oer-sandbox configuration bakes into the install snapshot: the setting was
// applied, stored correctly, and then ignored at runtime. Leaving it unset
// makes langmenu an ordinary site setting again, so SITE_SETTING_langmenu in
// oer-sandbox.conf decides whether a trial shows the switcher (and an admin
// inside the trial can still change it). A sandbox with a baked language pack
// needs the switcher; a single-language one leaves the setting off and gets
// upstream's behaviour unchanged.
`,
  },
  {
    file: "playground.config.json",
    what: "strip upstream's Sentry DSN (no visitor telemetry from this deployment)",
    // Upstream ships its own Sentry ingest DSN in the config (#286, ADR-0028),
    // and deploy.sh rsyncs this file verbatim to the deploy target - so without
    // this edit every OER trial visitor's browser errors (tagged with runtime,
    // Moodle branch and PHP version) would be reported to the upstream
    // project's Sentry account. Their client is a no-op when config.sentry.dsn
    // is unset (src/shell/main.js initMonitoring), so removing the block is a
    // complete disable. JSON cannot carry comments, so the marker lives in a
    // harmless extra key the shell never reads. The DSN is part of the anchor
    // deliberately: if upstream rotates it, the build stops here and a human
    // re-checks what else changed around monitoring.
    marker: "OER-SANDBOX PATCH: sentry telemetry stripped",
    find: `  "sentry": {
    "dsn": "https://e6dac7d88c3dae67f635103541a10d66@o4510456164712448.ingest.de.sentry.io/4511915755962448"
  },
`,
    replace: `  "sentryDisabled": "OER-SANDBOX PATCH: sentry telemetry stripped - this deployment reports nothing to upstream's Sentry",
`,
  },
  {
    file: "scripts/patch-moodle-source.sh",
    what: "make H5P build its content frame with srcdoc, not document.write",
    // This one edits the playground's OWN Moodle-source patcher rather than a
    // runtime file, because the defect is in Moodle's vendored H5P core and
    // that is where every other Moodle-source fix in this project lives. It is
    // a candidate to send upstream (moodle-playground): nothing about it is
    // specific to the OER deployment - any playground serving H5P is affected.
    // An upstream-flavoured copy of the hunk, and the PR notes for it, are in
    // dev-docs/oer-sandbox/UPSTREAM-h5p-srcdoc-2026-08-21.md.
    //
    // WHEN UPSTREAM MERGES IT: the anchor below still matches, so this edit
    // would insert a SECOND copy of the hunk; the h5p.js replacement inside it
    // then finds upstream's already-rewritten writeDocument, misses its needle
    // and stops the build - loudly, by design. The fix at that point is to
    // DELETE this entry, not to re-anchor it.
    marker: "OER-SANDBOX PATCH: h5p srcdoc",
    find: `# Apply per-branch patches (file copies from patches/$BRANCH/)
if [ -n "$BRANCH_PATCH_DIR" ]; then`,
    replace: `# OER-SANDBOX PATCH: h5p srcdoc - H5P must not build its content frame with
# document.write().
#
# Moodle renders H5P into an iframe whose document it writes by hand:
# h5p/templates/h5piframe.mustache ships src="about:blank", then
# h5p/h5plib/*/joubel/core/js/h5p.js does contentDocument.open() /
# write(...getHeadTags(id)...) / close(). Harmless on a server-backed Moodle.
# Here the SERVICE WORKER IS THE WEB SERVER, and Chromium gives an about:blank
# child frame no service-worker controller at all. document.write() is not what
# loses it - an untouched about:blank frame is already uncontrolled, so there was
# never a controller to lose. Firefox inherits it for a frame's INITIAL document,
# which is what Moodle's parser-created src="about:blank" frame is, which is why
# H5P works there and nowhere else.
#
# Measured 2026-08-21 on two independent harnesses, with in-run controls (the top
# document's own fetch of the same virtual URL is SW-served in every cell; the
# same URL 404s with no SW registered), against the REAL h5p.js:
#
#   Chromium 149.0.7827.55   about:blank frame (untouched, written, or with no
#                            src at all): uncontrolled, head-tag assets 404
#                            srcdoc frame: CONTROLLED, assets 200 from the SW
#   Firefox 151.0            initial about:blank document: controlled, assets
#                            200 - the H5P we already have working
#
# Firefox additionally does NOT inherit for a frame NAVIGATED after insertion
# (about:blank or srcdoc alike), which is the second reason it keeps the
# document.write path below rather than being switched to srcdoc with everyone else.
#
# So in Chromium H5P's head-tag assets bypass the SW, fall through to the
# static host and 404 as text/html (blocked by X-Content-Type-Options), no H5P
# instance is constructed, h5p/js/embed.js returns early at !H5P.instances[0],
# and the outer frame keeps height:0 - a silent blank area with no error text,
# in every engine except Firefox.
#
# Fix: deliver the identical HTML through srcdoc, which both engines keep under
# the service worker. Firefox deliberately KEEPS document.write: it already
# works there, and Firefox's srcdoc does not send cookies (Mozilla bug
# 1741489) - the same split TinyMCE ships for the same reason in
# lib/editor/tiny/js/tinymce/tinymce.js (TINY-8916).
#
# Not fixable by configuration: h5p/classes/framework.php hard-codes
# 'embedType' => 'iframe' and core's own comment there rejects 'div'.
for H5PJS in "$SOURCE_DIR/\${PUB}"h5p/h5plib/*/joubel/core/js/h5p.js; do
  [ -f "$H5PJS" ] || continue
  if grep -q 'OER-SANDBOX PATCH: h5p srcdoc' "$H5PJS"; then
    continue
  fi
  python3 - "$H5PJS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

needle = """    const writeDocument = function () {
      iframe.contentDocument.open();
      iframe.contentDocument.write('<!doctype html><html class="h5p-iframe" lang="' + contentLanguage + '"><head>' + H5P.getHeadTags(contentId) + '</head><body><div class="h5p-content" data-content-id="' + contentId + '"/></body></html>');
      iframe.contentDocument.close();
    };
"""

insert = r"""    // OER-SANDBOX PATCH: h5p srcdoc. Chromium gives an about:blank child frame
    // no service-worker controller at all, and in the playground the service
    // worker is the web server - so the head tags below would 404 and H5P would
    // render as a blank area. A srcdoc frame IS controlled there. Firefox keeps
    // document.write: it inherits the controller for a frame's initial document
    // (so this already works), it does NOT inherit for a frame navigated after
    // insertion, and its srcdoc drops cookies (Mozilla bug 1741489) - the same
    // split TinyMCE ships for the same reason (TINY-8916).
    const writeDocument = function () {
      // Make the head-tag URLs carry the runtime scope explicitly.
      //
      // H5P emits them from the H5PIntegration blob as absolute app-base URLs
      // (https://host/try/h5p/h5plib/...), never with the
      // /playground/<scope>/<runtime>/ segment, and the service worker's HTML
      // rewriter cannot help: it rewrites href/src ATTRIBUTES, and these live
      // inside a <script> JSON blob. So the SW can only route them by inferring
      // the scope from the request's Referer. Measured 2026-08-21: a srcdoc
      // document's own document.referrer is "" and the requests are served only
      // because the browser happens to attach the parent's URL as the Referer
      // header. Where a browser does not, every asset 404s against the static
      // host and H5P renders blank — the exact failure reported from a real
      // Chrome while this harness passed.
      //
      // This document's URL always carries the scope, so derive it and rewrite
      // rather than leaving the routing to be guessed. Plain string ops, and a
      // guard that skips the rewrite entirely if anything is already scoped, so
      // the worst case is today's behaviour rather than a double-scoped URL.
      var headTags = H5P.getHeadTags(contentId);
      var scopeMatch = window.location.pathname.match(/\\/playground\\/[^/]+\\/[^/]+\\//);
      if (scopeMatch) {
        var appBase = window.location.pathname.slice(0, scopeMatch.index);
        var scopedBase = appBase + scopeMatch[0].replace(/\\/$/, '');
        if (headTags.indexOf(window.location.origin + scopedBase) === -1) {
          headTags = headTags
            .split(window.location.origin + appBase + '/')
            .join(window.location.origin + scopedBase + '/')
            .split('"' + appBase + '/')
            .join('"' + scopedBase + '/');
        }
      }
      const h5pHtml = '<!doctype html><html class="h5p-iframe" lang="' + contentLanguage + '"><head>' + headTags + '</head><body><div class="h5p-content" data-content-id="' + contentId + '"/></body></html>';
      if (!/firefox/i.test(navigator.userAgent)) {
        // The re-entry guard is load-bearing, not defensive dressing: in the
        // contentDocument === null branch below, upstream binds writeDocument to
        // the frame's load event with .on() (not .one()). document.write fires
        // no load event, but assigning srcdoc does - so without this flag that
        // branch would set srcdoc, load, write again, forever.
        if (iframe.h5pSrcdocWritten) {
          return;
        }
        iframe.h5pSrcdocWritten = true;
        iframe.srcdoc = h5pHtml;
        return;
      }
      iframe.contentDocument.open();
      iframe.contentDocument.write(h5pHtml);
      iframe.contentDocument.close();
    };
"""

if needle not in text:
    raise SystemExit(
        f"h5p srcdoc patch: anchor not found in {path}. Upstream H5P core has "
        "changed writeDocument(); re-read it and update the anchor in "
        "oer-sandbox/scripts/patch-playground.mjs. Refusing to build a sandbox "
        "whose H5P is blank in every browser but Firefox."
    )

path.write_text(text.replace(needle, insert, 1), encoding="utf-8")
PY
done

# OER-SANDBOX PATCH: h5p div - render H5P WITHOUT the nested frame.
#
# The srcdoc change above only helps where the browser gives a srcdoc document
# its parent's service-worker controller. Chromium shipped that around 135;
# Vivaldi 6.8 (Chromium 126) does not, and there every H5P asset goes to the
# network instead of the SW and 404s against the static /try/ host. Confirmed
# 2026-08-21 from the reported failure: the request was correctly scoped and the
# DevTools Size column showed a network fetch, not "ServiceWorker".
#
# No page-side trick can fix that: the document is simply not controlled. The
# only robust answer is to stop creating a nested document at all, i.e. H5P's
# "div" embed type, which renders the content directly into embed.php - a real,
# scoped URL that IS service-worker-controlled in every browser.
#
# Moodle cannot be configured into this. framework.php hard-codes
# 'embedType' => 'iframe', and even overriding that is ignored because
# determineEmbedType() falls back to the library's own declaration - and every
# runnable library on this site declares embedtypes=iframe (checked against
# mdl_h5p_libraries, 2026-08-21). So force it in the H5P core, and repair the
# div branch, which is dead code upstream: player.php's get_assets() collects
# the content-library URLs into $this->jsrequires/$this->cssrequires, which
# NOTHING in the tree ever reads, and dereferences $CFG with no global
# declaration in scope. Both verified by grep with positive controls.
#
# Upstream's reason for preferring iframe is CSS/JS conflicts with the host
# page. That does not apply here: the content still sits alone inside
# embed.php's own iframe, so the isolation is unchanged - only the SECOND,
# inner frame goes away.
for H5PCORE in "$SOURCE_DIR/\${PUB}"h5p/h5plib/*/joubel/core/h5p.classes.php; do
  [ -f "$H5PCORE" ] || continue
  if grep -q 'OER-SANDBOX PATCH: h5p div' "$H5PCORE"; then
    continue
  fi
  python3 - "$H5PCORE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

needle = """  public static function determineEmbedType($contentEmbedType, $libraryEmbedTypes) {
    // Detect content embed type
"""

insert = """  public static function determineEmbedType($contentEmbedType, $libraryEmbedTypes) {
    // OER-SANDBOX PATCH: h5p div. In the playground the service worker IS the
    // web server, and a nested about:blank/srcdoc document is not
    // service-worker-controlled in every browser (Chromium below ~135, e.g.
    // Vivaldi 6.8 / Chromium 126), so its assets bypass the SW and 404. Render
    // into a div instead: the content then lives in embed.php's own document,
    // a real scoped URL that is controlled everywhere. Isolation is unaffected
    // because embed.php is itself an iframe. Libraries declare iframe support
    // only, which is why this cannot be done through configuration.
    return 'div';

    // Detect content embed type
"""

if needle not in text:
    raise SystemExit(
        f"h5p div patch: determineEmbedType anchor not found in {path}. Re-read "
        "the upstream H5P core and update oer-sandbox/scripts/patch-playground.mjs."
    )

path.write_text(text.replace(needle, insert, 1), encoding="utf-8")
PY
done

PLAYERPHP="$SOURCE_DIR/\${PUB}h5p/classes/player.php"
if [ -f "$PLAYERPHP" ] && ! grep -q 'OER-SANDBOX PATCH: h5p div' "$PLAYERPHP"; then
  python3 - "$PLAYERPHP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# 1. get_assets() dereferences $CFG with no global declaration - the div branch
#    has never run upstream. Declare what it uses.
sig_needle = """    private function get_assets(): array {
        // Get core assets.
"""
sig_insert = """    private function get_assets(): array {
        // OER-SANDBOX PATCH: h5p div. $CFG was already used below with no global
        // declaration (upstream's div branch is dead code); $PAGE is needed to
        // actually load the content-library assets.
        global $CFG, $PAGE;

        // Get core assets.
"""

# 2. Actually load the scripts/styles the div branch only ever listed.
js_needle = r"""                $this->jsrequires[] = new \\moodle_url($isexternal ? $url : $CFG->wwwroot . $url);"""
js_insert = r"""                $PAGE->requires->js(new \\moodle_url($isexternal ? $url : $CFG->wwwroot . $url), true);"""

css_needle = r"""                $this->cssrequires[] = new \\moodle_url($isexternal ? $url : $CFG->wwwroot . $url);"""
css_insert = r"""                $PAGE->requires->css(new \\moodle_url($isexternal ? $url : $CFG->wwwroot . $url));"""

for name, needle in (("get_assets signature", sig_needle), ("div js", js_needle), ("div css", css_needle)):
    if needle not in text:
        raise SystemExit(f"h5p div patch: {name} anchor not found in {path}")

text = text.replace(sig_needle, sig_insert, 1)
text = text.replace(js_needle, js_insert, 1)
text = text.replace(css_needle, css_insert, 1)
path.write_text(text, encoding="utf-8")
PY
fi

# OER-SANDBOX PATCH: h5p video iframe position.
#
# H5P's YouTube handler positions the player iframe by assigning to
# 'player.g.style' (H5P.Video-1.6/scripts/youtube.js:169) - 'g' being a MINIFIED
# private property of YouTube's Player object, not the documented
# 'player.getIframe()'. YouTube re-minifies regularly, so when 'g' stops being
# the iframe the assignment lands somewhere harmless and the iframe never
# becomes absolutely positioned. It then flows AFTER the aspect-ratio box the
# same script builds ('padding: 56.25% 0 0 0', youtube.js:23) and is clipped by
# the wrapper's overflow:hidden - the player keeps running just below the
# visible area, so you get audio and no picture.
#
# Measured live 2026-08-22 before the fix: iframe rect [0, 565, 1005, 565],
# position "static", and elementFromPoint at the centre of the video area
# returned a DIV, not the iframe. Injecting the rule below moved it to
# [0, 0, 1005, 565], position "absolute", with the IFRAME on top. (The same run
# confirmed YT.Player.prototype.getIframe exists, i.e. H5P had a supported API
# available and did not use it.)
#
# Fixed in CSS rather than JS on purpose: youtube.js ships INSIDE each .h5p
# content package, which this build pipeline never sees - only Moodle core is
# patchable here. The rule restores the layout the script intended whether or
# not its private-property assignment worked, so it is also future-proof against
# the next YouTube re-minification. Worth reporting to H5P separately.
#
# NOTE: any Moodle site serving this content is affected, not just the sandbox;
# there the same rule belongs in the theme's raw SCSS or additionalhtmlcss.
for H5PCSS in "$SOURCE_DIR/\${PUB}"h5p/h5plib/*/joubel/core/styles/h5p.css; do
  [ -f "$H5PCSS" ] || continue
  if grep -q 'OER-SANDBOX PATCH: h5p video iframe position' "$H5PCSS"; then
    continue
  fi
  if ! grep -q 'h5p-iframe-wrapper' "$H5PCSS"; then
    echo "ERROR: $H5PCSS does not look like the H5P core stylesheet" >&2
    echo "       (no .h5p-iframe-wrapper rule). Refusing to append the video" >&2
    echo "       iframe fix to the wrong file." >&2
    exit 1
  fi
  cat >>"$H5PCSS" <<'CSS'

/* OER-SANDBOX PATCH: h5p video iframe position. H5P's YouTube handler sets this
   inline via player.g (a minified YouTube internal); when that breaks, the
   iframe flows below its aspect-ratio box and is clipped away - audio plays,
   nothing is visible. Restore the intended layout in CSS so it does not depend
   on YouTube's private property names. */
.h5p-video-wrapper iframe {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  height: 100%;
}
CSS
done

EMBEDJS="$SOURCE_DIR/\${PUB}h5p/js/embed.js"
if [ -f "$EMBEDJS" ] && ! grep -q 'OER-SANDBOX PATCH: h5p div' "$EMBEDJS"; then
  python3 - "$EMBEDJS" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

needle = """    // Check for H5P iFrame.
    var iFrame = document.querySelector('.h5p-iframe');
    if (!iFrame || !iFrame.contentWindow) {
        return;
    }
"""

insert = """    // Check for H5P iFrame.
    var iFrame = document.querySelector('.h5p-iframe');
    if (!iFrame || !iFrame.contentWindow) {
        // OER-SANDBOX PATCH: h5p div. With div embedding there is no inner
        // frame - the content is in THIS document - and upstream would return
        // here, leaving the resize handshake undone and the outer frame stuck
        // at height 0. Shim the frame object so every use below (contentWindow,
        // contentDocument.body) works unchanged.
        if (!document.querySelector('.h5p-content')) {
            return;
        }
        iFrame = {contentWindow: window, contentDocument: document};
    }
"""

if needle not in text:
    raise SystemExit(f"h5p div patch: embed.js iframe guard anchor not found in {path}")

path.write_text(text.replace(needle, insert, 1), encoding="utf-8")
PY
fi

# Apply per-branch patches (file copies from patches/$BRANCH/)
if [ -n "$BRANCH_PATCH_DIR" ]; then`,
  },
];

function fail(lines) {
  for (const line of lines) {
    process.stderr.write(`${line}\n`);
  }
  process.exit(1);
}

const arg = process.argv[2];

if (arg === "--list") {
  for (const edit of EDITS) {
    process.stdout.write(`${edit.file}\n`);
  }
  process.exit(0);
}

if (!arg) {
  fail([
    "Usage: patch-playground.mjs <playground-dir>",
    "       patch-playground.mjs --list",
  ]);
}

let applied = 0;
let already = 0;

for (const edit of EDITS) {
  const path = join(arg, edit.file);
  if (!existsSync(path)) {
    fail([
      `ERROR: cannot patch a file that is not there: ${path}`,
      `       (${edit.what})`,
      "       The playground clone is incomplete, or upstream moved/renamed",
      "       this file. Check PLAYGROUND_REF in scripts/common.sh.",
    ]);
  }

  const before = readFileSync(path, "utf8");

  if (before.includes(edit.marker)) {
    already++;
    process.stderr.write(`Already patched: ${edit.file} (${edit.what})\n`);
    continue;
  }

  // Patched already, but with a different value than this run asks for. The
  // anchor is gone, so the generic "anchor found 0 times" failure below would
  // send the reader off to check upstream for a change that has not happened.
  if (edit.staleprefix && before.includes(edit.staleprefix)) {
    fail([
      `ERROR: ${edit.file} already carries an oer-sandbox patch with a`,
      "       DIFFERENT value than this build asks for.",
      `       Wanted: ${edit.marker}`,
      "       This is a re-run against an already-patched clone, not an",
      "       upstream change. Restore the file and re-run so the new value",
      "       is applied to pristine source:",
      `         git -C <playground-dir> checkout -- ${edit.file}`,
      "       (install.sh does this for you before its checkout.)",
    ]);
  }

  const occurrences = before.split(edit.find).length - 1;
  if (occurrences !== 1) {
    fail([
      `ERROR: patch anchor found ${occurrences} times (expected exactly 1) in`,
      `       ${edit.file}`,
      `       Purpose of the patch: ${edit.what}`,
      "       Upstream has changed this code, so the patch was NOT applied and",
      "       the build is stopping rather than shipping a sandbox silently",
      "       missing it. Re-read the upstream file at the current",
      "       PLAYGROUND_REF (scripts/common.sh) and update the anchor in",
      "       scripts/patch-playground.mjs to match. Anchor text was:",
      ...edit.find.replace(/\n$/, "").split("\n").map((l) => `         | ${l}`),
    ]);
  }

  writeFileSync(path, before.replace(edit.find, edit.replace));
  applied++;
  process.stderr.write(`Patched: ${edit.file} (${edit.what})\n`);
}

process.stderr.write(
  `Playground patches: ${applied} applied, ${already} already present, ` +
    `${EDITS.length} total\n`,
);
