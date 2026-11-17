# Changelog

## 0.7.0

* The opcache file cache is now pruned weekly by a plugin-owned systemd timer,
  `sgw-php-opcache-prune.timer`. Each run:
  * deletes `*.bin` files not read for `opcache_file_cache_max_age_days` (a
    new setting, default 30), then any directories that leaves empty,
    including system-id directories left behind by PHP upgrades;
  * removes the directory of any vhost that no FPM pool file points at any
    more, once the directory is a day old;
  * logs one line with counts and bytes freed to the journal.

  Each domain is pruned as its directory's owner, without following symlinks
  or crossing filesystems, and skipping anything that is not opcache's. The
  timer is installed on install, update and enable, and removed on disable and
  uninstall, or while `opcache_file_cache` is `''`.

## 0.6.0

* New `opcache_file_cache_only_versions` setting in `config.php` (empty by
  default), to give PHP 7.4 or 8.0 a file cache safely. For each version listed
  there, the plugin:
  * writes a drop-in to the version's `fpm/conf.d` that sets
    `opcache.file_cache_only = 1` and a master-level `opcache.file_cache`;
  * reloads every running master of the version;
  * gives the version's vhosts the per-vhost file cache line on their next
    build.

  With nothing stored in shared memory, the 7.4 and 8.0 map_ptr bug can't
  happen. Taking a version off the list, turning the file cache off, disabling
  the plugin or uninstalling it strips the line from every pool of that version
  before it removes the drop-in. A plugin update leaves both in place.

## 0.5.2

* Fixed: PHP 8.0 has the same opcache file cache bug as 7.4, so the default
  `opcache_file_cache_min_version` is now `8.1`. The root cause is that a
  script loaded from the file cache into process memory, because it doesn't fit
  the full shared memory, still claims map_ptr slots for its static variables
  and run-time cache that another worker then reuses for a script it stores in
  shared memory. Fixed upstream in PHP 8.1. See "Why not PHP 7.4 and 8.0" in the
  README.

## 0.5.1

* Fixed: the opcache file cache made PHP 7.4 FPM workers segfault once the
  master's shared memory was full (seen on 7.4.33 in production). Only vhosts
  on PHP 8.0 or later now get the file cache. The minimum is the new
  `opcache_file_cache_min_version` setting in `config.php` (default `8.0`). A
  vhost below it gets no directory, and its next build removes any
  `php_admin_value[opcache.file_cache]` line from its pool.

## 0.5.0

* Each vhost's FPM pool now gets its own opcache file cache, a second-level
  cache that opcache serves a script from when the master's shared memory is
  full. With many sites per master, that is most of the time. Every vhost built,
  on the default version and pool as well as in a named pool, gets
  `php_admin_value[opcache.file_cache] = <root>/<domain name>`, in a directory
  owned by the vhost's user and set to `0700`, under a root owned by root and
  set to `0711`. The directory is emptied when the vhost changes PHP version and
  removed when the vhost is deleted.
* New `opcache_file_cache` setting in `config.php`: the root, by default
  `/var/cache/php-opcache`, or `''` to turn the cache off. An invalid path stops
  the plugin installing, updating or enabling.

## 0.4.0

* A pool in `config.php` may now be an array as well as a label: a `label`, plus
  `proxy` settings for the vhost's FastCGI `ProxySet` line (`flushpackets`,
  `flushwait`, `timeout`), `fpm` settings for the vhost's pool file (`pm.*`,
  `request_terminate_timeout`, `request_slowlog_timeout`), and `php_ini`
  directives seeded into the pool's `php.ini` when it is first written. `proxy`
  and `fpm` are applied each time a vhost in the pool is built, from the
  `afterHttpdBuildConfFile` hook, and are gone the next time it is built
  elsewhere. A pool given as a string behaves exactly as before.
* Ships a `chat` pool for applications that stream Server-Sent Events:
  `flushpackets=on`, a 600 s proxy timeout, 24 `dynamic` workers, a 300 s
  `request_terminate_timeout` and `output_buffering = 0`.
* An invalid pool definition stops the plugin installing, updating or enabling,
  with a message naming the pool and the key. Until it is fixed, the pool is not
  offered, and a vhost in it is built in the default instance with stock files.
  `fpm` can never set `php_value` or `php_admin_value`, so i-MSCP's
  `open_basedir` and other limits always apply.
* Added `test/sse-probe.php` and `test/sse-probe.sh` (development only) for
  checking that a vhost delivers each event as it is flushed.

## 0.3.0

* Added GraphQL support: if the SGW_GraphQL plugin is installed, a domain's
  PHP version and pool are readable on `Domain`, `Subdomain` and
  `DomainAlias`, the installed versions and configured pools are readable
  through `Query.phpVersions`, and both can be changed through
  `Mutation.phpVersionSet` -- validated exactly as the client and reseller
  pages validate a submission, and reusing their `setChoice()`/`fetchDomain()`
  logic rather than duplicating it. This plugin still works exactly as before
  when SGW_GraphQL is not installed.

## 0.2.1

* Fixed the reseller page returning a fatal error, rather than a bad request,
  for a reseller with no customers. The navigation entry is gated on
  `resellerHasCustomers`, so for such a reseller the page had no entry in the
  menu, and the shared layout -- which reads a page's title and title class off
  whichever menu entry matches the request -- had nothing to read them from.
  The page now asserts the same condition its menu entry is gated on, as every
  i-MSCP page behind that condition does.

## 0.2.0

* A vhost can be put in a PHP-FPM pool as well as on a PHP version. A pool is a
  second FPM master for that version -- its own process manager, limits and
  `php.ini` -- serving only the vhosts put into it, so a handful of sites can be
  tuned without those settings reaching every other site on the machine.
* Pools are declared by the administrator as `pools` in `config.php`. The
  default instance, the one the distribution ships, is always offered.
* The plugin builds a pool the first time a vhost is put in it: the
  `/etc/php/<version>-<pool>` directory, its `php.ini`, `php-fpm.conf` and
  placeholder pool, and a `php<version>-fpm-<pool>.service` unit derived from
  the distribution's own. Each is written once and never written over again, so
  hand tuning survives; uninstalling leaves both the directories and the units
  in place for the same reason.
* Both panels gained a pool column and a bulk **Set** button of its own, so a
  batch can be moved between pools without touching anybody's version.

## 0.1.1

* Fixed every vhost being rebuilt onto the panel default version, while its
  recorded choice was left untouched, whenever the plugin passed through the
  `tochange` state. `Modules::Plugin` runs `disable()` and then `enable()` on
  the one instance for a change or an update, and an i-MSCP reconfigure puts
  every enabled plugin through `tochange`, so the flag `disable()` sets to force
  the default version was still standing when the domains were rebuilt in the
  same run.

## 0.1.0

First release.

* Per-vhost choice of PHP version for domains, subdomains, aliases and alias
  subdomains, for customers whose reseller has enabled PHP.
* Reseller page covering every vhost of every customer they own, with tick-and-
  set bulk assignment.
* Installed versions are detected by the backend and published for the panel;
  a version that disappears falls back to the panel default and is reported as
  not installed.
* Additional versions are given i-MSCP's own `php.ini`, `php-fpm.conf` and
  default pool the first time they are seen.
* Disabling the plugin returns every domain to the panel default while keeping
  the recorded choices; re-enabling restores them.
