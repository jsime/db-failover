#!/usr/bin/env perl

Failover->new()->run();

exit;

package Failover;

=head1 NAME

failover.pl - script to automate PostgreSQL failover.

=head1 SYNOPSIS

This script is designed to assist with OmniPITR-enabled PostgreSQL cluster failover. Given a
configuration which defines your hosts and PostgreSQL configurations, it is possible to
automate much of the process of IP takeover, promotion of replicating clusters to full
read-write mode, initiation of master backups that can be used to stand up a new replicating
host, and test various aspects of your environment.

Once configured, operation is fairly straightforward. You simply specify which hosts to
promote to read-write, which to remote to replication, and which you want to take full
backups of.

    failover.pl --promote host1 --demote host2 --demote host3 --backup host1

=head1 ACTIONS

Command line arguments to failover.pl are broken down into two groups: Actions and Options.
Actions determine what (and to which systems) failover.pl will do. Options determine how
those actions will be done and what kind of prompting or failure handling will be
performed.

The actions are detailed below. If more than one action is provided for a single
invocation of failover.pl, they will be performed in the order shown here, so that you
may safely promote, demote, and backup in a single with minimal to no downtime (actual
downtime will depend on the speed of the IP takeover, and your applications' ability
to reestablish connections to the database cluster).

=over 4

=item * Promotion

    failover.pl --promote <host>

Promoting a host will turn off replication, placing the specified host back into master
read-write operation, perform an IP takeover on the host. Once completed, the host will be
a fully functioning master database. Currently, only one host may be promoted in a single
run.

=item * Demotion

    failover.pl --demote <host>

Demoting will result in the specified host switching to recovery mode, replicating from
the configured master (and falling back on the configured WAL archive segments), as per
standard OmniPITR procedures. Multiple hosts may be demoted in a single run. Additionally,
your current master database may be demoted, without specifying a new host to take over,
but this is not recommended (for reasons which should be obvious).

=item * Backup

    failover.pl --backup <host>

Issuing the backup action for a host will cause a new full database backup to be
performed, using the omnipitr-master-backup program. This operation can potentially
take quite some time, depending on the size of your database cluster. The backup
produced will be suitable for standing up a new replicant.

=item * Test

    failover.pl --test

A special short-circuiting action which will preclude the use of any other actions (backup,
demote, and promote). This action causes failover.pl to test its entire configuration, as
well as connectivity to remote hosts. Connections over SSH and C<psql> will be made to
every host in the configuration (as appropriate) to verify their status. Hosts will be
checked for OmniPITR installations and PostgreSQL clusters. No modifications to any
systems will be made.

=back

=head1 OPTIONS

The following options modify the behavior of multiple actions, or overall script
behavior.

=over 4

=item * --config <file> | -c <file>

Specifies a configuration file to be used. This file, detailed in the L<CONFIGURATION>
section later, defines all hosts, IP addresses, backup targets, and global settings. By
default, failover.pl will use the first of the following files that exists and is readable:

    $scriptdir/failover.ini
    ~/failover.ini
    /etc/db-failover/failover.ini

=item * --dry-run | -d

Indicates that all steps of given actions should be processed, but no changes should
be made to any systems or database clusters. SSH connections will be made to remote hosts,
but all steps requiring modifications will simulate successful operations.

=item * --exit-on-error | -e

Will cause failover.pl to immediately exit upon any error condition. Default behavior is
to prompt the operator on whether to proceed, despite the error. This will preclude that
ability and any requested actions will need to be performed from scratch after addressing
whatever caused the reported error.

=item * --skip-confirmation | -s

This option will have failover.pl assume "Yes" to all prompts normally displayed to the
operator. This includes prompts which may be indicating an error occured (assuming you
have not also used --exit-on-error).

=item * --verbose | -v

May be used multiple times to increase the amount of output produced by failover.pl

=item * --help | -h

Displays the built-in help messages and terminates the script (even if actions are
given on the command line).

=back

=head1 CONFIGURATION

Configuration of failover.pl is done via a single INI file. This file should contain
details to connect to every host in the replication set, where to find certain programs
involved in failover management, queries that can be run to verify database connectivity,
shared IP addresses, and backup destinations.

=head2 Sections

The configuration file is broken down into multiple sections.

=over 4

=item * [common]

The [common] section can
be used to define a setting once for all other sections (or at least those that use the
particular setting). Any settings in the [common] section can be overridden in any of
the host-specific sections. Thus, if all of your PostgreSQL hosts listen on port 5432,
except for host-snowflake, you can define C<pg-port> in [common] as 5432, and C<pg-port>
in [host-snowflake] as 9876.

=item * [shared-ip]

Valid settings: C<host>

Defines the address (name or IP) used by the currently-active master database cluster.
Checks which require verification of database connectivity will use the host when
running the psql command.

=item * [host-XYZ]

Valid settings: C<host>, C<database>, C<user>, C<pg-data>, C<pg-conf>, C<pg-restart>,
C<pg-recovery>, C<pg-reload>, C<pg-start>, C<pg-stop>, C<pg-user>, C<pg-port>, C<omnipitr>,
C<interface>, C<method>, C<trigger-file>, C<timeout>

Each [host-*] section defines a member of the potential PostgreSQL replication set. The
section may be repeated any number of times, where the XYZ above is replaced by the name
you would like to use to refer to the host. It may be any arbitrary string composed of
the character class [a-z0-9_-]. The names must be unique.

=item * [backup-XYZ]

Valid settings: C<host>, C<user>, C<path>, C<tempdir>, C<dstbackup>

Defines a host which is used as a backup target. Settings used to run omnipitr-master-backup
to produce full-backups using rsync-over-ssh, as well as configure a -dr target for
omnipitr-archive for ongoing WAL archiving.

Backup target section naming follows the same rules as host sections.

If you wish to use a local path as the backup destination (e.g. your backup server already
exports the target directory over NFS or similar, and thus no scp/rsync is needed), then
your [backup] section should not define a host. If only the path is defined, it is
assumed to be accessible via the host on which this program is running.

If you have a host defined in your [common] section (which will be inherited by the
[backup] section), you may define an empty-string host value in [backup] to force the
use of a local path.

=item * [data-check-XYZ]

Valid settings: C<query>, C<result>, C<timeout>

Data checks are queries used to verify connectivity to a database host, and proper operation
of PostgreSQL (at least to a minimum level of operation). Each data-check requires a query
to run, and the expected return value against which the query's output will be compared.
Thus, if you have a data-check which calls a function/procedure in your database, that
function must be immutable. As such, a data-check with the query "select now()" is unsuitable
for use with failover.pl, since you cannot include a result setting in the configuration
which will match that at all times. However, a data-check of
"select now() > now() - interval '1 day'" and a result setting of "t" would work just fine,
as a properly-functioning PostgreSQL will always return the boolean "t".

Naming of data-check sections follow the same rules as host sections.

=back

=head2 Settings

The following is a list of every setting name possible, across all configuration sections,
and what the setting is used for.

=over 4

=item * database

Name of the database in a given host's PostgreSQL cluster.

=item * dstbackup

Path supplied to omnipitr-backup-master as the -x argument. Defines the directory used for
WAL segment archiving. This setting should mirror whatever has been used when configuring
omnipitr-archive's dst-backup.

Defaults to $tempdir/dstbackup if not defined.

=item * host

Hostname to which connections will be made. Depending on the context, these connections may
be over SSH, rsync, or using psql to connect to PostgreSQL directly.

=item * interface

Network interface to be used for the shared IP. Must be the full name of the interface as
required by whatever method defined in the C<method> setting. E.g. On Linux machines
using a single alias on the first physical interface and using the ifup/ifdown commands,
your value for this setting would likely be "eth0:0".

=item * method

The method by which network interfaces will be activated and deactivated. Currently, the
only supported values here at "ifupdown" and "none" (the latter of which will perform a
no-op on IP takeover actions).

=item * omnipitr

The base path of the host's OmniPITR installation.

=item * path

Used for backup hosts, this is the path to which the master backup will be performed,
and the base directory used for WAL segment archiving.

=item * pg-conf

The full path of each host's postgresql.conf configuration file.

=item * pg-data

The base PGDATA path for each host.

=item * pg-port

The port on which PostgreSQL listens.

=item * pg-recovery

Path (relative to failover.pl base directory, or an absolute path) to the recovery.conf
file to be used on systems being demoted. The file should be specified in host sections
(or the common section), and it may be a path on the system from which you are running
failover.pl (in which case it will be scp'ed to the remote host), or it may be a path
on the remote host (in which case it will simply be cp'ed).

=item * pg-reload

Full system command necessary to send a -HUP signal to the running PostgreSQL postmaster
process.

=item * pg-restart

Full system command necessary to restart PostgreSQL.

=item * pg-start

Full system command necessary to cold start PostgreSQL.

=item * pg-stop

Full system command necessary to halt PostgreSQL.

=item * pg-user

Database username used to connect to a given host's PostgreSQL cluster.

=item * query

The SQL query issued to PostgreSQL hosts to verify proper database operation. Must
result in a consistent value. That value may be any string. It does not have to be
a single boolean value, though those are simplest to match against.

=item * result

The exact result expected from a data-check query, as defined by the C<query>
setting, and as formatted by psql (booleans become "t" or "f" and so on). Be careful
to ensure that you match any psqlrc settings you may have configured for the user
under which failover.pl is run (e.g. a local .psqlrc may define NULLs to appear as
some arbitrary string, say "NULLNULLNULL", and if your data-check query is intended
to return a NULL, that custom string is what you must match against).

=item * tempdir

Used to supply the value for omnipitr-backup-master's -t argument. Defines the temp
directory used during the backup procedure. This will default to /tmp if not
supplied.

=item * timeout

Timeout in seconds which will be used for various commands (connecting via SSH,
runing data-check queries, etc.).

=item * trigger-file

The full path to the trigger-file on a PostgreSQL host used to switch omnipitr-restore
from replication to master read-write mode.

=item * user

Username used to connect to hosts via SSH.

=back

=head1 SAMPLE CONFIGURATION

What follows is a fairly minimal configuration that defines three database servers, one
backup server, a shared IP intended to point to the current master database, and two
data-checks. Most of the options are the same across hosts, which allows them to occupy
space only in the common section.

    [common]
    database = foobar
    pg-port = 5432
    pg-user = baz
    pg-recovery = recovery.conf
    user = postgres
    interface = eth0:1
    method = ifupdown

    [shared-ip]
    host = db.internal.company.com

    [host-db1]
    host = db1.internal.company.com

    [host-db2]
    host = db2.internal.company.com

    [host-db3]
    host = db3.internal.company.com
    interface = eth1

    [backup]
    user = backups
    host = backup.internal.company.com
    path = /backups/database/foobar

    [data-check-interval]
    query = select now() > now() - interval '1 hour'
    result = t

    [data-check-numbers]
    query = select count(num) from generate_series(1,100,10) gs(num)
    result = 10

=head1 INTERNALS

The following sections are intended for developers working on failover.pl itself and
are not particularly relevant for end-users of the program.

This program is intended to be usable on a system with only Perl core modules
installed. Modifications to the program should maintain this if at all possible,
requiring no dependencies outside CORE.

=head2 Basic Structure

The failover.pl internals are subdivided into several packages. The primary package,
C<Failover>, contains the high-level command line parsing, and action dispatchers.

C<Failover::Config> contains methods relating to locating, reading, and interacting
with the failover.ini configuration (either the default, located automatically by
failover.pl, or a configuration file pointed to by the --config command line argument).

C<Failover::Action> contains methods that provide the actual functionality behind
host promotion, demotion, backup, and testing.

C<Failover::Command> contains methods for constructing, executing, and capturing the
output of any shell or psql commands that need to be run locally or remotely. Commands
objects are defined through chained-method invocation.

C<Failover::Utils> contains a number of convenience subroutines. Things like sorting
hostnames (while handling little details like host-10 coming after host-5), printing
confirmation prompts, log messages, errors, and so on.

=cut

use Data::Dumper;
use File::Basename;
use Getopt::Long;

use strict;
use warnings;

=head2 Package: Failover

Contains methods to handle command line arguments and running of supported actions.

=cut 

=head3 new

Constructor for the Failover class. Parses command line options and locates the
configuration file.

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;

    ($self->{'name'}, $self->{'base_dir'}) = fileparse(__FILE__);

    $self->{'options'} = {};
    GetOptions($self->{'options'},
        # general options
        'config|c=s',
        'dry-run|d!',
        'skip-confirmation!',
        'exit-on-error|e!',
        'test|t!',
        'verbose|v+',
        'help|h!',
        # primary actions
        'promote=s',
        'demote=s@',
        'backup=s@',
    );

    if (exists $self->{'options'}{'help'} && $self->{'options'}{'help'}) {
        print $self->usage;
        exit(0);
    }

    $self->{'config'} = exists $self->{'options'}{'config'}
        ? Failover::Config->new($self->{'base_dir'}, $self->{'options'}{'config'})
        : Failover::Config->new($self->{'base_dir'});

    return $self;
}

=head3 usage

Display of program usage information.

=cut

sub usage {
    my ($self) = @_;

    return <<EOU;
$self->{'name'} - Failover Management for OmniPITR-enabled PostgreSQL

Basic options, common to multiple actions.

  --config -c <file>    Alternate configuration file to use. Defaults
                        to failover.ini in the same directory as this
                        program.

  --dry-run -d          Goes through all the motions, but only echoes
                        commands instead of running them.

  --exit-on-error -e    Immediately abort program execution on error
                        conditions normally requiring confirmation to
                        continue, instead of prompting.

  --skip-confirmation   Do not wait for confirmation after displaying
                        configuration summary. Proceed directly to
                        specified action.

  --verbose -v          May be specified multiple times.

  --help -h             Display this message and exit.

Actions, more than one of which may be performed in a single run. They
will be run in the order shown here when multiple are specified.

  --promote <host>      Makes <host> the new master database, and
                        demotes any other host currently a master.
                        This can only be specified once, as it involves
                        the specified host taking over the shared IP.

  --demote <host>       Singles out <host> for demotion. May be
                        specified multiple times.

  --backup <host>       Performs a master backup (using OmniPITR's
                        tools) of the specified host. If a promotion
                        is done, and no --backup given, the promoted
                        host will be suggested for a backup.

Special Actions, which if specified will cause other actions to be
ignored.

  --test -t             Tests connectivity/logins to all systems in
                        the given configuration, and verify current
                        OmniPITR status. Implies --skip-confirmation
                        since it makes no modifications to any
                        systems.

EOU
}

=head3 run

Performs the requested actions. Short-circuits if running in test mode, otherwise it displays a
summary of the current configuration, prompts to continue, and then proceeds to run promotions, then
IP takeovers, then demotions, then backups. This order is done to minimize possible downtime.

The new master should already be promoted before it assumes the shared IP. Running the demotion(s)
after that also allows for the user to terminate the program should they encounter an error or
self-doubt. Prior to the demotion(s) running, they will still have their original master to fall
back on to (assuming the failover is being done as a planned event, that is).

Backup is performed last because, depending on the size of the database(s) being backed up, this
operation may take a significant amount of time.

=cut

sub run {
    my ($self) = @_;

    if ($self->test) {
        # if run with --test action, run through all the tests and exit before anything else can be done
        exit $self->test_setup;
    }

    $self->show_config;
    Failover::Utils::get_confirmation('Proceed with this configuration?') if !$self->skip_confirmation;

    # Run configuration/host tests to verify current operational status before performing any actions
    $self->test_setup;

    # Run through hosts to be promoted
    Failover::Action->promotion($self, $_) for Failover::Utils::sort_section_names($self->promote);

    # If we've made it past promotion, then take the last host from the list and allow it to take over
    # the shared IP (the list is, for now, only either 0 or 1 hosts long, but should --promote ever
    # allow multiple uses, I'd like this to at least not go completely bonkers with IP reassignments)
    my $new_ip_host = (Failover::Utils::sort_section_names($self->promote))[-1];
    Failover::Action->ip_takeover($self, $new_ip_host) if defined $new_ip_host;

    # Run through hosts to be demoted
    Failover::Action->demotion($self, $_) for Failover::Utils::sort_section_names($self->demote);

    # Hosts on which we should (or may) perform omnipitr-backup-master
    if ($self->backup && $self->backup > 0) {
        Failover::Action->backup($self, $_) for Failover::Utils::sort_section_names($self->backup);
    }
}

=head3 show_config

Wrapper around configuration summary display method from Failover::Config.

=cut

sub show_config {
    my ($self) = @_;

    $self->config->display(
        promotions => [$self->promote],
        demotions  => [$self->demote],
        backups    => [$self->backup],
    );
}

=head3 test_setup

Performs a configuration test, verifying that hosts defined in the configuration are all reachable
and have all the necessary software installed at the specified (or default) locations.

=cut

sub test_setup {
    my ($self) = @_;

    my $gen_cmd = Failover::Command->new('/bin/false');

    # Check for invalid IP takeover methods
    $gen_cmd->print_running('Verifying IP Takeover methods.');
    my @bad_methods;

    foreach my $host (Failover::Utils::sort_section_names($self->config->get_hosts)) {
        push(@bad_methods, $host) unless exists $self->config->section($host)->{'method'}
            && grep { $_ eq $self->config->section($host)->{'method'} } qw( none ifupdown );
    }

    if (scalar(@bad_methods) > 0) {
        $gen_cmd->print_fail('Invalid IP Takeover methods on hosts: ' . join(', ', @bad_methods));
        exit(1) if $self->exit_on_error;
        Failover::Utils::get_confirmation('Will be unable to perform IP takeover on some hosts. Proceed anyway?')
            unless $self->skip_confirmation;
    } else {
        $gen_cmd->print_ok();
    }

    # Ensure that the user is not trying to promote and demote any of the same systems
    my %promote_demote_overlap;
    foreach my $host ($self->promote) {
        $promote_demote_overlap{$_} = 1 for grep { $_ eq $host } $self->demote;
    }
    if (scalar(keys(%promote_demote_overlap)) > 0) {
        my $fmt_list = join(', ', ('%s') x scalar(keys(%promote_demote_overlap)));
        Failover::Utils::die_error("You are attempting to both promote and demote the following hosts: $fmt_list",
            Failover::Utils::sort_section_names(keys %promote_demote_overlap));
    }

    # Ping check Shared IP
    foreach my $host (Failover::Utils::sort_section_names($self->config->get_shared_ips)) {
        my $cmd = Failover::Command->new('ping -q -c 10 -i 0.2',$self->config->section($host)->{'host'})
            ->verbose($self->verbose)
            ->name(sprintf('Ping Test - %s', $host))
            ->run($self->dry_run);

        next if $cmd->status == 0;
        exit(1) if $self->exit_on_error;
        Failover::Utils::get_confirmation('Current Shared IP host failed ping check. Proceed anyway?')
            unless $self->skip_confirmation;
    }

    # PSQL Data Checks for Shared IPs
    foreach my $check (Failover::Utils::sort_section_names($self->config->get_data_checks)) {
        foreach my $host (Failover::Utils::sort_section_names($self->config->get_shared_ips)) {
            my $cmd = Failover::Command->new($self->config->section($check)->{'query'})
                ->verbose($self->verbose)
                ->name(sprintf('Data Check - %s - Host: %s', $check, $host))
                ->host($self->config->section($host)->{'host'})
                ->port($self->config->section($host)->{'pg-port'})
                ->user($self->config->section($host)->{'pg-user'})
                ->database($self->config->section($host)->{'database'})
                ->compare($self->config->section($check)->{'result'})
                ->psql->run($self->dry_run);

            next if $cmd->status == 0;
            exit(1) if $self->exit_on_error;
            Failover::Utils::get_confirmation('Data check failed. Proceed anyway?')
                unless $self->skip_confirmation;
        }
    }

    # Test SSH connectivity to all database hosts
    foreach my $host (Failover::Utils::sort_section_names($self->config->get_hosts)) {
        my $cmd = Failover::Command->new('/bin/true')->name(sprintf('Connectivity Test - %s', $host))
            ->verbose($self->verbose)
            ->host($self->config->section($host)->{'host'})
            ->user($self->config->section($host)->{'user'})
            ->ssh->run($self->dry_run);

        next if $cmd->status == 0;
        exit(1) if $self->exit_on_error;
        Failover::Utils::get_confirmation('Database host failed connectivity check. Proceed anyway?')
            unless $self->skip_confirmation;
    }

    # Test SSH connectivity to all backup hosts
    foreach my $host (Failover::Utils::sort_section_names($self->config->get_backups)) {
        # Backup target can be a remote host, or a local directory -- if there's a value
        # for the hostname, it's remote and we need to test SSH connectivity. Otherwise,
        # the path setting is just a local directory we need to ensure exists.
        my $cmd;
        if (exists $self->config->section($host)->{'host'} && length($self->config->section($host)->{'host'}) > 0) {
            $cmd = Failover::Command->new('/bin/true')->name(sprintf('Connectivity Test - %s', $host))
                ->verbose($self->verbose)
                ->host($self->config->section($host)->{'host'})
                ->user($self->config->section($host)->{'user'})
                ->ssh->run($self->dry_run);
        } else {
            $cmd = Failover::Command->new('test','-d',$self->config->section($host)->{'path'})->name(sprintf('Connectivity Test - %s', $host))
                ->verbose($self->verbose)
                ->host($self->config->section($host)->{'host'})
                ->user($self->config->section($host)->{'user'})
                ->run($self->dry_run);
        }

        next if $cmd->status == 0;
        exit(1) if $self->exit_on_error;
        Failover::Utils::get_confirmation('Backup host failed connectivity check. Proceed anyway?')
            unless $self->skip_confirmation;
    }

    my %dirchecks = (
        'pg-data'   => ['PostgreSQL Data Directory',undef],
        'pg-conf'   => ['PostgreSQL Configuration','postgresql.conf'],
        'omnipitr'  => ['OmniPITR Directory',undef],
    );

    # Test various directory locations on all hosts
    foreach my $host (Failover::Utils::sort_section_names($self->config->get_hosts)) {
        foreach my $dirname (qw( pg-data pg-conf omnipitr)) {
            my $setting = $self->config->section($host)->{$dirname} || undef;
            Failover::Utils::die_error('Setting %s not defined for Host %s.', $dirname, $host)
                unless defined $setting;

            my $cmd = Failover::Command->new('ls',$setting . '/' . ($dirchecks{$dirname}[1] || ''))
                ->name(sprintf('Check %s for %s', $host, $dirchecks{$dirname}[0]))
                ->verbose($self->verbose)
                ->host($self->config->section($host)->{'host'})
                ->user($self->config->section($host)->{'user'})
                ->ssh->run($self->dry_run);

            next if $cmd->status == 0;
            exit(1) if $self->exit_on_error;
            Failover::Utils::die_error('%s could not be located at %s on host %s', $dirchecks{$dirname}[0],
                $setting, $host);
        }
    }
}

=head3 config

Returns the Failover object's reference to the Failover::Config object.

=cut

sub config {
    my ($self) = @_;
    return $self->{'config'} if exists $self->{'config'};
    return;
}

=head3 demote

Returns the list of hosts marked for demotion, as provided on failover.pl's command line.

=cut

sub demote {
    my ($self) = @_;

    my @hosts;

    @hosts = ($self->{'options'}{'demote'}) if exists $self->{'options'}{'demote'};
    @hosts = @{$self->{'options'}{'demote'}} if exists $self->{'options'}{'demote'}
        && ref($self->{'options'}{'demote'}) eq 'ARRAY';

    return unless scalar(@hosts) > 0;
    return map { $_ =~ m{^host} ? $_ : "host-$_" } @hosts;
}

=head3 promote

Returns the list of hosts marked for promotion, as provided on failover.pl's command line.

=cut

sub promote {
    my ($self) = @_;

    my @hosts;

    @hosts = ($self->{'options'}{'promote'}) if exists $self->{'options'}{'promote'};

    return unless scalar(@hosts) > 0;
    return map { $_ =~ m{^host} ? $_ : "host-$_" } @hosts;
}

=head3 promote

Returns the list of hosts marked for backup, as provided on failover.pl's command line.

=cut

sub backup {
    my ($self) = @_;

    my @hosts;

    @hosts = ($self->{'options'}{'backup'}) if exists $self->{'options'}{'backup'}
        && $self->{'options'}{'backup'} =~ m{\w}o;
    @hosts = @{$self->{'options'}{'backup'}} if exists $self->{'options'}{'backup'}
        && ref($self->{'options'}{'backup'}) eq 'ARRAY';

    return unless scalar(@hosts) > 0;
    return map { $_ =~ m{^host} ? $_ : "host-$_" } @hosts;
}

=head3 dry_run

Returns a boolean representing whether this is a dry-run, or not. Should it return true,
no modifications should be made to any systems. Default is false, but can be enabled with
command line argument --dry-run.

=cut

sub dry_run {
    my ($self) = @_;

    return $self->{'options'}{'dry-run'} if exists $self->{'options'}{'dry-run'};
    return 0;
}

=head3 exit_on_error

Returns a boolean representing whether the program should terminate on error conditions.
Default is false, but can be true if --exit-on-error was passed on command line.

=cut

sub exit_on_error {
    my ($self) = @_;

    return $self->{'options'}{'exit-on-error'} if exists $self->{'options'}{'exit-on-error'};
    return 0;
}

=head3 skip_confirmation

Returns a boolean representing whether the program should prompt the user to confirm something
before proceeding. Default is false, but will be true if --skip-confirmation was provided.

=cut

sub skip_confirmation {
    my ($self) = @_;

    return $self->{'options'}{'skip-confirmation'} if exists $self->{'options'}{'skip-confirmation'};
    return 0;
}

=head3 test

Returns a boolean representing whether the Test action was requested. Default is false, but
will be true if --test was provided on the command line.

=cut

sub test {
    my ($self) = @_;

    return $self->{'options'}{'test'} if exists $self->{'options'}{'test'};
    return 0;
}

=head3 verbose

Returns an integer value representing the level of verbosity requested. Defaults to 0, but
can be as high as the number of times --verbose/-v were specified on the command line.

=cut

sub verbose {
    my ($self) = @_;

    return $self->{'options'}{'verbose'} if exists $self->{'options'}{'verbose'};
    return 0;
}


package Failover::Action;

use strict;
use warnings;

=head2 Package: Failover::Action

Methods encapsulating the logic of actions provided by failover.pl. Individual steps taken
during promotion, demotion, and backup and detailed and managed within this package.

=cut 

=head3 ip_takeover

Class method used to issue commands on a remote server, dependent upon the specific host
configuration, to activate an appropriate interface for the shared IP. This method will
attempt to call the C<ip_yield> on all other hosts to ensure that only one machine is
attempting to lay claim to the shared address at any given time. It is not necessary to
call the yield method directly, except in circumstances where you may wish to specifically
disable an interface on a host without also activating the shared address interface
on another.

=cut

sub ip_takeover {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);

    if (!defined $host_cfg) {
        Failover::Utils::print_error('Invalid host %s given for Shared IP takover.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Proceed anyway?') if !$failover->skip_confirmation;
        return 0;
    }

    foreach my $key (qw( method interface )) {
        if (!exists $host_cfg->{$key}) {
            Failover::Utils::print_error('IP Takeover %s for %s is missing.', $key, $host);
            exit(1) if $failover->exit_on_error;
            Failover::Utils::get_confirmation('Unable to perform IP takeover on this host. Proceed anyway?')
                if !$failover->skip_confirmation;
            return 0;
        }
    }

    if (scalar(grep { $host_cfg->{'method'} eq $_ } qw( none ifupdown )) < 1) {
        Failover::Utils::print_error('IP Takeover method for %s is invalid.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Unable to perform IP takeover on this host. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    # get all hosts other than the one taking over the shared IP, as we need to ensure
    # none of them continue to think they should have it
    foreach my $yield_host (grep { $_ ne $host } $failover->config->get_hosts) {
        Failover::Action->ip_yield($failover, $yield_host);
    }

    # Now that IP should no longer be claimed by anyone else, attempt to take it over on
    # the requested host.
    return 1 if $host_cfg->{'method'} eq 'none';

    my $cmd;

    if ($host_cfg->{'method'} eq 'ifupdown') {
        $cmd = Failover::Command->new(cmd_ifupdown('up', $host_cfg->{'interface'}));
    }

    if (!defined $cmd) {
        Failover::Utils::print_error('IP Takeover method for %s is invalid.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Unable to perform IP takeover on this host. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    $cmd->name(sprintf('Starting up interface %s on %s.', $host_cfg->{'interface'}, $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->sudo(1)
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Interface was not enabled properly. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    # update system configuration, if appropriately configured and a supported OS,
    # to enable this interface on reboot
    if (!interface_activate($host_cfg)) {
        Failover::Utils::print_error("Unable to mark interface %s as permanently active on %s.\n",
            $host_cfg->{'interface'}, $host_cfg->{'host'});
        Failover::Utils::get_confirmation('This is not treated as a fatal error, but you are advised to resolve this to prevent the shared IP from being unreachable should this host reboot while still the primary system.');
    }

    return 1;
}

=head3 ip_yield

Method for disabling the interface responsible for listening on the shared address's IP. This
method is called by C<ip_takeover> automatically and generally does not need to be called
directly.

=cut

sub ip_yield {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);

    if (!defined $host_cfg) {
        Failover::Utils::print_error('Invalid host %s given for Shared IP yield.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Proceed anyway?') if !$failover->skip_confirmation;
        return 0;
    }

    foreach my $key (qw( method interface )) {
        if (!exists $host_cfg->{$key}) {
            Failover::Utils::print_error('IP Yield %s for %s is missing.', $key, $host);
            exit(1) if $failover->exit_on_error;
            Failover::Utils::get_confirmation('Unable to perform IP yield on this host. Proceed anyway?')
                if !$failover->skip_confirmation;
            return 0;
        }
    }

    if (scalar(grep { $host_cfg->{'method'} eq $_ } qw( none ifupdown )) < 1) {
        Failover::Utils::print_error('IP Takeover/Yield method for %s is invalid.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Unable to perform IP yield on this host. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    return 1 if $host_cfg->{'method'} eq 'none';

    my $cmd;

    if ($host_cfg->{'method'} eq 'ifupdown') {
        $cmd = Failover::Command->new(cmd_ifupdown('down', $host_cfg->{'interface'}));
    } # with room left for other interface methods in the future

    if (!defined $cmd) {
        Failover::Utils::print_error('IP Takeover/Yield method for %s is invalid.', $host);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Unable to perform IP yield on this host. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    $cmd->name(sprintf('Shutting down interface %s on %s.', $host_cfg->{'interface'}, $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->sudo(1)
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Interface was not shut down properly. Proceed anyway?')
            if !$failover->skip_confirmation;
        return 0;
    }

    # update system configuration, if appropriately configured and a supported OS,
    # to prevent this interface from being enabled on reboot (otherwise it will try to
    # reclaim the shared IP and cause problems)
    if (!interface_deactivate($host_cfg)) {
        Failover::Utils::print_error("Unable to mark interface %s as permanently inactive on %s.\n",
            $host_cfg->{'interface'}, $host_cfg->{'host'});
        Failover::Utils::get_confirmation('This is not treated as a fatal error, but you are advised to resolve this to prevent IP conflicts if this host reboots.');
    }

    return 1;
}

=head3 backup

Action method to issue commands necessary to perform a full master backup on a PostgreSQL
host server. The time required for this action depends entirely on the size of the database
cluster, the network speed between it and the backup host, and the write speed of the disks
on the backup target. The actual backup is performed by OmniPITR; this method is merely a
wrapper around that program.

=cut

sub backup {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    Failover::Utils::die_error('Invalid host %s given for backup.', $host) unless defined $host_cfg;

    return unless Failover::Utils::prompt_user(
        sprintf('Performing a master backup on %s may take a while. Proceed?', $host));

    my @cmd_remotes;

    foreach my $backup_host ($failover->config->get_backups) {
        my $backup_cfg = $failover->config->section($backup_host);
        next unless defined $backup_cfg;

        if (exists $backup_cfg->{'host'} && $backup_cfg->{'host'} =~ m{\w}o) {
            push(@cmd_remotes,
                '-dr', sprintf('gzip=%s:%s', $backup_cfg->{'host'}, $backup_cfg->{'path'}),
                '-t',  $backup_cfg->{'tempdir'},
                '-x',  $backup_cfg->{'dstbackup'},
            );
        } else {
            push(@cmd_remotes,
                '-dl', $backup_cfg->{'path'},
                '-t',  $backup_cfg->{'tempdir'},
                '-x',  $backup_cfg->{'dstbackup'},
            );
        }
    }

    return unless scalar(@cmd_remotes) > 0;

    my $cmd = Failover::Command->new('/opt/omnipitr/bin/omnipitr-backup-master',
            '-D',         $host_cfg->{'pg-data'},
            '-U',         $host_cfg->{'pg-user'},
            '-f',         '__HOSTNAME__-__FILETYPE__-^Y-^m-^d.tar__CEXT__',
            '--log',      sprintf('%s/omnipitr-master-backup-^Y-^m-^d-^H^M^S.log', $host_cfg->{'omnipitr'}),
            '--pid-file', sprintf('%s/backup-master.pid', $host_cfg->{'omnipitr'}),
            @cmd_remotes
        )
        ->name(sprintf('Creating New Master Backup - %s', $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        Failover::Utils::print_error("OmniPITR Master Backup failed on %s.\n%s", $host, $cmd->stderr);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Proceed anyway?') if !$failover->skip_confirmation;
    }
}

=head3 demotion

This action issues the commands necessary to demote a read-write database host to a replicant
state, using OmniPITR. Demoting a host does not, on its own, release the shared IP. Thus, if the
failover.pl script is run with nothing but a --demote <host> then no changes will be made in where
the shared address points. Only a --promote will alter network settings on remote hosts.

Issuing a demotion will cause failover.pl to attempt to locate the most recent master backup,
restore from that, and then enter continuous recovery mode against the configured backup host's
WAL segments. Under the hood, these replication services are handled by the core PostgreSQL
configuration and OmniPITR's tools.

=cut

sub demotion {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    Failover::Utils::die_error('Invalid host %s given for demotion.', $host) unless defined $host_cfg;

    my $check_cfg = $failover->config->section(($failover->config->get_data_checks())[0]);
    Failover::Utils::die_error('Could not locate a data check in the configuration to test demotion.')
        unless defined $check_cfg;

    my ($cmd);

    # stop postgresql (or prompt user if no pg-stop command defined)
    if (exists $host_cfg->{'pg-stop'}) {
        $cmd = Failover::Command->new($host_cfg->{'pg-stop'})
            ->name(sprintf('Stopping PostgreSQL on %s', $host))
            ->verbose($failover->verbose)
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'})
            ->sudo(1)
            ->ssh->run($failover->dry_run);

        if ($cmd->status != 0) {
            Failover::Utils::print_error("An error was encountered stopping PostgreSQL on %s.\n%s",
                $host, $cmd->stderr);
            exit(1) if $failover->exit_on_error;
            Failover::Utils::prompt_user('Please resolve this issue and stop PostgreSQL before proceeding.');
        }
    } else {
        Failover::Utils::prompt_user(sprintf('No pg-stop command defined for %h. Please stop PostgreSQL manually.', $host));
    }

    # check that postmaster is not running (prompt to continue or retest if it is)
    retry_check($failover, sub { check_postmaster_offline($failover, $host) });

    # archive current datadir if non-empty
    $cmd = Failover::Command->new(qw( du -s ), $host_cfg->{'pg-data'}, qw( | awk ), "'{ print \$1 }'")
        ->name(sprintf('Verifying empty datadir on %s.', $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->compare("0")
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        $cmd = Failover::Command->new(
                qw( tar cf ),
                sprintf('%s.%04d-%02d-%02d.tar', $host_cfg->{'pg-data'},
                    (localtime())[5] + 1900,
                    (localtime())[4] + 1,
                    (localtime())[3]),
                $host_cfg->{'pg-data'}
            )
            ->name(sprintf('Archiving existing datadir on %s.', $host))
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'})
            ->ssh->run($failover->dry_run);
    }

    # restore from latest data backup
    my %backup = latest_base_backup($failover);
    my $backup_cfg = $failover->config->section($backup{'host'});

    if ($backup_cfg->{'host'}) {
        $cmd = Failover::Command->new('rsync', '-q',
                sprintf('%s@%s:%s', $backup_cfg->{'user'}, $backup_cfg->{'user'}, $backup{'file'}),
                sprintf('%s/base_restore.tar.gz', $host_cfg->{'omnipitr'})
            )
            ->name(sprintf('Copying latest base backup from host %s.', $backup{'host'}))
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'})
            ->ssh->run($failover->dry_run);
        exit(1) if $failover->exit_on_error && $cmd->status != 0;
    } else {
        $cmd = Failover::Command->new('cp',
                $backup{'file'},
                sprintf('%s/base_restore.tar.gz', $host_cfg->{'omnipitr'}))
            ->name(sprintf('Copying latest base backup from host %s.', $backup{'host'}))
            ->run($failover->dry_run);
        exit(1) if $failover->exit_on_error && $cmd->status != 0;
    }

    $cmd = Failover::Command->new(qw( tar -x -z -C ), $host_cfg->{'pg-data'},
            '-f', sprintf('%s/base_restore.tar.gz', $host_cfg->{'omnipitr'})
        )
        ->name(sprintf('Restoring base backup to host %s.', $host))
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'});
    $cmd->ssh if $host_cfg->{'host'};
    $cmd->run($failover->dry_run);
    exit(1) if $failover->exit_on_error && $cmd->status != 0;

    # add recovery.conf from pg-recovery configuration path, if defined, otherwise
    # prompt user to put the file into place before we proceed with bringing up PG
    if (exists $host_cfg->{'pg-recovery'}) {
        if (my $recovery = locate_recovery_conf($failover, $host_cfg)) {
            if ($recovery->{'remote'}) {
                $cmd = Failover::Command->new('cp',
                        $recovery->{'path'},
                        sprintf('%s/recovery.conf', $host_cfg->{'pg-data'}))
                    ->name(sprintf('Copying recovery.conf on remote host %s', $host_cfg->{'host'}))
                    ->verbose($failover->verbose)
                    ->host($host_cfg->{'host'})
                    ->port($host_cfg->{'port'})
                    ->user($host_cfg->{'user'})
                    ->ssh->run($failover->dry_run);
            } else {
                $cmd = Failover::Command->new('cp',
                        $recovery->{'path'},
                        sprintf('%s/recovery.conf', $host_cfg->{'pg-data'}))
                    ->name(sprintf('Copying recovery.conf on local host %s', $host_cfg->{'host'}))
                    ->verbose($failover->verbose)
                    ->run($failover->dry_run);
            }

            if ($cmd->status != 0) {
                Failover::Utils::print_error("Could not place recovery.conf into the data-dir for host %s.\n", $host);
                exit(1) if $failover->exit_on_error;
                return 0;
            }
        } else {
            Failover::Utils::print_error("Could not locate the specified recovery.conf file %s for host %s.\n",
                $host_cfg->{'pg-recovery'}, $host);
            exit(1) if $failover->exit_on_error;
            return 0;
        }
    } else {
        Failover::Utils::prompt_user(sprintf('No pg-recovery defined for %s. Place a recovery.conf file in %s on %s before proceeding.',
            $host, $host_cfg->{'pg-data'}, $host));
    }

    # start postgresql (by prompting user to do so if there is no pg-start command in the config)
    if (exists $host_cfg->{'pg-start'}) {
        $cmd = Failover::Command->new($host_cfg->{'pg-start'})
            ->name(sprintf('Starting PostgreSQL on %s', $host))
            ->verbose($failover->verbose)
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'})
            ->sudo(1);
        $cmd->ssh if $host_cfg->{'host'};
        $cmd->run($failover->dry_run);

        if ($cmd->status != 0) {
            Failover::Utils::print_error("An error was encountered starting PostgreSQL on %s.\n%s",
                $host, $cmd->stderr);
            exit(1) if $failover->exit_on_error;
            Failover::Utils::prompt_user('Please resolve this issue and start PostgreSQL before proceeding.');
        }
    } else {
        Failover::Utils::prompt_user(sprintf('No pg-start command defined for %h. Please start PostgreSQL manually.', $host));
    }

    # connect and run test query
    $cmd = Failover::Command->new($check_cfg->{'query'})
        ->name(sprintf('Verifying PostgreSQL operating on %s', $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->database($host_cfg->{'database'})
        ->port($host_cfg->{'pg-port'})
        ->user($host_cfg->{'pg-user'})
        ->psql->run($failover->dry_run);
    exit(1) if $failover->exit_on_error && $cmd->status != 0;

    # demotion complete - prompt user to ensure that virtual IP's interface is not configured
    # to activate on reboot
    Failover::Utils::prompt_user(sprintf('Please ensure the virtual IP interface %s on %s *is not* configured to activate on boot.', $host_cfg->{'interface'}, $host));
}

=head3 promotion

The promotion action creates the trigger file on a remote host to indicate to OmniPITR and
PostgreSQL that they should exit recovery mode and enter full read-write operation. It will
then repeatedly check (until the timeout expires) that it is able to perform a modifying DML
statement against the host's database (creation of a temp table called failover_check)
before reporting a successful promotion.

=cut

sub promotion {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    Failover::Utils::die_error('Invalid host %s given for promotion.', $host) unless defined $host_cfg;

    my $backup_cfg = $failover->config->section('backup');
    Failover::Utils::die_error('Could not locate a backup server configuration.') unless defined $backup_cfg;

    Failover::Utils::die_error('No OmniPITR trigger file path provided for %s.', $host)
        unless exists $host_cfg->{'trigger-file'};

    # Create trigger file for OmniPITR to finish WAL recovery mode
    my $cmd = Failover::Command->new('touch', $host_cfg->{'trigger-file'})
        ->name(sprintf('Promotion trigger file - %s', $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        Failover::Utils::print_error("Failed to create promotion trigger file on %s.\n%s", $host, $cmd->stderr);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Proceed anyway?') if !$failover->skip_confirmation;
    }

    my $timeout = time() + ($host_cfg->{'timeout'} || 60);
    $cmd = Failover::Command->new('create temp table failover_check ( i int4 )')
        ->name(sprintf('Verification of %s PostgreSQL in R/W mode', $host))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'pg-port'})
        ->database($host_cfg->{'database'})
        ->user($host_cfg->{'pg-user'})
        ->psql;

    do {
        $cmd->run($failover->dry_run);
        sleep 3;
    } while ($cmd->status != 0 && time() < $timeout);

    if ($cmd->status != 0) {
        Failover::Utils::print_error("Could not promote PostgreSQL on %s.\n%s", $host, $cmd->stderr);
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation('Proceed anyway?') if !$failover->skip_confirmation;
    }

    # promotion complete - remind user to configure virtual IP interface to activate on boot
    Failover::Utils::prompt_user(sprintf('Please ensure the virtual IP interface %s on %s *is* configured to activate on boot.', $host_cfg->{'interface'}, $host));

    return 1;
}

=head3 retry_check

Wrapper function to issue a command, and on failure prompt the user as to whether to immediately
attempt the same again, or terminate operation.

=cut

sub retry_check {
    my ($failover, $check_sub, $prompt) = @_;

    my $r;

    while (($r = &$check_sub) != 1) {
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation($prompt || 'Would you like to retry this action?')
            if !$failover->skip_confirmation;
    }

    return $r;
}

=head3 cmd_ifupdown

Returns a formatted interface activation/deactivation command to be issued on a remote
host. Used during IP takeovers and yields.

=cut

sub cmd_ifupdown {
    my ($direction, $interface) = @_;

    Failover::Utils::die_error('Interface command requires a new state, and an interface name')
        unless defined $direction && defined $interface && $interface =~ m{\w}o;
    Failover::Utils::die_error('Invalid interface state %s provided.', $direction)
        unless grep { $_ eq $direction } qw( up down );

    return (sprintf('if%s', $direction), $interface);
}

=head3 check_wal_status

Attempts to locate active WAL archiving  on a remote host.

=cut

sub check_wal_status {
    my ($failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    my $pgconf_file = $host_cfg->{'pg-conf'} . '/postgresql.conf';

    my $cmd = Failover::Command->new(qw( ls -l ),$pgconf_file)
        ->name('Locating WAL Archives - ' . $host)
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);

    if ($cmd->status != 0) {
        exit(1) if $failover->exit_on_error;
        Failover::Utils::get_confirmation(
            'Could not determine whether WAL archiving configuration was active. Proceed anyway?'
            ) if !$failover->skip_confirmation;
        return -1;
    }

    return -1 unless $cmd->stdout =~ m{^(\w).+->\s+([^>]+)\s*$}o;
    return -1 unless $1 eq 'l'; # configuration was not symlinked to a wal/nowal variant
}

=head3 check_postmaster_offline

Verifies that PostgreSQL postmaster processes are not running on a remote host. Uses both a
psql check and remote SSH command.

=cut

sub check_postmaster_offline {
    my ($failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    my $data_check = $failover->config->section(($failover->config->get_data_checks)[0]);

    my $cmd = Failover::Command->new($data_check->{'query'})
        ->name('Postmaster Offline Status Check - Remote - ' . $host)
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->database($host_cfg->{'database'})
        ->port($host_cfg->{'pg-port'})
        ->user($host_cfg->{'pg-user'})
        ->expect_error(1)
        ->psql->run($failover->dry_run);

    return 1 if $cmd->status == 0;

    $cmd = Failover::Command->new(qw( ps -l -C postgres ))
        ->name('Postmaster Offline Status Check - Local Process - ' . $host)
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->expect_error(1)
        ->ssh->run($failover->dry_run);

    return 1 if $cmd->status == 0;

    # Both remote PSQL and local PS checks for a Postmaster failed and we have to assume
    # that PostgreSQL is not running on the target system at this time.
    return -1;
}

=head3 check_postmaster_online

Reverse of the _offline check. Verifies that a PostgreSQL postmaster is running on the remote
host and that it can be contacted via psql.

=cut

sub check_postmaster_online {
    my ($failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    my $data_check = $failover->config->section(($failover->config->get_data_checks)[0]);

    my $cmd = Failover::Command->new($data_check->{'query'})
        ->name('Postmaster Online Status Check - Remote - ' . $host)
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->database($host_cfg->{'database'})
        ->port($host_cfg->{'pg-port'})
        ->user($host_cfg->{'pg-user'})
        ->psql->run($failover->dry_run);

    # No need to check process table if we were able to connect to postgres on the host
    return 1 if $cmd->status == 0;

    $cmd = Failover::Command->new(qw( ps -l -C postgres ))
        ->name('Postmaster Online Status Check - Local Process - ' . $host)
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);

    return 1 if $cmd->status == 0;

    # Both remote PSQL and local PS checks for a Postmaster failed and we have to assume
    # that PostgreSQL is not running on the target system at this time.
    return -1;
}

=head3 latest_base_backup

Using the backup target configuration(s) from the failover.ini, this method attempts to
locate the most recently performed master database backup. Used prior to a demotion so that
the newly-initiated replication host starts from a clean backup before attempting to
replay WAL segments.

=cut

sub latest_base_backup {
    my ($failover) = @_;

    my %latest = ( ts => '0000-00-00' );

    # Fake a base backup entry for dry-runs
    if ($failover->dry_run) {
        $latest{'host'} = ($failover->config->get_backups())[0];
        $latest{'file'} = '/tmp/dry_run_archive.tar.gz';
    }

    foreach my $host ($failover->config->get_backups) {
        my $host_cfg = $failover->config->section($host);

        my $cmd = Failover::Command->new('ls',$host_cfg->{'path'})
            ->silent(1)
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'});

        if ($host_cfg->{'host'}) {
            $cmd->ssh->run($failover->dry_run);
        } else {
            $cmd->run($failover->dry_run);
        }

        next if $cmd->status != 0;

        foreach my $l (split(/\n/, $cmd->stdout)) {
            $l =~ s{(^\s+|\s+$)}{}ogs;
            next if $l !~ /-data-(\d{4}-\d\d-\d\d)(\D|$)/;

            if (!exists $latest{'file'} || $1 gt $latest{'ts'}) {
                %latest = ( 'host' => $host,
                            'ts'   => $1,
                            'file' => $host_cfg->{'path'} . '/' . $l
                );
            }
        }
    }

    if (!$failover->dry_run && !exists $latest{'file'}) {
        Failover::Utils::die_error('Could not locate any backup files.');
    }

    return %latest;
}

=head3 locate_recovery_conf

Performs a series of checks to locate an appropriate copy of the recovery.conf to be
used when demoting a PostgreSQL host.

=cut

sub locate_recovery_conf {
    my ($failover, $host_cfg) = @_;

    my $path = $host_cfg->{'pg-recovery'};
    return { remote => 0, path => $path } if -f $path && -r _;

    $path = $failover->{'base_dir'} . '/' . $host_cfg->{'pg-recovery'};
    return { remote => 0, path => $path } if -f $path && -r _;

    $path = $failover->{'base_dir'} . '/recovery.conf';
    return { remote => 0, path => $path } if -f $path && -r _;

    my $cmd = Failover::Command->new('ls',$host_cfg->{'pg-recovery'})
        ->name(sprintf('Locating PostgreSQL recovery.conf for %s', $host_cfg->{'host'}))
        ->verbose($failover->verbose)
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);

    return { remote => 1, path => $host_cfg->{'pg-recovery'}, %{$host_cfg} } if $cmd->status == 0;

    return;
}

=head3 interface_activate

Marks an interface on a host as permanently active (will remain enabled after reboot).

=cut

sub interface_activate {
    my ($host_cfg) = @_;

    # TODO
}

=head3 interface_deactivate

Marks an interface on a host as disabled, to prevent it from being initialized upon
reboot (and potentially causing an IP conflict if that machine is not currently the
owner of the related virtual IP).

=cut

sub interface_deactivate {
    my ($host_cfg) = @_;

    # TODO
}


package Failover::Command;

use strict;
use warnings;

use File::Temp qw( tempfile );
use Socket;
use Term::ANSIColor;
use Time::HiRes qw( gettimeofday tv_interval );

=head2 Package: Failover::Command

Methods to create and issue local, remote, and psql commands. Command objects are used
via chained-method calls. Except where noted, methods all return their own object on
success, or nothing on error (if they didn't die first).

=cut 

=head3 new

Constructor for Failover::Command objects. Accepts a list to be passed into a system()
call.

=cut

sub new {
    my ($class, @command) = @_;

    my $self = bless {}, $class;
    $self->{'expect_error'} = 0;
    $self->{'verbose'} = 0;
    $self->{'silent'} = 0;
    $self->{'sudo'} = 0;
    $self->{'command'} = [@command] if @command;
    Failover::Utils::die_error('Empty command list provided.') if !exists $self->{'command'};

    return $self;
}

=head3 name

Allows a human-readable description/name for the command to be included in any logging or
error output. Any printable string may be supplied.

=cut

sub name {
    my ($self, $name) = @_;

    $self->{'name'} = defined $name ? $name : '';
    Failover::Utils::log('Command object name set to %s.', $self->{'name'}) if $self->{'verbose'} >= 3;

    return $self;
}

=head3 host

Sets the remote hostname to be connected to before running the given command. For SSH commands,
this is the hostname to which ssh will login. For psql commands, this is the database host
psql will connect to using -h.

=cut

sub host {
    my ($self, $hostname) = @_;

    $self->{'host'} = defined $hostname ? $hostname : '';
    Failover::Utils::log('Command object host set to %s.', $self->{'host'}) if $self->{'verbose'} >= 3;

    return $self;
}

=head3 port

Remote port to be used when connecting. Applies to both SSH and psql commands, though it is
recommended to use an ssh_config(5) for setting ports on remote shell systems.

=cut

sub port {
    my ($self, $port) = @_;

    $self->{'port'} = defined $port ? $port : '';
    Failover::Utils::log('Command object port set to %s.', $self->{'port'}) if $self->{'verbose'} >= 3;

    return $self;
}

=head3 user

Remote user to connect as, for both SSH and psql commands. Either will default to the user
running failover.pl unless set through this method.

=cut

sub user {
    my ($self, $username) = @_;

    $self->{'user'} = defined $username ? $username : '';
    Failover::Utils::log('Command object user set to %s.', $self->{'user'}) if $self->{'verbose'} >= 3;

    return $self;
}

=head3 sudo

Indicates that the remote shell command should be issued through sudo. Ideally, as few commands
as necessary should make use of sudo, but some will require it (restarting the database, changing
network interfaces, etc). Please note that there is no facility to provide a password to sudo
through failover.pl, so the remote user will need to be configured for passwordless sudo.

=cut

sub sudo {
    my ($self, $sudo) = @_;

    $self->{'sudo'} = defined $sudo && ($sudo == 0 || $sudo == 1);
    Failover::Utils::log('Command object remote sudo usage set to %s.', $self->{'sudo'} ? 'on' : 'off')
        if $self->{'verbose'} >= 3;

    return $self;
}

=head3 database

Name of the database against which remote psql commands will be issued.

=cut

sub database {
    my ($self, $database) = @_;

    $self->{'database'} = defined $database ? $database : '';
    Failover::Utils::log('Command object database set to %s.', $self->{'database'}) if $self->{'verbose'} >= 3;

    return $self;
}

=head3 expect_error

By default, all command objects will expect to receive a status code of 0 (indicating success)
from the commands they run. This will invert that behavior and cause the Failover::Command
object to return true to its caller when its command has failed.

=cut

sub expect_error {
    my ($self, $flag) = @_;

    $self->{'expect_error'} = defined $flag && ($flag == 0 || $flag == 1);
    Failover::Utils::log('Command object failure expectation set to %s.',
        $self->{'expect_error'} == 1 ? 'true' : 'false') if $self->{'verbose'} >= 3;;

    return $self;
}

=head3 silent

By default, command objects will print output with their name and success/failure. Some
commands are not necessary or desirable to send output, and this will suppress that.

=cut

sub silent {
    my ($self, $silent) = @_;

    $self->{'silent'} = defined $silent && $silent ? 1 : 0;
    Failover::Utils::log('Command object silence set to %s.', $self->{'silence'} ? 'on' : 'off')
        if $self->{'verbose'} >= 2;

    return $self;
}

=head3 verbose

Sets the verbosity of the command. Higher levels will eventually result in the the raw
output of commands being run printed out to the console.

=cut

sub verbose {
    my ($self, $verbosity) = @_;

    $self->{'verbose'} = defined $verbosity && $verbosity =~ /^\d+$/o ? $verbosity : 0;
    Failover::Utils::log('Command object verbosity set to %s.', $self->{'verbose'}) if $self->{'verbose'} >= 2;

    return $self;
}

=head3 compare

Sets a string to which a command's STDOUT is required to match for it to be considered
a success.

=cut

sub compare {
    my ($self, $comparison) = @_;

    $self->{'comparison'} = $comparison if defined $comparison;
    $self->{'comparison'} =~ s{(^\s+|\s+$)}{}ogs if exists $self->{'comparison'};;
    Failover::Utils::log('Command object output comparison set to %s.', $self->{'comparison'})
        if $self->{'verbose'} >= 2;

    return $self;
}

=head3 psql

Indicates that the command object should issue its command through psql.

=cut

sub psql {
    my ($self) = @_;

    Failover::Utils::log('Marking command object as PSQL command.') if $self->{'verbose'} >= 3;

    my @psql_cmd = qw( psql -qAtX );

    push(@psql_cmd, '-h', $self->{'host'})     if exists $self->{'host'} && $self->{'host'} =~ m{\w+}o;
    push(@psql_cmd, '-p', $self->{'port'})     if exists $self->{'port'} && $self->{'port'} =~ m{^\d+$}o;
    push(@psql_cmd, '-U', $self->{'user'})     if exists $self->{'user'} && $self->{'user'} =~ m{\w+}o;
    push(@psql_cmd, '-d', $self->{'database'}) if exists $self->{'database'} && $self->{'database'} =~ m{\w+}o;

    push(@psql_cmd, '-c', quotemeta(join(' ', @{$self->{'command'}})));

    $self->{'command'} = \@psql_cmd;

    return $self;
}

=head3 ssh

Indicates that the command object should issue its command through ssh.

=cut

sub ssh {
    my ($self) = @_;

    Failover::Utils::log('Marking command object as SSH remote command.') if $self->{'verbose'} >= 3;

    my @ssh_cmd;

    # Check to make sure the target host isn't actually the machine we're running on
    # right now before adding all the SSH bits
    my ($l_host, $l_aliases) = gethostbyaddr(pack('C4',split('\.','127.0.0.1')),2);
    $l_aliases = [split(m{\s+}o, $l_aliases)];

    unless (grep { lc($_) eq lc($self->{'host'} || '') } ($l_host, @{$l_aliases})) {
        Failover::Utils::die_error('Attempt to issue an SSH command without a hostname.')
            unless exists $self->{'host'} && $self->{'host'} =~ m{\w+}o;

        @ssh_cmd = qw( ssh -q -oBatchMode=yes );

        push(@ssh_cmd, '-p', $self->{'port'}) if exists $self->{'port'} && $self->{'port'} =~ m{^\d+$}o;
        push(@ssh_cmd, exists $self->{'user'} && $self->{'user'} =~ m{\w+}o
            ? $self->{'user'} . '@' . $self->{'host'}
            : $self->{'host'}
        );

        push(@ssh_cmd, 'sudo') if $self->{'sudo'} && (!exists $self->{'user'} || $self->{'user'} ne 'root');
        push(@ssh_cmd, map { quotemeta } @{$self->{'command'}}) if exists $self->{'command'} && @{$self->{'command'}};
    } else {
        push(@ssh_cmd, 'sudo') if $self->{'sudo'} && (!exists $self->{'user'} || $self->{'user'} ne 'root');
        push(@ssh_cmd, @{$self->{'command'}}) if exists $self->{'command'} && @{$self->{'command'}};
    }

    $self->{'command'} = \@ssh_cmd;

    return $self;
}

=head3 run

The final method called, once all options for the command have been set. Results in
the command being issued. STDOUT and STDERR are captured and available for inspection
later.

=cut

sub run {
    my ($self, $dryrun) = @_;

    Failover::Utils::log('Received run request for command object: %s', join(' ', @{$self->{'command'}}))
        if $self->{'verbose'} >= 2;
    my $time_start = [gettimeofday];
    $self->print_running($self->{'name'} || join(' ', @{$self->{'command'}}));

    if ($dryrun) {
        $self->{'status'} = 0;
        $self->{'stdout'} = '';
        $self->{'stderr'} = '';
        sleep 1;
        $self->print_ok($time_start) unless $self->{'silent'};
        return $self;
    }

    my ($stdout_fh, $stdout_filename) = tempfile("failover.$$.stdout.XXXXXX");
    my ($stderr_fh, $stderr_filename) = tempfile("failover.$$.stderr.XXXXXX");

    my $command = sprintf('%s 2>%s >%s',
        join(' ', @{$self->{'command'}}),
        quotemeta $stderr_filename,
        quotemeta $stdout_filename);

    local $/ = undef;
    $self->{'status'} = system $command;
    $self->{'child_error'} = $? || 0;
    $self->{'os_error'} = $! || 0;

    $self->{'stdout'} = <$stdout_fh>;
    $self->{'stderr'} = <$stderr_fh>;

    $self->{'stdout'} =~ s{(^\s+|\s+$)}{}ogs;
    $self->{'stderr'} =~ s{(^\s+|\s+$)}{}ogs;

    if ($self->{'verbose'} >= 2 && length($self->{'stdout'}) > 0) {
        Failover::Utils::log('Command Object STDOUT: %s', $_) for split(/\n/, $self->{'stdout'});
    }

    if ($self->{'verbose'} && $self->{'status'} != 0) {
        Failover::Utils::log('Command Object STDERR: %s', $_) for split(/\n/, $self->{'stderr'});
    }

    # override exit status if the current command is expected to fail
    if ($self->{'status'} == 0 && $self->{'expect_error'} == 1) {
        $self->{'status'} = 1;
    } elsif ($self->{'status'} != 0 && $self->{'expect_error'} == 1) {
        $self->{'status'} = 0;
    }

    if ($self->{'status'} == 0) {
        if (exists $self->{'comparison'} && $self->{'stdout'} ne $self->{'comparison'}) {
            $self->print_fail('Unexpected command output. Got %s, Expected %s.',
                $self->{'stdout'}, $self->{'comparison'}) unless $self->{'silent'};
            $self->{'status'} = 1; # fake an error status to make sure caller reacts properly
        } else {
            $self->print_ok($time_start) unless $self->{'silent'};
        }
    } else {
        if ($self->{'child_error'} == -1) {
            $self->print_fail('Failed to execute: %s', $self->{'os_error'});
        } elsif ($self->{'child_error'} & 127) {
            $self->print_fail('Child died with signal %s, %s coredump.',
                ($self->{'child_error'} & 127),
                ($self->{'child_error'} & 128) ? 'with' : 'without');
        } else {
            $self->print_fail('Child exited with value %s', $self->{'child_error'} >> 8);
        }
    }

    close($stdout_fh);
    close($stderr_fh);

    unlink($stdout_filename, $stderr_filename);

    return $self;
}

=head3 status

Returns boolean for success or failure of the command. The status returned here is
not necessarilly the raw status returned by the remote command, as it takes into
account settings such as expect_failure().

=cut

sub status {
    my ($self) = @_;
    return $self->{'status'} if exists $self->{'status'};
    return;
}

=head3 stderr

Returns a scalar containing the raw STDERR output from the remote command.

=cut

sub stderr {
    my ($self) = @_;
    return $self->{'stderr'} if exists $self->{'stderr'};
    return;
}

=head3 stdout

Returns a scalar containing the raw STDOUT output from the remote command.

=cut

sub stdout {
    my ($self) = @_;
    return $self->{'stdout'} if exists $self->{'stdout'};
    return;
}

=head3 print_fail

Prints the [FAIL] status on console output for commands.

=cut

sub print_fail {
    my ($self, $fmt, @args) = @_;

    printf("  [%sFAIL%s]\n", color('bold red'), color('reset')) unless $self->{'silent'};
    printf("           $fmt\n", map { color('yellow') . $_ . color('reset') } @args) if defined $fmt && $self->{'verbose'};
    return 0;
}

=head3 print_ok

Prints the [OK] status on console output for commands.

=cut

sub print_ok {
    my ($self, $time_start) = @_;

    my $timing = '';

    if (defined $time_start) {
        my $time_end = [gettimeofday];

        my $diff = tv_interval($time_start, $time_end);

        my $h = int($diff / 3600);
        my $m = int(($diff - $h * 3600) / 60);
        my $s = $diff - $h * 3600 - $m * 60;

        $timing = sprintf('%02d:%02d:%04.1f', $h, $m, $s);
    }

    printf("%10s [%sOK%s]\n", $timing, color('bold green'), color('reset')) unless $self->{'silent'};
    return 1;
}

=head3 print_running

Prints the command name on console output for commands.

=cut

sub print_running {
    my ($self, $name) = @_;

    my $width = Failover::Utils::term_width() || 80;
    $width = 120 if $width > 120;
    $width -= 26;

    printf("  Running: %s%-${width}s%s",
        color('yellow'),
        (length($name) > $width ? substr($name, 0, ($width - 3)) . '...' : $name),
        color('reset')) unless $self->{'silent'};
}


package Failover::Config;

use Term::ANSIColor;

use strict;
use warnings;

=head2 Package: Failover::Config

Manages the location, reading, and interaction with failover.pl's configuration file.

=cut 

=head3 new

Constructor for Failover::Config objects.

=cut

sub new {
    my ($class, $base_dir, $file_path) = @_;
    my $self = bless {}, $class;

    if (defined $file_path) {
        Failover::Utils::die_error('Configuration file given as %s does not exist.', $file_path) unless -f $file_path;
        Failover::Utils::die_error('Configuration file at %s is not readable.', $file_path) unless -r _;
        $self->{'config'} = read_config($file_path)
            or Failover::Utils::die_error('Configuration file at %s is not valid.', $file_path);
    } elsif (defined $base_dir && -d $base_dir && -f "$base_dir/failover.ini" && -r _) {
        $self->{'config'} = read_config("$base_dir/failover.ini")
            or Failover::Utils::die_error('Invalid configuration located at %s.', "$base_dir/failover.ini");
    } else {
        Failover::Utils::die_error('No usable configuration specified or located.');
    }

    $self->validate() or Failover::Utils::die_error('Configuration failed validation.');

    return $self;
}

=head3 display

Produces terminal-width output summarizing the configuration as parsed by this package.
Groups sections together and displays their fully-configured states -- options defined
in the [common] section in the configuration file will be displayed here with the
individual hosts, to make it as clear as possible what settings will be used for each
machine.

=cut

sub display {
    my ($self, %opts) = @_;

    my $cols = Failover::Utils::term_width();

    $self->display_multisection_block($cols, 'Shared IP',
        Failover::Utils::sort_section_names(grep { $_ =~ m{^shared-ip}o } keys %{$self->{'config'}}));
    $self->display_multisection_block($cols, 'Backup',
        Failover::Utils::sort_section_names(grep { $_ =~ m{^backup}o } keys %{$self->{'config'}}));
    $self->display_multisection_block($cols, 'Host',
        Failover::Utils::sort_section_names(grep { $_ =~ m{^host-}o } keys %{$self->{'config'}}));
    $self->display_multisection_block($cols, 'Data Check',
        Failover::Utils::sort_section_names(grep { $_ =~ m{^data-check}o } keys %{$self->{'config'}}));

    my @actions;

    if (exists $opts{'promotions'} && ref($opts{'promotions'}) eq 'ARRAY' && scalar(@{$opts{'promotions'}}) > 0) {
        push(@actions, sprintf('%sPromoting:%s   %s', color('bold green'), color('reset'),
            join(', ', Failover::Utils::sort_section_names(@{$opts{'promotions'}}))));
    }
    if (exists $opts{'demotions'} && ref($opts{'demotions'}) eq 'ARRAY' && scalar(@{$opts{'demotions'}}) > 0) {
        push(@actions, sprintf('%sDemoting:%s    %s', color('bold red'), color('reset'),
            join(', ', Failover::Utils::sort_section_names(@{$opts{'demotions'}}))));
    }
    if (exists $opts{'backups'} && ref($opts{'backups'}) eq 'ARRAY' && scalar(@{$opts{'backups'}}) > 0) {
        push(@actions, sprintf('%sBacking Up:%s  %s', color('bold yellow'), color('reset'),
            join(', ', Failover::Utils::sort_section_names(@{$opts{'backups'}}))));
    }

    if (scalar(@actions) > 0) {
        print join("\n", @actions) . "\n\n";
    }
}

=head3 display_multisection_block

Method to work out the nearly-most-efficient layout for displaying several hosts on
a given terminal size. Keeps everything lined up and packs each host together into
the minimum width necessary for the largest values to fit.

=cut

sub display_multisection_block {
    my ($self, $cols, $label, @sections) = @_;

    # longest lengths of various things that get displayed, so we can line it all up, with min widths
    my ($lname, $lkey, $lval) = (8,4,8);

    $lname = (sort { $b <=> $a } map { length($_) } @sections)[0];
    foreach my $section (@sections) {
        my $l = (sort { $b <=> $a } map { length($_) } keys %{$self->{'config'}{$section}})[0];
        $lkey = $l if $l > $lkey;

        $l = (sort { $b <=> $a } map { length($_) } values %{$self->{'config'}{$section}})[0];
        $lval = $l if $l > $lval;
    }

    # width of each section           [..<key>..<value>....]   [Host: <host>....]
    my $swidth = (sort { $b <=> $a } ($lkey + $lval + 8,       length($label) + $lname + 6))[0];

    # how many can we fit on the terminal? (minus a col to prevent wrapping)
    my $sections_per_line = int($cols / ($swidth + 1));

    my $section_block;
    for (my $i = 0; $i < scalar(@sections); $i += $sections_per_line) {
        my @row_sections = grep { defined $_ } @sections[$i..$i+$sections_per_line-1];

        # most rows from a section for this "line" of output
        my $srows = (sort { $b <=> $a } map { scalar(keys(%{$self->{'config'}{$_}})) } @row_sections)[0];

        my @row_lines;

        $self->append_section_summary(\@row_lines, $_, $swidth, $label, $srows, $lname, $lkey, $lval)
            for @row_sections;

        $section_block .= join("\n", @row_lines) . "\n\n";
        @row_lines = ();
    }

    print $section_block;
}

=head3 append_section_summary

Tacks on the lines of a section to the output being sent to the console. Each section may be
multiple lines, and not all sections have the same lines (or the same number of lines). This
takes care of that, so the display is as clean and readable as possible.

=cut

sub append_section_summary {
    my ($self, $lines, $host, $width, $label, $rows, $lname, $lkey, $lval) = @_;

    $rows += 2; # need to account for the header and rule lines

    my @host_lines = (
        sprintf("%s%-${width}s%s", color('bold blue'), sprintf("%s: %s    ", $label, $host), color('reset')),
        sprintf('%s%s%s  ', color('bold blue'), '-'x($width-2), color('reset'))
    );

    foreach my $key (sort keys %{$self->{'config'}{$host}}) {
        push(@host_lines, sprintf("  %s%-${lkey}s%s  %-${lval}s    ",
            color('green'), $key, color('reset'), $self->{'config'}{$host}{$key}));
    }

    for (my $i = 0; $i < $rows; $i++) {
        my $line = scalar(@host_lines) > 0 ? shift(@host_lines) : " "x$width;

        $lines->[$i] = "" unless $lines->[$i];
        $lines->[$i] .= $line;
    }
}

=head3 read_config

Reads and parses the INI file into the internal nested hash structure, where each top-level
key is the section name, and the value is a hashref of setting key-value pairs.

=cut

sub read_config {
    my ($path) = @_;

    my %cfg;
    my $section = 'common';

    open(my $fh, '<', $path) or Failover::Utils::die_error('Error opening %s: %s', $path, $!);
    while (my $line = <$fh>) {
        # remove comments
        $line =~ s{\#.*$}{}o;

        if ($line =~ m{^\[([^\[]+)\]\s*$}o) {
            $section = lc($1);
            validate_section_name($section)
                or Failover::Utils::die_error('Invalid section %s at line %s.', $section, $.);
            Failover::Utils::die_error('Section %s defined more than once (line %s).', $section, $.)
                if exists $cfg{$section};
            $cfg{$section} = {};
            next;
        }

        if ($line =~ m{^(.*)=(.*)$}o) {
            my ($setting, $value) = (lc($1), $2);

            $setting = validate_setting_name($setting)
                or Failover::Utils::die_error('Invalid setting %s at line %s in section %s', $setting, $., $section);

            $cfg{$section}{$setting} = clean_value($value);
            next;
        }

        Failover::Utils::die_error('Invalid configuration entry found at line %s.', $.) if $line !~ m{^\s*$}os;
    }
    close($fh);

    return \%cfg;
}

=head3 validate

Ensures that all required settings are present, and that no unknown setting names are
encountered.

=cut

sub validate {
    my ($self) = @_;

    Failover::Utils::die_error('No configuration present.') unless exists $self->{'config'};

    $self->normalize_host($_) for grep { $_ =~ m{host-.+}o } keys %{$self->{'config'}};
    $self->normalize_checks($_) for grep { $_ =~ m{data-check-.+}o } keys %{$self->{'config'}};
    $self->normalize_backup();
    $self->normalize_shared();

    return 1;
}

=head3 normalize_backup

Combines each backup section encountered with the common section, if present, to come
up with the single, unified backup host configuration.

=cut

sub normalize_backup {
    my ($self) = @_;

    Failover::Utils::die_error('No backup server defined.') unless exists $self->{'config'}{'backup'};
    $self->normalize_section('backup', qw( host user path tempdir dstbackup ));

    $self->{'config'}{'backup'}{'tempdir'} = '/tmp' unless exists $self->{'config'}{'backup'}{'tempdir'};
    $self->{'config'}{'backup'}{'dstbackup'} = $self->{'config'}{'backup'}{'tempdir'} . '/dstbackup'
        unless exists $self->{'config'}{'backup'}{'dstbackup'};
    $self->{'config'}{'backup'}{'dstbackup'} =~ s{/+}{/}og;
}

=head3 normalize_checks

Combines each data-check section encountered with the common section, if present, to come
up with the single, unified data-check configuration.

=cut

sub normalize_checks {
    my ($self, $check) = @_;

    $self->normalize_section($check, qw( query result ));
}

=head3 normalize_host

Combines each host section encountered with the common section, if present, to come
up with the single, unified host configuration.

=cut

sub normalize_host {
    my ($self, $host) = @_;

    $self->normalize_section($host, qw(
        host user interface method timeout
        pg-data pg-conf pg-user pg-port database pg-restart pg-reload pg-start pg-stop pg-recovery
        omnipitr trigger-file
    ));

    if (!exists $self->{'config'}{$host}{'host'}) {
        Failover::Utils::die_error('Could not deduce hostname from section name %s.', $host)
            unless $host =~ m{^host-(.+)$}os;
        $self->{'config'}{$host}{'host'} = $1;
    }
}

=head3 normalize_shared

Combines the shared IP section with the common section, if present, to come
up with the single, unified shared IP configuration.

=cut

sub normalize_shared {
    my ($self) = @_;

    Failover::Utils::die_error('No shared IP section defined.') unless exists $self->{'config'}{'shared-ip'};
    $self->normalize_section('shared-ip', qw(
        host port database user pg-port pg-user
    ));
}

=head3 normalize_section

Called by each of the section-specific normalize_ methods, with a section
hashref containing all the setting key-values, followed by a list of setting
names valid for the given section type.

=cut

sub normalize_section {
    my ($self, $section, @settings) = @_;

    Failover::Utils::die_error('Invalid host section name: %s', $section) unless exists $self->{'config'}{$section};
    Failover::Utils::die_error('No settings defined for verification.') if scalar(@settings) < 1;

    foreach my $key (@settings) {
        next if exists $self->{'config'}{$section}{$key};
        $self->{'config'}{$section}{$key} = $self->{'config'}{'common'}{$key}
            if exists $self->{'config'}{'common'}{$key};
    }

    return 1;
}

=head3 clean_value

Trims setting values of whitespace, and quotes (if the quotes are matching at ^ and $).

=cut

sub clean_value {
    my ($value) = @_;

    $value =~ s{(^\s+|\s+$)}{}ogs;
    $value =~ s{(^["']|["']$)}{}ogs if $value =~ m{^(["']).+\1$}os;

    return $value;
}

=head3 validate_section_name

Compares an encountered section name with a whitelist of valid sections (taking
into account that most sections are <section>-<name>).

=cut

sub validate_section_name {
    my ($name) = @_;

    return 1 if grep { $_ eq $name } qw( common shared-ip backup );
    return 1 if $name =~ m{^host-[a-z0-9-]+$}o;
    return 1 if $name =~ m{^data-check(-[a-z0-9-]+)?$}o;
    return 0;
}

=head3 validate_setting_name

Ensures that an encountered setting is a valid one. Any settings in the configuration
file which do not match the whitelist will trigger a fatal error, so as to prevent
potentially harmful/invalid configurations from being used against production systems.

=cut

sub validate_setting_name {
    my ($name) = @_;

    $name =~ s{(^\s+|\s+$)}{}ogs;

    return $name if grep { $_ eq $name }
        qw( host port database user interface method trigger-file query result
            pg-data pg-conf pg-port pg-user pg-restart pg-reload pg-start pg-stop pg-recovery
            omnipitr path timeout tempdir dstbackup );
    return;
}

=head3 section

Returns the section by name from the parsed and validated configuration.

=cut

sub section {
    my ($self, $section) = @_;

    Failover::Utils::die_error('Invalid configuration section %s requested.', $section)
        if !defined $section || !exists $self->{'config'}{$section};
    return $self->{'config'}{$section};
}

=head3 get_hosts

Returns the list of host names discovered in the configuration.

=cut

sub get_hosts {
    my ($self) = @_;

    return grep { $_ =~ m{^host-}o } keys %{$self->{'config'}};
}

=head3 get_backups

Returns the list of backup host names discovered in the configuration.

=cut

sub get_backups {
    my ($self) = @_;

    return grep { $_ =~ m{^backup}o } keys %{$self->{'config'}};
}

=head3 get_data_checks

Returns the list of data check names discovered in the configuration.

=cut

sub get_data_checks {
    my ($self) = @_;

    return grep { $_ =~ m{^data-check}o } keys %{$self->{'config'}};
}

=head3 get_shared_ips

Returns the list of shared IP names discovered in the configuration.

=cut

sub get_shared_ips {
    my ($self) = @_;

    return grep { $_ =~ m{^shared-ip}o } keys %{$self->{'config'}};
}


package Failover::Utils;

use strict;
use warnings;

use File::Basename;
use Term::ANSIColor;

=head2 Package: Failover::Utils

Convenience subroutines used elsewhere.

=cut 

=head3 die_error

Issues a call to print_error() with all its arguments and then exits with the return
code of 255 to indicate a fatal error.

=cut

sub die_error {
    print_error(@_);
    exit(255);
}

=head3 get_confirmation

Displays a Y/N prompt, with a default response should the user just press Enter, and
blocks for user input.

=cut

sub get_confirmation {
    my ($question, $default) = @_;

    $default = defined $default && $default =~ m{^(y(es)?|no?)$}oi ? lc(substr($default, 0, 1)) : 'n';

    printf('%s [%s/%s]: ', $question,
        ( $default eq 'y'
            ? (color('bold') . 'Y' . color('reset'), 'n')
            : ('y', color('bold') . 'N' . color('reset'))
        ));

    my $r = <STDIN>;
    chomp $r;

    return 1 if $r =~ m{^\s*y(es)?\s*$}oi;

    if ($r =~ m{^\s*(no?)?\s*$}oi) {
        print color('red'), 'Exiting.', color('reset'), "\n";
        exit(0);
    }

    print "I'm sorry, you entered a response that I did not understand. Please try again.\n";
    get_confirmation($question, $default);
}

=head3 prompt_user

Displays a no-answer-necessary prompt to the user, suitable for pausing script operation
until the user indicates they have satisfied some external condition.

=cut

sub prompt_user {
    my ($question) = @_;

    printf('%s %s[Enter to continue]%s', $question, color('yellow'), color('reset'));
    my $r = <STDIN>;

    return 1;
}

=head3 log

Logs the given message to STDOUT. The first argument is used as a format specifier to
printf, with all following arguments passed as arguments to that same printf. Timestamps,
current PID, etc. are all added to the output.

=cut

sub log {
    my ($fmt, @args) = @_;

    $fmt = '' unless defined $fmt && length($fmt) > 0;
    @args = () unless @args;

    my ($sname) = fileparse(__FILE__);
    printf("%s[%s]%s - %s - %d - %s\n",
        color('yellow'), scalar(localtime()), color('reset'), $sname, $$,
            sprintf($fmt, map { color('yellow') . $_ . color('reset') } @args)
    );
}

=head3 print_error

Prints an error message to output.

=cut

sub print_error {
    my $error;

    if (scalar(@_) > 1 && $_[0] =~ m{\%}o) {
        $error = sprintf(shift @_, map { color('yellow') . $_ . color('reset') } @_);
    } elsif (scalar(@_) > 1) {
        $error = join(' ', @_);
    } elsif (scalar(@_) == 1) {
        $error = $_[0];
    } else {
        return;
    }

    printf("%sERROR:%s %s\n", color('bold red'), color('reset'), $error);
}

=head3 sort_section_names

Returns an array of sorted section names, to simplify ensuring that host-10 will be
sorted after host-4.

=cut

sub sort_section_names {
    my @names = @_;

    # get length of longest complete section name, to set sane format lengths for sorting below
    my $l = (sort { $b <=> $a } map { length($_) } @names)[0];

    my %maps;
    $maps{$_->[0]} = $_->[1] for map {
        $_ =~ m{^(.+\D)(\d+)$}o ? [sprintf("%-${l}s - %0${l}d", $1, $2), $_] : [$_, $_]
    } @names;

    return map { $maps{$_} } sort keys %maps;
}

=head3 term_width

Does its best to determine the width of the current terminal, without using non-CORE
Perl modules. Generally works okay on raw terminals as well as inside screen/tmux.

=cut

sub term_width {
    return $ENV{'COLUMNS'} if exists $ENV{'COLUMNS'} && $ENV{'COLUMNS'} =~ m{^\d+$}o;

    my $cols = `stty -a`;
    return ($1 - 2) if defined $cols && $cols =~ m{columns\s+(\d+)}ois;

    $cols = `tput cols 2>/dev/null`;
    return ($cols - 2) if defined $cols && $cols =~ m{^\d+$}o;

    return 78;
}

1;
