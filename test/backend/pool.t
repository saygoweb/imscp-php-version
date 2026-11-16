use strict;
use warnings;
use Test::More;
use Cwd 'abs_path';
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Temp 'tempdir';

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

# --- The opcache file cache ------------------------------------------------
#
# Every vhost's FPM pool gets a php_admin_value[opcache.file_cache] of its own,
# under a root that config.php names, so that a vhost whose scripts did not make
# it into the master's full shared memory is served from disk rather than
# compiled on every request.

sub parse_root { [ Plugin::SGW_PhpVersion::_parseFileCacheRoot(@_) ] }

is_deeply(parse_root('/var/cache/php-opcache'), [ '/var/cache/php-opcache' ],
    'the shipped root is valid');
is_deeply(parse_root('/var/cache/php-opcache/'), [ '/var/cache/php-opcache' ],
    'a trailing slash is dropped');
is_deeply(parse_root(''), [ '' ], 'an empty root turns the file cache off');
is_deeply(parse_root(undef), [ '' ], 'and so does leaving it out');
for my $bad ('var/cache/php-opcache', '/var/cache/../../etc', '/var/./cache', '/', '//',
    '/var/cache/php opcache', "/var/cache/x\n", '/var/www/virtual', '/var/www/virtual/x.com', [ '/x' ]
) {
    my $r = parse_root($bad);
    (my $name = ref $bad ? 'an array' : "'$bad'") =~ s/\n/\\n/g;
    ok(!defined $r->[0] && length $r->[1], "refused as a root: $name");
}

is(plugin(config => { opcache_file_cache => '/var/cache/php-opcache' })->_checkFileCache(), 0,
    'a valid root passes the install check');
is(plugin(config => {})->_checkFileCache(), 0, 'and so does none at all');
is(plugin(config => { opcache_file_cache => 'relative' })->_checkFileCache(), 1,
    'an invalid root stops install, update and enable');

ok(Plugin::SGW_PhpVersion::_isDomainName('h0005.hosting.saygoweb.com'), 'a domain name is a domain name');
ok(Plugin::SGW_PhpVersion::_isDomainName('xn--bcher-kva.example'), 'and so is a punycode one');
ok(!Plugin::SGW_PhpVersion::_isDomainName($_), "'$_' is not")
    for '..', 'localhost', '../etc.com', 'a/b.com', '.example.com', 'example.com.', '';

{
    my $on = sub { plugin(config => { opcache_file_cache => '/var/cache/php-opcache' }, @_) };
    my %data = (DOMAIN_NAME => 'example.com', PHP_SUPPORT => 'yes', FORWARD => 'no');

    is($on->()->_fileCacheDir({ %data }), '/var/cache/php-opcache/example.com',
        'a vhost gets a directory of its own, named for it');
    is(plugin()->_fileCacheDir({ %data }), '', 'none when config.php does not ask for one');
    is($on->()->_fileCacheDir({ %data, PHP_SUPPORT => 'no' }), '', 'none for a vhost without PHP');
    is($on->()->_fileCacheDir({ %data, FORWARD => 'http://elsewhere/' }), '',
        'none for a forwarded vhost');
    is($on->(forceDefault => 1)->_fileCacheDir({ %data }), '',
        'none while disable() or uninstall() rebuild everything onto the default');
    is($on->()->_fileCacheDir({ %data, DOMAIN_NAME => '../etc' }), '',
        'none for a name that could escape the root');
}

# The line in the vhost's pool file.

my $fixtures = dirname(abs_path(__FILE__)) . '/fixtures';
my $poolConf = do { open my $fh, '<', "$fixtures/pool.conf" or die $!; local $/; <$fh> };

sub build_conf
{
    my ($p, $filename, $text) = @_;
    $p->_onAfterBuildConfFile(\$text, $filename);
    $text;
}

{
    my $LINE = 'php_admin_value[opcache.file_cache] = /var/cache/php-opcache/h0005.hosting.saygoweb.com';
    my $count = sub { scalar(() = $_[0] =~ /^php_admin_value\[opcache\.file_cache\]/mg) };

    my $default = plugin(current => {
        building => 1, version => '7.3', pool => '',
        fileCache => '/var/cache/php-opcache/h0005.hosting.saygoweb.com'
    });
    my $built = build_conf($default, 'pool.conf', $poolConf);
    like($built, qr/^\Q$LINE\E$/m, 'the default version in the default instance gets the line');
    is($count->($built), 1, 'once');
    is(build_conf($default, 'pool.conf', $built), $built, 'and building it again changes nothing');

    my $stale = $poolConf . "php_admin_value[opcache.file_cache] = /somewhere/else\n";
    my $replaced = build_conf($default, 'pool.conf', $stale);
    is($count->($replaced), 1, 'a line already there is replaced, not duplicated');
    like($replaced, qr/^\Q$LINE\E$/m, 'with the vhost\'s own directory');

    my $named = plugin(
        config  => { pools => { chat => { label => 'Chat', fpm => { 'pm.max_children' => 24 } } } },
        current => {
            building => 1, version => '8.3', pool => 'chat',
            fileCache => '/var/cache/php-opcache/h0005.hosting.saygoweb.com'
        }
    );
    my $chat = build_conf($named, 'pool.conf', $poolConf);
    like($chat, qr/^\Q$LINE\E$/m, 'a vhost in a named pool gets the line');
    like($chat, qr/^pm\.max_children = 24$/m, 'alongside the pool\'s own fpm settings');

    my $labelOnly = plugin(current => {
        building => 1, version => '8.3', pool => 'cloudflare',
        fileCache => '/var/cache/php-opcache/h0005.hosting.saygoweb.com'
    });
    like(build_conf($labelOnly, 'pool.conf', $poolConf), qr/^\Q$LINE\E$/m,
        'and so does one in a pool that is a label alone');

    my $off = plugin(current => { building => 1, version => '7.3', pool => '', fileCache => '' });
    is(build_conf($off, 'pool.conf', $poolConf), $poolConf, 'with the file cache off the file is untouched');
    is(build_conf($default, 'domain.tpl', "<VirtualHost>\n</VirtualHost>\n"), "<VirtualHost>\n</VirtualHost>\n",
        'and the vhost file is never touched by it');
    is(build_conf(plugin(current => { version => '7.3', pool => '', fileCache => '/x/y.com' }),
        'pool.conf', $poolConf), $poolConf, 'nor is anything outside a build bracket');
}

# The directories, on disk. Needs root, which these tests run as anyway.

SKIP: {
    skip 'creating directories owned by other users needs root', 1 if $>;

    my $ROOT_ = tempdir(CLEANUP => 1);
    my $root = "$ROOT_/php-opcache";
    my $id = 'a' x 32;
    my ($nobody, $nogroup) = ((getpwnam 'nobody')[2], (getgrnam 'nogroup')[2]);
    my ($daemon, $daemonGroup) = ((getpwnam 'daemon')[2], (getgrnam 'daemon')[2]);
    my $mode = sub { (stat $_[0])[2] & 07777 };
    my $owner = sub { join ':', (stat $_[0])[4, 5] };

    my $p = plugin(config => { opcache_file_cache => $root });
    my $dir = "$root/example.com";

    is($p->_ensureFileCacheDir($dir, 'nobody', 'nogroup'), 0, 'a vhost\'s directory is created');
    is($owner->($root), '0:0', 'under a root owned by root');
    is(sprintf('%o', $mode->($root)), '711', 'that nobody else can list');
    is($owner->($dir), "$nobody:$nogroup", 'owned by the vhost\'s user');
    is(sprintf('%o', $mode->($dir)), '700', 'and nobody else\'s');

    make_path("$dir/$id/var/www");
    chown $nobody, $nogroup, "$dir/$id", "$dir/$id/var", "$dir/$id/var/www";
    is($p->_ensureFileCacheDir($dir, 'nobody', 'nogroup'), 0, 'building again is fine');
    ok(-d "$dir/$id/var/www", 'and keeps what the cache holds');

    chmod 0755, $dir;
    $p->_ensureFileCacheDir($dir, 'nobody', 'nogroup');
    is(sprintf('%o', $mode->($dir)), '700', 'a mode that has drifted is put back');

    is($p->_ensureFileCacheDir($dir, 'daemon', 'daemon'), 0, 'a vhost that has changed user');
    is($owner->($dir), "$daemon:$daemonGroup", 'has its directory handed over');
    ok(!-e "$dir/$id", 'emptied first, since the old user\'s entries could not be replaced');

    is($p->_ensureFileCacheDir("$root/x.com", 'no-such-user-here', 'nogroup'), 1,
        'a user that does not exist fails the build');

    make_path("$root/junk.com/public_html");
    is($p->_ensureFileCacheDir("$root/junk.com", 'nobody', 'nogroup'), 1,
        'a directory holding anything but a file cache fails the build');
    is($owner->("$root/junk.com"), '0:0', 'and is not handed over');

    # Changing version empties it.
    make_path("$dir/$id/var");
    my $db = bless {}, 'FakeDb';
    my $row = { php_version_id => 1, applied_version => '7.4', applied_pool => '', status => 'ok' };
    $p->{'db'} = $db;
    $p->{'current'} = { row => $row, version => '7.4', pool => '', building => 1, fileCache => $dir };
    is($p->_onAfterBuildDmn({ DOMAIN_NAME => 'example.com' }), 0, 'a rebuild on the same version');
    ok(-d "$dir/$id", 'leaves the cache alone');

    $p->{'current'} = { row => $row, version => '8.3', pool => '', building => 1, fileCache => $dir };
    is($p->_onAfterBuildDmn({ DOMAIN_NAME => 'example.com' }), 0, 'a rebuild onto another version');
    ok(!-e "$dir/$id", 'empties the cache');
    ok(-d $dir, 'but keeps the directory');

    make_path("$root/junk.com/$id");
    is($p->_emptyFileCacheDir("$root/junk.com"), 1, 'a directory that is not a file cache is not emptied');
    ok(-d "$root/junk.com/public_html", 'and keeps what it holds');

    # Deleting the vhost removes it.
    make_path("$dir/$id/var");
    $p->{'current'} = { row => undef, version => '7.3', pool => '' };
    is($p->_onAfterDelDmn({ DOMAIN_NAME => 'example.com' }), 0, 'deleting a vhost');
    ok(!-e $dir, 'removes its file cache');

    $p->{'current'} = { row => undef, version => '7.3', pool => '' };
    $p->_onAfterDelDmn({ DOMAIN_NAME => 'junk.com' });
    ok(-d "$root/junk.com/public_html", 'but not a directory that is not a file cache');

    my $elsewhere = "$ROOT_/elsewhere";
    make_path("$elsewhere/$id");
    symlink $elsewhere, "$root/link.com" or die $!;
    $p->{'current'} = { row => undef, version => '7.3', pool => '' };
    $p->_onAfterDelDmn({ DOMAIN_NAME => 'link.com' });
    ok(-d "$elsewhere/$id", 'nor anything a symlink under the root points at');
    unlink "$root/link.com";
}

done_testing();

package FakeDb;
sub doQuery { +{} }
