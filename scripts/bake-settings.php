#!/usr/bin/env php
<?php
// Applies SITE_SETTING_*, SITE_FILTER_* and TRIAL_DEFAULT_LANG values from a
// loaded oer-sandbox.conf directly into an install snapshot's SQLite file,
// before that snapshot is placed in the build's snapshot cache. Called from
// bake.sh, never directly.
//
// Reads instructions from stdin, one per line, fields separated by 0x1F
// (unit separator — not a tab: an admin-supplied setting value is allowed
// to contain a literal tab, and using a control character vanishingly
// unlikely to appear in one keeps a stray delimiter from silently
// misassigning a field; a line that still splits wrong is rejected below,
// not guessed at):
//   SETTING<0x1F><name><0x1F><value>  -> mdl_config row (a core,
//                                  non-plugin-scoped setting; the Advanced
//                                  textarea's PARAM_ALPHANUMEXT-validated
//                                  names are always unprefixed, so
//                                  config_plugins is never used)
//   FILTER<0x1F><name><0x1F>on|off    -> mdl_filter_active row at system
//                                  context (id 1) — filter state goes
//                                  through filter_set_global_state(), not
//                                  set_config(), which is why this is a
//                                  different table, not another mdl_config row
//   LANG<0x1F><code>              -> mdl_config 'lang' row (the site/trial
//                                  default language)
//
// Table prefix is hardcoded 'mdl_': generate-install-snapshot.sh hardcodes
// $CFG->prefix = 'mdl_' in the temporary config.php it writes for the CLI
// installer, and the spike in dev-docs/oer-platform/discoveries/
// 2026-07-31-baking-settings-into-the-install-snapshot.md confirmed it
// directly against a real snapshot's sqlite_master.
//
// Usage: bake-settings.php <install.sq3 path>  (instructions on stdin)
declare(strict_types=1);

if ($argc < 2) {
    fwrite(STDERR, "Usage: {$argv[0]} <install.sq3 path>\n");
    exit(1);
}
$dbfile = $argv[1];
if (!is_file($dbfile)) {
    fwrite(STDERR, "ERROR: snapshot not found: $dbfile\n");
    exit(1);
}

$db = new PDO('sqlite:' . $dbfile);
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

// UPDATE-then-INSERT rather than "INSERT OR REPLACE" or an "ON CONFLICT"
// upsert: it does not depend on mdl_config.name actually carrying a UNIQUE
// index in every Moodle version this ever runs against, and does not
// require a SQLite new enough for upsert syntax. Verified against a real
// snapshot in the spike (both an already-present key updated, and a fresh
// mdl_filter_active row inserted where none existed).
function set_core_config(PDO $db, string $name, string $value): void {
    $upd = $db->prepare('UPDATE mdl_config SET value = :value WHERE name = :name');
    $upd->execute(['value' => $value, 'name' => $name]);
    if ($upd->rowCount() === 0) {
        $ins = $db->prepare('INSERT INTO mdl_config (name, value) VALUES (:name, :value)');
        $ins->execute(['name' => $name, 'value' => $value]);
    }
    echo "SETTING $name = $value\n";
}

// Moodle's three filter states (lib/filterlib.php): anything else is a value
// core never writes and does not fully understand. This mattered: writing 0 for
// "off" happened to stop the filter rendering — filter_get_active_state()
// treats it as falsy and returns disabled (filterlib.php:254), and
// filter_get_active_in_context()'s HAVING clause reduces to `0 > 0` for a lone
// system-context row (:552) — but core's own test for "not available anywhere"
// is `active == TEXTFILTER_DISABLED` (:118), which a 0 row fails. So the filter
// read as merely off-but-available and a course inside the trial could switch
// it back on. TEXTFILTER_DISABLED is also what the Exchange's boot-time
// fallback writes via filter_set_global_state(), and the baked and boot-time
// paths must not mean different things by the same config line.
const TEXTFILTER_ON = 1;
const TEXTFILTER_DISABLED = -9999;

function set_filter_state(PDO $db, string $filter, string $state): void {
    $active = $state === 'on' ? TEXTFILTER_ON : ($state === 'off' ? TEXTFILTER_DISABLED : null);
    if ($active === null) {
        fwrite(STDERR, "ERROR: filter state must be 'on' or 'off', got '$state' for '$filter'\n");
        exit(1);
    }
    $select = $db->prepare('SELECT id FROM mdl_filter_active WHERE filter = :filter AND contextid = 1');
    $select->execute(['filter' => $filter]);
    if ($select->fetchColumn() !== false) {
        $upd = $db->prepare('UPDATE mdl_filter_active SET active = :active WHERE filter = :filter AND contextid = 1');
        $upd->execute(['active' => $active, 'filter' => $filter]);
    } else {
        $nextsort = (int) $db->query('SELECT COALESCE(MAX(sortorder), 0) FROM mdl_filter_active')->fetchColumn() + 1;
        $ins = $db->prepare(
            'INSERT INTO mdl_filter_active (filter, contextid, active, sortorder) VALUES (:filter, 1, :active, :sortorder)'
        );
        $ins->execute(['filter' => $filter, 'active' => $active, 'sortorder' => $nextsort]);
    }
    echo "FILTER $filter active=$active\n";
}

$db->beginTransaction();
$applied = 0;
while (($line = fgets(STDIN)) !== false) {
    $line = rtrim($line, "\n");
    if ($line === '') {
        continue;
    }
    $parts = explode("\x1f", $line);
    $kind = $parts[0];
    if ($kind === 'SETTING' && count($parts) === 3) {
        set_core_config($db, $parts[1], $parts[2]);
    } elseif ($kind === 'FILTER' && count($parts) === 3) {
        set_filter_state($db, $parts[1], $parts[2]);
    } elseif ($kind === 'LANG' && count($parts) === 2) {
        set_core_config($db, 'lang', $parts[1]);
    } else {
        fwrite(STDERR, "ERROR: malformed bake-settings instruction: $line\n");
        $db->rollBack();
        exit(1);
    }
    $applied++;
}
$db->commit();

if ($applied === 0) {
    fwrite(STDERR, "WARNING: bake-settings.php received no instructions — called with nothing to apply?\n");
}
echo "Applied $applied setting(s) to $dbfile\n";
