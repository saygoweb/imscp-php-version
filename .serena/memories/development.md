# Development, deployment and testing

Two dev environments exist. **The docker container in `../imscp/docker` is the live one**; the
Vagrant box the plugin README describes is the older path, and is what `tools/deploy.sh` is written
for. Full container detail: `mem:docker/core` in the `../imscp` project.

## The container

Container name `imscp-imscp`, Debian bookworm, systemd as PID 1, i-MSCP installed inside it with
`HTTPD_SERVER=apache_php_fpm` and `PHP_CONFIG_LEVEL=per_site` (set by `docker/preseed.pl`, which
names this plugin as the reason). Panel default `PHP_VERSION = 7.3`; `/etc/php` holds 5.6 through
8.5 from Sury, with only `php7.3-fpm.service` unmasked until this plugin brings another up.

**There is no deploy step.** `/home/cambell/src/sgw` is bind-mounted at `/var/www/imscp-plugins`, and
`docker/imscp link` (driven by `IMSCP_PLUGINS` in `docker/.env`, already listing `imscp-php-version`)
symlinks `/var/www/imscp/gui/plugins/SGW_PhpVersion` → `/var/www/imscp-plugins/imscp-php-version`.
A host edit is live on the next request. `tools/deploy.sh`'s rsync is for the Vagrant box only.

All commands run from `/home/cambell/src/sgw/imscp`:

    docker/imscp plugins          # which checkouts are linked, and where
    docker/imscp link             # (re-)apply the links after changing IMSCP_PLUGINS
    docker/imscp shell            # root shell
    docker/imscp exec <cmd>       # anything else, as root, cwd /var/www/imscp-git
    docker/imscp logs panel|errors|install
    docker/imscp journal -u imscp_daemon
    docker/imscp mysql            # mysql client as root

    # plugin lifecycle — plugin-ctl.php drives the panel's own PluginManager
    P=/var/www/imscp-plugins/imscp-php-version/tools/plugin-ctl.php
    docker/imscp exec sudo -u vu2000 php $P sync
    docker/imscp exec sudo -u vu2000 php $P install SGW_PhpVersion
    docker/imscp exec sudo -u vu2000 php $P enable  SGW_PhpVersion
    docker/imscp exec sudo -u vu2000 php $P status      # also: disable update uninstall delete

    # a lifecycle step only queues a request; this is what runs the backend half
    docker/imscp exec perl /var/www/imscp/engine/imscp-rqst-mngr

    # an edited PHP file the panel still ignores is opcache in the panel's own pool
    docker/imscp exec systemctl restart imscp_panel

## Tests

    docker/imscp exec sh -c 'cd /var/www/imscp-plugins/imscp-php-version/test/backend && perl all.t'

`test/backend/version.t` covers the pure decisions — which version a vhost is built on, where that
version's files live, and the push/pop bracket. `test/backend/pool.t` does the same for pools: the
token/service/unit naming, `_wantedPool`/`_appliedPool`, and the bracket with a pool. Both load the
module **by path** (`require_ok(abs_path('../../backend/SGW_PhpVersion.pm'))`) because the file name
and the package name differ, and build instances by hand with `bless`, so no database and no i-MSCP
boot is needed.
Must run as root: the module pulls `iMSCP::*` from `/var/www/imscp/engine/PerlLib`, which is not
world readable. Keep new backend logic testable that way — a sub that only reads fields set on the
instance can be tested; one that reaches for `$self->{'db'}` cannot.

`test/switch-matrix.sh <admin_id> <version>…` is the end-to-end check: it moves every vhost of a
customer onto each named version and reads the running version back off the live site. That is the
only thing that proves the vhost's proxy socket and the pool's `listen` still agree. **The container
has no reseller, customer or domain**, so it needs those created before it can run.

Building a pool needs a live systemd and so is not unit tested. To exercise it directly, bootstrap
the backend from a throwaway script (`iMSCP::Bootstrapper->getInstance()->boot({ mode => 'backend',
config_readonly => 1, nolock => 1 })`, `require` the `.pm` by path, then
`Plugin::SGW_PhpVersion->getInstance( config => { sync_php_conf => 1, pools => {...} } )`) and call
`_ensurePool`/`_startVersion`. Check `/etc/php/<v>-<pool>/fpm/`, the unit in
`/etc/systemd/system`, `systemctl is-active`, the socket and pid in `/run/php`, and that a second
run leaves hand edits untouched.

`tools/` and `test/` are development-only and excluded from the release tar by `upload-exclude.txt`.

## Releasing

`makefile.json` targets (phpmake): `clean`, `test`, `version`, `package`.
`php tools/version.php patch|minor|major|X.Y.Z` rewrites both `version` and `date` in `info.php` —
they must move together, because the panel will not offer an update for a version that has not
changed. Record what changed in `CHANGELOG.md` under the new version. `package` tars the checkout as
`SGW_PhpVersion.tgz` with paths rewritten to the installed name.
