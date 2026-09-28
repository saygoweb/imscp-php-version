# Changelog

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
