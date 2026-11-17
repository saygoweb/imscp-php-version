#!/usr/bin/perl

# i-MSCP SGW_PhpVersion plugin
# Copyright (C) 2026 Cambell Prince <cambell.prince@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

=head1 NAME

 opcache-prune.pl - prune the per-vhost opcache file cache

=head1 SYNOPSIS

 opcache-prune.pl [--dry-run] [--max-age-days N] <root>

=head1 DESCRIPTION

 Run weekly by the sgw-php-opcache-prune timer the plugin installs. Under each
 <root>/<domain>/<32 hex digits>/ it deletes the *.bin files that have not been
 read for N days (default 30), then every directory that leaves empty. The
 <domain> directory itself stays while an FPM pool file points at it; once none
 does, it goes too.

 A system-id subtree left behind by a PHP upgrade is never read again, so it
 ages out and goes the same way, with no need to work out which system ids are
 current.

 Every vhost user owns its own directory, and could swap any directory in it for
 a symlink while this runs. Each <domain> is therefore pruned in a child process
 that has dropped to that directory's owner, so nothing the user plants can make
 it delete what the user could not delete anyway. On top of that, nothing is
 followed through a symlink, nothing on another filesystem is touched, and a
 <domain> directory holding anything but 32-hex directories is skipped whole.

 One line goes to stdout, which the unit sends to the journal.

=cut

package SGW_PhpVersion::OpcachePrune;

use strict;
use warnings;
use Cwd ();
use Fcntl ':mode';
use Getopt::Long ();
use POSIX ();

sub isDomainName
{
    my ($name) = @_;

    defined $name && $name =~ /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/i;
}

# The entries of a directory, without . and .., or undef if it cannot be read.
sub _entries
{
    my ($dir) = @_;

    opendir my $dh, $dir or return undef;
    my @entries = grep { !/^\.{1,2}\z/ } readdir $dh;
    closedir $dh;
    \@entries;
}

# Nothing but 32-hex directories, none of them a symlink: what opcache writes.
sub isFileCacheTree
{
    my ($dir) = @_;

    my @st = lstat $dir or return 0;
    return 0 unless S_ISDIR( $st[2] );

    my $entries = _entries( $dir ) or return 0;
    for my $entry ( @{ $entries } ) {
        return 0 unless $entry =~ /^[0-9a-f]{32}\z/;
        my @est = lstat "$dir/$entry" or return 0;
        return 0 unless S_ISDIR( $est[2] );
    }

    1;
}

# Depth first under one directory already known to be a real directory on $dev.
sub _walk
{
    my ($dir, $opts, $acc) = @_;

    my $entries = _entries( $dir ) or return;

    for my $name ( @{ $entries } ) {
        my $path = "$dir/$name";
        my @st = lstat $path or next;

        # -xdev: a mount point is neither descended into nor removed.
        next if $st[0] != $opts->{'dev'};

        if ( S_ISDIR( $st[2] )) {
            _walk( $path, $opts, $acc );
            next if $opts->{'dry_run'};
            $acc->{'dirs'}++ if rmdir $path;
        } elsif ( S_ISREG( $st[2] ) && $name =~ /\.bin\z/ && $st[8] < $opts->{'cutoff'} ) {
            next unless $opts->{'dry_run'} || unlink $path;
            $acc->{'files'}++;
            $acc->{'bytes'} += $st[7];
        }

        # Anything else -- a symlink, a socket, a file that is not a .bin -- is
        # not opcache's and is left where it is.
    }
}

=head2 pruneDomain( $dir, \%opts )

 Prune one <domain> directory, in the calling process

 Return hashref { files, bytes, dirs }

=cut

sub pruneDomain
{
    my ($dir, $opts) = @_;

    my %acc = ( files => 0, bytes => 0, dirs => 0 );

    for my $id ( @{ _entries( $dir ) || [] } ) {
        next unless $id =~ /^[0-9a-f]{32}\z/;
        my $path = "$dir/$id";
        my @st = lstat $path or next;
        next unless S_ISDIR( $st[2] ) && $st[0] == $opts->{'dev'};

        _walk( $path, $opts, \%acc );
        $acc{'dirs'}++ if !$opts->{'dry_run'} && rmdir $path;
    }

    \%acc;
}

# Prune one <domain> directory in a child running as its owner.
sub _pruneAs
{
    my ($dir, $uid, $gid, $opts) = @_;

    pipe my $reader, my $writer or die "pipe: $!\n";
    my $pid = fork // die "fork: $!\n";

    unless ( $pid ) {
        close $reader;
        my $ok = eval {
            POSIX::setgid( $gid ) or die "setgid: $!\n";
            $) = "$gid $gid";
            POSIX::setuid( $uid ) or die "setuid: $!\n";
            die "could not drop to $uid:$gid\n" unless $< == $uid && $> == $uid;

            # Now as the owner: the directory must still be where it was.
            die "moved\n" unless ( Cwd::realpath( $dir ) // '' ) eq $dir;

            my $acc = pruneDomain( $dir, $opts );
            print {$writer} "$acc->{'files'} $acc->{'bytes'} $acc->{'dirs'}\n";
            1;
        };
        print STDERR "opcache-prune: $dir: $@" unless $ok;
        close $writer;
        POSIX::_exit( $ok ? 0 : 1 );
    }

    close $writer;
    my $line = <$reader>;
    close $reader;
    waitpid $pid, 0;

    return undef unless $? == 0 && defined $line && $line =~ /^(\d+) (\d+) (\d+)$/;
    { files => $1, bytes => $2, dirs => $3 };
}

=head2 referencedDomains( $root, $realRoot, $glob )

 The <domain> names that some FPM pool file points its opcache.file_cache at

 Return hashref name => 1

=cut

sub referencedDomains
{
    my ($root, $realRoot, $glob) = @_;

    my %names;
    for my $file ( glob $glob ) {
        open my $fh, '<', $file or next;
        while ( my $line = <$fh> ) {
            next unless $line =~ /^[ \t]*php_admin_value\[opcache\.file_cache\][ \t]*=[ \t]*"?([^"\s]+)"?/;
            my $value = $1;
            $value =~ s{/+\z}{};
            for my $base ( $root, $realRoot ) {
                $names{$1} = 1 if $value =~ m{^\Q$base\E/([^/]+)\z};
            }
        }
        close $fh;
    }

    \%names;
}

=head2 prune( $root, \%opts )

 Prune every <domain> directory directly under $root

 A <domain> directory that no FPM pool file names any more -- the vhost has
 gone, or moved to a version that does not get the file cache -- is emptied and
 removed outright, once it is a day old, so that a build that has made the
 directory but not yet written the pool file is left alone. If no pool file
 names any directory at all, nothing is taken for orphaned: a pool glob that
 matches nothing must not empty the whole cache.

 Options: max_age_days (default 30), dry_run, now (for tests), pool_glob
 (default /etc/php/*/fpm/pool.d/*.conf).

 Return hashref { domains, skipped, files, bytes, dirs, orphans }, die on a bad
 root

=cut

sub prune
{
    my ($root, $opts) = @_;
    $opts = { %{ $opts || {} } };

    die "the root must be an absolute path\n" unless defined $root && $root =~ m{^/};

    my @rst = lstat $root or die "$root: $!\n";
    die "$root is not a directory (or is a symlink)\n" unless S_ISDIR( $rst[2] );

    my $realRoot = Cwd::realpath( $root ) // die "$root: $!\n";
    die "the root must not be /\n" if $realRoot eq '/';

    my $days = $opts->{'max_age_days'} // 30;
    die "max age must be a whole number of days, at least 1\n" unless $days =~ /^[1-9][0-9]*\z/;

    $opts->{'cutoff'} = ( $opts->{'now'} // time ) - $days * 86400;
    $opts->{'dev'} = $rst[0];

    my %total = ( domains => 0, skipped => 0, files => 0, bytes => 0, dirs => 0, orphans => 0 );

    my $referenced = referencedDomains( $root, $realRoot, $opts->{'pool_glob'} // '/etc/php/*/fpm/pool.d/*.conf' );
    my $orphansOk = %{ $referenced } ? 1 : 0;
    my $now = $opts->{'now'} // time;

    for my $name ( sort @{ _entries( $realRoot ) || [] } ) {
        my $dir = "$realRoot/$name";
        my @st = lstat $dir or next;

        # Not a name the plugin would have made: left alone, and not counted.
        next unless isDomainName( $name );

        # A symlink, root's own, on another filesystem, or holding anything
        # opcache did not write: skipped whole.
        unless ( S_ISDIR( $st[2] ) && $st[4] != 0 && $st[0] == $rst[0] && isFileCacheTree( $dir )) {
            $total{'skipped'}++;
            next;
        }

        my $orphan = $orphansOk && !$referenced->{$name} && $st[9] < $now - 86400;

        # An orphan has everything opcache wrote in it removed, however recent.
        my $acc = _pruneAs( $dir, $st[4], $st[5], $orphan ? { %{ $opts }, cutoff => 9**9**9 } : $opts );
        unless ( $acc ) {
            $total{'skipped'}++;
            next;
        }

        $total{'domains'}++;
        $total{$_} += $acc->{$_} for qw/ files bytes dirs /;

        next unless $orphan;

        # The owner cannot remove its own directory: the root is root's. Only
        # an empty, real directory goes, and rmdir follows no symlink.
        if ( $opts->{'dry_run'} ) {
            $total{'orphans'}++;
        } elsif ( ( lstat $dir ) && S_ISDIR( ( lstat _ )[2] ) && rmdir $dir ) {
            $total{'orphans'}++;
            $total{'dirs'}++;
        }
    }

    \%total;
}

sub main
{
    my (@argv) = @_;

    my %opts = ( max_age_days => 30 );
    Getopt::Long::GetOptionsFromArray(
        \@argv,
        'dry-run'        => \$opts{'dry_run'},
        'max-age-days=i' => \$opts{'max_age_days'},
        'pool-glob=s'    => \$opts{'pool_glob'}
    ) && @argv == 1 or do {
        print STDERR "usage: opcache-prune.pl [--dry-run] [--max-age-days N] [--pool-glob GLOB] <root>\n";
        return 2;
    };

    my $total = eval { prune( $argv[0], \%opts ) };
    unless ( $total ) {
        print STDERR "opcache-prune: $@";
        return 1;
    }

    printf "opcache-prune%s: %s, older than %d days: %d domains, %d skipped, %d files, %d bytes (%.1f MiB) %s, %d directories removed, %d orphaned domain directories%s\n",
        ( $opts{'dry_run'} ? ' (dry run)' : '' ), $argv[0], $opts{'max_age_days'},
        @{ $total }{ qw/ domains skipped files bytes / }, $total->{'bytes'} / 1048576,
        ( $opts{'dry_run'} ? 'would be freed' : 'freed' ), $total->{'dirs'}, $total->{'orphans'},
        ( $opts{'dry_run'} ? ' would go' : ' removed' );

    0;
}

exit main( @ARGV ) unless caller;

1;
