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

use PDO;

/**
 * Every vhost owned by the customers the given condition picks out.
 *
 * i-MSCP keeps the four vhost kinds in four tables; the version rows are keyed
 * by the same (type, id) pair i-MSCP itself uses, so one union gives the whole
 * picture including alias subdomains. The condition is spliced into each arm
 * of the union rather than applied afterwards, so that a reseller's page and a
 * customer's page differ by their WHERE clause alone.
 *
 * Only customers whose reseller has given them PHP appear at all: without PHP
 * there is no version to choose.
 *
 * @param string $ownerCondition SQL predicate over the `domain` alias `d`
 * @param array $params Parameters for one occurrence of $ownerCondition
 * @return array
 */
function fetchDomains($ownerCondition, array $params)
{
    $sql = "
        SELECT v.*, ad.admin_name,
            p.php_version_id, p.php_version, p.applied_version, p.status
        FROM (
            SELECT 'dmn' AS domain_type, d.domain_id AS domain_id,
                d.domain_admin_id AS admin_id,
                d.domain_name AS domain_name, d.domain_status AS domain_status,
                d.url_forward AS url_forward
            FROM domain AS d
            WHERE d.domain_php = 'yes' AND ($ownerCondition)

            UNION ALL

            SELECT 'sub', s.subdomain_id, d.domain_admin_id,
                CONCAT(s.subdomain_name, '.', d.domain_name), s.subdomain_status,
                s.subdomain_url_forward
            FROM subdomain AS s
            JOIN domain AS d USING(domain_id)
            WHERE d.domain_php = 'yes' AND ($ownerCondition)

            UNION ALL

            SELECT 'als', a.alias_id, d.domain_admin_id,
                a.alias_name, a.alias_status, a.url_forward
            FROM domain_aliasses AS a
            JOIN domain AS d USING(domain_id)
            WHERE d.domain_php = 'yes' AND ($ownerCondition)

            UNION ALL

            SELECT 'alssub', sa.subdomain_alias_id, d.domain_admin_id,
                CONCAT(sa.subdomain_alias_name, '.', a.alias_name),
                sa.subdomain_alias_status, sa.subdomain_alias_url_forward
            FROM subdomain_alias AS sa
            JOIN domain_aliasses AS a USING(alias_id)
            JOIN domain AS d USING(domain_id)
            WHERE d.domain_php = 'yes' AND ($ownerCondition)
        ) AS v
        JOIN admin AS ad ON ad.admin_id = v.admin_id
        LEFT JOIN php_version AS p
            ON p.domain_type = v.domain_type AND p.domain_id = v.domain_id
        ORDER BY ad.admin_name, v.domain_name
    ";

    $stmt = exec_query($sql, array_merge($params, $params, $params, $params));

    return array_values(array_filter(
        $stmt->fetchAll(PDO::FETCH_ASSOC), __NAMESPACE__ . '\runsPhp'
    ));
}

/**
 * Every vhost one customer owns.
 *
 * @param int $adminId Customer unique identifier
 * @return array
 */
function getDomains($adminId)
{
    return fetchDomains('d.domain_admin_id = ?', array($adminId));
}

/**
 * Every vhost owned by any of a reseller's customers.
 *
 * @param int $resellerId Reseller unique identifier
 * @return array
 */
function getResellerDomains($resellerId)
{
    return fetchDomains(
        "d.domain_admin_id IN (
            SELECT admin_id FROM admin WHERE created_by = ? AND admin_type = 'user'
        )",
        array($resellerId)
    );
}

/**
 * Does this vhost run PHP of its own?
 *
 * A vhost that forwards or proxies elsewhere is built from the forward
 * template, which has no PHP handler and gets no pool, so offering it a
 * version would be offering something that could never take effect.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @return bool
 */
function runsPhp(array $domain)
{
    return $domain['url_forward'] === NULL
        || $domain['url_forward'] === ''
        || $domain['url_forward'] === 'no';
}

/**
 * The form key identifying one vhost.
 *
 * A hyphen rather than a colon: the key ends up both in an HTML attribute and
 * in the jQuery selector that reads it back, and a colon needs escaping in
 * one and means something in the other.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @return string
 */
function domainKey(array $domain)
{
    return $domain['domain_type'] . '-' . $domain['domain_id'];
}

/**
 * The PHP versions the backend last found installed, oldest first.
 *
 * The list is written by the plugin's backend rather than read off the
 * filesystem here, because what makes a version usable is more than a
 * directory under /etc/php: it also needs an FPM binary and a service unit,
 * and only the backend is in a position to see those.
 *
 * @return array Version string => is it the panel default?
 */
function installedVersions()
{
    static $versions = NULL;

    if (NULL === $versions) {
        $versions = array();
        $stmt = exec_query(
            'SELECT version, is_default FROM php_version_installed ORDER BY version + 0, version'
        );

        foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $versions[$row['version']] = (bool)$row['is_default'];
        }
    }

    return $versions;
}

/**
 * The version a vhost with no choice of its own runs on.
 *
 * @return string Version string, or '' when the backend has not run yet
 */
function defaultVersion()
{
    foreach (installedVersions() as $version => $isDefault) {
        if ($isDefault) {
            return $version;
        }
    }

    return '';
}

/**
 * The choice recorded for a vhost, as opposed to what that resolves to.
 *
 * '' means "follow the panel default", which is a choice in its own right and
 * has to stay distinguishable from being pinned to the version that happens to
 * be the default today. The selectors are built from this, so that submitting
 * a page unchanged records no change.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @return string
 */
function rawVersion(array $domain)
{
    return ($domain['php_version'] === NULL) ? '' : $domain['php_version'];
}

/**
 * The version a vhost is meant to be running, default included.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @return string
 */
function chosenVersion(array $domain)
{
    return ($domain['php_version'] === NULL || $domain['php_version'] === '')
        ? defaultVersion()
        : $domain['php_version'];
}

/**
 * Record a choice of version for one vhost, and schedule the rebuild.
 *
 * Two rows change: this plugin's own, which is what the backend's listeners
 * read while the vhost is being built, and the vhost's own status, which is
 * what makes i-MSCP rebuild it at all. Nothing here writes any configuration;
 * the whole point is that i-MSCP still builds the vhost and the pool, only
 * pointed at a different version.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @param string $version Version to run, or '' for the panel default
 * @return void
 */
function setVersion(array $domain, $version)
{
    if ($domain['php_version_id'] === NULL) {
        exec_query(
            '
                INSERT INTO php_version (
                    admin_id, domain_type, domain_id, domain_name, php_version,
                    applied_version, status
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ',
            array(
                $domain['admin_id'], $domain['domain_type'], $domain['domain_id'],
                $domain['domain_name'], $version, '', 'toadd'
            )
        );
    } else {
        exec_query(
            'UPDATE php_version SET php_version = ?, status = ? WHERE php_version_id = ?',
            array($version, 'tochange', $domain['php_version_id'])
        );
    }

    scheduleRebuild($domain['admin_id'], $domain['domain_type'], $domain['domain_id']);
}

/**
 * Apply a version to a set of vhosts, skipping those that would not change.
 *
 * A vhost already on the wanted version is left alone rather than being
 * rebuilt for nothing, which matters when a reseller sweeps a version across
 * a few hundred domains at once.
 *
 * @param array $domains Rows as returned by fetchDomains()
 * @param string $version Version to run, or '' for the panel default
 * @return array (applied, skipped) counts
 */
function applyVersion(array $domains, $version)
{
    $applied = $skipped = 0;

    foreach ($domains as $domain) {
        // A vhost the backend is mid-way through is left alone rather than
        // having a second change stacked on top of it.
        if (!isSettled($domain) || rawVersion($domain) === $version) {
            $skipped++;
            continue;
        }

        setVersion($domain, $version);
        $applied++;
    }

    return array($applied, $skipped);
}

/**
 * Mark one vhost for rebuild by i-MSCP.
 *
 * The four vhost kinds carry their status in four differently named columns;
 * this is the same mapping the core PHP editor uses when a customer changes a
 * php.ini setting, minus the per_user case, which this plugin refuses to run
 * under at all.
 *
 * @param int $adminId Owning customer's unique identifier
 * @param string $type One of dmn, sub, als, alssub
 * @param int $id Vhost unique identifier within its type
 * @return void
 */
function scheduleRebuild($adminId, $type, $id)
{
    switch ($type) {
        case 'dmn':
            $query = "
                UPDATE domain SET domain_status = 'tochange'
                WHERE domain_admin_id = ? AND domain_id = ?
                AND domain_status NOT IN('disabled', 'todelete')
            ";
            break;
        case 'sub':
            $query = "
                UPDATE subdomain JOIN domain USING(domain_id)
                SET subdomain_status = 'tochange'
                WHERE domain_admin_id = ? AND subdomain_id = ?
                AND subdomain_status NOT IN('disabled', 'todelete')
            ";
            break;
        case 'als':
            $query = "
                UPDATE domain_aliasses JOIN domain USING(domain_id)
                SET alias_status = 'tochange'
                WHERE domain_admin_id = ? AND alias_id = ?
                AND alias_status NOT IN('disabled', 'todelete')
            ";
            break;
        case 'alssub':
            $query = "
                UPDATE subdomain_alias
                JOIN domain_aliasses USING(alias_id)
                JOIN domain USING(domain_id)
                SET subdomain_alias_status = 'tochange'
                WHERE domain_admin_id = ? AND subdomain_alias_id = ?
                AND subdomain_alias_status NOT IN('disabled', 'todelete')
            ";
            break;
        default:
            return;
    }

    exec_query($query, array($adminId, $id));
}

/**
 * Human readable name for a vhost kind.
 *
 * @param string $type One of dmn, sub, als, alssub
 * @return string
 */
function domainKindLabel($type)
{
    $labels = array(
        'dmn'    => tr('Domain'),
        'sub'    => tr('Subdomain'),
        'als'    => tr('Alias'),
        'alssub' => tr('Alias subdomain')
    );

    return isset($labels[$type]) ? $labels[$type] : $type;
}

/**
 * Map an item status onto one of the theme's status icons.
 *
 * @param string|null $status
 * @return string
 */
function statusIcon($status)
{
    if ($status === NULL || $status === 'ok' || $status === 'disabled') {
        return 'ok';
    }

    if (in_array($status, array('toadd', 'tochange', 'todisable', 'todelete'))) {
        return 'reload';
    }

    return 'error';
}

/**
 * Human readable item status.
 *
 * @param string|null $status
 * @return string
 */
function statusText($status)
{
    switch ($status) {
        case NULL:
        case 'ok':
        case 'disabled':
            return tr('Running');
        case 'toadd':
        case 'tochange':
            return tr('Applying...');
        case 'todisable':
        case 'todelete':
            return tr('Removing...');
        default:
            return tr('Error');
    }
}

/**
 * Is the item settled, i.e. is the backend done with it?
 *
 * A busy item must not be edited, or the backend would act on half of one
 * change and half of the next. A vhost i-MSCP itself is still working on is
 * equally off limits, since the rebuild this plugin depends on has not
 * finished.
 *
 * @param array $domain Row as returned by fetchDomains()
 * @return bool
 */
function isSettled(array $domain)
{
    $ours = $domain['status'];
    $settled = $ours === NULL || $ours === 'ok' || $ours === 'disabled'
        || statusIcon($ours) === 'error';

    return $settled && in_array($domain['domain_status'], array('ok', 'disabled'));
}
