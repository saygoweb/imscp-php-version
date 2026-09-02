use strict;
use warnings;
use Test::More;
use Cwd 'abs_path';

# The parts worth unit testing are the ones that decide which version a domain
# is built on and where that version's files live. Everything downstream of
# that is i-MSCP's own build, which test/switch-matrix.sh checks against a live
# panel.
#
# Run as root: the module pulls in iMSCP::* from the engine, whose directory
# the panel keeps unreadable to other users.
#
#   cd test/backend && sudo perl all.t
use lib '/var/www/imscp/engine/PerlLib';

# The file is backend/SGW_PhpVersion.pm but the package is
# Plugin::SGW_PhpVersion, so it is loaded by path the way i-MSCP loads it.
require_ok(abs_path('../../backend/SGW_PhpVersion.pm'))
    or BAIL_OUT('cannot load the plugin');

# These methods touch no state beyond the fields set here, so they can be
# called on a hand-built instance rather than booting the whole i-MSCP backend
# and its database.
sub plugin
{
    bless {
        defaultVersion      => '7.3',
        phpConfig           => { PHP_CONF_DIR_PATH => '/etc/php/7.3' },
        _installedVersions  => [ qw/ 7.3 7.4 8.1 8.3 / ],
        @_
    }, 'Plugin::SGW_PhpVersion';
}

# --- Where a version's files live ------------------------------------------
#
# Derived from the directory i-MSCP recorded for its own version, so that a
# non-Debian layout would move both together rather than only one.

my $p = plugin();
is($p->_confDir('8.3'), '/etc/php/8.3', 'conf dir follows the recorded layout');
is($p->_poolDir('8.3'), '/etc/php/8.3/fpm/pool.d', 'pool dir hangs off the conf dir');
is($p->_confDir('7.3'), '/etc/php/7.3', 'the default version is no special case');

# --- Which version a domain is built on ------------------------------------

is(plugin()->_wantedVersion(undef), '7.3',
    'a vhost with no row follows the panel default');
is(plugin()->_wantedVersion({ php_version => '' }), '7.3',
    'an empty choice means the panel default, not an empty version');
is(plugin()->_wantedVersion({ php_version => '8.1' }), '8.1',
    'a recorded choice is honoured');

# A customer pinned to a version an administrator has since removed must not
# send the build into a pool directory that is not there.
is(plugin()->_wantedVersion({ php_version => '8.9' }), '7.3',
    'a version that is no longer installed falls back to the default');

# disable() and uninstall() put every domain back on the default without
# having to rewrite any rows first.
is(plugin(forceDefault => 1)->_wantedVersion({ php_version => '8.1' }), '7.3',
    'forceDefault overrides a recorded choice');

# --- Which version a domain was last built on ------------------------------
#
# This is what tells the sweep which pool.d still holds a stale file.

is(plugin()->_appliedVersion(undef), '7.3',
    'a vhost with no row was last built on the default');
is(plugin()->_appliedVersion({ applied_version => '' }), '7.3',
    'a row that has never been built counts as the default');
is(plugin()->_appliedVersion({ applied_version => '8.3' }), '8.3',
    'a built version is reported as it stands');

# --- Overriding and restoring the PHP configuration ------------------------
#
# The whole plugin rests on this bracket: i-MSCP reads PHP_VERSION and
# PHP_FPM_POOL_DIR_PATH once per domain, so changing them for the duration of
# one build moves the vhost and its pool together.

{
    my $p = plugin();
    $p->{'active'} = 1;
    $p->{'phpConfig'} = {
        PHP_VERSION           => '7.3',
        PHP_CONF_DIR_PATH     => '/etc/php/7.3',
        PHP_FPM_POOL_DIR_PATH => '/etc/php/7.3/fpm/pool.d'
    };
    my %original = %{ $p->{'phpConfig'} };

    $p->_pushVersion('8.1');
    is($p->{'phpConfig'}->{'PHP_VERSION'}, '8.1', 'push moves the version');
    is($p->{'phpConfig'}->{'PHP_CONF_DIR_PATH'}, '/etc/php/8.1',
        'push moves the configuration directory with it');
    is($p->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'}, '/etc/php/8.1/fpm/pool.d',
        'push moves the pool directory with it');

    $p->_popVersion();
    is_deeply($p->{'phpConfig'}, \%original, 'pop restores every value it took');

    # A build that fails returns before its 'after' event fires, leaving the
    # override in place. The next push has to undo it, or one failed domain
    # would move every domain built after it.
    $p->_pushVersion('8.3');
    $p->_pushVersion('7.4');
    is($p->{'phpConfig'}->{'PHP_VERSION'}, '7.4',
        'a push after an unclosed bracket still lands on the right version');
    $p->_popVersion();
    is_deeply($p->{'phpConfig'}, \%original,
        'and one pop is still enough to get back to where i-MSCP left off');

    # Popping when nothing is outstanding must not wipe the configuration.
    $p->_popVersion();
    is_deeply($p->{'phpConfig'}, \%original, 'a spare pop changes nothing');

    # The default version is left exactly as i-MSCP set it rather than being
    # recomputed, so a non-standard layout survives the round trip.
    $p->_pushVersion('7.3');
    is_deeply($p->{'phpConfig'}, \%original,
        'pushing the default version touches nothing');
    $p->_popVersion();
}

# A plugin that stood down at init because the httpd server is not PHP-FPM must
# not touch the configuration at all.
{
    my $p = plugin();
    $p->{'phpConfig'} = { PHP_VERSION => '7.3' };
    $p->_pushVersion('8.1');
    is($p->{'phpConfig'}->{'PHP_VERSION'}, '7.3',
        'an inactive plugin leaves the version alone');
}

# --- Ordering versions -----------------------------------------------------
#
# Sorted as numbers, so that a future 8.10 does not sort between 8.1 and 8.2.

is_deeply(
    [ sort { Plugin::SGW_PhpVersion::_compareVersions($a, $b) }
        qw/ 8.2 7.4 8.10 5.6 8.1 10.0 / ],
    [ qw/ 5.6 7.4 8.1 8.2 8.10 10.0 / ],
    'versions order numerically, not as strings'
);

done_testing();
