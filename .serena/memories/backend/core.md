# backend/SGW_PhpVersion.pm

Loaded by `iMSCP::Plugins` (globs `$PLUGINS_DIR/*/backend/*.pm`, loads only when the plugin directory
name equals the `.pm` basename) and run by `Modules::Plugin` inside the daemon, as root.

Lifecycle subs: `install`, `update`, `enable`, `disable`, `uninstall`, `run`. `run()` executes
**before** the domain modules of the same pass, so it is where anything the rebuilds depend on gets
put in place; the rebuilds themselves are caught by event listeners registered in `_init()`.

## The override bracket

`_init()` registers on `beforeHttpdAddDmn`/`afterHttpdAddDmn` and `beforeHttpdAddSub`/`afterHttpdAddSub`
(neither calls the other, so both are needed) and on `beforeHttpdDelDmn`/`afterHttpdDelDmn` (deletion
*does* delegate: `deleteSub()` calls `deleteDmn()`, so listening on the Sub event too would nest one
bracket inside another).

`_pushVersion($version, $pool)` / `_popVersion` swap three `phpConfig` keys: `PHP_VERSION`,
`PHP_CONF_DIR_PATH`, `PHP_FPM_POOL_DIR_PATH`. What goes into them is the **token**
`_token($version, $pool)` — `'8.3'`, or `'8.3-cloudflare'` — so version and pool move together and
nothing downstream needs to know a pool exists. The push is a no-op only when the token equals
`defaultVersion`: the panel's own version *in a pool* still needs the override.

Non-obvious mechanics, each the reason for code that otherwise looks wrong:

- **`phpConfig` is a tied `iMSCP::Config` opened read-only outside setup.** A plain assignment dies.
  The tie honours a `temporary` flag which keeps writes in memory only; `_init()` sets it. Nothing
  ever reaches `/etc/imscp/php/php.data`.
- **`_pushVersion` calls `_popVersion` first.** A build that fails part way returns before its
  `after` event and leaves the override standing; restoring on entry stops one failed domain moving
  every domain built after it.
- Paths are **derived, never assumed**: `_confDir($token)` is `dirname(PHP_CONF_DIR_PATH) .
  "/$token"`, so the plugin and i-MSCP cannot disagree about where PHP lives. `_confDir`/`_poolDir`
  take a token, not a version; token == version when the pool is `''`.
- `_ensurePool` runs in `_onBeforeBuildDmn` **before** `_pushVersion`, because i-MSCP is about to
  write a pool file into a directory that may not exist yet. It is safe to call `$httpd->setData` /
  `flushData` there: `addDmn()`/`addSub()` call `setData($data)` *after* triggering the before event.
  A pool that cannot be built fails the build rather than silently landing the vhost elsewhere.
- `$self->{'active'}` is 0 when `HTTPD_SERVER` is not `apache_php_fpm`, or when `phpConfig` turned
  out not to be tied. The listeners then stand down rather than half working.

## Consequences that are handled

1. **Stale pools.** Moving a vhost leaves its old pool file in the previous combination's `pool.d`,
   where that master keeps serving it. `_onAfterBuildDmn` compares `(applied_version, applied_pool)`
   with what was just built and `_removePool($v, $p, $name)`s the difference. Deletion uses the same
   bracket so `deleteDmn()` removes the pool file that exists, not one under the default version.
2. **A pool does not exist until something builds it.** `_ensurePool($v, $p)` makes the directory,
   calls `_syncPhpConf` and `_ensureUnit`, and is idempotent — everything is written **only if
   absent**, and `{'_builtPools'}` caches the token for the rest of the run (set only after the whole
   thing succeeded, so a half-done run retries).
3. **i-MSCP masks every other PHP-FPM service** during setup and only ever reloads its own.
   `_startVersion($v, $p)` (`_ensurePool` → enable/unmask → start) and `_startVersionsInUse` bring the
   others up; `_onBeforeHttpdRestart` reloads every combination whose `pool.d` this run touched —
   including one a domain has just moved *off*, which has a pool file to forget. It skips only the
   token equal to `defaultVersion`.
4. **`beforeHttpdRestart` may never fire.** `Servers::httpd`'s own `END` block stands down when `$?`
   is already set, which any unrelated server failure earlier in the run does. A pool written but
   never loaded is a domain that does not run, so an `END` block here repeats the reloads
   (`local $?;` — the run's exit status is not its to change). It is a no-op on a clean run, because
   `_onBeforeHttpdRestart` empties `{'touched'}`.

## State on the object

    active          listeners do nothing when false
    forceDefault    every rebuild goes to the default version whatever its row says
    noDb            tables are gone (uninstall runs after the frontend dropped them)
    touched         { token => { version =>, pool => } } — pool.d changed this run (_touch)
    _builtPools     { token => 1 } — pools _ensurePool has already seen to this run
    saved           the phpConfig values _popVersion must put back
    defaultVersion  phpConfig PHP_VERSION as it was at construction

`forceDefault` forces **both** the default version and the default pool. `_scheduleRebuild`
conditions carry both columns: `enable()` uses `php_version <> '' OR php_pool <> ''`, `disable()`
uses `applied_version <> '' OR applied_pool <> ''`.

**`enable()` must clear `forceDefault`.** `Modules::Plugin::_change()`/`_update()` call `disable()`
then `enable()` on the *same instance*, and an i-MSCP reconfigure puts every enabled plugin through
`tochange` — leaving the flag set rebuilt every vhost onto the default while its row still named
another version. That was the 0.1.1 bug; do not reintroduce it.

## Other subs

- `_token`/`_serviceName`/`_unitPath` — **plain functions, not methods** (like `_compareVersions`).
  `php<v>-fpm` or `php<v>-fpm-<pool>`; the unit goes in `/etc/systemd/system`.
- `_wantedPool($row)` / `_appliedPool($row)` — mirror `_wantedVersion`/`_appliedVersion`. A pool not
  in `_pools()` falls back to `''`, exactly as an uninstalled version falls back to the default.
- `_pools()` — `config.php`'s `pools` hashref, filtered by `^[a-z0-9][a-z0-9-]*$`. Guard with
  `ref eq 'HASH'`: an empty PHP array arrives as an arrayref, not a hashref.
- `_refreshInstalledVersions` — rewrites `php_version_installed` for the frontend, and calls
  `_syncPhpConf($v, '')` for any version not seen before.
- `_syncPhpConf($version, $pool)` — builds i-MSCP's own `php.ini`, `php-fpm.conf` and default pool
  from `$httpd->{'phpCfgDir'}` templates via `setData`/`buildConfFile`/`flushData`, rendered with the
  **token** as `PHP_VERSION` so the master gets its own pid file, log and `www` socket. For a version
  this stops a move silently changing timezone/opcache/session behaviour, and `config.php`'s
  `sync_php_conf` turns it off. For a pool the switch has **no say** — a pool has no configuration at
  all until this writes it — and existing files are never rewritten.
- `_markHandTuned` — `buildConfFile()` strips every comment out of i-MSCP's templates, so a pool's
  files arrive saying nothing about themselves; this heads each one with a note that it is the
  administrator's to tune.
- `_ensureUnit` — derives the pool's unit from the distribution's own: appends `(<pool> pool)` to
  `Description=`, rewrites `--fpm-config` and appends `-c <confDir>/fpm`, **drops** the
  `php-fpm-socket-helper` `ExecStartPost=`/`ExecStopPost=` lines (a second master must not fight the
  distribution's over the version-generic `/run/php/php-fpm.sock`), keeps everything else verbatim,
  fails loudly if no `ExecStart` could be rewritten, then `daemonReload()`s — nothing else will.
  **No `conf.d` and no `PHP_INI_SCAN_DIR`:** `-c` moves only `php.ini`, the scan directory is
  compiled in, so a pool loads the same extensions as its version. Verified in the container.
- `_distroUnit($version)` — scans systemd's own unit paths for a **regular file**. Do *not* use
  `iMSCP::Service`'s `resolveUnit`: i-MSCP masks every PHP-FPM service but its own, and a mask is a
  symlink to `/dev/null` that `resolveUnit` reports as the unit and that reads as an empty file.
- `_startVersionsInUse` — `SELECT DISTINCT CONCAT(php_version,'-',php_pool) AS pair, php_version,
  php_pool ... WHERE php_version <> '' OR php_pool <> ''`, keyed on `pair` because `doQuery` keys by
  one column. A version that is empty or no longer installed reads as `defaultVersion`, which still
  has a pool master to start.
- `uninstall()` — `noDb = 1`, so pools come from `config.php`. Sweeps per-domain pool files (keeps
  `www.conf`), stops and disables each master, and **leaves the `/etc/php/<token>` directories and
  the unit files in place**: they are hand tuned and a reinstall should find them as they were.
- `_installedVersions` — a directory under the PHP conf root is not enough: also requires
  `$root/$v/fpm/pool.d` and `iMSCP::ProgramFinder::find("php-fpm$v")`. `excluded_versions` from
  `config.php` is applied, except that the panel's own version is never excludable.
- `_scheduleRebuild($condition)` — four UPDATEs joining `php_version` to each vhost table.
- `_reapDeletedRows` — safety net for vhosts that vanished while the plugin was disabled.
- `_checkRequirements` — the two hard requirements in `mem:core`.

## Style

Old-style i-MSCP Perl: return int, `0` = success, `error()` from `iMSCP::Debug` first; `eval { }; if
( $@ )` only around service calls. POD `=item` above every sub. Never raw filesystem builtins or
`systemctl` — `iMSCP::File`, `iMSCP::Dir`, `iMSCP::Service`. Database through
`$self->{'db'}->doQuery( $key, $sql, @bind )`, whose return is a hashref on success and an error
**string** on failure — every call site must check `ref $qrs eq 'HASH'`.
