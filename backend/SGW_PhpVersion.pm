=head1 NAME

 Plugin::SGW_PhpVersion

=cut

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

package Plugin::SGW_PhpVersion;

use strict;
use warnings;
use File::Basename;
use iMSCP::Database;
use iMSCP::Debug;
use iMSCP::Dir;
use iMSCP::EventManager;
use iMSCP::File;
use iMSCP::ProgramFinder;
use iMSCP::Service;
use Servers::httpd;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 Backend for the i-MSCP SGW_PhpVersion plugin.

 i-MSCP builds a vhost and its PHP-FPM pool from one server-wide PHP version,
 read out of $httpd->{'phpConfig'}->{'PHP_VERSION'} at the top of addDmn(). This
 plugin does not write any configuration of its own: it brackets each domain's
 rebuild, points that one value at the version the domain has been given, and
 lets i-MSCP build exactly what it would otherwise have built, one version over.

 A vhost is also given an FPM instance to run in, which is nothing more than the
 same trick one step further. The overridden value is a token rather than a bare
 version -- '8.3', or '8.3-cloudflare' -- and every path i-MSCP derives from it
 follows: /etc/php/8.3-cloudflare for the configuration, its own pool.d, its own
 socket. The pool's master runs as php8.3-fpm-cloudflare.service. Unlike a
 version, a pool is not something the machine already has, so the plugin builds
 the directory and the unit the first time one is needed -- and never writes over
 either again, because tuning them by hand is the point of having them.

 Four things follow from that and are handled here:

 - phpConfig is a readonly tied iMSCP::Config outside of setup. It honours a
   'temporary' flag which keeps writes in memory, which is what makes the
   override possible without touching /etc/imscp/php/php.data.
 - Moving a domain between versions leaves its old pool file behind in the old
   version's pool.d, where FPM would go on serving it. Each domain's previously
   built version is remembered so that the stale file can be swept.
 - i-MSCP stops and masks every PHP-FPM service but its own, and only ever
   reloads its own. Services for the version and pool combinations in use are
   unmasked, started and reloaded here.
 - A pool's directory and systemd unit have to exist before i-MSCP writes a pool
   file into the one or anything tries to start the other, so they are put in
   place before the build that needs them.

=head1 PUBLIC METHODS

=over 4

=item install( )

 Perform install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
    my ($self) = @_;

    my $rs = $self->_checkRequirements();
    $rs ||= $self->_refreshInstalledVersions();
    $rs;
}

=item update( $fromVersion, $toVersion )

 Perform update tasks

 Return int 0 on success, other on failure

=cut

sub update
{
    my ($self) = @_;

    my $rs = $self->_checkRequirements();
    $rs ||= $self->_refreshInstalledVersions();
    $rs;
}

=item enable( )

 Perform enable tasks

 Return int 0 on success, other on failure

=cut

sub enable
{
    my ($self) = @_;

    # Modules::Plugin::_change() and ::_update() both call disable() and then
    # enable() on this same instance, so the flag disable() sets to force every
    # rebuild onto the default version is still on when we get here. Clearing it
    # is what stops a plugin change, a plugin update or an i-MSCP reconfigure --
    # all of which put the plugin through 'tochange' -- from rebuilding every
    # vhost onto the default version while its row still names another one.
    $self->{'forceDefault'} = 0;

    my $rs = $self->_checkRequirements();
    $rs ||= $self->_refreshInstalledVersions();
    return $rs if $rs;

    # A domain that was pinned before the plugin was disabled has been put back
    # on the default in the meantime, so ask for it to be built again.
    $rs = $self->_scheduleRebuild( "php_version <> '' OR php_pool <> ''" );
    $rs ||= $self->_startVersionsInUse();
    $rs;
}

=item disable( )

 Perform disable tasks

 Every domain goes back onto the panel's default version, in the instance the
 distribution ships, so that disabling the plugin leaves nothing running where
 i-MSCP does not know to look. Each row keeps its php_version and php_pool, so
 re-enabling the plugin restores the choices.

 Return int 0 on success, other on failure

=cut

sub disable
{
    my ($self) = @_;

    # Read by _wantedVersion() for the rest of this run: every domain rebuilt
    # from here on is built on the default, whatever its row says.
    $self->{'forceDefault'} = 1;

    $self->_scheduleRebuild( "applied_version <> '' OR applied_pool <> ''" );
}

=item uninstall( )

 Perform uninstall tasks

 Runs after the frontend has dropped this plugin's tables, so nothing here may
 read them. Everything it needs is on disk.

 Return int 0 on success, other on failure

=cut

sub uninstall
{
    my ($self) = @_;

    $self->{'forceDefault'} = 1;
    $self->{'noDb'} = 1;

    # Any pool file this plugin put anywhere but the instance i-MSCP itself
    # drives is now unreachable from the panel, so it goes, and the master
    # serving it with it.
    my @pairs;
    for my $version ( @{ $self->_installedVersions() } ) {
        push @pairs, [ $version, '' ] unless $version eq $self->{'defaultVersion'};
        push @pairs, [ $version, $_ ] for sort keys %{ $self->_pools() };
    }

    my $rs = 0;
    for my $pair ( @pairs ) {
        my ($version, $pool) = @{ $pair };

        my $poolDir = $self->_poolDir( _token( $version, $pool ));
        next unless -d $poolDir;

        for my $file ( glob "$poolDir/*.conf" ) {
            next if basename( $file ) eq 'www.conf';
            $rs ||= iMSCP::File->new( filename => $file )->delFile();
        }

        # The directory and the unit stay where they are. They were built once
        # and tuned by hand from there on, and an administrator who reinstalls
        # the plugin should find them as they were left.
        eval {
            my $service = iMSCP::Service->getInstance();
            my $unit = _serviceName( $version, $pool );
            $service->stop( $unit );
            $service->disable( $unit );
        };
        if ( $@ ) {
            error( $@ );
            $rs ||= 1;
        }
    }

    $rs;
}

=item run( )

 Process pending items

 Runs before the domain modules in the same pass, so this is where anything the
 rebuilds are about to depend on gets put in place; the rebuilds themselves are
 picked up by the listeners registered in _init().

 Return int 0 on success, other on failure

=cut

sub run
{
    my ($self) = @_;

    my $rs = $self->_refreshInstalledVersions();
    $rs ||= $self->_startVersionsInUse();
    $rs ||= $self->_reapDeletedRows();
    $rs;
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init( )

 Initialize plugin

 Return Plugin::SGW_PhpVersion

=cut

sub _init
{
    my ($self) = @_;

    $self->{'db'} = iMSCP::Database->factory();
    $self->{'httpd'} = Servers::httpd->factory();
    $self->{'phpConfig'} = $self->{'httpd'}->{'phpConfig'};
    $self->{'defaultVersion'} = $self->{'phpConfig'}->{'PHP_VERSION'};

    # Version and pool combinations whose pool.d this run has written into or
    # deleted from, and which therefore need their FPM master told about it.
    # Keyed by token, so that a version and one of its pools count separately.
    $self->{'touched'} = {};
    $self->{'saved'} = undef;

    # Only the PHP-FPM implementation keeps one pool file per site, which is
    # what makes a per-domain version possible at all. Under any other httpd
    # implementation the plugin stands down rather than half working.
    unless ( $::imscpConfig{'HTTPD_SERVER'} eq 'apache_php_fpm' ) {
        error( sprintf(
            'The SGW_PhpVersion plugin supports the apache_php_fpm httpd server only; %s is in use. No domain will be switched.',
            $::imscpConfig{'HTTPD_SERVER'}
        ));
        return $self;
    }

    # phpConfig is tied readonly outside of setup. iMSCP::Config lets a tied
    # hash be written anyway when the underlying object is marked temporary,
    # in which case the value is changed in memory and never written back to
    # /etc/imscp/php/php.data. That is exactly the lifetime wanted here: one
    # domain's build, then restored.
    my $tied = tied %{ $self->{'phpConfig'} };
    if ( $tied ) {
        $tied->{'temporary'} = 1;
    } else {
        error( "Couldn't make the PHP configuration writable: it is not a tied iMSCP::Config" );
        return $self;
    }

    my $events = iMSCP::EventManager->getInstance();

    # A domain and an alias are built by addDmn(); a subdomain and an alias
    # subdomain by addSub(). Neither calls the other, so both are needed.
    $events->register( 'beforeHttpdAddDmn', sub { $self->_onBeforeBuildDmn( @_ ); } );
    $events->register( 'afterHttpdAddDmn', sub { $self->_onAfterBuildDmn( @_ ); } );
    $events->register( 'beforeHttpdAddSub', sub { $self->_onBeforeBuildDmn( @_ ); } );
    $events->register( 'afterHttpdAddSub', sub { $self->_onAfterBuildDmn( @_ ); } );

    # Deletion is the other way about: deleteSub() delegates to deleteDmn(),
    # so the Dmn event alone covers all four kinds, and listening for the Sub
    # event as well would nest one bracket inside the other.
    $events->register( 'beforeHttpdDelDmn', sub { $self->_onBeforeDelDmn( @_ ); } );
    $events->register( 'afterHttpdDelDmn', sub { $self->_onAfterDelDmn( @_ ); } );

    $events->register( 'beforeHttpdRestart', sub { $self->_onBeforeHttpdRestart( @_ ); } );

    $self->{'active'} = 1;
    $self;
}

=item _onBeforeBuildDmn( \%data )

 Point i-MSCP at the version and pool this vhost is meant to run in.

 Both the vhost's FastCGI proxy target and the pool file's name and location
 come out of phpConfig, which is read once at the top of addDmn(); overriding it
 here is therefore enough to move the whole build.

 Return int 0 on success, other on failure

=cut

sub _onBeforeBuildDmn
{
    my ($self, $data) = @_;

    return 0 unless $self->{'active'};

    my $row = $self->_rowFor( $data );
    my $version = $self->_wantedVersion( $row );
    my $pool = $self->_wantedPool( $row );

    # i-MSCP is about to write a pool file into the pool's directory and this
    # is the last moment at which it can be told the directory is missing. A
    # pool that cannot be built stops the vhost here rather than leaving it
    # proxying to a socket no master is listening on.
    my $rs = $self->_ensurePool( $version, $pool );
    return $rs if $rs;

    $self->{'current'} = { row => $row, version => $version, pool => $pool };
    $self->_pushVersion( $version, $pool );
    0;
}

=item _onAfterBuildDmn( \%data )

 Restore the configuration, sweep the pool the vhost has just moved off, and
 record where it now is.

 Return int 0 on success, other on failure

=cut

sub _onAfterBuildDmn
{
    my ($self, $data) = @_;

    my $ctx = delete $self->{'current'} or return 0;

    $self->_popVersion();

    my ($version, $pool) = ( $ctx->{'version'}, $ctx->{'pool'} );
    my $wasVersion = $self->_appliedVersion( $ctx->{'row'} );
    my $wasPool = $self->_appliedPool( $ctx->{'row'} );

    my $rs = 0;
    if ( $wasVersion ne $version || $wasPool ne $pool ) {
        # i-MSCP has just written the pool file where the vhost now belongs. The
        # one it wrote last time is still sitting in the previous combination's
        # pool.d, and that master would go on serving the vhost from it.
        $rs = $self->_removePool( $wasVersion, $wasPool, $data->{'DOMAIN_NAME'} );
        $self->_touch( $wasVersion, $wasPool );
    }

    $self->_touch( $version, $pool );

    $rs ||= $self->_recordApplied( $ctx->{'row'}, $data, $version, $pool );
    $rs;
}

=item _onBeforeDelDmn( \%data )

 Point i-MSCP at the version and pool the vhost was built in, so that
 deleteDmn() removes the pool file that actually exists rather than one under
 the default version.

 Return int 0

=cut

sub _onBeforeDelDmn
{
    my ($self, $data) = @_;

    return 0 unless $self->{'active'};

    my $row = $self->_rowFor( $data );
    my $version = $self->_appliedVersion( $row );
    my $pool = $self->_appliedPool( $row );

    $self->{'current'} = { row => $row, version => $version, pool => $pool };
    $self->_pushVersion( $version, $pool );
    0;
}

=item _onAfterDelDmn( \%data )

 Restore the configuration and drop the row for a vhost that no longer exists.

 Return int 0 on success, other on failure

=cut

sub _onAfterDelDmn
{
    my ($self, $data) = @_;

    my $ctx = delete $self->{'current'} or return 0;

    $self->_popVersion();
    $self->_touch( $ctx->{'version'}, $ctx->{'pool'} );

    return 0 unless $ctx->{'row'};

    my $qrs = $self->{'db'}->doQuery(
        'dummy', 'DELETE FROM php_version WHERE php_version_id = ?',
        $ctx->{'row'}->{'php_version_id'}
    );
    unless ( ref $qrs eq 'HASH' ) {
        error( $qrs );
        return 1;
    }

    0;
}

=item _onBeforeHttpdRestart( )

 Reload the FPM masters this run has written pool files for.

 i-MSCP reloads the one service belonging to the version it was set up with, in
 the instance the distribution ships; every other master whose pool.d changed
 has to be told separately, including one a domain has just moved away from,
 which has a pool file to forget.

 Return int 0 on success, other on failure

=cut

sub _onBeforeHttpdRestart
{
    my ($self) = @_;

    my $rs = 0;

    for my $token ( sort keys %{ $self->{'touched'} } ) {
        # i-MSCP reloads its own version, in the default pool, itself,
        # immediately after this.
        next if $token eq $self->{'defaultVersion'};

        my $pair = $self->{'touched'}->{$token};

        # One master that will not come up is not a reason to leave the others
        # holding a pool file they have not read.
        if ( my $err = $self->_startVersion( $pair->{'version'}, $pair->{'pool'} )) {
            $rs ||= $err;
            next;
        }

        eval {
            my $service = iMSCP::Service->getInstance();
            my $unit = _serviceName( $pair->{'version'}, $pair->{'pool'} );

            $self->{'httpd'}->{'forceRestart'}
                ? $service->restart( $unit ) : $service->reload( $unit );
        };
        if ( $@ ) {
            error( $@ );
            $rs ||= 1;
        }
    }

    %{ $self->{'touched'} } = ();
    $rs;
}

=item _touch( $version, $pool )

 Note that one version and pool combination has a pool.d this run has changed

 Return void

=cut

sub _touch
{
    my ($self, $version, $pool) = @_;

    $self->{'touched'}->{ _token( $version, $pool ) } = {
        version => $version, pool => $pool
    };
}

=item _pushVersion( $version [, $pool = '' ] )

 Override the PHP version and pool for the build that is about to happen

 Return void

=cut

sub _pushVersion
{
    my ($self, $version, $pool) = @_;

    return unless $self->{'active'};

    # A build that failed part way through returns before its 'after' event,
    # leaving the override in place. Undoing it here rather than trusting the
    # bracket to close keeps one failed domain from silently moving every
    # domain built after it onto the wrong version.
    $self->_popVersion();

    $self->{'saved'} = {
        map { $_ => $self->{'phpConfig'}->{$_} }
            qw/ PHP_VERSION PHP_CONF_DIR_PATH PHP_FPM_POOL_DIR_PATH /
    };

    my $token = _token( $version, $pool );
    return if $token eq $self->{'defaultVersion'};

    $self->{'phpConfig'}->{'PHP_VERSION'} = $token;
    $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = $self->_confDir( $token );
    $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = $self->_poolDir( $token );
}

=item _popVersion( )

 Put the PHP configuration back the way i-MSCP left it

 Return void

=cut

sub _popVersion
{
    my ($self) = @_;

    my $saved = delete $self->{'saved'} or return;

    $self->{'phpConfig'}->{$_} = $saved->{$_} for keys %{ $saved };
}

=item _rowFor( \%data )

 The plugin's row for the vhost being built, or undef

 Return hashref|undef

=cut

sub _rowFor
{
    my ($self, $data) = @_;

    # uninstall() runs after the frontend has dropped the tables.
    return undef if $self->{'noDb'};

    my $rows = $self->{'db'}->doQuery(
        'php_version_id',
        'SELECT * FROM php_version WHERE domain_type = ? AND domain_id = ?',
        $data->{'DOMAIN_TYPE'}, $data->{'DOMAIN_ID'}
    );
    unless ( ref $rows eq 'HASH' ) {
        error( $rows );
        return undef;
    }

    ( values %{ $rows } )[0];
}

=item _wantedVersion( \%row )

 The version a vhost should be built on

 A version a customer was pinned to but which is no longer installed falls back
 to the default rather than producing a pool under a directory that is not
 there; the frontend says as much on the customer's page.

 Return string

=cut

sub _wantedVersion
{
    my ($self, $row) = @_;

    return $self->{'defaultVersion'} if $self->{'forceDefault'};
    return $self->{'defaultVersion'} unless $row && length $row->{'php_version'};

    my $version = $row->{'php_version'};

    return $self->{'defaultVersion'} unless grep {
        $_ eq $version
    } @{ $self->_installedVersions() };

    $version;
}

=item _wantedPool( \%row )

 The pool a vhost should be built in

 A pool an administrator has since taken out of config.php is one nothing
 maintains any more -- the plugin will not build its directory or start its
 master -- so a vhost naming it goes back into the instance the distribution
 ships rather than into a directory that may not be there; the frontend says as
 much on the customer's page.

 Return string Pool name, or '' for the default instance

=cut

sub _wantedPool
{
    my ($self, $row) = @_;

    return '' if $self->{'forceDefault'};
    return '' unless $row && length $row->{'php_pool'};

    my $pool = $row->{'php_pool'};
    return '' unless exists $self->_pools()->{$pool};

    $pool;
}

=item _pools( )

 The pools an administrator has configured

 A pool name becomes both a service name and a directory name, so a name that
 would not survive either is not a pool at all. The frontend filters the same
 list the same way, and neither trusts the other to have done it.

 Return hashref Pool name => truth

=cut

sub _pools
{
    my ($self) = @_;

    my $pools = $self->{'config'}->{'pools'};
    return {} unless ref $pools eq 'HASH';

    +{ map { $_ => 1 } grep { /^[a-z0-9][a-z0-9-]*$/ } keys %{ $pools } };
}

=item _appliedPool( \%row )

 The pool a vhost was last actually built in

 Return string Pool name, or '' for the default instance

=cut

sub _appliedPool
{
    my ($self, $row) = @_;

    ( $row && defined $row->{'applied_pool'} ) ? $row->{'applied_pool'} : '';
}

=item _appliedVersion( \%row )

 The version a vhost was last actually built on

 Return string

=cut

sub _appliedVersion
{
    my ($self, $row) = @_;

    return $self->{'defaultVersion'}
        unless $row && length $row->{'applied_version'};

    $row->{'applied_version'};
}

=item _recordApplied( \%row, \%data, $version, $pool )

 Remember where a vhost was built, so that the next move knows what to sweep

 A vhost on the default version, in the default pool, with no row of its own
 stays that way: a row is only created once a customer has actually chosen
 something.

 Return int 0 on success, other on failure

=cut

sub _recordApplied
{
    my ($self, $row, $data, $version, $pool) = @_;

    return 0 unless $row;
    return 0 if $row->{'applied_version'} eq $version
        && ( $row->{'applied_pool'} // '' ) eq $pool
        && $row->{'status'} eq 'ok';

    my $qrs = $self->{'db'}->doQuery(
        'dummy',
        "
            UPDATE php_version SET applied_version = ?, applied_pool = ?, status = 'ok'
            WHERE php_version_id = ?
        ",
        $version, $pool, $row->{'php_version_id'}
    );
    unless ( ref $qrs eq 'HASH' ) {
        error( $qrs );
        return 1;
    }

    0;
}

=item _removePool( $version, $pool, $domainName )

 Remove one vhost's pool file from one version and pool combination's pool
 directory

 Return int 0 on success, other on failure

=cut

sub _removePool
{
    my ($self, $version, $pool, $domainName) = @_;

    my $file = $self->_poolDir( _token( $version, $pool )) . "/$domainName.conf";
    return 0 unless -f $file;

    iMSCP::File->new( filename => $file )->delFile();
}

=item _token( $version [, $pool = '' ] )

 The name one version in one pool goes by

 Everything the plugin overrides is derived by i-MSCP from a single value, so a
 pool is expressed by making that value say more than a version does: '8.3' is
 PHP 8.3 in the instance the distribution ships, '8.3-cloudflare' is PHP 8.3 in
 the pool named cloudflare. The configuration directory, the pool directory, the
 pid file, the log and the sockets all follow from it, which is why the vhost and
 its pool file cannot end up disagreeing.

 Return string

=cut

sub _token
{
    my ($version, $pool) = @_;

    ( defined $pool && length $pool ) ? "$version-$pool" : $version;
}

=item _serviceName( $version [, $pool = '' ] )

 The FPM service that runs one version in one pool

 Return string

=cut

sub _serviceName
{
    my ($version, $pool) = @_;

    ( defined $pool && length $pool )
        ? "php$version-fpm-$pool" : "php$version-fpm";
}

=item _unitPath( $version, $pool )

 Where this plugin writes a pool's systemd unit

 Under /etc/systemd/system rather than /lib, both because it is generated
 configuration and because that is the one place the distribution will never
 write over.

 Return string

=cut

sub _unitPath
{
    my ($version, $pool) = @_;

    '/etc/systemd/system/' . _serviceName( $version, $pool ) . '.service';
}

=item _confDir( $token )

 The configuration directory of the given version and pool combination

 Derived from the directory i-MSCP found for its own version rather than
 assumed, so that the two cannot disagree about where PHP lives. A token that is
 a bare version names the directory the distribution already ships; one carrying
 a pool names a sibling of it, which this plugin creates.

 Return string

=cut

sub _confDir
{
    my ($self, $token) = @_;

    dirname( $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} ) . "/$token";
}

=item _poolDir( $token )

 The FPM pool directory of the given version and pool combination

 Return string

=cut

sub _poolDir
{
    my ($self, $token) = @_;

    $self->_confDir( $token ) . '/fpm/pool.d';
}

=item _installedVersions( )

 Every PHP version on this machine that can run a pool

 A directory under the PHP configuration root is not enough on its own: the
 version also needs an FPM binary and a pool directory to write into.

 Return arrayref Versions, oldest first

=cut

sub _installedVersions
{
    my ($self) = @_;

    return $self->{'_installedVersions'} if $self->{'_installedVersions'};

    my $root = dirname( $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} );
    my @versions;

    local $@;
    eval {
        @versions = grep {
            /^[0-9]+\.[0-9]+$/
                && -d "$root/$_/fpm/pool.d"
                && iMSCP::ProgramFinder::find( "php-fpm$_" )
        } iMSCP::Dir->new( dirname => $root )->getDirs();
    };
    if ( $@ ) {
        error( $@ );
        return $self->{'_installedVersions'} = [];
    }

    my %excluded = map { $_ => 1 } @{ $self->{'config'}->{'excluded_versions'} || [] };

    # The version i-MSCP itself runs on is never excludable: it is what every
    # domain falls back to.
    @versions = grep {
        $_ eq $self->{'defaultVersion'} || !$excluded{$_}
    } @versions;

    $self->{'_installedVersions'} = [
        sort { _compareVersions( $a, $b ) } @versions
    ];
}

=item _compareVersions( $a, $b )

 Order two versions numerically, so that 8.10 would sort after 8.9

 Return int

=cut

sub _compareVersions
{
    my ($left, $right) = @_;

    my @l = split /\./, $left;
    my @r = split /\./, $right;

    ( $l[0] <=> $r[0] ) || ( $l[1] <=> $r[1] );
}

=item _refreshInstalledVersions( )

 Publish the installed versions for the frontend, and set up any that are new

 The frontend cannot see /etc/php in a way it could trust, so the list it offers
 is whatever was last written here.

 Return int 0 on success, other on failure

=cut

sub _refreshInstalledVersions
{
    my ($self) = @_;

    delete $self->{'_installedVersions'};
    my $versions = $self->_installedVersions();

    my $known = $self->{'db'}->doQuery(
        'version', 'SELECT version FROM php_version_installed'
    );
    unless ( ref $known eq 'HASH' ) {
        error( $known );
        return 1;
    }

    my $rs = 0;
    for my $version ( @{ $versions } ) {
        # A version i-MSCP has never configured has Debian's php.ini rather
        # than i-MSCP's, which would change timezone, opcache and session
        # behaviour under a domain purely by moving it.
        $rs ||= $self->_syncPhpConf( $version, '' ) unless exists $known->{$version};
    }
    return $rs if $rs;

    my $qrs = $self->{'db'}->doQuery( 'dummy', 'DELETE FROM php_version_installed' );
    unless ( ref $qrs eq 'HASH' ) {
        error( $qrs );
        return 1;
    }

    for my $version ( @{ $versions } ) {
        $qrs = $self->{'db'}->doQuery(
            'dummy',
            'INSERT INTO php_version_installed (version, is_default) VALUES (?, ?)',
            $version, ( $version eq $self->{'defaultVersion'} ? 1 : 0 )
        );
        unless ( ref $qrs eq 'HASH' ) {
            error( $qrs );
            return 1;
        }
    }

    0;
}

=item _syncPhpConf( $version, $pool )

 Give one version and pool combination the same php.ini, php-fpm.conf and
 default pool that i-MSCP built for its own version

 Rendered with the combination's own token, so the master gets a pid file, a log
 and a default socket that no other master shares.

 A pool's files are written once and then left alone. They exist to be tuned --
 that is the whole reason for running a second master -- so anything already
 there is the administrator's, not this plugin's to reconsider.

 Return int 0 on success, other on failure

=cut

sub _syncPhpConf
{
    my ($self, $version, $pool) = @_;

    my $token = _token( $version, $pool );
    return 0 if $token eq $self->{'defaultVersion'};

    # sync_php_conf says whether i-MSCP's own php.ini should be pushed onto a
    # version the distribution configured for itself. A pool has no
    # configuration at all until this writes it, so the switch has no say there.
    return 0 if $token eq $version && !$self->{'config'}->{'sync_php_conf'};

    my $confDir = $self->_confDir( $token );
    return 0 unless -d "$confDir/fpm";

    my $httpd = $self->{'httpd'};

    $httpd->setData( {
        HTTPD_USER                          => $httpd->{'config'}->{'HTTPD_USER'},
        HTTPD_GROUP                         => $httpd->{'config'}->{'HTTPD_GROUP'},
        PEAR_DIR                            => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
        PHP_CONF_DIR_PATH                   => $confDir,
        PHP_FPM_POOL_DIR_PATH               => $self->_poolDir( $token ),
        PHP_FPM_LOG_LEVEL                   => $self->{'phpConfig'}->{'PHP_FPM_LOG_LEVEL'} || 'error',
        PHP_FPM_EMERGENCY_RESTART_THRESHOLD => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_THRESHOLD'} || 10,
        PHP_FPM_EMERGENCY_RESTART_INTERVAL  => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_INTERVAL'} || '1m',
        PHP_FPM_PROCESS_CONTROL_TIMEOUT     => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_CONTROL_TIMEOUT'} || '60s',
        PHP_FPM_PROCESS_MAX                 => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_MAX'} // 0,
        PHP_FPM_RLIMIT_FILES                => $self->{'phpConfig'}->{'PHP_FPM_RLIMIT_FILES'} // 4096,
        PHP_VERSION                         => $token,
        TIMEZONE                            => $::imscpConfig{'TIMEZONE'},
        PHP_OPCODE_CACHE_ENABLED            => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_ENABLED'},
        PHP_OPCODE_CACHE_MAX_MEMORY         => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_MAX_MEMORY'}
    } );

    my $tplDir = $httpd->{'phpCfgDir'};
    my @files = (
        [ "$tplDir/fpm/php.ini", "$confDir/fpm/php.ini" ],
        [ "$tplDir/fpm/php-fpm.conf", "$confDir/fpm/php-fpm.conf" ],
        [ "$tplDir/fpm/pool.conf.default", $self->_poolDir( $token ) . '/www.conf' ]
    );

    my $rs = 0;
    for my $file ( @files ) {
        my ($template, $destination) = @{ $file };

        next if length $pool && -f $destination;

        my $err = $httpd->buildConfFile( $template, {}, {
            destination => $destination
        } );

        # buildConfFile() strips every comment out of i-MSCP's templates, so a
        # file that has just been put in front of the person who is meant to
        # edit it arrives saying nothing about itself at all.
        $err ||= _markHandTuned( $destination, $pool ) if length $pool && !$err;

        $rs ||= $err;
    }

    $httpd->flushData();
    $rs;
}

=item _markHandTuned( $filename, $pool )

 Head a pool's configuration file with a note saying it is nobody's but the
 administrator's

 The comment syntax is the same for php.ini and for an FPM configuration file,
 which is why one banner does for both.

 Return int 0 on success, other on failure

=cut

sub _markHandTuned
{
    my ($filename, $pool) = @_;

    my $file = iMSCP::File->new( filename => $filename );
    my $content = $file->get();
    unless ( defined $content ) {
        error( sprintf( "Couldn't read the '%s' file", $filename ));
        return 1;
    }

    my $rs = $file->set( sprintf( <<"BANNER", $pool ) . $content );
; Written for the %s PHP-FPM pool by the i-MSCP SGW_PhpVersion plugin.
;
; It is written once, when the pool is first needed, and never again: tuning it
; -- and the pool's systemd unit -- by hand is what having a pool of your own is
; for. Deleting it puts the pool back to how the plugin would have built it.

BANNER
    $rs ||= $file->save();
    $rs;
}

=item _startVersion( $version [, $pool = '' ] )

 Make sure one PHP-FPM master is built, unmasked, enabled and running

 i-MSCP stops and masks every version but its own during setup, so a version a
 customer picks has to be brought back up before its pool can serve anything. A
 pool's master has to be built before it can be brought up at all.

 Return int 0 on success, other on failure

=cut

sub _startVersion
{
    my ($self, $version, $pool) = @_;

    return 0 if _token( $version, $pool ) eq $self->{'defaultVersion'};

    my $rs = $self->_ensurePool( $version, $pool );
    return $rs if $rs;

    local $@;
    eval {
        my $service = iMSCP::Service->getInstance();
        my $unit = _serviceName( $version, $pool );

        # enable() unmasks first, which is what i-MSCP's disable() did to it.
        $service->enable( $unit ) unless $service->isEnabled( $unit );
        $service->start( $unit ) unless $service->isRunning( $unit );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _ensurePool( $version, $pool )

 Build one pool, if it is not there already

 Everything here is written exactly once. A pool exists to be tuned by hand --
 its process manager, its limits, its php.ini, its unit -- so finding a file
 already in place is the ordinary case and is left untouched.

 Return int 0 on success, other on failure

=cut

sub _ensurePool
{
    my ($self, $version, $pool) = @_;

    return 0 unless defined $pool && length $pool;

    my $token = _token( $version, $pool );
    return 0 if $self->{'_builtPools'}->{$token};

    local $@;
    eval {
        iMSCP::Dir->new( dirname => $self->_poolDir( $token ))->make( {
            user  => $::imscpConfig{'ROOT_USER'},
            group => $::imscpConfig{'ROOT_GROUP'},
            mode  => 0755
        } );
    };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    my $rs = $self->_syncPhpConf( $version, $pool );
    $rs ||= $self->_ensureUnit( $version, $pool );
    return $rs if $rs;

    # Only after everything is in place: a run that got half way must try again
    # rather than take the pool for built.
    $self->{'_builtPools'}->{$token} = 1;
    0;
}

=item _distroUnit( $version )

 The distribution's own systemd unit for one version's FPM master

 iMSCP::Service's resolver is no use here. i-MSCP masks every PHP-FPM service
 but the one it drives, and a mask is a symlink to /dev/null which the resolver
 reports as the unit and which reads as an empty file. What is wanted is the
 unit the distribution shipped, so only a regular file will do.

 Return string|undef Path to the unit, or undef if there is none

=cut

sub _distroUnit
{
    my ($version) = @_;

    my $unit = _serviceName( $version ) . '.service';

    # The places systemd itself looks, in the order it looks in them.
    for my $dir ( qw{
        /etc/systemd/system /usr/local/lib/systemd/system /lib/systemd/system
        /usr/lib/systemd/system
    } ) {
        return "$dir/$unit" if -f "$dir/$unit";
    }

    undef;
}

=item _ensureUnit( $version, $pool )

 Write a pool's systemd unit, if it is not there already

 Derived from the distribution's own unit for the version rather than written
 from nothing, so that whatever hardening or ordering the distribution thinks an
 FPM master needs comes along with it.

 Return int 0 on success, other on failure

=cut

sub _ensureUnit
{
    my ($self, $version, $pool) = @_;

    my $unitPath = _unitPath( $version, $pool );
    return 0 if -f $unitPath;

    my $service = iMSCP::Service->getInstance();
    unless ( $service->isSystemd() ) {
        error( sprintf(
            "The SGW_PhpVersion plugin can only create the '%s' PHP-FPM instance under systemd; %s is in use.",
            $pool, $service->getInitSystem()
        ));
        return 1;
    }

    my $source = _distroUnit( $version );
    unless ( $source ) {
        error( sprintf(
            "Couldn't find a systemd unit for %s to derive the '%s' pool from.",
            _serviceName( $version ), $pool
        ));
        return 1;
    }

    my $template = iMSCP::File->new( filename => $source )->get();
    unless ( defined $template ) {
        error( sprintf( "Couldn't read the '%s' unit", $source ));
        return 1;
    }

    my $confDir = $self->_confDir( _token( $version, $pool ));
    my $unit = '';

    for my $line ( split /^/, $template ) {
        # The socket helper installs the version-generic /run/php/php-fpm.sock
        # alternative. A second master for the same version must not fight the
        # distribution's own over which of them owns it.
        next if $line =~ /php-fpm-socket-helper/;

        $line =~ s/^(Description=.*?)\s*$/$1 ($pool pool)\n/;

        # --fpm-config moves the master onto the pool's own configuration, and
        # -c moves php.ini with it, so that the two masters can be tuned apart.
        # The scan directory for extensions is compiled in and is deliberately
        # left alone: a pool runs the same PHP as the version it belongs to.
        $line =~ s{^(ExecStart=.*?)--fpm-config\s+\S+(.*?)\s*$}
                  {$1--fpm-config $confDir/fpm/php-fpm.conf$2 -c $confDir/fpm\n};

        $unit .= $line;
    }

    unless ( $unit =~ /^ExecStart=.*\Q$confDir\E/m ) {
        error( sprintf(
            "Couldn't derive '%s' from '%s': it has no ExecStart line naming an FPM configuration file.",
            $unitPath, $source
        ));
        return 1;
    }

    my $file = iMSCP::File->new( filename => $unitPath );
    my $rs = $file->set( $unit );
    $rs ||= $file->save();
    $rs ||= $file->owner( $::imscpConfig{'ROOT_USER'}, $::imscpConfig{'ROOT_GROUP'} );
    $rs ||= $file->mode( 0644 );
    return $rs if $rs;

    # Nothing else will: the unit is about to be enabled and started by a name
    # systemd has never heard.
    eval { $service->getProvider()->daemonReload(); };
    if ( $@ ) {
        error( $@ );
        return 1;
    }

    0;
}

=item _startVersionsInUse( )

 Bring up the FPM master of every version and pool combination a domain has
 been given

 Return int 0 on success, other on failure

=cut

sub _startVersionsInUse
{
    my ($self) = @_;

    # Keyed on the pair rather than on either column, so that a version in two
    # pools is two rows here and not one.
    my $rows = $self->{'db'}->doQuery(
        'pair',
        "
            SELECT DISTINCT CONCAT(php_version, '-', php_pool) AS pair,
                php_version, php_pool
            FROM php_version
            WHERE php_version <> '' OR php_pool <> ''
        "
    );
    unless ( ref $rows eq 'HASH' ) {
        error( $rows );
        return 1;
    }

    my %installed = map { $_ => 1 } @{ $self->_installedVersions() };
    my $pools = $self->_pools();
    my $rs = 0;

    for my $pair ( values %{ $rows } ) {
        # The same reading _wantedVersion() gives a row: no version named, or
        # one that is no longer installed, means the panel default -- which
        # still has a master to start if the row names a pool.
        my $version = $pair->{'php_version'};
        $version = $self->{'defaultVersion'}
            unless length $version && $installed{$version};

        # A pool taken out of config.php is one _wantedPool() no longer hands
        # out, so there is no master left to start for it.
        my $pool = $pair->{'php_pool'} // '';
        next if length $pool && !exists $pools->{$pool};

        $rs ||= $self->_startVersion( $version, $pool );
    }

    $rs;
}

=item _scheduleRebuild( $condition )

 Mark for rebuild every vhost whose row matches the given condition

 Return int 0 on success, other on failure

=cut

sub _scheduleRebuild
{
    my ($self, $condition) = @_;

    my %statements = (
        dmn    => "
            UPDATE domain AS t JOIN php_version AS p
                ON p.domain_type = 'dmn' AND p.domain_id = t.domain_id
            SET t.domain_status = 'tochange'
            WHERE t.domain_status NOT IN('disabled', 'todelete') AND ($condition)
        ",
        sub    => "
            UPDATE subdomain AS t JOIN php_version AS p
                ON p.domain_type = 'sub' AND p.domain_id = t.subdomain_id
            SET t.subdomain_status = 'tochange'
            WHERE t.subdomain_status NOT IN('disabled', 'todelete') AND ($condition)
        ",
        als    => "
            UPDATE domain_aliasses AS t JOIN php_version AS p
                ON p.domain_type = 'als' AND p.domain_id = t.alias_id
            SET t.alias_status = 'tochange'
            WHERE t.alias_status NOT IN('disabled', 'todelete') AND ($condition)
        ",
        alssub => "
            UPDATE subdomain_alias AS t JOIN php_version AS p
                ON p.domain_type = 'alssub' AND p.domain_id = t.subdomain_alias_id
            SET t.subdomain_alias_status = 'tochange'
            WHERE t.subdomain_alias_status NOT IN('disabled', 'todelete') AND ($condition)
        "
    );

    for my $sql ( values %statements ) {
        my $qrs = $self->{'db'}->doQuery( 'dummy', $sql );
        unless ( ref $qrs eq 'HASH' ) {
            error( $qrs );
            return 1;
        }
    }

    0;
}

=item _reapDeletedRows( )

 Drop rows for vhosts that are already gone

 The listener on deleteDmn removes a row as its vhost goes, which covers the
 ordinary case. This is the safety net for a vhost that disappeared while the
 plugin was disabled, or by some route that never reached the httpd server.

 Return int 0 on success, other on failure

=cut

sub _reapDeletedRows
{
    my ($self) = @_;

    my $qrs = $self->{'db'}->doQuery( 'dummy', "
        DELETE p FROM php_version AS p
        LEFT JOIN domain AS d
            ON p.domain_type = 'dmn' AND p.domain_id = d.domain_id
        LEFT JOIN subdomain AS s
            ON p.domain_type = 'sub' AND p.domain_id = s.subdomain_id
        LEFT JOIN domain_aliasses AS a
            ON p.domain_type = 'als' AND p.domain_id = a.alias_id
        LEFT JOIN subdomain_alias AS sa
            ON p.domain_type = 'alssub' AND p.domain_id = sa.subdomain_alias_id
        WHERE d.domain_id IS NULL AND s.subdomain_id IS NULL
            AND a.alias_id IS NULL AND sa.subdomain_alias_id IS NULL
    " );
    unless ( ref $qrs eq 'HASH' ) {
        error( $qrs );
        return 1;
    }

    0;
}

=item _checkRequirements( )

 Refuse to install where a per-domain version could not work

 Return int 0 on success, other on failure

=cut

sub _checkRequirements
{
    my ($self) = @_;

    unless ( $::imscpConfig{'HTTPD_SERVER'} eq 'apache_php_fpm' ) {
        error( sprintf(
            "The SGW_PhpVersion plugin requires the 'apache_php_fpm' httpd server; %s is in use.",
            $::imscpConfig{'HTTPD_SERVER'}
        ));
        return 1;
    }

    # Under per_user or per_domain a pool is shared between several vhosts, so
    # a version could not be chosen per vhost without silently moving the
    # others with it.
    unless ( $self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'} eq 'per_site' ) {
        error( sprintf(
            "The SGW_PhpVersion plugin requires the 'per_site' PHP configuration level; '%s' is in use. Run: perl %s/engine/setup/imscp-reconfigure -dar php",
            $self->{'phpConfig'}->{'PHP_CONFIG_LEVEL'},
            $::imscpConfig{'ROOT_DIR'}
        ));
        return 1;
    }

    0;
}

=back

=head1 END

 Reload anything beforeHttpdRestart did not get to.

 Servers::httpd's own END block stands down when $? is already set, which any
 unrelated server failure earlier in the run will have done; hanging this
 plugin's reloads off beforeHttpdRestart alone would take them down with it. A
 pool file that has been written but never loaded is a domain that does not
 run, so the reload happens either way. It is a no-op on a clean run, where
 beforeHttpdRestart has already emptied the list.

=cut

END
    {
        my $instance = $Plugin::SGW_PhpVersion::_instance or return;

        # Whatever the reloads report, the exit status of the run is not this
        # block's to change.
        local $?;
        $instance->_onBeforeHttpdRestart();
    }

=head1 AUTHOR

 Cambell Prince <cambell.prince@gmail.com>

=cut

1;
__END__
