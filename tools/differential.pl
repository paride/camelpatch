#!/usr/bin/perl
# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use 5.022001;
use strict;
use warnings;

use Cwd qw(abs_path);
use Errno qw(EIO EAGAIN);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use JSON::PP;
use POSIX qw(setsid WNOHANG);
use Time::HiRes qw(time sleep lstat utime);

my $root = dirname(dirname(abs_path($0)));
my (@groups, @names);
my $reference = '/usr/bin/patch';
my $manifest_path;
my $timeout = 10;
my ($list, $help);
GetOptions(
    'reference=s' => \$reference,
    'manifest=s'  => \$manifest_path,
    'group=s@'    => \@groups,
    'case=s@'     => \@names,
    'timeout=i'   => \$timeout,
    'list'       => \$list,
    'help'       => \$help,
) or die "Use --help for usage.\n";
die "Unexpected operands: @ARGV\n" if @ARGV;
die "--timeout must be positive\n" unless $timeout > 0;
if ($help) {
    print <<'HELP';
Usage: perl tools/differential.pl [OPTION]...

Compare Camel patch with the GNU patch reference executable.
This runs project-owned cases only; tools/test.pl runs GNU's suite separately.

  --reference PATH  GNU patch executable (default: /usr/bin/patch)
  --manifest PATH   compatibility manifest (default: newest in compat/)
  --group NAME      select a group (repeatable or comma-separated)
  --case NAME       select a named case (repeatable or comma-separated)
  --timeout N       seconds per process (default: 10)
  --list            list cases without running executables
  --help            show this help

Artifacts are retained under build/differential/run.XXXXXX/.
Exit status: 0 when all selected cases match, 1 for differences/timeouts,
2 for a runner or prerequisite error. GNU's suite XFAILs do not apply here.
HELP
    exit 0;
}

sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    local $/;
    my $bytes = <$fh>;
    close $fh or die "Cannot close $path: $!\n";
    return defined $bytes ? $bytes : '';
}

sub write_bytes {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print {$fh} $bytes or die "Cannot write $path: $!\n";
    close $fh or die "Cannot close $path: $!\n";
}

sub executable {
    my ($name) = @_;
    for my $path ($name =~ m{/} ? $name : map { File::Spec->catfile($_, $name) } File::Spec->path) {
        return abs_path($path) if -f $path && -x $path;
    }
    die "Executable not found: $name\n";
}

sub newest_manifest {
    my @paths = glob "$root/compat/*.json";
    @paths = grep { m{/\d+(?:\.\d+)*\.json\z} } @paths;
    @paths = sort {
        my @a = ($a =~ m{/([\d.]+)\.json\z})[0] =~ /(\d+)/g;
        my @b = ($b =~ m{/([\d.]+)\.json\z})[0] =~ /(\d+)/g;
        my $cmp = 0;
        for my $i (0 .. (@a > @b ? $#a : $#b)) {
            $cmp = ($a[$i] // 0) <=> ($b[$i] // 0);
            last if $cmp;
        }
        $cmp;
    } @paths;
    die "No compatibility manifest in compat/\n" unless @paths;
    return $paths[-1];
}

sub load_cases {
    my @cases;
    for my $path (sort glob "$root/tests/differential/*.pl") {
        my $definitions = do $path;
        die "Cannot load $path: " . ($@ || $! || 'expected an array reference') . "\n"
            unless ref $definitions eq 'ARRAY';
        push @cases, @$definitions;
    }
    die "No differential cases found\n" unless @cases;
    my %seen;
    for my $case (@cases) {
        die "Invalid case name\n" unless ($case->{name} // '') =~ /\A[a-z][a-z0-9-]*\.[a-z0-9-]+\z/;
        die "Duplicate case: $case->{name}\n" if $seen{$case->{name}}++;
    }
    return @cases;
}

sub selected_cases {
    my (@cases) = @_;
    my %groups = map { $_ => 1 } map { split /,/ } @groups;
    my %names = map { $_ => 1 } map { split /,/ } @names;
    my %known_names = map { $_->{name} => 1 } @cases;
    my %known_groups = map { (split /\./, $_->{name})[0] => 1 } @cases;
    for my $name (keys %names) {
        die "Unknown case: $name\n" unless $known_names{$name};
    }
    for my $group (keys %groups) {
        die "Unknown group: $group\n" unless $known_groups{$group};
    }
    my @selected = grep {
        (!%names || $names{$_->{name}})
        && (!%groups || $groups{(split /\./, $_->{name})[0]})
    } @cases;
    die "No cases selected\n" unless @selected;
    return @selected;
}

sub setup_tree {
    my ($case, $work) = @_;
    make_path($work);
    for my $name (sort keys %{ $case->{files} // {} }) {
        my $spec = $case->{files}{$name};
        $spec = { content => $spec } unless ref $spec;
        my $path = "$work/$name";
        write_bytes($path, $spec->{content});
        chmod($spec->{mode} // 0644, $path) or die "chmod $path: $!\n";
        if (defined $spec->{mtime}) {
            utime($spec->{mtime}, $spec->{mtime}, $path) or die "utime $path: $!\n";
        }
        if (defined $spec->{mtime_sec} && defined $spec->{mtime_nsec}) {
            my $mtime = $spec->{mtime_sec} + $spec->{mtime_nsec} / 1_000_000_000;
            utime($mtime, $mtime, $path) or die "utime $path: $!\n";
        }
        if (defined $spec->{uid} || defined $spec->{gid}) {
            my $uid = $spec->{uid} // -1;
            my $gid = $spec->{gid} // -1;
            chown($uid, $gid, $path) == 1 or die "chown $path: $!\n";
        }
    }
    for my $name (sort keys %{ $case->{symlinks} // {} }) {
        make_path(dirname("$work/$name"));
        symlink($case->{symlinks}{$name}, "$work/$name") or die "symlink $name: $!\n";
    }
    for my $name (sort keys %{ $case->{hardlinks} // {} }) {
        make_path(dirname("$work/$name"));
        link("$work/$case->{hardlinks}{$name}", "$work/$name") or die "link $name: $!\n";
    }
}

sub child_runner_error {
    my ($dir, $message) = @_;
    if (open my $fh, '>', "$dir/runner-error.txt") {
        print {$fh} "$message\n";
        close $fh;
    }
    POSIX::_exit(125);
}

sub run_process {
    my ($command, $case, $dir) = @_;
    my $work = "$dir/work";
    setup_tree($case, $work);
    write_bytes("$dir/stdin", $case->{stdin} // '');
    my $pty;
    if (exists $case->{tty_input}) {
        require IO::Pty;
        $pty = IO::Pty->new;
    }
    my $pid = fork;
    die "fork: $!\n" unless defined $pid;
    if (!$pid) {
        if ($pty) {
            open STDOUT, '>&', $pty->slave
                or child_runner_error($dir, "open pty stdout: $!");
        }
        else {
            open STDOUT, '>:raw', "$dir/stdout"
                or child_runner_error($dir, "open stdout: $!");
        }
        if ($pty) {
            $pty->make_slave_controlling_terminal
                or child_runner_error($dir, 'make controlling terminal failed');
            open STDERR, '>:raw', "$dir/stderr"
                or child_runner_error($dir, "open stderr: $!");
            $pty->close_slave;
            close $pty;
        }
        else {
            open STDERR, '>:raw', "$dir/stderr"
                or child_runner_error($dir, "open stderr: $!");
            setsid() >= 0 or child_runner_error($dir, "setsid: $!");
        }
        chdir $work or child_runner_error($dir, "chdir $work: $!");
        umask 0022;
        delete @ENV{qw(PATCH_GET POSIXLY_CORRECT QUOTING_STYLE SIMPLE_BACKUP_SUFFIX
                       VERSION_CONTROL PATCH_VERSION_CONTROL TMPDIR TMP TEMP GDB
                       PERL5OPT PERL5LIB LANGUAGE)};
        @ENV{qw(LC_ALL LANG TZ)} = ('C', 'C', 'UTC0');
        for my $key (keys %{ $case->{env} // {} }) {
            if (defined $case->{env}{$key}) { $ENV{$key} = $case->{env}{$key} }
            else { delete $ENV{$key} }
        }
        open STDIN, '<:raw', "$dir/stdin"
            or child_runner_error($dir, "open stdin: $!");
        if (!exec { $command->[0] } @$command, @{ $case->{args} // [] }) {
            child_runner_error($dir, "exec $command->[0]: $!");
        }
    }
    if ($pty) {
        $pty->close_slave;
        my $input = $case->{tty_input};
        my $offset = 0;
        while ($offset < length $input) {
            my $written = syswrite($pty, $input, length($input) - $offset, $offset);
            die "write prompt input: $!\n" unless defined $written && $written > 0;
            $offset += $written;
        }
    }
    my $deadline = time() + $timeout;
    my $status;
    my $timed_out = 0;
    while (1) {
        my $waited = waitpid($pid, WNOHANG);
        if ($waited == $pid) { $status = $?; last }
        die "waitpid: $!\n" if $waited < 0;
        if (time() >= $deadline) {
            $timed_out = 1;
            kill 'TERM', -$pid;
            sleep 0.1;
            kill 'KILL', -$pid;
            waitpid($pid, 0);
            $status = $?;
            last;
        }
        sleep 0.01;
    }
    my $result = { exit => $status >> 8, signal => $status & 127,
                   timed_out => $timed_out };
    if ($pty) {
        my $output = '';
        while (1) {
            my $read = sysread($pty, my $chunk, 65536);
            last if !defined($read) && ($! == EIO || $! == EAGAIN);
            die "read prompt output: $!\n" unless defined $read;
            last unless $read;
            $output .= $chunk;
        }
        write_bytes("$dir/stdout", $output);
    }
    if (-f "$dir/runner-error.txt") {
        $result->{runner_error} = read_bytes("$dir/runner-error.txt");
        chomp $result->{runner_error};
    }
    write_bytes("$dir/status.json", JSON::PP->new->canonical->pretty->encode($result));
    return $result;
}

sub check_runner_error {
    my ($target, $result) = @_;
    die "$target runner setup failed: $result->{runner_error}\n"
        if $result->{runner_error};
}

sub snapshot {
    my ($work, $case) = @_;
    my %tree;
    my %links;
    find({ no_chdir => 1, wanted => sub {
        my $path = $File::Find::name;
        return if $path eq $work;
        my $name = substr($path, length($work) + 1);
        my @st = Time::HiRes::lstat($path);
        die "lstat $path: $!\n" unless @st;
        my $entry = { mode => sprintf('%04o', $st[2] & 07777),
                      uid => $st[4], gid => $st[5] };
        if (-l _) {
            $entry->{type} = 'symlink';
            $entry->{target} = readlink $path;
        }
        elsif (-d _) { $entry->{type} = 'directory' }
        elsif (-f _) {
            $entry->{type} = 'file';
            $entry->{content_hex} = unpack('H*', read_bytes($path));
            push @{ $links{"$st[0],$st[1]"} }, $name;
        }
        else { $entry->{type} = sprintf('special:%o', $st[2] & 0170000) }
        if (grep { $_ eq $name } @{ $case->{compare_mtime} // [] }) {
            $entry->{mtime} = int $st[9];
        }
        if (grep { $_ eq $name } @{ $case->{compare_mtime_nsec} // [] }) {
            my $seconds = int $st[9];
            $seconds-- if $st[9] < $seconds;
            my $nanoseconds = int(($st[9] - $seconds) * 1_000_000_000 + 0.5);
            $nanoseconds = 0 if $nanoseconds >= 1_000_000_000;
            $entry->{mtime_nsec} = $nanoseconds;
        }
        $tree{$name} = $entry;
    } }, $work);
    for my $paths (values %links) {
        my @sorted = sort @$paths;
        $tree{$_}{hardlinks} = \@sorted for @sorted;
    }
    return \%tree;
}

sub normalize_output {
    my ($bytes, $command) = @_;
    my $program = $command->[0];
    $bytes =~ s/^\Q$program\E: /<patch>: /mg;
    my $short = basename($program);
    $bytes =~ s/^\Q$short\E: /<patch>: /mg;
    $bytes =~ s/^patch: /<patch>: /mg;
    $bytes =~ s/'\Q$program\E --help'/'<patch> --help'/g;
    return $bytes;
}

sub compare_case {
    my ($case, $dir, $commands) = @_;
    my %results;
    my $json = JSON::PP->new->canonical->pretty;
    for my $target (qw(reference camel)) {
        my $side = "$dir/$target";
        $results{$target} = run_process($commands->{$target}, $case, $side);
        check_runner_error($target, $results{$target});
        for my $stream (qw(stdout stderr)) {
            $results{$target}{$stream} = normalize_output(read_bytes("$side/$stream"), $commands->{$target});
        }
        $results{$target}{tree} = snapshot("$side/work", $case);
        write_bytes("$side/tree.json", $json->encode($results{$target}{tree}));
    }
    my @differences;
    for my $target (qw(reference camel)) {
        push @differences, "$target timed out" if $results{$target}{timed_out};
        push @differences, "$target terminated by signal $results{$target}{signal}"
            if $results{$target}{signal};
    }
    if (defined $case->{reference_exit} && $results{reference}{exit} != $case->{reference_exit}) {
        push @differences, "reference exit differs from case sanity check ($case->{reference_exit})";
    }
    for my $prompt (@{ $case->{stdout_contains} // [] }) {
        for my $target (qw(reference camel)) {
            push @differences, "$target stdout missing expected text: $prompt"
                if index($results{$target}{stdout}, $prompt) < 0;
        }
    }
    if (defined $case->{setup_error}) {
        for my $target (qw(reference camel)) {
            push @differences, "$target stderr missing expected text: $case->{setup_error}"
                if index($results{$target}{stderr}, $case->{setup_error}) < 0;
        }
    }
    for my $name (sort keys %{ $case->{expected_files} // {} }) {
        my $expected = unpack('H*', $case->{expected_files}{$name});
        for my $target (qw(reference camel)) {
            my $entry = $results{$target}{tree}{$name};
            if (!$entry || $entry->{type} ne 'file'
                || $entry->{content_hex} ne $expected) {
                push @differences, "$target expected file differs: $name";
            }
        }
    }
    for my $name (@{ $case->{expected_absent} // [] }) {
        for my $target (qw(reference camel)) {
            if (exists $results{$target}{tree}{$name}) {
                push @differences, "$target expected path to be absent: $name";
            }
        }
    }
    for my $field (qw(exit signal stdout stderr tree)) {
        if ($json->encode($results{reference}{$field}) ne $json->encode($results{camel}{$field})) {
            push @differences, "$field differs";
        }
    }
    write_bytes("$dir/result.json", $json->encode({ case => $case->{name}, differences => \@differences }));
    return @differences;
}

sub main {
    my @cases = selected_cases(load_cases());
    if ($list) {
        print "$_->{name}\n" for @cases;
        printf "%d cases\n", scalar @cases;
        return 0;
    }
    $manifest_path //= newest_manifest();
    my $manifest = JSON::PP->new->decode(read_bytes($manifest_path));
    $reference = executable($reference);
    my $perl = executable($^X);
    make_path("$root/build/differential");
    my $run = tempdir('run.XXXXXX', DIR => "$root/build/differential", CLEANUP => 0);
    my $version = run_process([$reference, '--version'], {}, "$run/preflight");
    check_runner_error('reference preflight', $version);
    my $banner = read_bytes("$run/preflight/stdout");
    my $release = $manifest->{target}{release};
    die "Reference must report GNU patch $release (see $run/preflight/)\n"
        unless !$version->{timed_out} && !$version->{signal} && !$version->{exit}
            && $banner =~ /\AGNU patch \Q$release\E\n/;
    my $launcher = "$run/camel-patch";
    my $source = "$root/patch.pl";
    $source =~ s/([\\'])/\\$1/g;
    write_bytes($launcher, "#!$perl\nmy \$status = do '$source';\ndie \$@ if \$@;\ndie \$! unless defined \$status;\nexit \$status;\n");
    chmod 0755, $launcher or die "chmod launcher: $!\n";
    my $commands = { reference => [$reference], camel => [$launcher] };
    write_bytes("$run/run.json", JSON::PP->new->canonical->pretty->encode({
        manifest => abs_path($manifest_path), reference => $reference,
        release => $release, system_perl => $perl,
        cases => [ map { $_->{name} } @cases ],
    }));
    print "GNU reference: $reference ($release)\nPerl: $perl\nArtifacts: $run\n\n";
    my $failed = 0;
    for my $case (@cases) {
        my @differences = compare_case($case, "$run/$case->{name}", $commands);
        $failed++ if @differences;
        printf "%-4s %s%s\n", @differences ? 'FAIL' : 'PASS', $case->{name},
            @differences ? ' (' . join('; ', @differences) . ')' : '';
    }
    printf "\n%d cases: %d PASS, %d FAIL, 0 SKIP\n", scalar @cases, @cases - $failed, $failed;
    print 'Verdict: ', $failed ? 'FAIL' : 'PASS', "\n";
    return $failed ? 1 : 0;
}

my $status = eval { main() };
if ($@) { print STDERR $@; exit 2 }
exit $status;
