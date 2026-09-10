use strict;
use warnings;
use Test::More;
use Cwd 'abs_path';

# A pool is a second PHP-FPM master for a version, with its own configuration
# directory and its own service. What is worth unit testing is the naming that
# ties those three together, and the decision about which pool a vhost belongs
# in; building the directory and the unit needs a live systemd and is checked
# against the container instead.
#
# Run as root, as version.t is:
#
#   cd test/backend && sudo perl all.t
use lib '/var/www/imscp/engine/PerlLib';

require_ok(abs_path('../../backend/SGW_PhpVersion.pm'))
    or BAIL_OUT('cannot load the plugin');

sub plugin
{
    bless {
        defaultVersion     => '7.3',
        phpConfig          => { PHP_CONF_DIR_PATH => '/etc/php/7.3' },
        _installedVersions => [ qw/ 7.3 7.4 8.1 8.3 / ],
        config             => { pools => { cloudflare => 'Cloudflare' } },
        @_
    }, 'Plugin::SGW_PhpVersion';
}

# --- What a version in a pool is called ------------------------------------
#
# One token stands for the pair everywhere: it is what the override puts in
# PHP_VERSION, so the vhost's socket and its pool file cannot disagree.

is(Plugin::SGW_PhpVersion::_token('8.3', 'cloudflare'), '8.3-cloudflare',
    'a pool is spelt onto the end of the version');
is(Plugin::SGW_PhpVersion::_token('8.3', ''), '8.3',
    'the default instance leaves the version as it was');
is(Plugin::SGW_PhpVersion::_token('8.3', undef), '8.3',
    'and so does no pool at all');

is(Plugin::SGW_PhpVersion::_serviceName('8.3', 'cloudflare'),
    'php8.3-fpm-cloudflare', 'a pool has a service of its own');
is(Plugin::SGW_PhpVersion::_serviceName('8.3', ''), 'php8.3-fpm',
    'the default instance keeps the service the distribution ships');

is(Plugin::SGW_PhpVersion::_unitPath('8.3', 'cloudflare'),
    '/etc/systemd/system/php8.3-fpm-cloudflare.service',
    'the unit is written where the distribution will not overwrite it');

# --- Where a pool's files live ---------------------------------------------

my $p = plugin();
is($p->_confDir('8.3-cloudflare'), '/etc/php/8.3-cloudflare',
    'a pool sits beside the version it belongs to');
is($p->_poolDir('8.3-cloudflare'), '/etc/php/8.3-cloudflare/fpm/pool.d',
    'with a pool directory of its own');
is($p->_confDir('8.3'), '/etc/php/8.3',
    'a bare version still names the directory the distribution ships');

# --- Which pool a vhost is built in ----------------------------------------

is(plugin()->_wantedPool(undef), '',
    'a vhost with no row is in the default instance');
is(plugin()->_wantedPool({ php_pool => '' }), '',
    'and so is one that has never been given a pool');
is(plugin()->_wantedPool({ php_pool => 'cloudflare' }), 'cloudflare',
    'a configured pool is honoured');

# A pool an administrator has taken out of config.php is one nothing builds or
# starts any more, so a vhost still naming it must not be sent to a directory
# that may not be there.
is(plugin()->_wantedPool({ php_pool => 'gone' }), '',
    'a pool that is no longer configured falls back to the default instance');

# The name becomes a service name and a directory name, so the backend filters
# config.php the same way the frontend does rather than trusting it.
is(
    plugin(config => { pools => { '../etc' => 'Escape' } })
        ->_wantedPool({ php_pool => '../etc' }),
    '',
    'a name that could not be a service or a directory is not a pool'
);

# disable() and uninstall() put every vhost back where i-MSCP expects it, which
# means the default version in the default instance, not one of the two.
is(plugin(forceDefault => 1)->_wantedPool({ php_pool => 'cloudflare' }), '',
    'forceDefault overrides a recorded pool as well as a recorded version');

# --- Which pool a vhost was last built in ----------------------------------

is(plugin()->_appliedPool(undef), '',
    'a vhost with no row was last built in the default instance');
is(plugin()->_appliedPool({ applied_pool => '' }), '',
    'a row that has never been built counts as the default instance');
is(plugin()->_appliedPool({ applied_pool => 'cloudflare' }), 'cloudflare',
    'a built pool is reported as it stands');

# --- Overriding and restoring the PHP configuration ------------------------

{
    my $p = plugin();
    $p->{'active'} = 1;
    $p->{'phpConfig'} = {
        PHP_VERSION           => '7.3',
        PHP_CONF_DIR_PATH     => '/etc/php/7.3',
        PHP_FPM_POOL_DIR_PATH => '/etc/php/7.3/fpm/pool.d'
    };
    my %original = %{ $p->{'phpConfig'} };

    $p->_pushVersion('8.3', 'cloudflare');
    is($p->{'phpConfig'}->{'PHP_VERSION'}, '8.3-cloudflare',
        'push moves the version and the pool together');
    is($p->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}, '/etc/php/8.3-cloudflare',
        'push moves the configuration directory to the pool');
    is($p->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'},
        '/etc/php/8.3-cloudflare/fpm/pool.d',
        'push moves the pool directory to the pool');

    $p->_popVersion();
    is_deeply($p->{'phpConfig'}, \%original, 'pop restores every value it took');

    # The default version in a pool is not the default anything: it needs the
    # override just as much as another version does.
    $p->_pushVersion('7.3', 'cloudflare');
    is($p->{'phpConfig'}->{'PHP_VERSION'}, '7.3-cloudflare',
        'the panel default version in a pool is still overridden');
    $p->_popVersion();

    # ...whereas the default version in the default instance is exactly what
    # i-MSCP was already set up to build.
    $p->_pushVersion('7.3', '');
    is_deeply($p->{'phpConfig'}, \%original,
        'the default version in the default instance touches nothing');
    $p->_popVersion();
}

# --- Building a pool -------------------------------------------------------
#
# The default instance is the distribution's to maintain, so there is nothing
# for the plugin to build and nothing for it to start.

is(plugin()->_ensurePool('8.3', ''), 0,
    'the default instance is never built');
is(plugin()->_startVersion('7.3', ''), 0,
    'and the panel default version in it is never started');

done_testing();
