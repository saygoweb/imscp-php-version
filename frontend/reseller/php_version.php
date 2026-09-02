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
 * Save the versions the reseller submitted.
 *
 * The form carries one version per vhost, ticked or not: ticking is only what
 * the bulk control in the page acts on, so that what is submitted is exactly
 * what the reseller can see in the selects. Only vhosts belonging to this
 * reseller's own customers are ever listed, and the submitted keys are matched
 * against that list rather than trusted.
 *
 * @param int $resellerId Reseller unique identifier
 * @return void
 */
function handleSubmit($resellerId)
{
    if (!isset($_POST['submit'])) {
        return;
    }

    $wanted = isset($_POST['version']) && is_array($_POST['version'])
        ? $_POST['version'] : array();
    $installed = installedVersions();
    $applied = 0;
    $busy = 0;

    foreach (getResellerDomains($resellerId) as $domain) {
        $key = domainKey($domain);

        if (!isset($wanted[$key])) {
            continue;
        }

        $version = clean_input($wanted[$key]);

        // '' is the panel default, which is always a valid choice; anything
        // else has to be a version the backend has reported as installed.
        if ($version !== '' && !array_key_exists($version, $installed)) {
            showBadRequestErrorPage();
        }

        if (rawVersion($domain) === $version) {
            continue;
        }

        // A vhost the backend is mid-way through is left alone rather than
        // having a second change stacked on top of it. Across a few hundred
        // domains that is worth reporting rather than passing over in silence.
        if (!isSettled($domain)) {
            $busy++;
            continue;
        }

        setVersion($domain, $version);
        $applied++;
    }

    if ($applied) {
        send_request();
        set_page_message(
            tr('PHP version scheduled to change on %d domain(s).', $applied), 'success'
        );
    } elseif (!$busy) {
        set_page_message(tr('Nothing to change.'), 'info');
    }

    if ($busy) {
        set_page_message(
            tr('%d domain(s) were left alone because an update was already in progress. Try them again shortly.', $busy),
            'warning'
        );
    }

    redirectTo('php_version.php');
}

/**
 * Fill the domain table.
 *
 * @param TemplateEngine $tpl
 * @param int $resellerId Reseller unique identifier
 * @return void
 */
function generatePage($tpl, $resellerId)
{
    $versions = installedVersions();

    if (!$versions) {
        $tpl->assign(array(
            'DOMAIN_LIST' => '',
            'NO_DOMAINS'  => tr('No PHP versions have been reported yet. They are detected the next time the backend runs.')
        ));
        $tpl->parse('NO_DOMAINS_BLOCK', 'no_domains_block');

        return;
    }

    $domains = getResellerDomains($resellerId);

    if (!$domains) {
        $tpl->assign(array(
            'DOMAIN_LIST' => '',
            'NO_DOMAINS'  => tr('None of your customers has a domain that runs PHP.')
        ));
        $tpl->parse('NO_DOMAINS_BLOCK', 'no_domains_block');

        return;
    }

    $tpl->assign(array(
        'NO_DOMAINS_BLOCK' => '',
        'BULK_OPTIONS'     => versionOptions($versions, NULL)
    ));

    foreach ($domains as $domain) {
        $settled = isSettled($domain);

        $tpl->assign(array(
            'DOMAIN_KEY'      => tohtml(domainKey($domain), 'htmlAttr'),
            'CUSTOMER_NAME'   => tohtml(decode_idna($domain['admin_name'])),
            'DOMAIN_NAME'     => tohtml(decode_idna($domain['domain_name'])),
            'DOMAIN_KIND'     => tohtml(domainKindLabel($domain['domain_type'])),
            'STATUS'          => tohtml(statusText($domain['status'])),
            'STATUS_ICON'     => statusIcon($domain['status']),
            'CURRENT_VERSION' => tohtml(versionLabel($domain, $versions)),
            'VERSION_OPTIONS' => versionOptions($versions, rawVersion($domain)),
            'ROW_DISABLED'    => $settled ? '' : ' disabled'
        ));

        $tpl->parse('DOMAIN_ITEM', '.domain_item');
    }
}

/***********************************************************************************************************************
 * Main
 */

EventAggregator::getInstance()->dispatch(Events::onResellerScriptStart);
check_login('reseller');

$resellerId = intval($_SESSION['user_id']);

handleSubmit($resellerId);

$tpl = new TemplateEngine();
$tpl->define_dynamic(array(
    'layout'           => 'shared/layouts/ui.tpl',
    'page'             => '../../plugins/SGW_PhpVersion/themes/default/view/reseller/php_version.tpl',
    'page_message'     => 'layout',
    'no_domains_block' => 'page',
    'domain_list'      => 'page',
    'domain_item'      => 'domain_list'
));
$tpl->assign(array(
    'TR_PAGE_TITLE'   => tr('Reseller / Customers / PHP Version'),
    'TR_INTRO'        => tr('Choose which PHP version your customers\' domains run. Tick the domains you want to move, pick a version below and press Set, then Apply.'),
    'TR_STATUS'       => tr('Status'),
    'TR_CUSTOMER'     => tr('Customer'),
    'TR_DOMAIN_NAME'  => tr('Domain'),
    'TR_DOMAIN_KIND'  => tr('Type'),
    'TR_CURRENT'      => tr('Running'),
    'TR_NEW_VERSION'  => tr('PHP version'),
    'TR_BULK_SET'     => tr('Set ticked domains to'),
    'TR_BULK_APPLY'   => tr('Set'),
    'TR_APPLY'        => tr('Apply'),
    'TR_SELECT_ALL'   => tr('Select all')
));

generateNavigation($tpl);
generatePage($tpl, $resellerId);
generatePageMessage($tpl);

$tpl->parse('LAYOUT_CONTENT', 'page');
EventAggregator::getInstance()->dispatch(Events::onResellerScriptEnd, array('templateEngine' => $tpl));
$tpl->prnt();
