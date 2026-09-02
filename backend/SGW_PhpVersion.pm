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

 Three things follow from that and are handled here:

 - phpConfig is a readonly tied iMSCP::Config outside of setup. It honours a
   'temporary' flag which keeps writes in memory, which is what makes the
   override possible without touching /etc/imscp/php/php.data.
 - Moving a domain between versions leaves its old pool file behind in the old
   version's pool.d, where FPM would go on serving it. Each domain's previously
   built version is remembered so that the stale file can be swept.
 - i-MSCP stops and masks every PHP-FPM service but its own, and only ever
   reloads its own. Services for versions in use are unmasked, started and
   reloaded here.

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

    my $rs = $self->_checkRequirements();
    $rs ||= $self->_refreshInstalledVersions();
    return $rs if $rs;

    # A domain that was pinned before the plugin was disabled has been put back
    # on the default in the meantime, so ask for it to be built again.
    $rs = $self->_scheduleRebuild( "php_version <> ''" );
    $rs ||= $self->_startVersionsInUse();
    $rs;
}

=item disable( )

 Perform disable tasks

 Every domain goes back onto the panel's default version, so that disabling the
 plugin leaves nothing running on a version i-MSCP does not know about. Each
 row keeps its php_version, so re-enabling the plugin restores the choices.

 Return int 0 on success, other on failure

=cut

sub disable
{
    my ($self) = @_;

    # Read by _wantedVersion() for the rest of this run: every domain rebuilt
    # from here on is built on the default, whatever its row says.
    $self->{'forceDefault'} = 1;

    $self->_scheduleRebuild( "applied_version <> ''" );
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

    # Any pool this plugin put under a non-default version is now unreachable
    # from the panel, so it goes, and its service with it.
    my $rs = 0;
    for my $version ( @{ $self->_installedVersions() } ) {
        next if $version eq $self->{'defaultVersion'};

        my $poolDir = $self->_poolDir( $version );
        next unless -d $poolDir;

        for my $pool ( glob "$poolDir/*.conf" ) {
            next if basename( $pool ) eq 'www.conf';
            $rs ||= iMSCP::File->new( filename => $pool )->delFile();
        }

        eval {
            my $service = iMSCP::Service->getInstance();
            $service->stop( sprintf( 'php%s-fpm', $version ));
            $service->disable( sprintf( 'php%s-fpm', $version ));
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

    # Versions whose pool.d this run has written into or deleted from, and
    # which therefore need their FPM service told about it.
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

 Point i-MSCP at the version this vhost is meant to run on.

 Both the vhost's FastCGI proxy target and the pool file's name and location
 come out of phpConfig, which is read once at the top of addDmn(); overriding it
 here is therefore enough to move the whole build.

 Return int 0

=cut

sub _onBeforeBuildDmn
{
    my ($self, $data) = @_;

    return 0 unless $self->{'active'};

    my $row = $self->_rowFor( $data );
    my $wanted = $self->_wantedVersion( $row );

    $self->{'current'} = { row => $row, wanted => $wanted };
    $self->_pushVersion( $wanted );
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

    my $wanted = $ctx->{'wanted'};
    my $previous = $self->_appliedVersion( $ctx->{'row'} );

    my $rs = 0;
    if ( $previous ne $wanted ) {
        # i-MSCP has just written the pool under $wanted. The one it wrote last
        # time is still sitting in $previous's pool.d, and FPM would go on
        # serving the vhost from it.
        $rs = $self->_removePool( $previous, $data->{'DOMAIN_NAME'} );
        $self->{'touched'}->{$previous} = 1;
    }

    $self->{'touched'}->{$wanted} = 1;

    $rs ||= $self->_recordApplied( $ctx->{'row'}, $data, $wanted );
    $rs;
}

=item _onBeforeDelDmn( \%data )

 Point i-MSCP at the version the vhost was built on, so that deleteDmn() removes
 the pool that actually exists rather than one under the default version.

 Return int 0

=cut

sub _onBeforeDelDmn
{
    my ($self, $data) = @_;

    return 0 unless $self->{'active'};

    my $row = $self->_rowFor( $data );
    my $applied = $self->_appliedVersion( $row );

    $self->{'current'} = { row => $row, wanted => $applied };
    $self->_pushVersion( $applied );
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
    $self->{'touched'}->{ $ctx->{'wanted'} } = 1;

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

 Reload the FPM services this run has written pools for.

 i-MSCP reloads the one service belonging to the version it was set up with;
 every other version whose pool.d changed has to be told separately, including
 one a domain has just moved away from, which has a pool to forget.

 Return int 0 on success, other on failure

=cut

sub _onBeforeHttpdRestart
{
    my ($self) = @_;

    my $rs = 0;

    for my $version ( sort keys %{ $self->{'touched'} } ) {
        # i-MSCP reloads its own version itself, immediately after this.
        next if $version eq $self->{'defaultVersion'};

        $rs ||= $self->_startVersion( $version );
        next if $rs;

        eval {
            my $service = iMSCP::Service->getInstance();
            my $unit = sprintf( 'php%s-fpm', $version );

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

=item _pushVersion( $version )

 Override the PHP version for the build that is about to happen

 Return void

=cut

sub _pushVersion
{
    my ($self, $version) = @_;

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

    return if $version eq $self->{'defaultVersion'};

    $self->{'phpConfig'}->{'PHP_VERSION'} = $version;
    $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} = $self->_confDir( $version );
    $self->{'phpConfig'}->{'PHP_FPM_POOL_DIR_PATH'} = $self->_poolDir( $version );
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

=item _recordApplied( \%row, \%data, $version )

 Remember where a vhost was built, so that the next move knows what to sweep

 A vhost on the default version with no row of its own stays that way: a row is
 only created once a customer has actually chosen something.

 Return int 0 on success, other on failure

=cut

sub _recordApplied
{
    my ($self, $row, $data, $version) = @_;

    return 0 unless $row;
    return 0 if $row->{'applied_version'} eq $version && $row->{'status'} eq 'ok';

    my $qrs = $self->{'db'}->doQuery(
        'dummy',
        "UPDATE php_version SET applied_version = ?, status = 'ok' WHERE php_version_id = ?",
        $version, $row->{'php_version_id'}
    );
    unless ( ref $qrs eq 'HASH' ) {
        error( $qrs );
        return 1;
    }

    0;
}

=item _removePool( $version, $domainName )

 Remove one vhost's pool file from one version's pool directory

 Return int 0 on success, other on failure

=cut

sub _removePool
{
    my ($self, $version, $domainName) = @_;

    my $pool = $self->_poolDir( $version ) . "/$domainName.conf";
    return 0 unless -f $pool;

    iMSCP::File->new( filename => $pool )->delFile();
}

=item _confDir( $version )

 The configuration directory of the given PHP version

 Derived from the directory i-MSCP found for its own version rather than
 assumed, so that the two cannot disagree about where PHP lives.

 Return string

=cut

sub _confDir
{
    my ($self, $version) = @_;

    dirname( $self->{'phpConfig'}->{'PHP_CONF_DIR_PATH'} ) . "/$version";
}

=item _poolDir( $version )

 The FPM pool directory of the given PHP version

 Return string

=cut

sub _poolDir
{
    my ($self, $version) = @_;

    $self->_confDir( $version ) . '/fpm/pool.d';
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
        $rs ||= $self->_syncPhpConf( $version ) unless exists $known->{$version};
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

=item _syncPhpConf( $version )

 Give one version the same php.ini, php-fpm.conf and default pool that i-MSCP
 built for its own version

 Return int 0 on success, other on failure

=cut

sub _syncPhpConf
{
    my ($self, $version) = @_;

    return 0 if $version eq $self->{'defaultVersion'};
    return 0 unless $self->{'config'}->{'sync_php_conf'};

    my $confDir = $self->_confDir( $version );
    return 0 unless -d "$confDir/fpm";

    my $httpd = $self->{'httpd'};

    $httpd->setData( {
        HTTPD_USER                          => $httpd->{'config'}->{'HTTPD_USER'},
        HTTPD_GROUP                         => $httpd->{'config'}->{'HTTPD_GROUP'},
        PEAR_DIR                            => $self->{'phpConfig'}->{'PHP_PEAR_DIR'},
        PHP_CONF_DIR_PATH                   => $confDir,
        PHP_FPM_POOL_DIR_PATH               => $self->_poolDir( $version ),
        PHP_FPM_LOG_LEVEL                   => $self->{'phpConfig'}->{'PHP_FPM_LOG_LEVEL'} || 'error',
        PHP_FPM_EMERGENCY_RESTART_THRESHOLD => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_THRESHOLD'} || 10,
        PHP_FPM_EMERGENCY_RESTART_INTERVAL  => $self->{'phpConfig'}->{'PHP_FPM_EMERGENCY_RESTART_INTERVAL'} || '1m',
        PHP_FPM_PROCESS_CONTROL_TIMEOUT     => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_CONTROL_TIMEOUT'} || '60s',
        PHP_FPM_PROCESS_MAX                 => $self->{'phpConfig'}->{'PHP_FPM_PROCESS_MAX'} // 0,
        PHP_FPM_RLIMIT_FILES                => $self->{'phpConfig'}->{'PHP_FPM_RLIMIT_FILES'} // 4096,
        PHP_VERSION                         => $version,
        TIMEZONE                            => $::imscpConfig{'TIMEZONE'},
        PHP_OPCODE_CACHE_ENABLED            => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_ENABLED'},
        PHP_OPCODE_CACHE_MAX_MEMORY         => $self->{'phpConfig'}->{'PHP_OPCODE_CACHE_MAX_MEMORY'}
    } );

    my $tplDir = $httpd->{'phpCfgDir'};
    my $rs = $httpd->buildConfFile( "$tplDir/fpm/php.ini", {}, {
        destination => "$confDir/fpm/php.ini"
    } );
    $rs ||= $httpd->buildConfFile( "$tplDir/fpm/php-fpm.conf", {}, {
        destination => "$confDir/fpm/php-fpm.conf"
    } );
    $rs ||= $httpd->buildConfFile( "$tplDir/fpm/pool.conf.default", {}, {
        destination => $self->_poolDir( $version ) . '/www.conf'
    } );

    $httpd->flushData();
    $rs;
}

=item _startVersion( $version )

 Make sure one PHP-FPM service is unmasked, enabled and running

 i-MSCP stops and masks every version but its own during setup, so a version a
 customer picks has to be brought back up before its pool can serve anything.

 Return int 0 on success, other on failure

=cut

sub _startVersion
{
    my ($self, $version) = @_;

    return 0 if $version eq $self->{'defaultVersion'};

    local $@;
    eval {
        my $service = iMSCP::Service->getInstance();
        my $unit = sprintf( 'php%s-fpm', $version );

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

=item _startVersionsInUse( )

 Bring up the FPM service of every version a domain has been given

 Return int 0 on success, other on failure

=cut

sub _startVersionsInUse
{
    my ($self) = @_;

    my $rows = $self->{'db'}->doQuery(
        'php_version',
        "SELECT DISTINCT php_version FROM php_version WHERE php_version <> ''"
    );
    unless ( ref $rows eq 'HASH' ) {
        error( $rows );
        return 1;
    }

    my %installed = map { $_ => 1 } @{ $self->_installedVersions() };
    my $rs = 0;

    for my $version ( keys %{ $rows } ) {
        next unless $installed{$version};
        $rs ||= $self->_startVersion( $version );
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
