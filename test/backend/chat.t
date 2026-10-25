use strict;
use warnings;
use Test::More;
use Cwd 'abs_path';
use File::Basename 'dirname';

# A pool may be more than a label: it can carry settings for the vhost's
# FastCGI proxy, for the vhost's FPM pool file and for the pool's php.ini -- the
# 'chat' pool that a streaming (Server-Sent Events) application runs in is the
# one shipped. What is unit tested here is the parsing and validation of those
# definitions, and the text transforms applied to i-MSCP's rendered files. The
# fixtures are files i-MSCP actually rendered, taken from the development
# container.
#
# Run as root, as version.t is:
#
#   cd test/backend && sudo perl all.t
use lib '/var/www/imscp/engine/PerlLib';

require_ok(abs_path('../../backend/SGW_PhpVersion.pm'))
    or BAIL_OUT('cannot load the plugin');

my $fixtures = dirname(abs_path(__FILE__)) . '/fixtures';

sub fixture
{
    my ($name) = @_;
    open my $fh, '<', "$fixtures/$name" or die "$name: $!";
    local $/;
    <$fh>;
}

my %CHAT = (
    label   => 'Chat (streaming)',
    proxy   => { flushpackets => 'on', timeout => 600 },
    fpm     => {
        'pm'                        => 'dynamic',
        'pm.max_children'           => 24,
        'pm.start_servers'          => 4,
        'pm.min_spare_servers'      => 2,
        'pm.max_spare_servers'      => 6,
        'request_terminate_timeout' => '300s'
    },
    php_ini => { output_buffering => '0', 'zlib.output_compression' => 'Off' }
);

sub plugin
{
    bless {
        defaultVersion     => '7.3',
        phpConfig          => { PHP_CONF_DIR_PATH => '/etc/php/7.3' },
        _installedVersions => [ qw/ 7.3 7.4 8.1 8.3 / ],
        config             => { pools => { cloudflare => 'Cloudflare', chat => { %CHAT } } },
        @_
    }, 'Plugin::SGW_PhpVersion';
}

sub pools_with
{
    my ($definition) = @_;
    plugin(config => { pools => { cloudflare => 'Cloudflare', bad => $definition } })->_poolDefinitions();
}

# --- Parsing what config.php says ------------------------------------------

{
    my $parsed = plugin()->_poolDefinitions();
    is_deeply($parsed->{'errors'}, [], 'the shipped definitions are valid');
    is_deeply([ sort keys %{ $parsed->{'pools'} } ], [ qw/ chat cloudflare / ],
        'a label and an array are both pools');
    is_deeply($parsed->{'pools'}->{'cloudflare'},
        { label => 'Cloudflare', proxy => {}, fpm => {}, php_ini => {} },
        'a label alone is a pool with nothing to tune, exactly as before');
    is($parsed->{'pools'}->{'chat'}->{'label'}, 'Chat (streaming)', 'an array carries its label');
    is($parsed->{'pools'}->{'chat'}->{'proxy'}->{'flushpackets'}, 'on', 'and its proxy settings');
    is($parsed->{'pools'}->{'chat'}->{'fpm'}->{'pm.max_children'}, 24, 'and its fpm settings');
    is($parsed->{'pools'}->{'chat'}->{'php_ini'}->{'output_buffering'}, '0', 'and its php_ini settings');
}

is_deeply(
    pools_with({ label => 'Bare', proxy => [], fpm => [] })->{'pools'}->{'bad'},
    { label => 'Bare', proxy => {}, fpm => {}, php_ini => {} },
    "an empty PHP array() -- a JSON list by the time it gets here -- is no settings"
);

# Every refusal must name the pool and the key, so that the administrator can
# find what to fix from the message alone.
for my $case (
    [ { proxy => { timeout => 600 } },                   qr/'label' is required/,             'a label is required' ],
    [ { label => '' },                                   qr/'label' must not be empty/,       'and must not be empty' ],
    [ { label => "Two\nlines" },                         qr/'label' must not contain a line/, 'and must be one line' ],
    [ "Two\nlines",                                      qr/the label must not contain a line/, 'as must a label alone' ],
    [ [ 'Chat' ],                                        qr/must be a label or an array/,     'a list is not a definition' ],
    [ { label => 'X', 'php.ini' => {} },                 qr/'php\.ini' is not a pool setting/, 'an unknown setting is refused, not ignored' ],
    [ { label => 'X', proxy => 'on' },                   qr/'proxy' must be an array/,        'settings must be an array' ],
    [ { label => 'X', proxy => { retry => 0 } },         qr/proxy key 'retry' is not allowed/, 'only the allowed proxy keys' ],
    [ { label => 'X', proxy => { flushpackets => 'yes' } }, qr/proxy key 'flushpackets' cannot be 'yes'/, 'flushpackets is on, off or auto' ],
    [ { label => 'X', proxy => { timeout => '10m' } },   qr/proxy key 'timeout' cannot be '10m'/, 'a proxy timeout is whole seconds' ],
    [ { label => 'X', proxy => { flushwait => -1 } },    qr/proxy key 'flushwait' cannot be '-1'/, 'flushwait is whole milliseconds' ],
    [ { label => 'X', fpm => { 'php_admin_value[open_basedir]' => '/' } },
        qr/fpm key 'php_admin_value\[open_basedir\]' is not allowed/, 'no php_admin_value: i-MSCP\'s limits stay' ],
    [ { label => 'X', fpm => { 'php_value[display_errors]' => 'on' } },
        qr/fpm key 'php_value\[display_errors\]' is not allowed/, 'and no php_value' ],
    [ { label => 'X', fpm => { listen => '/tmp/x.sock' } }, qr/fpm key 'listen' is not allowed/, 'nor anything else outside the list' ],
    [ { label => 'X', fpm => { pm => 'lazy' } },         qr/fpm key 'pm' cannot be 'lazy'/,   'pm is a process manager FPM knows' ],
    [ { label => 'X', fpm => { 'pm.max_children' => 'lots' } }, qr/fpm key 'pm\.max_children' cannot be 'lots'/, 'counts are whole numbers' ],
    [ { label => 'X', fpm => { 'request_terminate_timeout' => '5 min' } },
        qr/fpm key 'request_terminate_timeout' cannot be '5 min'/, 'timeouts carry an FPM unit or none' ],
    [ { label => 'X', fpm => { 'pm.max_children' => "24\nuser = root" } },
        qr/fpm key 'pm\.max_children' must not contain a line break/, 'a value cannot smuggle in a second directive' ],
    [ { label => 'X', php_ini => { 'a b' => 1 } },       qr/php_ini key 'a b' is not an ini directive name/, 'php_ini keys are directive names' ],
    [ { label => 'X', php_ini => { output_buffering => [ 0 ] } },
        qr/php_ini key 'output_buffering' must be a string or a number/, 'php_ini values are scalars' ],
    [ { label => 'X', php_ini => { output_buffering => "0\nopen_basedir = /" } },
        qr/php_ini key 'output_buffering' must not contain a line break/, 'php_ini values are one line' ],
) {
    my ($definition, $message, $name) = @{ $case };
    my $parsed = pools_with($definition);

    ok(!exists $parsed->{'pools'}->{'bad'}, "$name: the pool is left out");
    ok(exists $parsed->{'pools'}->{'cloudflare'}, "$name: the others are not");
    like($parsed->{'errors'}->[0] // '', qr/^The 'bad' pool .*: /, "$name: the message names the pool");
    like($parsed->{'errors'}->[0] // '', $message, "$name: and says what is wrong");
}

# A vhost recorded in a pool that has since been made invalid is built in the
# default instance with stock files, rather than in the pool with half of what
# was asked for.
is(
    plugin(config => { pools => { chat => { label => 'Chat', fpm => { listen => 'x' } } } })
        ->_wantedPool({ php_pool => 'chat' }),
    '',
    'an invalid pool falls back to the default instance'
);
is(plugin()->_wantedPool({ php_pool => 'chat' }), 'chat', 'a valid array pool is honoured');

{
    # error() is iMSCP::Debug's, imported into the plugin's package.
    my @logged;
    no warnings qw/ redefine once /;
    local *Plugin::SGW_PhpVersion::error = sub { push @logged, @_ };

    is(plugin()->_checkPools(), 0, 'install, update and enable accept valid pools');
    is(scalar @logged, 0, 'and say nothing about them');

    my $p = plugin(config => { pools => { chat => { label => 'Chat', fpm => { listen => 'x' } } } });
    is($p->_checkPools(), 1, 'but refuse an invalid one');
    like($logged[0] // '', qr/'chat' pool .*fpm key 'listen' is not allowed/, 'naming the pool and the key');
}

# --- The vhost's FastCGI proxy ---------------------------------------------

my $vhost = fixture('vhost.conf');
my $vhostSsl = fixture('vhost_ssl.conf');
my $proxy = { flushpackets => 'on', timeout => 600 };

{
    my $tuned = Plugin::SGW_PhpVersion::_tuneVhost($vhost, $proxy);

    like($tuned, qr/^        ProxySet connectiontimeout=5 timeout=600 flushpackets=on$/m,
        'a key on the line is replaced in place and a new one added at the end');

    (my $expected = $vhost) =~ s/ProxySet connectiontimeout=5 timeout=7200/ProxySet connectiontimeout=5 timeout=600 flushpackets=on/;
    is($tuned, $expected, 'nothing else in the vhost changes');

    is(Plugin::SGW_PhpVersion::_tuneVhost($tuned, $proxy), $tuned, 'applying the same settings twice changes nothing more');

    (my $expectedSsl = $vhostSsl) =~ s/ProxySet connectiontimeout=5 timeout=7200/ProxySet connectiontimeout=5 timeout=600 flushpackets=on/;
    is(Plugin::SGW_PhpVersion::_tuneVhost($vhostSsl, $proxy), $expectedSsl, 'the SSL vhost is tuned the same way');

    like(Plugin::SGW_PhpVersion::_tuneVhost($vhost, { flushwait => 10 }),
        qr/^        ProxySet connectiontimeout=5 timeout=7200 flushwait=10$/m, 'flushwait is added too');
}

{
    (my $noSet = $vhost) =~ s/^\s*ProxySet[^\n]*\n//m;
    like(Plugin::SGW_PhpVersion::_tuneVhost($noSet, $proxy),
        qr{retry=0>\n        ProxySet flushpackets=on timeout=600\n    </Proxy>},
        'a block with no ProxySet line is given one');
}

{
    my $forward = <<'VHOST';
<VirtualHost *:80>
    ServerName fwd.test
    ProxyPassMatch "^/((?!(?:errors|\.well-known)/acme-challenge/).*)" "http://elsewhere/$1" retry=30 timeout=7200
</VirtualHost>
VHOST
    is(Plugin::SGW_PhpVersion::_tuneVhost($forward, $proxy), $forward,
        'a forwarding vhost has no FastCGI proxy, and comes back unchanged');

    my $other = <<'VHOST';
<VirtualHost *:80>
    <Proxy "balancer://cluster">
        ProxySet lbmethod=byrequests
    </Proxy>
</VirtualHost>
VHOST
    is(Plugin::SGW_PhpVersion::_tuneVhost($other, $proxy), $other,
        'a <Proxy> block that is not the FastCGI one is left alone');
}

# --- The vhost's FPM pool file ---------------------------------------------

my $poolConf = fixture('pool.conf');

{
    my $tuned = Plugin::SGW_PhpVersion::_tuneFpmPool($poolConf, $CHAT{'fpm'}, '8.3-chat');

    like($tuned, qr/^pm = dynamic$/m, 'pm is replaced');
    like($tuned, qr/^pm\.max_children = 24$/m, 'pm.max_children is replaced');
    unlike($tuned, qr/^pm\.max_children = 6$/m, 'and the stock value is gone');
    like($tuned, qr/^pm\.start_servers = 4$/m, 'pm.start_servers is replaced');
    like($tuned, qr/^request_terminate_timeout = 300s$/m, 'an absent directive is added');
    is(scalar(() = $tuned =~ /^pm\.max_children =/mg), 1, 'each directive is set exactly once');

    my @kept = grep { !/^(?:pm|pm\.max_children|pm\.start_servers|pm\.min_spare_servers|pm\.max_spare_servers) =/ } split /\n/, $poolConf;
    my %tunedLines = map { $_ => 1 } split /\n/, $tuned;
    is_deeply([ grep { !$tunedLines{$_} } @kept ], [], 'every line not being set is still there, unchanged');

    is(Plugin::SGW_PhpVersion::_tuneFpmPool($tuned, $CHAT{'fpm'}, '8.3-chat'), $tuned,
        'applying the same settings twice changes nothing more');

    unlike($tuned, qr/^slowlog/m, 'no slow log is added unless one is needed');
}

{
    my $tuned = Plugin::SGW_PhpVersion::_tuneFpmPool($poolConf, { request_slowlog_timeout => '5s' }, '8.3-chat');
    like($tuned, qr/^request_slowlog_timeout = 5s$/m, 'request_slowlog_timeout is set');
    like($tuned, qr/^slowlog = \/var\/log\/php8\.3-chat-fpm\.\$pool\.slow\.log$/m,
        'with the slow log FPM will not start that pool without');

    unlike(Plugin::SGW_PhpVersion::_tuneFpmPool($poolConf, { request_slowlog_timeout => '0' }, '8.3-chat'),
        qr/^slowlog/m, 'a slowlog timeout of 0 is off, and needs none');
}

{
    my $text = "; head\n[one]\na = 1\n;b = 2\n\n[two]\nc = 3\n";
    is(Plugin::SGW_PhpVersion::_setDirectives($text, { b => 5 }),
        "; head\n[one]\na = 1\n;b = 2\nb = 5\n\n[two]\nc = 3\n",
        'a commented-out directive is added at the end of the first section');
    is(Plugin::SGW_PhpVersion::_setDirectives("[one]\na = 1", { b => 2 }), "[one]\na = 1\nb = 2\n",
        'a file with one section and no final newline gets the directive at the end');
    is(Plugin::SGW_PhpVersion::_setDirectives($text, { c => 4 }), "; head\n[one]\na = 1\n;b = 2\n\n[two]\nc = 4\n",
        'an active directive is replaced where it is, in whichever section');
}

# --- The pool's php.ini ----------------------------------------------------

{
    my $ini = fixture('php.ini');
    my $tuned = Plugin::SGW_PhpVersion::_setDirectives($ini, $CHAT{'php_ini'});

    like($tuned, qr/^output_buffering = 0$/m, 'output_buffering is seeded');
    like($tuned, qr/^zlib\.output_compression = Off$/m, 'zlib.output_compression is seeded');
    unlike($tuned, qr/^output_buffering = 4096$/m, 'and the stock value is gone');
    is(Plugin::SGW_PhpVersion::_setDirectives($tuned, $CHAT{'php_ini'}), $tuned, 'seeding twice changes nothing more');

    my $added = Plugin::SGW_PhpVersion::_setDirectives($ini, { 'zend.exception_ignore_args' => 'On' });
    like($added, qr/^zend\.exception_ignore_args = On\n(?:\n)*\[Date\]$/m, 'an absent one goes at the end of [PHP]');
}

# --- Which files are touched -----------------------------------------------
#
# Driven through the listener, with the build bracket's context as
# _onBeforeBuildDmn() would have left it.

sub build
{
    my ($p, $pool, $filename, $text) = @_;

    $p->{'current'} = { row => undef, version => '8.3', pool => $pool, building => 1 };
    $p->_onAfterBuildConfFile(\$text, $filename, {}, {});
    delete $p->{'current'};
    $text;
}

{
    my $p = plugin();

    like(build($p, 'chat', 'domain.tpl', $vhost), qr/flushpackets=on/, 'a vhost in chat is tuned');
    like(build($p, 'chat', 'pool.conf', $poolConf), qr/^pm\.max_children = 24$/m, 'and so is its pool file');

    is(build($p, '', 'domain.tpl', $vhost), $vhost, 'a vhost in the default instance is byte-identical');
    is(build($p, '', 'pool.conf', $poolConf), $poolConf, 'and so is its pool file');
    is(build($p, 'cloudflare', 'domain.tpl', $vhost), $vhost, 'a vhost in a label-only pool is byte-identical');
    is(build($p, 'cloudflare', 'pool.conf', $poolConf), $poolConf, 'and so is its pool file');
    is(build($p, 'chat', 'custom.conf.tpl', $vhost), $vhost, 'no other file is touched, even in chat');

    my $text = $vhost;
    $p->_onAfterBuildConfFile(\$text, 'domain.tpl', {}, {});
    is($text, $vhost, 'nor anything built outside a vhost\'s build bracket');

    $p->{'current'} = { row => undef, version => '8.3', pool => 'chat' };
    $p->_onAfterBuildConfFile(\$text, 'domain.tpl', {}, {});
    is($text, $vhost, 'nor anything while a vhost is being deleted');
    delete $p->{'current'};

    my $invalid = plugin(config => { pools => { chat => { label => 'Chat', proxy => { timeout => 'x' } } } });
    is(build($invalid, 'chat', 'domain.tpl', $vhost), $vhost, 'an invalid pool tunes nothing');
}

done_testing();
