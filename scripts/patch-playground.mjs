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

const EDITS = [
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
