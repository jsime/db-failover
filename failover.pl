#!/usr/bin/env perl

Failover->new()->run();

exit;

package Failover;

use Data::Dumper;
use File::Basename;
use Getopt::Long;

use strict;
use warnings;

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
    if (scalar($self->backup) > 0) {
        Failover::Action->backup($self, $_) for Failover::Utils::sort_section_names($self->backup);
    } elsif (scalar($self->promote) > 0) {
        Failover::Action->backup($self, $_) for Failover::Utils::sort_section_names($self->promote);
    }
}

sub show_config {
    my ($self) = @_;

    $self->config->display(
        promotions => [$self->promote],
        demotions  => [$self->demote],
        backups    => [$self->backup],
    );
}

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
        my $cmd = Failover::Command->new('/bin/true')->name(sprintf('Connectivity Test - %s', $host))
            ->verbose($self->verbose)
            ->host($self->config->section($host)->{'host'})
            ->user($self->config->section($host)->{'user'})
            ->ssh->run($self->dry_run);

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

sub config {
    my ($self) = @_;
    return $self->{'config'} if exists $self->{'config'};
    return;
}

sub demote {
    my ($self) = @_;

    return @{$self->{'options'}{'demote'}} if exists $self->{'options'}{'demote'}
        && ref($self->{'options'}{'demote'}) eq 'ARRAY';
    return $self->{'options'}{'demote'} if exists $self->{'options'}{'demote'};
    return;
}

sub promote {
    my ($self) = @_;

    return $self->{'options'}{'promote'} if exists $self->{'options'}{'promote'};
    return;
}

sub backup {
    my ($self) = @_;

    return @{$self->{'options'}{'backup'}} if exists $self->{'options'}{'backup'}
        && ref($self->{'options'}{'backup'}) eq 'ARRAY';
    return $self->{'options'}{'backup'} if exists $self->{'options'}{'backup'};
    return;
}

sub dry_run {
    my ($self) = @_;

    return $self->{'options'}{'dry-run'} if exists $self->{'options'}{'dry-run'};
    return 0;
}

sub exit_on_error {
    my ($self) = @_;

    return $self->{'options'}{'exit-on-error'} if exists $self->{'options'}{'exit-on-error'};
    return 0;
}

sub skip_confirmation {
    my ($self) = @_;

    return $self->{'options'}{'skip-confirmation'} if exists $self->{'options'}{'skip-confirmation'};
    return 0;
}

sub test {
    my ($self) = @_;

    return $self->{'options'}{'test'} if exists $self->{'options'}{'test'};
    return 0;
}

sub verbose {
    my ($self) = @_;

    return $self->{'options'}{'verbose'} if exists $self->{'options'}{'verbose'};
    return 0;
}


package Failover::Action;

use strict;
use warnings;

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
        ->ssh->run($failover->dry_run);

    return 1 if $cmd->status == 0;

    exit(1) if $failover->exit_on_error;
    Failover::Utils::get_confirmation('Interface was not enabled properly. Proceed anyway?')
        if !$failover->skip_confirmation;
    return 0;
}

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
        ->ssh->run($failover->dry_run);

    return 1 if $cmd->status == 0;

    exit(1) if $failover->exit_on_error;
    Failover::Utils::get_confirmation('Interface was not shut down properly. Proceed anyway?')
        if !$failover->skip_confirmation;
    return 0;
}

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

        push(@cmd_remotes,
            '-dr',
            sprintf('gzip=%s@%s:%s', $backup_cfg->{'user'}, $backup_cfg->{'host'}, $backup_cfg->{'path'})
        );
    }

    return unless scalar(@cmd_remotes) > 0;

    my $cmd = Failover::Command->new('/opt/omnipitr/bin/omnipitr-backup-master',
            '-D',         $host_cfg->{'pg-data'},
            '-t',         '/var/tmp/omnipitr/',
            '-x',         '/var/tmp/omnipitr/dstbackup',
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

sub demotion {
    my ($class, $failover, $host) = @_;

    my $host_cfg = $failover->config->section($host);
    Failover::Utils::die_error('Invalid host %s given for demotion.', $host) unless defined $host_cfg;

    my $check_cfg = $failover->config->section(($failover->config->get_data_checks())[0]);
    Failover::Utils::die_error('Could not locate a data check in the configuration to test demotion.')
        unless defined $check_cfg;

    my ($cmd);

    # check that postmaster is not running (prompt to continue or retest if it is)
    retry_check($failover, sub { check_postmaster_offline($failover, $host) });

    # archive current datadir if non-empty
    $cmd = Failover::Command->new(qw( du -s ), $host_cfg->{'pg-data'}, qw( | awk '{ print $1 }' ))
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
                sprintf('%s.%04d-%02d-%02d.tar', $host_cfg->{'pg-data'}, (localtime())[5] + 1900, (localtime())[4,3]),
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

    $cmd = Failover::Command->new(qw( tar -x -z -C ), $host_cfg->{'pg-data'},
            '-f', sprintf('%s/base_restore.tar.gz', $host_cfg->{'omnipitr'})
        )
        ->name(sprintf('Restoring base backup to host %s.', $host))
        ->host($host_cfg->{'host'})
        ->port($host_cfg->{'port'})
        ->user($host_cfg->{'user'})
        ->ssh->run($failover->dry_run);
    exit(1) if $failover->exit_on_error && $cmd->status != 0;

    # add recovery.conf
    # start postgresql (by prompting user to do so if there is no pg-start command in the config)
    if (exists $host_cfg->{'pg-start'}) {
        $cmd = Failover::Command->new($host_cfg->{'pg-start'})
            ->name(sprintf('Starting PostgreSQL on %s', $host))
            ->verbose($failover->verbose)
            ->host($host_cfg->{'host'})
            ->port($host_cfg->{'port'})
            ->user($host_cfg->{'user'})
            ->ssh->run($failover->dry_run);

        if ($cmd->status != 0) {
            exit(1) if $failover->exit_on_error;
            Failover::Utils::print_error("An error was encountered starting PostgreSQL on %s.\n%s",
                $host, $cmd->stderr);
            Failover::Utils::prompt_user('Please resolve this issue and start PostgreSQL before proceeding.');
        }
    } else {
        Failover::Utils::prompt_user(sprintf('Please start PostgreSQL on %s.', $host));
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
}

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

    return 1;
}

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

sub cmd_ifupdown {
    my ($direction, $interface) = @_;

    Failover::Utils::die_error('Interface command requires a new state, and an interface name')
        unless defined $direction && defined $interface && $interface =~ m{\w}o;
    Failover::Utils::die_error('Invalid interface state %s provided.', $direction)
        unless grep { $_ eq $direction } qw( up down );

    return (sprintf('if%s', $direction), $interface);
}

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

sub latest_base_backup {
    my ($failover) = @_;

    my %latest = ( ts => '0000-00-00-000000' );

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
            ->user($host_cfg->{'user'})
            ->ssh->run($failover->dry_run);

        next if $cmd->status != 0;

        foreach my $l (split(/\n/, $cmd->stdout)) {
            $l =~ s{(^\s+|\s+$)}{}ogs;
            next if $l !~ m|-data-(\d{4}-\d\d-\d\d-\d{6})\.tar\.gz|;

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


package Failover::Command;

use strict;
use warnings;

use File::Temp qw( tempfile );
use Term::ANSIColor;

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

sub name {
    my ($self, $name) = @_;

    $self->{'name'} = defined $name ? $name : '';
    Failover::Utils::log('Command object name set to %s.', $self->{'name'}) if $self->{'verbose'} >= 3;

    return $self;
}

sub host {
    my ($self, $hostname) = @_;

    $self->{'host'} = defined $hostname ? $hostname : '';
    Failover::Utils::log('Command object host set to %s.', $self->{'host'}) if $self->{'verbose'} >= 3;

    return $self;
}

sub port {
    my ($self, $port) = @_;

    $self->{'port'} = defined $port ? $port : '';
    Failover::Utils::log('Command object port set to %s.', $self->{'port'}) if $self->{'verbose'} >= 3;

    return $self;
}

sub user {
    my ($self, $username) = @_;

    $self->{'user'} = defined $username ? $username : '';
    Failover::Utils::log('Command object user set to %s.', $self->{'user'}) if $self->{'verbose'} >= 3;

    return $self;
}

sub sudo {
    my ($self, $sudo) = @_;

    $self->{'sudo'} = defined $sudo && ($sudo == 0 || $sudo == 1);
    Failover::Utils::Log('Command object remote sudo usage set to %s.', $self->{'sudo'} ? 'on' : 'off');

    return $self;
}

sub database {
    my ($self, $database) = @_;

    $self->{'database'} = defined $database ? $database : '';
    Failover::Utils::log('Command object database set to %s.', $self->{'database'}) if $self->{'verbose'} >= 3;

    return $self;
}

sub expect_error {
    my ($self, $flag) = @_;

    $self->{'expect_error'} = defined $flag && ($flag == 0 || $flag == 1);
    Failover::Utils::log('Command object failure expectation set to %s.',
        $self->{'expect_error'} == 1 ? 'true' : 'false') if $self->{'verbose'} >= 3;;

    return $self;
}

sub silent {
    my ($self, $silent) = @_;

    $self->{'silent'} = defined $silent && $silent ? 1 : 0;
    Failover::Utils::log('Command object silence set to %s.', $self->{'silence'} ? 'on' : 'off')
        if $self->{'verbose'} >= 2;

    return $self;
}

sub verbose {
    my ($self, $verbosity) = @_;

    $self->{'verbose'} = defined $verbosity && $verbosity =~ /^\d+$/o ? $verbosity : 0;
    Failover::Utils::log('Command object verbosity set to %s.', $self->{'verbose'}) if $self->{'verbose'} >= 2;

    return $self;
}

sub compare {
    my ($self, $comparison) = @_;

    $self->{'comparison'} = $comparison if defined $comparison;
    $self->{'comparison'} =~ s{(^\s+|\s+$)}{}ogs if exists $self->{'comparison'};;
    Failover::Utils::log('Command object output comparison set to %s.', $self->{'comparison'})
        if $self->{'verbose'} >= 2;

    return $self;
}

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

sub ssh {
    my ($self) = @_;

    Failover::Utils::log('Marking command object as SSH remote command.') if $self->{'verbose'} >= 3;
    Failover::Utils::die_error('Attempt to issue an SSH command without a hostname.')
        unless exists $self->{'host'} && $self->{'host'} =~ m{\w+}o;

    my @ssh_cmd = qw( ssh -q -oBatchMode=yes );

    push(@ssh_cmd, '-p', $self->{'port'}) if exists $self->{'port'} && $self->{'port'} =~ m{^\d+$}o;
    push(@ssh_cmd, exists $self->{'user'} && $self->{'user'} =~ m{\w+}o
        ? $self->{'user'} . '@' . $self->{'host'}
        : $self->{'host'}
    );
    push(@ssh_cmd, 'sudo') if $self->{'sudo'} && (!exists $self->{'user'} || $self->{'user'} ne 'root');
    push(@ssh_cmd, map { quotemeta } @{$self->{'command'}}) if exists $self->{'command'} && @{$self->{'command'}};

    $self->{'command'} = \@ssh_cmd;

    return $self;
}

sub run {
    my ($self, $dryrun) = @_;

    Failover::Utils::log('Received run request for command object: %s', join(' ', @{$self->{'command'}}))
        if $self->{'verbose'} >= 2;
    $self->print_running($self->{'name'} || join(' ', @{$self->{'command'}}));

    if ($dryrun) {
        $self->{'status'} = 0;
        $self->{'stdout'} = '';
        $self->{'stderr'} = '';
        sleep 1;
        $self->print_ok() unless $self->{'silent'};
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
            $self->print_ok() unless $self->{'silent'};
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

sub status {
    my ($self) = @_;
    return $self->{'status'} if exists $self->{'status'};
    return;
}

sub stderr {
    my ($self) = @_;
    return $self->{'stderr'} if exists $self->{'stderr'};
    return;
}

sub stdout {
    my ($self) = @_;
    return $self->{'stdout'} if exists $self->{'stdout'};
    return;
}

sub print_fail {
    my ($self, $fmt, @args) = @_;

    printf("  [%sFAIL%s]\n", color('bold red'), color('reset')) unless $self->{'silent'};
    printf("           $fmt\n", map { color('yellow') . $_ . color('reset') } @args) if defined $fmt && $self->{'verbose'};
    return 0;
}

sub print_ok {
    my ($self) = @_;
    printf("  [%sOK%s]\n", color('bold green'), color('reset')) unless $self->{'silent'};
    return 1;
}

sub print_running {
    my ($self, $name) = @_;

    my $width = Failover::Utils::term_width() || 80;
    $width = 120 if $width > 120;
    $width -= 16;

    printf("  Running: %s%-${width}s%s",
        color('yellow'),
        (length($name) > $width ? substr($name, 0, ($width - 3)) . '...' : $name),
        color('reset')) unless $self->{'silent'};
}


package Failover::Config;

use Term::ANSIColor;

use strict;
use warnings;

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

sub validate {
    my ($self) = @_;

    Failover::Utils::die_error('No configuration present.') unless exists $self->{'config'};

    $self->normalize_host($_) for grep { $_ =~ m{host-.+}o } keys %{$self->{'config'}};
    $self->normalize_checks($_) for grep { $_ =~ m{data-check-.+}o } keys %{$self->{'config'}};
    $self->normalize_backup();
    $self->normalize_shared();

    return 1;
}

sub normalize_backup {
    my ($self) = @_;

    Failover::Utils::die_error('No backup server defined.') unless exists $self->{'config'}{'backup'};
    $self->normalize_section('backup', qw( host user path ));
}

sub normalize_checks {
    my ($self, $check) = @_;

    $self->normalize_section($check, qw( query result ));
}

sub normalize_host {
    my ($self, $host) = @_;

    $self->normalize_section($host, qw(
        host user interface method timeout
        pg-data pg-conf pg-user pg-port database pg-restart pg-reload pg-start pg-stop
        omnipitr trigger-file
    ));

    if (!exists $self->{'config'}{$host}{'host'}) {
        Failover::Utils::die_error('Could not deduce hostname from section name %s.', $host)
            unless $host =~ m{^host-(.+)$}os;
        $self->{'config'}{$host}{'host'} = $1;
    }
}

sub normalize_shared {
    my ($self) = @_;

    Failover::Utils::die_error('No shared IP section defined.') unless exists $self->{'config'}{'shared-ip'};
    $self->normalize_section('shared-ip', qw(
        host port database user pg-port pg-user
    ));
}

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

sub clean_value {
    my ($value) = @_;

    $value =~ s{(^\s+|\s+$)}{}ogs;
    $value =~ s{(^["']|["']$)}{}ogs if $value =~ m{^(["']).+\1$}os;

    return $value;
}

sub validate_section_name {
    my ($name) = @_;

    return 1 if grep { $_ eq $name } qw( common shared-ip backup );
    return 1 if $name =~ m{^host-[a-z0-9-]+$}o;
    return 1 if $name =~ m{^data-check(-[a-z0-9-]+)?$}o;
    return 0;
}

sub validate_setting_name {
    my ($name) = @_;

    $name =~ s{(^\s+|\s+$)}{}ogs;

    return $name if grep { $_ eq $name }
        qw( host port database user interface method trigger-file query result
            pg-data pg-conf pg-port pg-user pg-restart pg-reload pg-start pg-stop
            omnipitr path timeout );
    return;
}

sub section {
    my ($self, $section) = @_;

    Failover::Utils::die_error('Invalid configuration section %s requested.', $section)
        if !defined $section || !exists $self->{'config'}{$section};
    return $self->{'config'}{$section};
}

sub get_hosts {
    my ($self) = @_;

    return grep { $_ =~ m{^host-}o } keys %{$self->{'config'}};
}

sub get_backups {
    my ($self) = @_;

    return grep { $_ =~ m{^backup}o } keys %{$self->{'config'}};
}

sub get_data_checks {
    my ($self) = @_;

    return grep { $_ =~ m{^data-check}o } keys %{$self->{'config'}};
}

sub get_shared_ips {
    my ($self) = @_;

    return grep { $_ =~ m{^shared-ip}o } keys %{$self->{'config'}};
}


package Failover::Utils;

use strict;
use warnings;

use File::Basename;
use Term::ANSIColor;

sub die_error {
    print_error(@_);
    exit(255);
}

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

sub prompt_user {
    my ($question) = @_;

    printf('%s %s[Enter to continue]%s', $question, color('yellow'), color('reset'));
    my $r = <STDIN>;

    return 1;
}

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

sub term_width {
    return $ENV{'COLUMNS'} if exists $ENV{'COLUMNS'} && $ENV{'COLUMNS'} =~ m{^\d+$}o;

    my $cols = `stty -a`;
    return ($1 - 2) if defined $cols && $cols =~ m{columns\s+(\d+)}ois;

    $cols = `tput cols 2>/dev/null`;
    return ($cols - 2) if defined $cols && $cols =~ m{^\d+$}o;

    return 78;
}

1;
