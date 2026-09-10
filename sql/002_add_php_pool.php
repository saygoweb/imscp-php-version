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
// Which PHP-FPM instance a vhost runs in, alongside which version it runs.
// The two are chosen and applied together: a vhost lives in exactly one
// (version, pool) pair, and its pool file sits in that pair's directory.
//
// An empty php_pool means the instance the distribution ships, which is what
// every vhost starts on; applied_pool is where the backend last actually built
// the vhost, and is what tells it which directory a stale pool file has to be
// swept out of. Both mirror php_version and applied_version exactly.
return array(
    'up'   => "
        ALTER TABLE `php_version`
        ADD COLUMN IF NOT EXISTS `php_pool` varchar(32) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' AFTER `php_version`,
        ADD COLUMN IF NOT EXISTS `applied_pool` varchar(32) COLLATE utf8_unicode_ci NOT NULL DEFAULT '' AFTER `applied_version`;
    ",
    'down' => "
        ALTER TABLE `php_version` DROP COLUMN `applied_pool`, DROP COLUMN `php_pool`;
    "
);
