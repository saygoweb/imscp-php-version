# SGW_PhpVersion — Project Core

i-MSCP plugin (`imscp-php-version` checkout, **`SGW_PhpVersion` installed name**) letting a customer
choose which installed PHP version each of their vhosts runs on **and which PHP-FPM pool it runs
in**, and a reseller move any set of their customers' vhosts in one go.

The host panel it plugs into is the sibling checkout `../imscp`, which carries its own Serena
memories — read those for i-MSCP itself (`core`, `plugins/core`, `engine/core`, `docker/core`,
`conventions`). This memory set covers only what is specific to this plugin.

## Source map

    SGW_PhpVersion.php          frontend half: AbstractPlugin subclass — lifecycle, routes, nav, item status
    backend/SGW_PhpVersion.pm   backend half: the whole mechanism. See `mem:backend/core`.
    frontend/common.php         data access + the vhost model shared by both panel pages
    frontend/view.php           HTML fragment builders (<option> lists, labels)
    frontend/{client,reseller}/php_version.php   the two pages. See `mem:frontend/core`.
    themes/default/view/{client,reseller}/php_version.tpl   their templates
    sql/NNN_*.php               migrations, each returning array('up' => …, 'down' => …)
                                001 creates php_version/php_version_installed; 002 adds php_pool +
                                applied_pool. Idiom is `ADD COLUMN IF NOT EXISTS`; migrateDb() tracks
                                `db_schema_version` in the plugin row's info.
    config.php / info.php       plugin config defaults / panel metadata
    l10n/en_GB.php              empty on purpose: registers the translation domain, source is en_GB
    tools/ test/                development only, excluded from the release tar by upload-exclude.txt

## The central idea

The plugin **writes no vhost or pool configuration of its own.** i-MSCP builds a vhost and its
PHP-FPM pool from one server-wide value, `$httpd->{'phpConfig'}->{'PHP_VERSION'}`, read at the top of
`addDmn()`. The backend brackets each domain's build, overrides that value, and lets i-MSCP build
what it would otherwise have built, one version over. Vhost socket and pool therefore cannot
disagree — they come from the same value. Everything else in the backend exists to clean up after
that trick. See `mem:backend/core`.

**A pool is the same trick one step further.** The overridden value is a *token*, not a bare
version: `8.3`, or `8.3-cloudflare`. Every path i-MSCP derives from it follows —
`/etc/php/8.3-cloudflare`, its own `fpm/pool.d`, `/run/php/php8.3-cloudflare-fpm-*.sock` — and the
master reading them is `php8.3-fpm-cloudflare.service`. Unlike a version, a pool is **not already on
the machine**, so the plugin builds the directory, its three configuration files and the systemd
unit the first time one is needed, and then never writes over any of them: hand tuning them is the
whole point. Pools are declared by the administrator as `pools` in `config.php` (`name => label`;
the default instance is implicit and always offered).

## Hard requirements (enforced, install fails otherwise)

- `HTTPD_SERVER` must be `apache_php_fpm` — the only implementation with one pool file per site.
- `PHP_CONFIG_LEVEL` must be `per_site` — under `per_domain`/`per_user` one pool serves several
  vhosts, so moving one would silently move its neighbours.

## Invariants

- A vhost is identified by `(domain_type, domain_id)` with `domain_type` in `dmn|sub|als|alssub` —
  the same pair i-MSCP uses. Four kinds, four i-MSCP tables, four differently-named status columns;
  anything touching them needs all four arms (see `scheduleRebuild()`, `_scheduleRebuild()`).
- `php_version = ''` means "follow the panel default" and is a **choice in its own right**, distinct
  from being pinned to the version that happens to be the default today. Never collapse the two.
- A vhost with no row at all is on the default. Rows are created only when somebody chooses.
- `applied_version` / `applied_pool` are what was last actually built; together they are the only
  thing that says which `pool.d` a stale pool file has to be swept out of. Never derive either from
  `php_version` / `php_pool`.
- `php_pool = ''` is the instance the distribution ships. Unlike `php_version = ''` it is **not** a
  "follow something else" choice — the default instance cannot move underneath a vhost — so it is
  simply one of the pools, and `''` is a legitimate key of the frontend's `pools()` list.
- A pool name lands in a service name *and* a directory name, so it must match
  `^[a-z0-9][a-z0-9-]*$`. Frontend and backend each filter `config.php` that way; neither trusts the
  other to have done it. A pool taken out of `config.php` stops being offered and any vhost still
  naming it is built in the default instance.
- The frontend never reads `/etc/php`. The list of usable versions is published into
  `php_version_installed` by the backend, which alone can see the FPM binary and service.
- Panel and backend both refuse to act on a vhost that is not settled (its own status and i-MSCP's
  `*_status` both quiet), rather than stacking a second change on a half-finished one.
- Version comparison is numeric per component (`_compareVersions`), so 8.10 sorts after 8.9.

## Development

Deploying into the running dev container, installing/enabling, driving the backend and the tests:
`mem:development`.
