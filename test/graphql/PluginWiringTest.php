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

use iMSCP\Event\Event;
use iMSCP\Plugin\SGW_GraphQL\Extension\ExtensionRegistry;
use iMSCP\Plugin\SGW_GraphQL\Test\Integration\IntegrationTestCase;
use iMSCP\Plugin\SGW_PhpVersion\GraphQL\PhpVersionExtension;
use iMSCP\Plugin\SGW_PhpVersion\Test\Graphql\Double\EventManagerSpy;
use iMSCP\Registry;

/**
 * The opt-in shape docs/EXTENSIONS.md asks for: SGW_PhpVersion::register()
 * listens for the event by its string name, and its
 * onGraphQLRegisterExtensions() registers this plugin's extension - and
 * nothing outside that one method ever names a GraphQL class, so this plugin
 * still works with SGW_GraphQL not installed at all.
 *
 * Double\EventManagerSpy - which implements the panel's own
 * EventManagerInterface - is required here rather than imported at the top of
 * this file, and only from inside a test method: that interface does not
 * exist until IntegrationTestCase::setUpBeforeClass() has bootstrapped the
 * panel, which has not happened yet while PHPUnit is still discovering test
 * files.
 */
class PluginWiringTest extends IntegrationTestCase
{
    public function testRegisterListensForTheGraphqlEvent(): void
    {
        require_once __DIR__ . '/Double/EventManagerSpy.php';

        $plugin = Registry::get('pluginManager')->pluginGet('SGW_PhpVersion');
        $spy = new EventManagerSpy();

        $plugin->register($spy);

        self::assertContains('onGraphQLRegisterExtensions', $spy->registeredOn);
    }

    public function testTheListenerRegistersThePhpVersionExtension(): void
    {
        $plugin = Registry::get('pluginManager')->pluginGet('SGW_PhpVersion');
        $registry = new ExtensionRegistry();
        $event = new Event('onGraphQLRegisterExtensions', array('registry' => $registry));

        $plugin->onGraphQLRegisterExtensions($event);

        $all = $registry->all();
        self::assertArrayHasKey('SGW_PhpVersion', $all);
        self::assertInstanceOf(PhpVersionExtension::class, $all['SGW_PhpVersion']);
    }
}
