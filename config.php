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
    'sync_php_conf' => true
);
