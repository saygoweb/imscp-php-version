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

// This suite runs entirely on the SGW_GraphQL plugin's own PHPUnit and its own
// test helpers (AuthzTestCase, Fixture, the doubles): it proves what THIS
// plugin adds to an API that plugin serves, so it borrows that plugin's rig
// rather than building a second one.
//
// This exact path, not a copy vendored into this plugin: the panel loads the
// very same file when SGW_GraphQL is enabled, and PHP's require_once dedupes
// on the realpath. A second copy would be a second definition of every class
// in it and fatal with "Cannot redeclare ...".
$graphQlAutoload = '/var/www/imscp-plugins/imscp-graphql/vendor/autoload.php';

if (!is_readable($graphQlAutoload)) {
    fwrite(STDERR,
        "This suite needs the SGW_GraphQL plugin's Composer dependencies.\n" .
        "Expected to find them at:\n\n    $graphQlAutoload\n\n" .
        "Clone saygoweb/imscp-graphql there and run its `composer install`, " .
        "or run this suite inside the imscp-imscp / imscp-ci containers, " .
        "where that checkout is already mounted.\n"
    );
    exit(1);
}

require_once $graphQlAutoload;

// SchemaFactory reads schema/schema.graphql off this plugin's own root, not
// off ours, so the test case needs it too rather than reusing dirname(__DIR__)
// the way a test *inside* imscp-graphql can.
define('SGW_GRAPHQL_PLUGIN_DIR', dirname($graphQlAutoload, 2));

// Only the panel's own Composer autoloader, not the panel itself -
// IntegrationTestCase's own tests bootstrap the panel lazily, in
// setUpBeforeClass(), and skip when it is not installed on this machine; this
// suite leaves that exactly as it is.
//
// It is registered here, eagerly, because the panel's Composer autoloader
// registers itself with spl_autoload_register(..., true, true) too
// (vendor/composer/autoload_real.php), and a later prepend always wins the
// race against an earlier one, whichever order the two calls happen in. Left
// to IntegrationTestCase's setUpBeforeClass(), the panel's own would be the
// later one - it runs the moment a test class bootstraps the panel - and push
// ours behind it. Getting it registered here first, then prepending ours
// after, means ours is the later call and so the one that wins; Composer's own
// getLoader() memoises the instance, so requiring this same file again later,
// as the panel's own bootstrap does, registers nothing a second time and does
// not reorder anything.
$panelAutoload = dirname(\iMSCP\Plugin\SGW_GraphQL\Test\Integration\IntegrationTestCase::IMSCP_LIB, 2)
    . '/vendor/autoload.php';

if (is_readable($panelAutoload)) {
    require_once $panelAutoload;
}

// Prepended, so that this - the checkout under test - wins over whatever the
// panel's own Composer autoloader maps iMSCP\Plugin\SGW_PhpVersion\ to: a
// different checkout, symlinked into gui/plugins by the panel's own install,
// which is not this worktree.
$pluginRoot = dirname(__DIR__, 2);

spl_autoload_register(static function ($class) use ($pluginRoot) {
    $prefix = 'iMSCP\\Plugin\\SGW_PhpVersion\\';

    if (strncmp($class, $prefix, strlen($prefix)) !== 0) {
        return;
    }

    $relative = substr($class, strlen($prefix));
    $file = $pluginRoot . '/' . str_replace('\\', '/', $relative) . '.php';

    if (is_file($file)) {
        require $file;
    }
}, true, true);
