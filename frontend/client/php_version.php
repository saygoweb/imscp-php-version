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

namespace SGW_PhpVersion;

use iMSCP\Event\EventAggregator;
use iMSCP\Event\Events;
use iMSCP\TemplateEngine;

require_once __DIR__ . '/../common.php';
require_once __DIR__ . '/../view.php';

/***********************************************************************************************************************
 * Functions
 */

/**
 * Save the versions and pools the customer submitted.
 *
 * The form carries one version and one pool per vhost, so a customer may move
 * several domains onto different versions or pools in a single submit. Only
 * the ones that actually differ are acted on.
 *
 * @param int $adminId Customer unique identifier
 * @return void
 */
function handleSubmit($adminId)
{
    if (!isset($_POST['submit'])) {
        return;
    }

    $wanted = isset($_POST['version']) && is_array($_POST['version'])
        ? $_POST['version'] : array();
    $wantedPools = isset($_POST['pool']) && is_array($_POST['pool'])
        ? $_POST['pool'] : array();
    $installed = installedVersions();
    $pools = pools();
    $applied = 0;

    foreach (getDomains($adminId) as $domain) {
        $key = domainKey($domain);

        if (!isset($wanted[$key]) || !isset($wantedPools[$key])) {
            continue;
        }

        $version = clean_input($wanted[$key]);
        $pool = clean_input($wantedPools[$key]);

        // '' is the panel default, which is always a valid choice; anything
        // else has to be a version the backend has reported as installed.
        if ($version !== '' && !array_key_exists($version, $installed)) {
            showBadRequestErrorPage();
        }

        // Unlike the version above, '' is itself a legitimate key of
        // pools() -- it names the default instance -- so it needs no
        // special case here before the lookup.
        if (!array_key_exists($pool, $pools)) {
            showBadRequestErrorPage();
        }

        if (!isSettled($domain)
            || (rawVersion($domain) === $version && rawPool($domain) === $pool)
        ) {
            continue;
        }

        setChoice($domain, $version, $pool);
        $applied++;
    }

    if ($applied) {
        send_request();
        set_page_message(
            tr('PHP settings scheduled to change on %d domain(s).', $applied), 'success'
        );
    } else {
        set_page_message(tr('Nothing to change.'), 'info');
    }

    redirectTo('php_version.php');
}

/**
 * Fill the domain table.
 *
 * @param TemplateEngine $tpl
 * @param int $adminId Customer unique identifier
 * @return void
 */
function generatePage($tpl, $adminId)
{
    $versions = installedVersions();
    $pools = pools();

    if (!$versions) {
        $tpl->assign(array(
            'DOMAIN_LIST' => '',
            'NO_DOMAINS'  => tr('No PHP versions have been reported yet. They are detected the next time the backend runs.')
        ));
        $tpl->parse('NO_DOMAINS_BLOCK', 'no_domains_block');

        return;
    }

    $domains = getDomains($adminId);

    if (!$domains) {
        $tpl->assign(array(
            'DOMAIN_LIST' => '',
            'NO_DOMAINS'  => tr('You have no domains that run PHP.')
        ));
        $tpl->parse('NO_DOMAINS_BLOCK', 'no_domains_block');

        return;
    }

    $tpl->assign(array(
        'NO_DOMAINS_BLOCK'  => '',
        'BULK_OPTIONS'      => versionOptions($versions, NULL),
        'BULK_POOL_OPTIONS' => poolOptions($pools, NULL)
    ));

    foreach ($domains as $domain) {
        $settled = isSettled($domain);

        $tpl->assign(array(
            'DOMAIN_KEY'      => tohtml(domainKey($domain), 'htmlAttr'),
            'DOMAIN_NAME'     => tohtml(decode_idna($domain['domain_name'])),
            'DOMAIN_KIND'     => tohtml(domainKindLabel($domain['domain_type'])),
            'STATUS'          => tohtml(statusText($domain['status'])),
            'STATUS_ICON'     => statusIcon($domain['status']),
            'CURRENT_VERSION' => tohtml(versionLabel($domain, $versions)),
            'CURRENT_POOL'    => tohtml(poolLabel($domain, $pools)),
            'VERSION_OPTIONS' => versionOptions($versions, rawVersion($domain)),
            'POOL_OPTIONS'    => poolOptions($pools, rawPool($domain)),
            'ROW_DISABLED'    => $settled ? '' : ' disabled'
        ));

        $tpl->parse('DOMAIN_ITEM', '.domain_item');
    }
}

/***********************************************************************************************************************
 * Main
 */

EventAggregator::getInstance()->dispatch(Events::onClientScriptStart);
check_login('user');

// The feature is the reseller's PHP permission and nothing else.
if (!customerHasFeature('php')) {
    showBadRequestErrorPage();
}

$adminId = intval($_SESSION['user_id']);

handleSubmit($adminId);

$tpl = new TemplateEngine();
$tpl->define_dynamic(array(
    'layout'           => 'shared/layouts/ui.tpl',
    'page'             => '../../plugins/SGW_PhpVersion/themes/default/view/client/php_version.tpl',
    'page_message'     => 'layout',
    'no_domains_block' => 'page',
    'domain_list'      => 'page',
    'domain_item'      => 'domain_list'
));
$tpl->assign(array(
    'TR_PAGE_TITLE'     => tr('Client / Domains / PHP Version'),
    'TR_INTRO'          => tr('Choose which PHP version each of your domains runs and which pool it runs in. Versions and pools run side by side, so different domains may be on different ones.'),
    'TR_STATUS'         => tr('Status'),
    'TR_DOMAIN_NAME'    => tr('Domain'),
    'TR_DOMAIN_KIND'    => tr('Type'),
    'TR_CURRENT'        => tr('Running'),
    'TR_CURRENT_POOL'   => tr('Pool'),
    'TR_NEW_VERSION'    => tr('PHP version'),
    'TR_NEW_POOL'       => tr('PHP pool'),
    'TR_BULK_SET'       => tr('Set ticked domains to'),
    'TR_BULK_SET_POOL'  => tr('Set ticked domains to pool'),
    'TR_BULK_APPLY'     => tr('Set'),
    'TR_APPLY'          => tr('Apply'),
    'TR_SELECT_ALL'     => tr('Select all')
));

generateNavigation($tpl);
generatePage($tpl, $adminId);
generatePageMessage($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
EventAggregator::getInstance()->dispatch(Events::onClientScriptEnd, array('templateEngine' => $tpl));
$tpl->prnt();
