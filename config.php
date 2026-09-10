<?php
/**
 * i-MSCP SGW_PhpVersion plugin
 * Copyright (C) 2026 Cambell Prince <cambell.prince@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

return array(
    // Versions that must never be offered to customers, whatever is installed
    // on the machine. Minor versions, as they appear under /etc/php, e.g.
    // array('5.6', '7.0'). An empty list offers everything that is installed
    // and usable through PHP-FPM.
    'excluded_versions' => array(),

    // Give each additional version the same php.ini, php-fpm.conf and default
    // pool that i-MSCP builds for the version it was set up with, so that a
    // domain does not silently change timezone, opcache or session behaviour
    // just by moving between versions.
    'sync_php_conf' => true,

    // PHP-FPM instances a domain may be placed in, beyond the one the
    // distribution ships. Each is a master process of its own, with its own
    // service and its own configuration directory, so that it can be tuned --
    // process manager, limits, php.ini -- independently of every other site on
    // the machine:
    //
    //   'cloudflare' => php8.3-fpm-cloudflare.service, /etc/php/8.3-cloudflare
    //
    // The key names the service and the directory, so it must be lowercase
    // letters, digits and hyphens; the value is what the panel calls it. The
    // default instance is always offered and is not listed here.
    //
    // The plugin creates the directory and the service for a pool the first
    // time it is needed and never writes over either again: from there on they
    // are yours to tune.
    'pools' => array(
        'cloudflare' => 'Cloudflare'
    )
);
