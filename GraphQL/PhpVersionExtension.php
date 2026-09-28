<?php
namespace iMSCP\Plugin\SGW_PhpVersion\GraphQL;

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

use iMSCP\Plugin\SGW_GraphQL\Auth\Scope;
use iMSCP\Plugin\SGW_GraphQL\Extension\Extension;
use iMSCP\Plugin\SGW_GraphQL\Extension\ExtensionContext;
use iMSCP\Plugin\SGW_GraphQL\Security\Guard;
use iMSCP\Plugin\SGW_GraphQL\Support\Provisioning;

require_once __DIR__ . '/../frontend/common.php';

/**
 * Puts this plugin's per-vhost PHP version and pool on the GraphQL API that
 * the SGW_GraphQL plugin serves, only ever loaded when that plugin dispatches
 * onGraphQLRegisterExtensions (see SGW_PhpVersion::onGraphQLRegisterExtensions()).
 *
 * Every rule here is the frontend pages' own, reused rather than repeated:
 * \SGW_PhpVersion\fetchDomain() is the same domain_php and runsPhp() filter
 * client/php_version.php and reseller/php_version.php read their domain lists
 * through, and setChoice() is the same write both pages' handleSubmit() calls.
 */
final class PhpVersionExtension implements Extension
{
    public function getName(): string
    {
        return 'SGW_PhpVersion';
    }

    public function getSdl(): string
    {
        return '
            "One PHP version the backend has reported as installed and usable."
            type PhpVersionInstalled {
              version: String!
              "Whether i-MSCP itself falls back to this version."
              isDefault: Boolean!
            }

            "One PHP-FPM instance a vhost may be placed in, beyond the default one."
            type PhpVersionPool {
              "\'\' names the default instance the distribution ships."
              name: String!
              label: String!
            }

            type PhpVersionOptions {
              "Oldest first."
              versions: [PhpVersionInstalled!]!
              "The default instance first."
              pools: [PhpVersionPool!]!
            }

            """
            The PHP version and pool one vhost is set to run. Null when no choice has
            ever been recorded for it - it simply follows the panel default, in the
            default pool - or when its domain does not run PHP at all.
            """
            type PhpVersionSetting {
              "The version recorded for this vhost. \'\' follows the panel default."
              version: String!
              "The version the backend last actually built this vhost with. \'\' before the first apply."
              appliedVersion: String!
              "The pool recorded for this vhost. \'\' is the default PHP-FPM instance."
              pool: String!
              "The pool the backend last actually built this vhost in. \'\' before the first apply."
              appliedPool: String!
              "Whether the backend has caught up with this choice yet."
              provisioning: Provisioning!
            }

            extend type Domain { phpVersion: PhpVersionSetting }
            extend type Subdomain { phpVersion: PhpVersionSetting }
            extend type DomainAlias { phpVersion: PhpVersionSetting }

            extend type Query {
              "The PHP versions and pools a vhost may be set to run in."
              phpVersions: PhpVersionOptions!
            }

            input PhpVersionSetInput {
              "A Domain, Subdomain or DomainAlias."
              id: ID!
              "\'\' selects the panel default version."
              version: String!
              "\'\' selects the default PHP-FPM instance."
              pool: String!
            }

            extend type Mutation {
              "FEATURE_UNAVAILABLE when the vhost\'s domain does not run PHP."
              phpVersionSet(input: PhpVersionSetInput!): VirtualHost!
            }
        ';
    }

    public function getResolvers(ExtensionContext $context): array
    {
        $read = static function ($source, array $args, $ctx) use ($context) {
            $context->requireScope($ctx, Scope::DOMAINS_READ);
            $vhost = $context->virtualHost($source);

            return $context->loader()->keyed(
                'SGW_PhpVersion:php_version',
                $vhost->getKind() . ':' . $vhost->getKey(),
                static function (array $keys) use ($context) {
                    $found = array();
                    $where = array();
                    $bind = array();

                    foreach ($keys as $key) {
                        list($kind, $id) = explode(':', $key, 2);
                        $where[] = '(domain_type = ? AND domain_id = ?)';
                        $bind[] = $kind;
                        $bind[] = (int)$id;
                    }

                    foreach ($context->db()->rows(
                        'SELECT domain_type, domain_id, php_version, php_pool,
                            applied_version, applied_pool, status
                         FROM php_version WHERE ' . implode(' OR ', $where),
                        $bind
                    ) as $row) {
                        $provisioning = Provisioning::fromStatus($row['status']);

                        $found[$row['domain_type'] . ':' . $row['domain_id']] = array(
                            'version'        => $row['php_version'],
                            'appliedVersion' => $row['applied_version'],
                            'pool'           => $row['php_pool'],
                            'appliedPool'    => $row['applied_pool'],
                            'provisioning'   => array(
                                'state'   => $provisioning->getState(),
                                'raw'     => $provisioning->getRaw(),
                                'settled' => $provisioning->isSettled(),
                                'message' => $provisioning->getMessage()
                            )
                        );
                    }

                    return $found;
                }
            );
        };

        return array(
            'Domain.phpVersion'      => $read,
            'Subdomain.phpVersion'   => $read,
            'DomainAlias.phpVersion' => $read,

            'Query.phpVersions' => static function ($source, array $args, $ctx) use ($context) {
                $context->requireScope($ctx, Scope::DOMAINS_READ);

                $versions = array();
                foreach (\SGW_PhpVersion\installedVersions() as $version => $isDefault) {
                    $versions[] = array('version' => $version, 'isDefault' => $isDefault);
                }

                $pools = array();
                foreach (\SGW_PhpVersion\pools() as $name => $label) {
                    $pools[] = array('name' => $name, 'label' => $label);
                }

                return array('versions' => $versions, 'pools' => $pools);
            },

            'Mutation.phpVersionSet' => static function ($source, array $args, $ctx) use ($context) {
                $input = (array)$args['input'];

                // Spec section 8.1: ownership (NOT_FOUND), then scope
                // (FORBIDDEN), in that order.
                $vhost = $context->targetVirtualHost(
                    $context->identity($ctx), $input['id'] ?? null, Scope::DOMAINS_WRITE, 'input.id'
                );

                // The vhost itself - the domain, subdomain or alias i-MSCP
                // builds - must not be mid-rebuild. 'disabled' is settled too:
                // both frontend pages allow a disabled vhost's PHP choice to
                // be changed, for i-MSCP to pick up whenever it is re-enabled.
                Guard::requireState(
                    (string)$vhost->getStatus(),
                    array(Provisioning::STATE_OK, Provisioning::STATE_DISABLED)
                );

                // The plugin's own rule: without PHP there is no version to
                // choose. \SGW_PhpVersion\fetchDomain() is exactly the filter
                // fetchDomains() applies for the frontend pages - domain_php
                // = 'yes' and a vhost that does not merely forward elsewhere -
                // so a vhost neither page would ever list answers the same
                // way here.
                $domain = \SGW_PhpVersion\fetchDomain($vhost->getKind(), $vhost->getKey());
                Guard::requireFeature($domain !== null, 'phpVersion');

                // This plugin's own row must have settled too, so that a
                // second change is never stacked on an unfinished first one.
                // No row at all (never touched) reads as settled, exactly as
                // \SGW_PhpVersion\isSettled() treats it.
                Guard::requireState(
                    (string)$domain['status'],
                    array(Provisioning::STATE_OK, Provisioning::STATE_DISABLED, Provisioning::STATE_ERROR)
                );

                $version = (string)($input['version'] ?? '');
                $pool = (string)($input['pool'] ?? '');

                if ($version !== '' && !array_key_exists($version, \SGW_PhpVersion\installedVersions())) {
                    throw Guard::badInput('input.version', 'That PHP version is not installed.');
                }

                if (!array_key_exists($pool, \SGW_PhpVersion\pools())) {
                    throw Guard::badInput('input.pool', 'That pool is not configured.');
                }

                \SGW_PhpVersion\setChoice($domain, $version, $pool);

                // Wakes the daemon; never inside a transaction.
                $context->core()->sendRequest();

                // The object returned is read after the write (decision D18).
                $context->loader()->reset();

                return $context->virtualHostReference($vhost);
            }
        );
    }

    public function getComplexity(): array
    {
        // Query.phpVersions has no arguments to bound it by, so it is charged
        // a flat estimate rather than left to graphql-php's default: both
        // lists are small and bounded by what the administrator configured
        // (excluded_versions, config.php's pools), never by anything a caller
        // controls.
        $flat = static function (int $childComplexity): int {
            return 10 * $childComplexity;
        };

        return array(
            'PhpVersionOptions.versions' => $flat,
            'PhpVersionOptions.pools'    => $flat
        );
    }
}
