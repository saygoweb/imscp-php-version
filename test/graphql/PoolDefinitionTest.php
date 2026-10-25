<?php
namespace iMSCP\Plugin\SGW_PhpVersion\Test\Graphql;

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

use PHPUnit\Framework\TestCase;

require_once __DIR__ . '/../../frontend/common.php';

/**
 * \SGW_PhpVersion\poolDefinitionError() is the frontend's copy of the
 * backend's _parsePool() rules (test/backend/chat.t covers those): a pool the
 * backend would refuse to build must never be offered to a customer, on the
 * pages or through Query.phpVersions.
 */
class PoolDefinitionTest extends TestCase
{
    public function testTheShippedPoolsAreValid(): void
    {
        $config = require __DIR__ . '/../../config.php';

        foreach ($config['pools'] as $name => $definition) {
            self::assertNull(\SGW_PhpVersion\poolDefinitionError($definition), $name);
        }
    }

    public function testALabelAloneIsValid(): void
    {
        self::assertNull(\SGW_PhpVersion\poolDefinitionError('Cloudflare'));
    }

    /**
     * @dataProvider invalidDefinitions
     */
    public function testAnInvalidDefinitionIsRefused($definition, string $message): void
    {
        self::assertStringContainsString($message, (string)\SGW_PhpVersion\poolDefinitionError($definition));
    }

    public function invalidDefinitions(): array
    {
        return array(
            'no label'          => array(array('proxy' => array()), "'label' is required"),
            'empty label'       => array(array('label' => ''), "'label' must not be empty"),
            'label alone, two lines' => array("A\nB", 'the label must not contain a line break'),
            'unknown setting'   => array(array('label' => 'X', 'php.ini' => array()), "'php.ini' is not a pool setting"),
            'proxy key'         => array(array('label' => 'X', 'proxy' => array('retry' => 0)), "proxy key 'retry' is not allowed"),
            'flushpackets'      => array(array('label' => 'X', 'proxy' => array('flushpackets' => 'yes')), "proxy key 'flushpackets' cannot be 'yes'"),
            'php_admin_value'   => array(
                array('label' => 'X', 'fpm' => array('php_admin_value[open_basedir]' => '/')),
                "fpm key 'php_admin_value[open_basedir]' is not allowed"
            ),
            'pm'                => array(array('label' => 'X', 'fpm' => array('pm' => 'lazy')), "fpm key 'pm' cannot be 'lazy'"),
            'newline in value'  => array(
                array('label' => 'X', 'fpm' => array('pm.max_children' => "24\nuser = root")),
                "fpm key 'pm.max_children' must not contain a line break"
            ),
            'php_ini name'      => array(array('label' => 'X', 'php_ini' => array('a b' => 1)), "php_ini key 'a b' is not an ini directive name"),
            'php_ini value'     => array(
                array('label' => 'X', 'php_ini' => array('output_buffering' => false)),
                "php_ini key 'output_buffering' must be a string or a number"
            ),
        );
    }
}
