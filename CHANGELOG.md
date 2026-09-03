# Changelog

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
