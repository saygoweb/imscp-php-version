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
    // One row per vhost that has been given a version other than the panel
    // default, or that has had one at some point. (domain_type, domain_id) is
    // how i-MSCP itself identifies a vhost, and covers all four kinds
    // including alias subdomains ('alssub').
    //
    // php_version is what the customer asked for; applied_version is what the
    // backend last actually built, and is what tells it which version's
    // pool.d a stale pool file has to be swept out of. An empty php_version
    // means 'whatever the panel default is', which is also what a vhost with
    // no row at all gets.
    'up'   => "
        CREATE TABLE IF NOT EXISTS `php_version` (
            `php_version_id`  int(11) unsigned NOT NULL AUTO_INCREMENT,
            `admin_id`        int(11) unsigned NOT NULL,
            `domain_type`     enum('dmn','sub','als','alssub') COLLATE utf8_unicode_ci NOT NULL,
            `domain_id`       int(11) unsigned NOT NULL,
            `domain_name`     varchar(255) COLLATE utf8_unicode_ci NOT NULL,
            `php_version`     varchar(8) COLLATE utf8_unicode_ci NOT NULL DEFAULT '',
            `applied_version` varchar(8) COLLATE utf8_unicode_ci NOT NULL DEFAULT '',
            `status`          varchar(255) COLLATE utf8_unicode_ci NOT NULL,
            PRIMARY KEY (`php_version_id`),
            UNIQUE KEY `php_version_domain` (`domain_type`, `domain_id`),
            KEY `php_version_admin_id` (`admin_id`),
            KEY `php_version_status` (`status`(15))
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;

        CREATE TABLE IF NOT EXISTS `php_version_installed` (
            `version`    varchar(8) COLLATE utf8_unicode_ci NOT NULL,
            `is_default` tinyint(1) NOT NULL DEFAULT '0',
            PRIMARY KEY (`version`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
    ",
    'down' => "
        DROP TABLE IF EXISTS `php_version_installed`;
        DROP TABLE IF EXISTS `php_version`;
    "
);
