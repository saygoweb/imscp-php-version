# i-MSCP PHP Version Plugin

Lets a customer choose which of the PHP versions installed on the machine each
of their domains runs on, and lets a reseller move any set of their customers'
domains onto a version in one go. Versions run side by side: one domain can be
on 7.4 while the one next to it is on 8.3.

See [CHANGELOG](CHANGELOG.md) for what has changed in each version.

## Requirements

* i-MSCP 1.5.x (plugin API 1.5.1)
* The **`apache_php_fpm`** httpd server. The other two implementations do not
  give a vhost a pool of its own, so there would be nothing to point elsewhere.
* The **`per_site`** PHP configuration level. Under `per_domain` or `per_user` a
  single pool is shared between several vhosts, and moving one would silently
  move the others. Check with `grep PHP_CONFIG_LEVEL /etc/imscp/php/php.data`;
  change it with `perl /var/www/imscp/engine/setup/imscp-reconfigure -dar php`.
* More than one PHP version installed. On Debian these come from
  [Sury](https://packages.sury.org/php/), which i-MSCP's own package list
  already configures.

The plugin refuses to install if either of the first two is not met, naming
what it found.

## Installation

1. Upload `SGW_PhpVersion.tgz` through the plugin management interface
2. Install the plugin through the plugin management interface

Nothing is rebuilt at install time: every domain is already on the panel's own
version, which is what they keep until somebody chooses otherwise.

## What a customer sees

Under **Domains / PHP Version**, one row per vhost — domain, subdomain, alias
and alias subdomain alike — showing what it is running and a selector for what
it should run. Tick some rows, pick a version, press **Set** to fill their
selectors in, then **Apply**. The selectors are what is submitted, so what is
about to happen is on the screen before it happens.

The page appears only for a customer whose reseller has enabled PHP for them,
and lists only vhosts that serve PHP: one that just forwards or proxies
elsewhere has no PHP to configure.

**Panel default** is a choice in its own right, and the one every vhost starts
on. A vhost left on it follows the panel when an administrator changes the
server's PHP version; a vhost pinned to a version stays there.

A reseller gets the same table at **Customers / PHP Version**, across every
customer they own, which is where a few hundred domains get moved at once.

## How it works

i-MSCP builds a vhost and its PHP-FPM pool from one server-wide version, read
out of `$httpd->{'phpConfig'}->{'PHP_VERSION'}` at the top of `addDmn()`. This
plugin writes no configuration of its own. It brackets each domain's rebuild,
points that one value at the version the domain has been given, and lets i-MSCP
build exactly what it would otherwise have built, one version over. The vhost's
FastCGI socket and the pool that listens on it therefore cannot disagree: they
come from the same value.

Three consequences are handled in the backend, and each is the reason for a
piece of code that would otherwise look odd:

**The PHP configuration is read-only.** `phpConfig` is a tied `iMSCP::Config`
opened read-only outside of setup, so a plain assignment dies. The tie honours a
`temporary` flag which keeps writes in memory, and that is what the plugin sets:
the override lasts one domain's build and never reaches
`/etc/imscp/php/php.data`.

**Moving a domain strands its old pool.** The pool that was written under the
previous version is still in that version's `pool.d`, and FPM would go on
serving the vhost from it. Each row remembers the version it was last actually
built on, which is what tells the sweep where to look. The same override is
applied while a domain is being deleted, so `deleteDmn()` removes the pool that
exists rather than one under the default version.

**i-MSCP masks every other PHP-FPM service.** Setup stops and masks all
versions but its own, and only ever reloads its own. The plugin unmasks, enables
and starts the service for each version in use, and reloads every version whose
`pool.d` changed — including one a domain has just moved off, which has a pool
to forget.

That last reload also runs from an `END` block. `Servers::httpd`'s own `END`
stands down when `$?` is already set, which any unrelated server failure earlier
in the run will have done; a pool written but never loaded is a domain that does
not run, so the reload happens either way.

## PHP configuration for the additional versions

i-MSCP builds its `php.ini`, `php-fpm.conf` and default pool only for the
version it was set up with. A version it has never configured has Debian's
stock files, so moving a domain onto it would change its timezone, opcache and
session behaviour as a side effect of changing its version. The plugin
therefore generates the same three files, from i-MSCP's own templates, for each
version the first time it sees it. Set `sync_php_conf` to `false` in
`config.php` to leave those files alone.

## Removing the plugin

Disabling puts every domain back on the panel's default version and sweeps the
pools it created, while keeping each choice recorded, so re-enabling restores
them. Uninstalling additionally stops and re-masks the services it woke up.

## Caveats

**An i-MSCP reconfigure purges the other PHP versions.** `DebianAdapter` puts
every unselected `<phpX.Y>` alternative's packages on the uninstall list, so
running the installer or `imscp-reconfigure` removes the versions customers are
using and leaves their domains unserved. Until that is addressed in i-MSCP
itself, check which versions are in use before reconfiguring, and reinstall them
afterwards. The plugin falls back to the panel default for any pinned version it
can no longer find, and says so on the customer's page, so the damage is a
version change rather than an outage.

## Development

The `tools/` and `test/` directories are development-only and are excluded from
the release archive.

```shell
# In the i-MSCP repository, bring up the Debian 13 box:
cd imscp/Vagrant && vagrant up imscp_debian_trixie --provider=libvirt

# Inside the box: deploy the plugin
sudo /usr/local/src/imscp-php-version/tools/deploy.sh
```

`deploy.sh` copies the working tree into the panel's plugins directory rather
than mounting it there, because the virtiofs share carries the host's uid and
the panel runs as `vu2000`. It restarts `imscp_panel` afterwards, since that
pool's opcache would otherwise keep serving the previous version of a file.

Then either use *Settings / Plugins* in the panel, or drive the same plugin
manager from the command line:

```shell
sudo -u vu2000 php /usr/local/src/imscp-php-version/tools/plugin-ctl.php sync
sudo -u vu2000 php .../plugin-ctl.php install SGW_PhpVersion
sudo perl /var/www/imscp/engine/imscp-rqst-mngr
sudo -u vu2000 php .../plugin-ctl.php status
```

Tests:

```shell
# Version selection and the override bracket, no live panel needed. Must run as
# root: the module pulls in iMSCP::* from the engine, whose directory is not
# world readable.
cd test/backend && sudo perl all.t

# End to end against a live panel: moves every vhost of a customer onto each
# named version and reads the running version back off the site.
sudo ./test/switch-matrix.sh 9 8.1 8.3
```
