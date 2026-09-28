<?php
namespace iMSCP\Plugin\SGW_PhpVersion\Test\Graphql\Double;

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

use iMSCP\Event\Listener\EventListener;
use iMSCP\Event\Listener\PriorityQueue;
use iMSCP\Event\Listener\ResponseCollection;
use iMSCP\Event\EventManagerInterface;

// Named so that it does not end in "Test.php": PHPUnit's default file suffix
// filter would otherwise try to include this file - and so resolve
// EventManagerInterface below - while it is still discovering test files,
// long before any test's setUpBeforeClass() has bootstrapped the panel that
// interface lives in. PluginWiringTest requires this file itself, from inside
// a test method, once that bootstrap has already run.

/**
 * Records which events register() asked to listen on; nothing here needs to
 * actually dispatch anything.
 */
class EventManagerSpy implements EventManagerInterface
{
    /** @var string[] */
    public $registeredOn = array();

    public function dispatch($event, $arguments = array())
    {
        return new ResponseCollection();
    }

    public function registerListener($event, $listener, $priority = 1)
    {
        foreach ((array)$event as $name) {
            $this->registeredOn[] = $name;
        }

        return $this;
    }

    public function unregisterListener(EventListener $listener)
    {
        return false;
    }

    public function getEvents()
    {
        return $this->registeredOn;
    }

    public function getListeners($event)
    {
        return new PriorityQueue();
    }

    public function clearListeners($event)
    {
    }

    public function hasListener($event)
    {
        return in_array($event, $this->registeredOn, true);
    }
}
