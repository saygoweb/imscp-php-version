# i-MSCP PHP Version Plugin

[![Test](https://github.com/saygoweb/imscp-php-version/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/saygoweb/imscp-php-version/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/saygoweb/imscp-php-version/branch/main/graph/badge.svg)](https://codecov.io/gh/saygoweb/imscp-php-version)

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

## Chat (streaming) pool

A pool can also carry settings, for an application whose requests need
something the rest of the machine does not. The one shipped is `chat`, for an
application that streams [Server-Sent
Events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events):
each request holds a worker for minutes, and every event has to reach the
browser the moment PHP flushes it.

```php
'pools' => array(
    'cloudflare' => 'Cloudflare',
    'chat'       => array(
        'label'   => 'Chat (streaming)',
        'proxy'   => array('flushpackets' => 'on', 'timeout' => 600),
        'fpm'     => array(
            'pm'                        => 'dynamic',
            'pm.max_children'           => 24,
            'pm.start_servers'          => 4,
            'pm.min_spare_servers'      => 2,
            'pm.max_spare_servers'      => 6,
            'request_terminate_timeout' => '300s'
        ),
        'php_ini' => array('output_buffering' => '0', 'zlib.output_compression' => 'Off')
    )
)
```

A pool given as a string is a label and nothing else, exactly as before. An
array needs a `label`, and may have any of:

| Setting | Applied to | Keys |
|---|---|---|
| `proxy` | the `ProxySet` line in the vhost's PHP-FPM `<Proxy>` block, HTTP and HTTPS | `flushpackets` (`on`, `off`, `auto`), `flushwait` (ms), `timeout` (s) |
| `fpm` | the vhost's own FPM pool file | `pm`, `pm.max_children`, `pm.start_servers`, `pm.min_spare_servers`, `pm.max_spare_servers`, `pm.max_spawn_rate`, `pm.max_requests`, `pm.process_idle_timeout`, `request_terminate_timeout`, `request_slowlog_timeout` |
| `php_ini` | the pool's `php.ini`, once, when the plugin first writes it | any directive name, with a one-line value |

What each of the shipped values is for:

* **`flushpackets=on`** makes Apache's `mod_proxy_fcgi` pass each piece of
  output on as soon as PHP-FPM sends it. Without it Apache fills its own buffer
  first, and a stream of small events arrives in bursts many seconds apart. The
  probe below shows this: with `flushpackets` removed by hand, the first event
  took 15 s to arrive even with `output_buffering = 0`. It is required, not just
  a precaution.
* **`timeout=600`** is how long Apache waits on PHP-FPM for more output. It must
  be longer than the longest request the application allows.
* **`pm.max_children = 24`** and the `dynamic` manager: every open stream holds
  a worker for its whole length, and i-MSCP's default of 6 `ondemand` workers is
  used up by a handful of streams, leaving nothing for the rest of the site.
* **`request_terminate_timeout = 300s`** lets a request run for five minutes of
  wall time. `max_execution_time`, which i-MSCP locks with `php_admin_value`, is
  left alone: on Linux it counts CPU time, and a stream waiting on the network
  uses almost none of it.
* **`output_buffering = 0`** and **`zlib.output_compression = Off`**, so that
  nothing in PHP holds output back either.

The application must still do its part: send `Content-Type: text/event-stream`,
end any output buffers it has started, and call `flush()` after each event.

Nothing else about the vhost changes. Its `open_basedir`, `session.save_path`,
`display_errors`, `Authorization` header passthrough and rewrites are i-MSCP's
as usual: `fpm` cannot name `php_value` or `php_admin_value`, and nothing
outside the `<Proxy>` block's `ProxySet` line is edited.

**Moving a vhost in and out.** Choose *Chat (streaming)* as its pool, on the
customer's or reseller's page or through `phpVersionSet`, like any other pool.
`proxy` and `fpm` are applied every time a vhost in the pool is built. When it
is moved back to *Default*, or to any other pool, its next build renders i-MSCP's
stock vhost and pool file, with no trace of them. A change to `proxy` or `fpm` in
`config.php` reaches every vhost in the pool the next time the plugin is
enabled, which is what changing its configuration does.

**`php_ini` is seeded once.** Like everything else in a pool's directory,
`/etc/php/<version>-chat/fpm/php.ini` is written once and left alone after that,
so a change to `php_ini` does not reach a pool that already exists. To seed it
again, delete the file and rebuild a vhost in the pool:

```shell
rm /etc/php/8.3-chat/fpm/php.ini
# then put any vhost in the pool through a rebuild, e.g. Apply it on its page
```

**An invalid definition is refused.** A missing label, an unknown key, a value
that is not allowed or that contains a line break: the plugin refuses to
install, update or enable, and the message names the pool and the key, e.g.

```
The 'chat' pool in the SGW_PhpVersion plugin's config.php is invalid: fpm key
'php_admin_value[open_basedir]' is not allowed (allowed: pm, pm.max_children, ...)
```

Until the definition is put right, the pool is not offered, and a vhost already
in it is built in the default instance with stock files, never with half of what
was asked for. Because the failed change is still pending, the panel will not
take the corrected `config.php` straight away. Clear the error, then
synchronise the plugins again:

```shell
mysql imscp -e "UPDATE plugin SET plugin_status = 'enabled', plugin_error = NULL WHERE plugin_name = 'SGW_PhpVersion'"
# then Settings / Plugins / Update plugin list
```

**Checking a vhost streams.** `test/sse-probe.php` sends an event every 500 ms,
each reporting the SAPI and the `output_buffering` and `max_execution_time` it
ran with. `test/sse-probe.sh` reads it, timestamps every event as it arrives,
and fails if the first takes over a second, if any two are more than a second
apart (bunching), or if any are missing. Copy the PHP file into the vhost's
document root, run the probe from anywhere, then delete the file again:

```shell
test/sse-probe.sh https://qa.example.com/sse-probe.php 180
# In the development container, through the published port:
test/sse-probe.sh http://localhost:8080/sse-probe.php 180 -H 'Host: chat.cust1.test'
```

Closing the client part way through is noticed by the probe within a few
writes. Apache only gives up on PHP-FPM once a write to the client fails. The
probe logs it to `sse-probe.log` beside itself.

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
