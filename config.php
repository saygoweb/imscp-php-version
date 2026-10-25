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
    //
    // A pool may also be an array: a 'label', plus any of
    //
    //   'proxy'   => the vhost's FastCGI ProxySet: flushpackets (on|off|auto),
    //                flushwait (ms) and timeout (s).
    //   'fpm'     => the vhost's FPM pool file: pm, pm.max_children,
    //                pm.start_servers, pm.min_spare_servers, pm.max_spare_servers,
    //                pm.max_spawn_rate, pm.max_requests, pm.process_idle_timeout,
    //                request_terminate_timeout and request_slowlog_timeout.
    //   'php_ini' => directives seeded into the pool's php.ini when the plugin
    //                first writes it; never applied to one already there.
    //
    // proxy and fpm are applied every time a vhost in the pool is built, and are
    // gone again the first time it is built anywhere else. A definition the
    // plugin cannot accept stops it installing, updating or enabling, naming the
    // pool and the key. See "Chat (streaming) pool" in the README.
    'pools' => array(
        'cloudflare' => 'Cloudflare',

        // For an application that streams Server-Sent Events: each request
        // holds a worker for minutes and every event must reach the browser as
        // it is flushed.
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
);
