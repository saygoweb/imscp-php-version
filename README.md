# i-MSCP PHP Version Plugin

Lets a customer choose which of the PHP versions installed on the machine each
of their domains runs on, and which PHP-FPM pool it runs in; and lets a reseller
move any set of their customers' domains onto a version or into a pool in one
go. Versions and pools run side by side: one domain can be on 7.4 while the one
next to it is on 8.3, and either can be given an FPM master of its own with
limits nothing else on the machine shares.

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

Beside the version selector is a **PHP pool** selector, listing **Default** and
whatever pools the administrator has configured. The two are chosen together and
have their own **Set** button each, so a batch can be moved between pools without
touching anybody's version.

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

A pool is the same trick one step further. The value the plugin overrides is a
token rather than a bare version — `8.3`, or `8.3-cloudflare` — and every path
i-MSCP derives from it follows: `/etc/php/8.3-cloudflare` for the configuration,
its own `pool.d`, its own sockets, and `php8.3-fpm-cloudflare.service` for the
master that reads them.

Four consequences are handled in the backend, and each is the reason for a
piece of code that would otherwise look odd:

**The PHP configuration is read-only.** `phpConfig` is a tied `iMSCP::Config`
opened read-only outside of setup, so a plain assignment dies. The tie honours a
`temporary` flag which keeps writes in memory, and that is what the plugin sets:
the override lasts one domain's build and never reaches
`/etc/imscp/php/php.data`.

**Moving a domain strands its old pool.** The pool file that was written under
the previous version and pool is still in that combination's `pool.d`, and its
master would go on serving the vhost from it. Each row remembers the version and
the pool it was last actually built in, which is what tells the sweep where to
look. The same override is applied while a domain is being deleted, so
`deleteDmn()` removes the pool file that exists rather than one under the default
version.

**A pool does not exist until something builds it.** A version is already on the
machine; a pool is not. Its configuration directory and its systemd unit are put
in place immediately before the build that first needs them — see below.

**i-MSCP masks every other PHP-FPM service.** Setup stops and masks all
versions but its own, and only ever reloads its own. The plugin unmasks, enables
and starts the service for each version and pool combination in use, and reloads
every one whose `pool.d` changed — including one a domain has just moved off,
which has a pool file to forget.

That last reload also runs from an `END` block. `Servers::httpd`'s own `END`
stands down when `$?` is already set, which any unrelated server failure earlier
in the run will have done; a pool written but never loaded is a domain that does
not run, so the reload happens either way.

## Pools

A pool is a second PHP-FPM master for a version: its own process manager, its own
limits, its own `php.ini`, serving only the vhosts put into it. That is what makes
it useful — a handful of sites behind Cloudflare with long timeouts and a fixed
worker count, say, without those settings reaching every other site on the box.

Pools are declared by the administrator in `config.php`:

```php
'pools' => array(
    'cloudflare' => 'Cloudflare'
)
```

The key names the service and the directory, so it must be lowercase letters,
digits and hyphens; the value is the label the panel shows. The default instance
— the one the distribution ships — is always offered and is not listed.

The first time a vhost is put into a pool, the plugin builds it:

| Written | What it is |
|---|---|
| `/etc/php/8.3-cloudflare/fpm/php.ini` | from i-MSCP's own template |
| `/etc/php/8.3-cloudflare/fpm/php-fpm.conf` | its own pid file, log and `pool.d` |
| `/etc/php/8.3-cloudflare/fpm/pool.d/www.conf` | the placeholder pool FPM insists on |
| `/etc/systemd/system/php8.3-fpm-cloudflare.service` | from the distribution's own unit |

Each is written once and **never written over again**: tuning them by hand is the
whole point of having a pool. Delete one and the plugin builds it afresh; leave
one and it is left alone. The unit is derived from the distribution's own so that
whatever hardening and ordering Debian thinks an FPM master needs comes with it;
the `php-fpm-socket-helper` hooks are dropped, since a second master must not
fight the distribution's over the version-generic `/run/php/php-fpm.sock`.

Extensions are deliberately *not* duplicated. `-c` moves only `php.ini`; the scan
directory is compiled into the binary, so a pool loads exactly the same extensions
as the version it belongs to, and enabling one for a version enables it for every
pool of that version.

A pool removed from `config.php` stops being offered, and any vhost still naming
it is built in the default instance again until it is put somewhere else.

## PHP configuration for the additional versions

i-MSCP builds its `php.ini`, `php-fpm.conf` and default pool only for the
version it was set up with. A version it has never configured has Debian's
stock files, so moving a domain onto it would change its timezone, opcache and
session behaviour as a side effect of changing its version. The plugin
therefore generates the same three files, from i-MSCP's own templates, for each
version the first time it sees it. Set `sync_php_conf` to `false` in
`config.php` to leave those files alone.

That switch covers versions only. A pool has no configuration at all until the
plugin writes it, so turning the switch off cannot stop a pool being built — it
would only leave one that could not start.

## GraphQL

If [SGW_GraphQL](https://github.com/saygoweb/imscp-graphql) is installed, this
plugin adds a domain's PHP version and pool to its API — no setup beyond
having both plugins enabled; this plugin never touches a GraphQL class unless
SGW_GraphQL is asking it to.

Reading what a `Domain`, `Subdomain` or `DomainAlias` is set to run:

```graphql
query {
  node(id: "RG9tYWluOjE") {
    ... on Domain {
      phpVersion {
        version         # '' follows the panel default
        appliedVersion  # what the backend last actually built; '' before the first apply
        pool            # '' is the default PHP-FPM instance
        appliedPool
        provisioning { state settled }
      }
    }
  }
}
```

`phpVersion` is `null` when nobody has ever set a choice for that vhost: it is
simply following the panel default, in the default pool.

The versions and pools available to choose from:

```graphql
query {
  phpVersions {
    versions { version isDefault }
    pools { name label }
  }
}
```

Changing a vhost's version or pool — `FEATURE_UNAVAILABLE` when its domain
does not run PHP, `CONFLICT` while either the vhost or a previous choice on it
is still being applied, `BAD_USER_INPUT` for a version that is not installed
or a pool that is not configured:

```graphql
mutation {
  phpVersionSet(input: { id: "RG9tYWluOjE", version: "8.3", pool: "cloudflare" }) {
    name
    provisioning { state }
    ... on Domain { phpVersion { version pool } }
  }
}
```

## Removing the plugin

Disabling puts every domain back on the panel's default version, in the default
instance, and sweeps the pool files it created, while keeping each choice
recorded, so re-enabling restores them. Uninstalling additionally stops and
disables the services it woke up, pool masters included.

What uninstalling does **not** remove is the `/etc/php/<version>-<pool>`
directories and the `/etc/systemd/system/php<version>-fpm-<pool>.service` units.
They have been tuned by hand by then, and an administrator who reinstalls the
plugin should find them as they were left. Delete them yourself if you want them
gone.

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

The i-MSCP repository next door runs a Debian container with systemd as PID 1,
with this working tree mounted and symlinked into the panel's plugins directory.
There is no deploy step: an edit on the host is live in the container.

```shell
# In the i-MSCP repository:
docker/imscp up
docker/imscp exec systemctl restart imscp_panel   # the panel's opcache
```

Then either use *Settings / Plugins* in the panel, or drive the same plugin
manager from the command line:

```shell
P=/var/www/imscp-plugins/imscp-php-version/tools/plugin-ctl.php
docker/imscp exec sudo -u vu2000 php $P sync
docker/imscp exec sudo -u vu2000 php $P install SGW_PhpVersion
docker/imscp exec perl /var/www/imscp/engine/imscp-rqst-mngr
docker/imscp exec sudo -u vu2000 php $P status
```

`tools/deploy.sh` is for the older Vagrant box, which has no such mount: it
copies the working tree in, because the virtiofs share carries the host's uid
while the panel runs as `vu2000`.

Tests:

```shell
# Version and pool selection, the naming, and the override bracket; no live
# panel needed. Must run as root: the module pulls in iMSCP::* from the engine,
# whose directory is not world readable.
cd test/backend && sudo perl all.t

# End to end against a live panel: moves every vhost of a customer onto each
# named version and reads the running version back off the site.
sudo ./test/switch-matrix.sh 9 8.1 8.3
```
