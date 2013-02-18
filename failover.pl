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
        'no-demotion!',
        'dry-run|d!',
        'skip-confirmation!',
        'exit-on-error|e!',
        'test|t!',
        'verbose|v+',
        'help|h!',
        # primary actions
        'promote=s',
        'demote=s@',
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

  --no-demotion         Prevents the current master database from
                        being demoted to a slave when a new master is
                        promoted.

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

  --demote <host>       Singles out <host> for demotion, in the
                        event a --promote was run with --no-demotion
                        previously (leaving you with a false master).
                        May be specified multiple times.

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

}

sub show_config {
    my ($self) = @_;

    $self->config->display( promotions => [$self->promote], demotions => [$self->demote] );
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
                ->port($self->config->section($host)->{'port'})
                ->user($self->config->section($host)->{'user'})
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
        pgdata   => ['PostgreSQL Data Directory',undef],
        pgconf   => ['PostgreSQL Configuration','postgresql.conf'],
        omnipitr => ['OmniPITR Directory',undef],
    );

    # Test various directory locations on all hosts
    foreach my $host (Failover::Utils::sort_section_names($self->config->get_hosts)) {
        foreach my $dirname (qw( pgdata pgconf omnipitr)) {
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


package Failover::Command;

use strict;
use warnings;

use File::Temp qw( tempfile );
use Term::ANSIColor;

sub new {
    my ($class, @command) = @_;

    my $self = bless {}, $class;
    $self->{'verbose'} = 0;
    $self->{'silent'} = 0;
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

sub database {
    my ($self, $database) = @_;

    $self->{'database'} = defined $database ? $database : '';
    Failover::Utils::log('Command object database set to %s.', $self->{'database'}) if $self->{'verbose'} >= 3;

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
    push(@ssh_cmd, 'sudo') if $self->{'user'} ne 'root';
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
        push(@actions, sprintf('%sPromoting:%s %s', color('bold green'), color('reset'),
            join(', ', Failover::Utils::sort_section_names(@{$opts{'promotions'}}))));
    }
    if (exists $opts{'demotions'} && ref($opts{'demotions'}) eq 'ARRAY' && scalar(@{$opts{'demotions'}}) > 0) {
        push(@actions, sprintf('%sDemoting:%s  %s', color('bold red'), color('reset'),
            join(', ', Failover::Utils::sort_section_names(@{$opts{'demotions'}}))));
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

    $self->normalize_section($host, qw( host user interface method pgdata pgconf pg-restart pg-reload omnipitr ));

    if (!exists $self->{'config'}{$host}{'host'}) {
        Failover::Utils::die_error('Could not deduce hostname from section name %s.', $host)
            unless $host =~ m{^host-(.+)$}os;
        $self->{'config'}{$host}{'host'} = $1;
    }
}

sub normalize_shared {
    my ($self) = @_;

    Failover::Utils::die_error('No shared IP section defined.') unless exists $self->{'config'}{'shared-ip'};
    $self->normalize_section('shared-ip', qw( host port database user ));
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
            pgdata pgconf pg-restart pg-reload omnipitr path );
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
    return $1 if defined $cols && $cols =~ m{columns\s+(\d+)}ois;

    $cols = `tput cols 2>/dev/null`;
    return $cols if defined $cols && $cols =~ m{^\d+$}o;

    return 80;
}

1;
