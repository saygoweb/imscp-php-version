use strict;
use warnings;
use Test::More;
use Cwd 'abs_path';
use File::Basename 'dirname';
use File::Path 'make_path';
use File::Temp 'tempdir';

# The weekly prune of the per-vhost opcache file cache: what the script picks to
# delete, and the timer the plugin installs and removes to run it.
#
# Run as root, as version.t is:
#
#   cd test/backend && sudo perl all.t
use lib '/var/www/imscp/engine/PerlLib';

my $backend = dirname(dirname(dirname(abs_path(__FILE__)))) . '/backend';

require_ok("$backend/opcache-prune.pl") or BAIL_OUT('cannot load the prune script');
require_ok("$backend/SGW_PhpVersion.pm") or BAIL_OUT('cannot load the plugin');

my $DAY = 86400;
my $NOW = time;
my $ID = 'a' x 32;
my $OLD_ID = 'b' x 32;

sub spit
{
    my ($path, $content, $age, $uid, $gid) = @_;
    make_path(dirname($path));
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $content;
    close $fh;
    utime $NOW - $age, $NOW - $age, $path;
    chown $uid, $gid, $path if defined $uid;
}

sub chown_tree
{
    my ($uid, $gid, @dirs) = @_;
    system('chown', '-R', "$uid:$gid", @dirs) == 0 or die 'chown failed';
}

# --- Selection -------------------------------------------------------------

SKIP: {
    skip 'pruning as each directory\'s owner needs root', 1 if $>;

    my ($uid, $gid) = ((getpwnam 'nobody')[2], (getgrnam 'nogroup')[2]);
    my $base = tempdir(CLEANUP => 1);
    chmod 0711, $base;    # as /var/cache is: the owners must be able to reach their own
    my $root = "$base/php-opcache";
    make_path($root);
    chmod 0711, $root;

    # example.com: one current system id and one a PHP upgrade left behind.
    my $d = "$root/example.com";
    my $cur = "$d/$ID/var/www/virtual/example.com/htdocs";
    spit("$cur/old.php.bin", 'x' x 1000, 40 * $DAY);
    spit("$cur/recent.php.bin", 'x' x 500, 2 * $DAY);
    spit("$cur/old-but-not-bin.txt", 'x' x 10, 40 * $DAY);
    spit("$d/$OLD_ID/var/www/virtual/example.com/htdocs/index.php.bin", 'x' x 2000, 90 * $DAY);
    make_path("$d/$ID/var/www/virtual/example.com/empty-already");

    # Outside the root, reached through a symlink planted in the cache.
    my $outside = "$base/outside";
    spit("$outside/victim.bin", 'v', 365 * $DAY);
    symlink $outside, "$cur/link-to-outside" or die $!;
    symlink "$outside/victim.bin", "$cur/linked.php.bin" or die $!;
    chown_tree($uid, $gid, $d);
    chmod 0700, $d;

    # A domain directory holding something opcache did not write.
    spit("$root/foreign.com/$ID/x.php.bin", 'f', 40 * $DAY);
    spit("$root/foreign.com/public_html/index.php", 'f', 40 * $DAY);
    chown_tree($uid, $gid, "$root/foreign.com");

    # A domain directory that is a symlink to somewhere else.
    spit("$base/elsewhere/$ID/y.php.bin", 'e', 40 * $DAY);
    chown_tree($uid, $gid, "$base/elsewhere");
    symlink "$base/elsewhere", "$root/symlinked.com" or die $!;

    # Root's own directory, and a name the plugin would never have made.
    spit("$root/rootowned.com/$ID/z.php.bin", 'r', 40 * $DAY);
    spit("$root/not-a-domain/$ID/w.php.bin", 'n', 40 * $DAY);

    my $dry = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW, dry_run => 1 });
    is($dry->{'files'}, 2, 'a dry run counts the two old .bin files');
    is($dry->{'bytes'}, 3000, 'and their size');
    ok(-f "$cur/old.php.bin", 'but deletes nothing');

    my $t = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW });
    is($t->{'domains'}, 1, 'one domain directory is pruned');
    is($t->{'skipped'}, 3, 'the foreign, symlinked and root-owned ones are skipped');
    is($t->{'files'}, 2, 'two files go');
    is($t->{'bytes'}, 3000, 'freeing their size');

    ok(!-e "$cur/old.php.bin", 'a .bin not read for 40 days is deleted');
    ok(-f "$cur/recent.php.bin", 'one read 2 days ago stays');
    ok(-f "$cur/old-but-not-bin.txt", 'a file that is not a .bin stays, however old');
    ok(!-e "$d/$OLD_ID", 'a system id nothing reads any more ages out entirely');
    ok(!-e "$d/$ID/var/www/virtual/example.com/empty-already", 'an empty directory goes');
    ok(-d $d, 'the domain directory itself stays');
    ok(-f "$outside/victim.bin", 'nothing is followed through a symlinked directory');
    ok(-l "$cur/linked.php.bin", 'and a symlink named .bin is not a .bin');
    ok(-f "$root/foreign.com/$ID/x.php.bin", 'a domain directory with foreign entries is left whole');
    ok(-f "$base/elsewhere/$ID/y.php.bin", 'a symlinked domain directory is not followed');
    ok(-f "$root/rootowned.com/$ID/z.php.bin", 'a root-owned domain directory is not pruned');
    ok(-f "$root/not-a-domain/$ID/w.php.bin", 'nor is a directory that is not named for a domain');

    is_deeply(SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW }),
        { domains => 1, skipped => 3, files => 0, bytes => 0, dirs => 0, orphans => 0 }, 'a second run finds nothing more');

    unlink "$cur/old-but-not-bin.txt", "$cur/link-to-outside", "$cur/linked.php.bin";
    my $later = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 1, now => $NOW });
    is($later->{'files'}, 1, 'a shorter age takes the recent file too');
    ok(!-e "$d/$ID", 'and the system id it was the last thing in');

    # The child runs as the directory's owner: a directory the owner cannot
    # write keeps its files even though root could delete them.
    spit("$d/$ID/locked/old.php.bin", 'l', 40 * $DAY);
    chown_tree($uid, $gid, "$d/$ID");
    chown 0, 0, "$d/$ID/locked";
    chmod 0755, "$d/$ID/locked";
    SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW });
    ok(-f "$d/$ID/locked/old.php.bin", 'pruning runs as the directory\'s owner, not as root');

    # Directories no pool file points at any more.
    my $pools = "$base/php";
    make_path("$pools/8.3/fpm/pool.d", "$pools/7.4/fpm/pool.d");
    my $orph = "$root/orphan.com";
    spit("$orph/$ID/var/x.php.bin", 'o' x 100, 0);
    spit("$orph/$OLD_ID/y.php.bin", 'o' x 50, 90 * $DAY);
    spit("$root/fresh.com/$ID/z.php.bin", 'f' x 10, 0);
    chown_tree($uid, $gid, $orph, "$root/fresh.com");
    my $glob = "$pools/*/fpm/pool.d/*.conf";

    my $none = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW, pool_glob => $glob });
    is($none->{'orphans'}, 0, 'with no pool file naming any directory, nothing is taken for orphaned');
    ok(-d $orph, 'so a glob that matches nothing cannot empty the cache');

    # That run pruned the old system id, which made the directory new again.
    utime $NOW - 3 * $DAY, $NOW - 3 * $DAY, $orph;

    spit("$pools/8.3/fpm/pool.d/example.com.conf",
        "[example.com]\nphp_admin_value[opcache.file_cache] = $root/example.com\n", 0);
    spit("$pools/7.4/fpm/pool.d/orphan.com.conf", "[orphan.com]\nuser = x\n", 0);

    my $dry2 = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW, pool_glob => $glob, dry_run => 1 });
    is($dry2->{'orphans'}, 1, 'a dry run counts the orphan');
    ok(-f "$orph/$ID/var/x.php.bin", 'and removes nothing');

    my $o = SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 30, now => $NOW, pool_glob => $glob });
    is($o->{'orphans'}, 1, 'one orphaned domain directory goes');
    ok(!-e $orph, 'with everything in it, however recently read');
    ok(-d "$root/fresh.com", 'but not one made in the last day, which a build may be about to name');
    ok(-d "$root/example.com", 'nor one a pool file names');
    ok(-f "$root/foreign.com/public_html/index.php", 'and foreign directories are still left whole');

    is_deeply(SGW_PhpVersion::OpcachePrune::referencedDomains($root, $root, $glob), { 'example.com' => 1 },
        'a pool file\'s opcache.file_cache line is what counts as naming a directory');

    eval { SGW_PhpVersion::OpcachePrune::prune('relative', {}) };
    like($@, qr/absolute/, 'a relative root is refused');
    eval { SGW_PhpVersion::OpcachePrune::prune("$root/symlinked.com", {}) };
    like($@, qr/symlink/, 'a symlinked root is refused');
    eval { SGW_PhpVersion::OpcachePrune::prune($root, { max_age_days => 0 }) };
    like($@, qr/max age/, 'and so is an age of 0');

    my $out = `perl $backend/opcache-prune.pl --dry-run --max-age-days 30 $root`;
    is($? >> 8, 0, 'the script runs from the command line');
    like($out, qr/^opcache-prune \(dry run\): \Q$root\E, older than 30 days: \d+ domains, 3 skipped, \d+ files, \d+ bytes.*orphaned domain directories would go$/,
        'and says what it found on one line');
}

# --- The timer -------------------------------------------------------------

package FakeService {
    sub new { bless { calls => [] }, shift }
    sub isSystemd { 1 }
}

SKIP: {
    skip 'writing root-owned unit files needs root', 1 if $>;

    my $units = tempdir(CLEANUP => 1);
    my $calls = [];
    my $cache = tempdir(CLEANUP => 1) . '/php-opcache';

    my $plugin = sub {
        my ($config) = @_;
        bless {
            defaultVersion => '7.3',
            phpConfig      => { PHP_CONF_DIR_PATH => '/etc/php/7.3' },
            config         => $config,
            unitDir        => $units,
            service        => FakeService->new,
            systemctl      => sub { push @{ $calls }, join ' ', @_ },
            pruneScript    => '/plugins/SGW_PhpVersion/backend/opcache-prune.pl'
        }, 'Plugin::SGW_PhpVersion';
    };

    my $p = $plugin->({ opcache_file_cache => $cache, opcache_file_cache_max_age_days => 45 });
    is($p->_ensurePruneTimer(), 0, 'the timer is installed');
    ok(-f "$units/sgw-php-opcache-prune.service", 'with its service');
    ok(-f "$units/sgw-php-opcache-prune.timer", 'and its timer');
    ok(-d $cache, 'and the root it is allowed to write, which systemd needs to exist');
    is_deeply($calls, [ 'daemon-reload', 'enable --now sgw-php-opcache-prune.timer' ],
        'systemd is told, and the timer enabled and started');

    my $service = do { local (@ARGV, $/) = "$units/sgw-php-opcache-prune.service"; <> };
    like($service, qr{^ExecStart=/usr/bin/perl /plugins/SGW_PhpVersion/backend/opcache-prune\.pl --max-age-days 45 \Q$cache\E$}m,
        'the service runs the script on the configured root and age');
    like($service, qr/^ProtectSystem=strict$/m, 'sandboxed read-only');
    like($service, qr/^ReadWritePaths=\Q$cache\E$/m, 'except for the root');
    my $timer = do { local (@ARGV, $/) = "$units/sgw-php-opcache-prune.timer"; <> };
    like($timer, qr/^OnCalendar=weekly$/m, 'weekly');
    like($timer, qr/^Persistent=true$/m, 'catching up on a run missed while the machine was down');

    is($plugin->({ opcache_file_cache => $cache })->_pruneMaxAgeDays(), 30, 'the age defaults to 30 days');
    is($plugin->({ opcache_file_cache => $cache, opcache_file_cache_max_age_days => $_ })->_pruneMaxAgeDays(), undef,
        "an age of '$_' is invalid") for 0, -1, '30d', 3651, '1e3';
    is($plugin->({ opcache_file_cache => $cache, opcache_file_cache_max_age_days => 'x' })->_checkFileCache(), 1,
        'and stops install, update and enable');

    @{ $calls } = ();
    my $off = $plugin->({ opcache_file_cache => '' });
    is($off->_ensurePruneTimer(), 0, 'with the file cache off');
    ok(!-e "$units/sgw-php-opcache-prune.service" && !-e "$units/sgw-php-opcache-prune.timer",
        'the timer is removed');
    is_deeply($calls, [ 'disable --now sgw-php-opcache-prune.timer', 'daemon-reload' ],
        'after being stopped and disabled');

    $p->_ensurePruneTimer();
    my $q = $plugin->({ opcache_file_cache => $cache });
    is($q->_removePruneTimer(), 0, 'disable and uninstall remove it');
    ok(!-e "$units/sgw-php-opcache-prune.timer", 'leaving nothing behind');
    @{ $calls } = ();
    my $r = $plugin->({ opcache_file_cache => $cache });
    is($r->_removePruneTimer(), 0, 'and removing it again');
    is_deeply($calls, [], 'does nothing at all');
}

done_testing();
