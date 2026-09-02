<?php
/**
 * Drive the i-MSCP plugin manager from the command line.
 *
 * The panel's plugin management page is the supported way to install, enable
 * and remove a plugin. During development the same steps are wanted after
 * every deploy, so this runs them directly against the same PluginManager the
 * page uses. It is a development tool and is not part of the release archive.
 *
 * Run inside the box, as the panel user so that the files it writes stay
 * readable by the panel:
 *
 *   sudo -u vu2000 php /usr/local/src/imscp-php-version/tools/plugin-ctl.php sync
 *   sudo -u vu2000 php .../plugin-ctl.php install SGW_PhpVersion
 *   sudo -u vu2000 php .../plugin-ctl.php enable  SGW_PhpVersion
 *   sudo -u vu2000 php .../plugin-ctl.php status
 *
 * A step that needs the backend leaves a request behind; run it with
 *   sudo perl /var/www/imscp/engine/imscp-rqst-mngr
 */

if (PHP_SAPI !== 'cli') {
    exit("This script must be run from the command line.\n");
}

require_once '/var/www/imscp/gui/include/imscp-lib.php';

use iMSCP\Registry;

$command = isset($argv[1]) ? $argv[1] : 'status';
$plugin = isset($argv[2]) ? $argv[2] : 'SGW_PhpVersion';

/** @var \iMSCP\Plugin\PluginManager $pm */
$pm = Registry::get('pluginManager');

try {
    switch ($command) {
        case 'sync':
            $pm->pluginSyncData();
            echo "Plugin list synchronised.\n";
            break;

        case 'install':
            $pm->pluginInstall($plugin);
            echo "$plugin: install requested.\n";
            break;

        case 'enable':
            $pm->pluginEnable($plugin);
            echo "$plugin: enable requested.\n";
            break;

        case 'disable':
            $pm->pluginDisable($plugin);
            echo "$plugin: disable requested.\n";
            break;

        case 'update':
            $pm->pluginUpdate($plugin);
            echo "$plugin: update requested.\n";
            break;

        case 'uninstall':
            $pm->pluginUninstall($plugin);
            echo "$plugin: uninstall requested.\n";
            break;

        case 'delete':
            $pm->pluginDelete($plugin);
            echo "$plugin: deleted.\n";
            break;

        case 'status':
            foreach ($pm->pluginGetList(false) as $name) {
                printf(
                    "%-20s %-12s %s\n",
                    $name,
                    $pm->pluginGetStatus($name),
                    $pm->pluginGetError($name) ?: ''
                );
            }
            break;

        default:
            exit("Unknown command: $command\n");
    }
} catch (Throwable $e) {
    exit(sprintf("%s failed: %s\n", $command, $e->getMessage()));
}
