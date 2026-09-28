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

use GraphQL\Type\Schema;
use iMSCP\Plugin\SGW_GraphQL\Api\Container;
use iMSCP\Plugin\SGW_GraphQL\Auth\Scope;
use iMSCP\Plugin\SGW_GraphQL\Extension\ExtensionRegistry;
use iMSCP\Plugin\SGW_GraphQL\Support\GlobalId;
use iMSCP\Plugin\SGW_GraphQL\Support\NodeType;
use iMSCP\Plugin\SGW_GraphQL\Test\Authz\AuthzTestCase;
use iMSCP\Plugin\SGW_PhpVersion\GraphQL\PhpVersionExtension;

/**
 * Runs the real PhpVersionExtension - the one SGW_PhpVersion::
 * onGraphQLRegisterExtensions() registers - against the SGW_GraphQL plugin's
 * own fixture, exactly as ExtensionContextTest.php does for a fixture
 * extension. What it proves is this plugin's side of the bargain: reading and
 * writing php_version through the API follows the same rules
 * client/php_version.php and reseller/php_version.php do.
 */
class PhpVersionExtensionTest extends AuthzTestCase
{
    /** A version nothing in this suite ever installs, for the bad-input cases. */
    const UNINSTALLED_VERSION = '99.9';

    /** @var bool */
    private static $schemaEnsured = false;

    protected function setUp(): void
    {
        $this->ensureSchema();

        parent::setUp();

        // installedVersions() and pools() must answer the same way regardless
        // of whatever the box this suite happens to run on has detected or been
        // configured with, and regardless of what an earlier test in this
        // process left cached in their static memo. Both are reset inside the
        // fixture's own transaction, so the box's real rows are untouched.
        $this->db->pdo()->exec('UPDATE php_version_installed SET is_default = 0');
        $statement = $this->db->pdo()->prepare(
            'INSERT INTO php_version_installed (version, is_default) VALUES (?, ?), (?, ?)
             ON DUPLICATE KEY UPDATE is_default = VALUES(is_default)'
        );
        $statement->execute(array('7.4', 0, '8.3', 1));
    }

    /**
     * The plugin's tables may not exist yet on a box this suite is the first
     * thing to touch - a bare CI image the reusable workflow only *linked*
     * the plugin into (install: false), rather than one that ran its
     * install() and therefore its own sql/ migrations. Run them here rather
     * than writing the schema a second time, and before any fixture opens a
     * transaction: DDL commits on its own and would take the fixture's
     * rollback with it.
     */
    private function ensureSchema(): void
    {
        if (self::$schemaEnsured) {
            return;
        }

        self::$schemaEnsured = true;

        if (\iMSCP\Plugin\SGW_GraphQL\Repository\Db::fromPanel()
                ->value("SHOW TABLES LIKE 'php_version'") !== null
        ) {
            return;
        }

        $sqlDir = dirname(__DIR__, 2) . '/sql';

        foreach (array('001_create_php_version_tables.php', '002_add_php_pool.php') as $file) {
            $migration = include $sqlDir . '/' . $file;

            foreach (explode(';', $migration['up']) as $statement) {
                $statement = trim($statement);

                if ($statement !== '') {
                    \iMSCP\Plugin\SGW_GraphQL\Repository\Db::fromPanel()->pdo()->exec($statement);
                }
            }
        }
    }

    protected function schema(): Schema
    {
        $registry = new ExtensionRegistry();
        $registry->register(new PhpVersionExtension());

        return Container::forTesting(
            SGW_GRAPHQL_PLUGIN_DIR,
            array(),
            static function (string $sql, array $bind = array()) { return null; },
            static function (int $adminId) { return null; },
            static function (int $adminId) { return true; },
            $this->db,
            (array)\iMSCP\Registry::get('config'),
            $this->core,
            $this->probe,
            $this->sqlServer,
            null,
            null,
            $registry
        )->schemaFactory()->create();
    }

    /**
     * A php_version row for one vhost, written directly rather than through
     * setChoice(): what the read side sees, independent of the write side.
     */
    private function putRow($kind, $id, $adminId, $name, $version, $pool, $appliedVersion, $appliedPool, $status)
    {
        $statement = $this->db->pdo()->prepare('
            INSERT INTO php_version (
                admin_id, domain_type, domain_id, domain_name, php_version,
                php_pool, applied_version, applied_pool, status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ');
        $statement->execute(array(
            $adminId, $kind, $id, $name, $version, $pool, $appliedVersion, $appliedPool, $status
        ));
    }

    private function statusOf($kind, $id)
    {
        return $this->db->value(
            'SELECT status FROM php_version WHERE domain_type = ? AND domain_id = ?',
            array($kind, $id)
        );
    }

    private function read($tag, $key, $who = 'admin')
    {
        $result = $this->execute(
            'query($id: ID!) { node(id: $id) {
                ... on Domain { phpVersion { version appliedVersion pool appliedPool provisioning { state raw settled message } } }
                ... on Subdomain { phpVersion { version appliedVersion pool appliedPool provisioning { state raw settled message } } }
                ... on DomainAlias { phpVersion { version appliedVersion pool appliedPool provisioning { state raw settled message } } }
            } }',
            array('id' => GlobalId::encode($tag, $key)),
            $this->fixture->identity($who)
        );

        self::assertArrayNotHasKey('errors', $result, json_encode($result));

        return $result['data']['node']['phpVersion'];
    }

    private function set($tag, $key, $version, $pool, $who, array $scopes = array())
    {
        return $this->execute(
            'mutation($id: ID!, $version: String!, $pool: String!) {
                phpVersionSet(input: { id: $id, version: $version, pool: $pool }) {
                    name
                    provisioning { state }
                    ... on Domain { phpVersion { version pool } }
                    ... on Subdomain { phpVersion { version pool } }
                    ... on DomainAlias { phpVersion { version pool } }
                }
            }',
            array('id' => GlobalId::encode($tag, $key), 'version' => $version, 'pool' => $pool),
            $this->fixture->identity($who, $scopes)
        );
    }

    // ---- reads --------------------------------------------------------

    public function testEachVhostKindReadsItsOwnRow(): void
    {
        $domainId = $this->fixture->domainId();
        $subdomainId = $this->fixture->subdomainId();
        $aliasId = $this->fixture->aliasId();
        $aliasSubdomainId = $this->fixture->aliasSubdomainId();
        $owner = $this->fixture->customerId();

        $this->putRow('dmn', $domainId, $owner, $this->fixture->domainName(), '8.3', '', '8.3', '', 'ok');
        $this->putRow('sub', $subdomainId, $owner, $this->fixture->subdomainName(), '7.4', 'cloudflare', '', '', 'toadd');
        $this->putRow('als', $aliasId, $owner, $this->fixture->aliasName(), '', '', '', '', 'ok');
        // No row at all for the alias subdomain: proves null-when-no-row.

        self::assertSame(
            array(
                'version' => '8.3', 'appliedVersion' => '8.3', 'pool' => '', 'appliedPool' => '',
                'provisioning' => array('state' => 'OK', 'raw' => 'ok', 'settled' => true, 'message' => null)
            ),
            $this->read(NodeType::DOMAIN, $domainId)
        );
        self::assertSame(
            array(
                'version' => '7.4', 'appliedVersion' => '', 'pool' => 'cloudflare', 'appliedPool' => '',
                'provisioning' => array('state' => 'PENDING', 'raw' => 'toadd', 'settled' => false, 'message' => null)
            ),
            $this->read(NodeType::SUBDOMAIN, $subdomainId)
        );
        self::assertSame(
            array(
                'version' => '', 'appliedVersion' => '', 'pool' => '', 'appliedPool' => '',
                'provisioning' => array('state' => 'OK', 'raw' => 'ok', 'settled' => true, 'message' => null)
            ),
            $this->read(NodeType::DOMAIN_ALIAS, $aliasId)
        );
        self::assertNull($this->read(NodeType::ALIAS_SUBDOMAIN, $aliasSubdomainId));
    }

    public function testAFieldAsksForDomainsReadScope(): void
    {
        $result = $this->execute(
            'query($id: ID!) { node(id: $id) { ... on Domain { phpVersion { version } } } }',
            array('id' => GlobalId::encode(NodeType::DOMAIN, $this->fixture->domainId())),
            $this->fixture->identity('customer', array(Scope::DOMAINS_WRITE))
        );

        self::assertSame('FORBIDDEN', $result['errors'][0]['extensions']['code'], json_encode($result));
    }

    public function testPhpVersionsListsInstalledVersionsAndConfiguredPools(): void
    {
        $result = $this->execute(
            'query { phpVersions { versions { version isDefault } pools { name label } } }',
            array(),
            $this->fixture->identity('customer')
        );

        self::assertArrayNotHasKey('errors', $result, json_encode($result));

        $versions = $result['data']['phpVersions']['versions'];
        $byVersion = array();
        foreach ($versions as $row) {
            $byVersion[$row['version']] = $row['isDefault'];
        }

        self::assertArrayHasKey('7.4', $byVersion);
        self::assertFalse($byVersion['7.4']);
        self::assertArrayHasKey('8.3', $byVersion);
        self::assertTrue($byVersion['8.3']);

        $pools = array();
        foreach ($result['data']['phpVersions']['pools'] as $row) {
            $pools[$row['name']] = $row['label'];
        }
        self::assertSame(array('' => 'Default', 'cloudflare' => 'Cloudflare'), $pools);
    }

    // ---- the mutation's happy path -------------------------------------

    /**
     * @dataProvider owningActors
     */
    public function testTheOwnerTheirResellerAndTheAdministratorMaySetIt(string $who): void
    {
        $subdomainId = $this->fixture->subdomainId();

        $result = $this->set(NodeType::SUBDOMAIN, $subdomainId, '8.3', 'cloudflare', $who);

        self::assertArrayNotHasKey('errors', $result, json_encode($result));
        self::assertSame($this->fixture->subdomainName(), $result['data']['phpVersionSet']['name']);
        self::assertSame(
            array('version' => '8.3', 'pool' => 'cloudflare'),
            $result['data']['phpVersionSet']['phpVersion']
        );
        self::assertSame('PENDING', $result['data']['phpVersionSet']['provisioning']['state']);

        // The row was written...
        $row = $this->db->rows(
            'SELECT php_version, php_pool, status FROM php_version WHERE domain_type = ? AND domain_id = ?',
            array('sub', $subdomainId)
        );
        self::assertCount(1, $row);
        self::assertSame('8.3', $row[0]['php_version']);
        self::assertSame('cloudflare', $row[0]['php_pool']);
        self::assertSame('toadd', $row[0]['status']);

        // ...and the daemon was woken, exactly once.
        self::assertSame(1, $this->core->requests);
    }

    public function owningActors(): array
    {
        return array('customer' => array('customer'), 'reseller' => array('reseller'), 'admin' => array('admin'));
    }

    public function testSettingItAgainUpdatesTheExistingRow(): void
    {
        $domainId = $this->fixture->domainId();
        $owner = $this->fixture->customerId();
        $this->putRow('dmn', $domainId, $owner, $this->fixture->domainName(), '7.4', '', '7.4', '', 'ok');

        $result = $this->set(NodeType::DOMAIN, $domainId, '8.3', '', 'customer');

        self::assertArrayNotHasKey('errors', $result, json_encode($result));

        $rows = $this->db->rows('SELECT COUNT(*) AS c FROM php_version WHERE domain_type = ? AND domain_id = ?', array('dmn', $domainId));
        self::assertSame(1, (int)$rows[0]['c']);
        self::assertSame('tochange', $this->statusOf('dmn', $domainId));
    }

    // ---- ownership and scope -------------------------------------------

    /**
     * @dataProvider strangers
     */
    public function testAnybodyElseIsToldTheVhostDoesNotExist(string $who): void
    {
        $result = $this->set(NodeType::DOMAIN, $this->fixture->domainId(), '8.3', '', $who);

        self::assertSame('NOT_FOUND', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame('input.id', $result['errors'][0]['extensions']['field']);
        self::assertSame(0, $this->core->requests);
    }

    public function strangers(): array
    {
        return array(
            'sibling'       => array('sibling'),
            'otherCustomer' => array('otherCustomer'),
            'otherReseller' => array('otherReseller')
        );
    }

    public function testADomainsReadOnlyTokenMayNotSetIt(): void
    {
        $result = $this->set(
            NodeType::DOMAIN, $this->fixture->domainId(), '8.3', '', 'customer', array(Scope::DOMAINS_READ)
        );

        self::assertSame('FORBIDDEN', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame(0, $this->core->requests);
    }

    // ---- state -----------------------------------------------------------

    public function testAPendingVhostAnswersConflict(): void
    {
        // The fixture's alias subdomain is still 'toadd'.
        $result = $this->set(
            NodeType::ALIAS_SUBDOMAIN, $this->fixture->aliasSubdomainId(), '8.3', '', 'customer'
        );

        self::assertSame('CONFLICT', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame(0, $this->core->requests);
    }

    public function testAPendingRowOfOursAnswersConflict(): void
    {
        $domainId = $this->fixture->domainId();
        $owner = $this->fixture->customerId();
        $this->putRow('dmn', $domainId, $owner, $this->fixture->domainName(), '7.4', '', '', '', 'tochange');

        $result = $this->set(NodeType::DOMAIN, $domainId, '8.3', '', 'customer');

        self::assertSame('CONFLICT', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame(0, $this->core->requests);
    }

    public function testADisabledVhostMayStillBeSet(): void
    {
        $domainId = $this->fixture->domainId();
        $this->db->pdo()
            ->prepare('UPDATE domain SET domain_status = ? WHERE domain_id = ?')
            ->execute(array('disabled', $domainId));

        $result = $this->set(NodeType::DOMAIN, $domainId, '8.3', '', 'customer');

        self::assertArrayNotHasKey('errors', $result, json_encode($result));
        self::assertSame(1, $this->core->requests);
    }

    // ---- the plugin's own feature gate -----------------------------------

    public function testADomainWithoutPhpAnswersFeatureUnavailable(): void
    {
        $domainId = $this->fixture->domainId();
        $this->db->pdo()
            ->prepare('UPDATE domain SET domain_php = ? WHERE domain_id = ?')
            ->execute(array('no', $domainId));

        $result = $this->set(NodeType::DOMAIN, $domainId, '8.3', '', 'customer');

        self::assertSame('FEATURE_UNAVAILABLE', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame('phpVersion', $result['errors'][0]['extensions']['feature']);
        self::assertSame(0, $this->core->requests);
    }

    public function testAForwardingVhostAnswersFeatureUnavailable(): void
    {
        $domainId = $this->fixture->domainId();
        $this->db->pdo()
            ->prepare('UPDATE domain SET url_forward = ? WHERE domain_id = ?')
            ->execute(array('https://example.net/', $domainId));

        $result = $this->set(NodeType::DOMAIN, $domainId, '8.3', '', 'customer');

        self::assertSame('FEATURE_UNAVAILABLE', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame(0, $this->core->requests);
    }

    // ---- input -------------------------------------------------------

    public function testAnUninstalledVersionIsBadInput(): void
    {
        $result = $this->set(
            NodeType::DOMAIN, $this->fixture->domainId(), self::UNINSTALLED_VERSION, '', 'customer'
        );

        self::assertSame('BAD_USER_INPUT', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame('input.version', $result['errors'][0]['extensions']['field']);
        self::assertSame(0, $this->core->requests);
    }

    public function testAnUnconfiguredPoolIsBadInput(): void
    {
        $result = $this->set(NodeType::DOMAIN, $this->fixture->domainId(), '8.3', 'bogus-pool', 'customer');

        self::assertSame('BAD_USER_INPUT', $result['errors'][0]['extensions']['code'], json_encode($result));
        self::assertSame('input.pool', $result['errors'][0]['extensions']['field']);
        self::assertSame(0, $this->core->requests);
    }

    public function testThePanelDefaultVersionAndPoolAreAlwaysValid(): void
    {
        $result = $this->set(NodeType::DOMAIN, $this->fixture->domainId(), '', '', 'customer');

        self::assertArrayNotHasKey('errors', $result, json_encode($result));
        self::assertSame(1, $this->core->requests);
    }

    // ---- ExtensionLoader kept it, quietly --------------------------------

    public function testTheExtensionIsKeptAndLogsNothing(): void
    {
        $registry = new ExtensionRegistry();
        $registry->register(new PhpVersionExtension());

        $container = Container::forTesting(
            SGW_GRAPHQL_PLUGIN_DIR,
            array(),
            static function (string $sql, array $bind = array()) { return null; },
            static function (int $adminId) { return null; },
            static function (int $adminId) { return true; },
            $this->db,
            (array)\iMSCP\Registry::get('config'),
            $this->core,
            $this->probe,
            $this->sqlServer,
            null,
            null,
            $registry
        );
        $container->schemaFactory()->create();

        $names = array();
        foreach ($container->extensions() as $extension) {
            $names[] = $extension->getName();
        }

        self::assertContains('SGW_PhpVersion', $names);
        self::assertSame(array(), $this->core->logs);
    }
}
