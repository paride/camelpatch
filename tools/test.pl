#!/usr/bin/perl
#
# NonGNU patch -- test runner.
#
# Runs the GNU patch reference test suite from the pinned reference checkout
# against patch.pl (default) or against a reference patch executable given
# with --patch.  See AGENTS.md for the testing workflow and result policy.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use File::Path qw(make_path remove_tree);
use File::Spec::Functions qw(catdir catfile);
use JSON::PP ();
use POSIX qw(setsid);

my $ROOT = dirname(dirname(abs_path($0)));

my %opt = (
    timeout => 300,
    log_dir => catdir($ROOT, 'build', 'logs'),
);

# ------------------------------------------------------------------ usage

sub usage {
    my ($stream) = @_;
    print {$stream} <<"END";
Usage: perl tools/test.pl [OPTION]...

Run the pinned GNU patch test suite against a patch implementation.

  --test NAME       run only NAME (repeatable or comma-separated)
  --patch PATH      test the given executable instead of patch.pl
  --perl PATH       Perl interpreter used to run patch.pl (default: this one)
  --manifest PATH   compatibility manifest (default: newest in compat/)
  --log-dir DIR     directory for per-test logs (default: build/logs)
  --timeout N       seconds allowed per test (default: 300)
  --list            print the test inventory and exit
  --keep            keep the scratch work directory
  --help            show this help

Exit status is 0 only when no test FAILs, no test unexpectedly passes
(XPASS), and no test is skipped; a skip means incomplete coverage.
END
}

# ----------------------------------------------------------------- options

sub parse_args {
    my @select;
    my $need = sub {
        my ($name) = @_;
        die "Option $name requires an argument\n" unless @ARGV;
        return shift @ARGV;
    };
    while (@ARGV) {
        my $arg = shift @ARGV;
        if    ($arg eq '--help')     { usage(*STDOUT); exit 0 }
        elsif ($arg eq '--list')     { $opt{list} = 1 }
        elsif ($arg eq '--keep')     { $opt{keep} = 1 }
        elsif ($arg eq '--test')     { push @select, split /,/, $need->('--test') }
        elsif ($arg eq '--patch')    { $opt{patch}    = $need->('--patch') }
        elsif ($arg eq '--perl')     { $opt{perl}     = $need->('--perl') }
        elsif ($arg eq '--manifest') { $opt{manifest} = $need->('--manifest') }
        elsif ($arg eq '--log-dir')  { $opt{log_dir}  = $need->('--log-dir') }
        elsif ($arg eq '--timeout') {
            my $value = $need->('--timeout');
            $value =~ /^\d+\z/ or die "Option --timeout expects a number\n";
            $opt{timeout} = $value;
        }
        else { die "Unknown option: $arg\nRun with --help for usage.\n" }
    }
    $opt{select} = \@select;
}

# --------------------------------------------------------------- manifest

sub version_cmp {
    my ($x, $y) = @_;
    my @x = $x =~ /(\d+)/g;
    my @y = $y =~ /(\d+)/g;
    for my $i (0 .. (@x > @y ? $#x : $#y)) {
        my $diff = ($x[$i] // 0) <=> ($y[$i] // 0);
        return $diff if $diff;
    }
    return 0;
}

sub find_manifest {
    my $dir = catdir($ROOT, 'compat');
    opendir my $dh, $dir or die "Cannot read $dir: $!\n";
    my @candidates = grep { /\A\d+(?:\.\d+)*\.json\z/ } readdir $dh;
    closedir $dh;
    die "No compatibility manifest found in $dir\n" unless @candidates;
    my ($newest) = sort { version_cmp($b, $a) } @candidates;
    return catfile($dir, $newest);
}

sub load_manifest {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read manifest $path: $!\n";
    my $json = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->decode($json) };
    die "Invalid JSON in manifest $path: $@" if !defined $data && $@;
    return $data;
}

sub manifest_path {
    my ($manifest, $key) = @_;
    my $relative = $manifest->{target}{$key}
        or die "Manifest target is missing '$key'\n";
    return catdir($ROOT, split m{/}, $relative);
}

# --------------------------------------------------------------- reference

sub git_output {
    my ($subdir, @args) = @_;
    open my $fh, '-|', 'git', '-C', $subdir, @args
        or die "Cannot run git in $subdir: $!\n";
    my $output = do { local $/; <$fh> };
    close $fh;
    return $output;
}

sub verify_reference {
    my ($manifest) = @_;
    my $checkout = manifest_path($manifest, 'reference_checkout');
    die "GNU reference checkout $checkout is missing\n"
        . "Run: git submodule update --init\n"
        unless -e $checkout;
    my $head = git_output($checkout, 'rev-parse', 'HEAD');
    my ($have) = defined $head ? $head =~ /\A([0-9a-f]{40})/ : ();
    $have
        or die "git rev-parse failed in $checkout\n"
             . "Is the reference checkout initialized?\n";
    my $want = lc $manifest->{target}{commit}
        or die "Manifest target is missing 'commit'\n";
    $have eq $want
        or die "GNU reference checkout $have does not match manifest "
             . "commit $want\nRun: git -C $checkout checkout $want\n";
    my $tag = git_output($checkout, 'describe', '--tags', '--exact-match');
    $tag //= '';
    chomp $tag;
    return ($have, $tag);
}

# -------------------------------------------------------------- inventory

sub read_makefile_vars {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!\n";
    my %vars;
    my $var;
    while (defined(my $line = <$fh>)) {
        $line =~ s/#.*//;
        if (defined $var) {
            my $continues = $line =~ s/\\\s*\z//;
            push @{ $vars{$var} }, split ' ', $line;
            $var = undef unless $continues;
            next;
        }
        next unless $line =~ /\A\s*(TESTS|XFAIL_TESTS)\s*=\s*(.*?)(\\\s*)?\z/;
        my $continues = defined $3;
        push @{ $vars{$1} }, split ' ', $2;
        $var = $continues ? $1 : undef;
    }
    close $fh;
    return \%vars;
}

sub read_inventory {
    my ($tests_dir) = @_;
    my $vars = read_makefile_vars(catfile($tests_dir, 'Makefile.am'));
    my @tests = @{ $vars->{TESTS} // [] };
    die "No TESTS found in $tests_dir/Makefile.am\n" unless @tests;
    for my $test (@tests) {
        die "Test script $test does not exist in $tests_dir\n"
            unless -f catfile($tests_dir, $test);
    }
    my %xfail = map { $_ => 1 } @{ $vars->{XFAIL_TESTS} // [] };
    return (\@tests, \%xfail);
}

sub crosscheck_expected_failures {
    my ($manifest, $inventory_xfail) = @_;
    my %declared = %{ $manifest->{reference_expected_failures} // {} };
    for my $test (keys %declared) {
        $inventory_xfail->{$test}
            or die "Manifest declares expected failure '$test', "
                 . "which the GNU reference does not declare\n";
    }
    for my $test (keys %$inventory_xfail) {
        $declared{$test}
            or die "GNU reference expected failure '$test' is missing from "
                 . "the manifest; review it and record it in compat/\n";
    }
}

# --------------------------------------------------------------- launcher

sub resolve_perl {
    my $perl = $^X;
    if ($perl =~ m{/}) {
        my $absolute = abs_path($perl);
        die "Cannot resolve Perl path $perl\n" unless $absolute;
        return $absolute;
    }
    for my $dir (File::Spec->path) {
        my $candidate = catfile($dir, $perl);
        return abs_path($candidate) if -f $candidate && -x _;
    }
    die "Cannot locate Perl interpreter '$perl'\n";
}

sub write_launcher {
    my ($path, $perl, $patch_pl) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!\n";
    print {$fh} <<"END";
#!$perl
# Generated by tools/test.pl; do not edit.
# Run patch.pl through this launcher so \$0 stays the invoked program name.
my \$status = do '$patch_pl';
die "patch.pl failed to load: \$\@" if !defined \$status && \$\@;
exit \$status // 255;
END
    close $fh;
    chmod 0755, $path;
}

sub resolve_target {
    if (defined $opt{patch}) {
        die "--patch $opt{patch} is not executable\n" unless -x $opt{patch};
        return ($opt{patch}, basename($opt{patch}));
    }
    my $patch_pl = catfile($ROOT, 'patch.pl');
    die "$patch_pl does not exist\n" unless -f $patch_pl;
    my $launcher = catdir($ROOT, 'build', 'patch');
    write_launcher($launcher, $opt{perl} // resolve_perl(), $patch_pl);
    return ($launcher, 'patch.pl');
}

sub first_line_of {
    my (@command) = @_;
    open my $fh, '-|', @command or die "Cannot run @command: $!\n";
    my $line = <$fh>;
    close $fh;
    die "No --version output from @command\n" unless defined $line;
    chomp $line;
    return $line;
}

# ------------------------------------------------------------- test runs

sub run_test {
    my (%arg) = @_;
    my $pid = fork;
    die "Cannot fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open STDIN,  '<',  '/dev/null'      or die "stdin: $!\n";
        open STDOUT, '>>', $arg{log}        or die "log: $!\n";
        open STDERR, '>&', \*STDOUT        or die "stderr: $!\n";
        chdir $arg{work}                    or die "chdir: $!\n";
        $ENV{$_} = $arg{env}{$_} for keys %{ $arg{env} };
        print "# command: /bin/sh $arg{script}\n";
        print "# PATCH: $arg{env}{PATCH}\n";
        POSIX::setsid();
        exec '/bin/sh', $arg{script} or die "exec: $!\n";
    }
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $arg{timeout};
        waitpid $pid, 0;
        alarm 0;
    };
    if ($@ and $@ eq "timeout\n") {
        $timed_out = 1;
        kill 'TERM', -$pid;
        sleep 1;
        kill 'KILL', -$pid;
        waitpid $pid, 0;
    }
    elsif ($@) { die $@ }
    return wantarray ? ($? >> 8, $timed_out) : ($? >> 8);
}

sub skip_reason {
    my ($log) = @_;
    open my $fh, '<', $log or return 'exit status 77';
    my $reason;
    while (<$fh>) {
        $reason = $1 if /^This test requires (.+)$/;
    }
    close $fh;
    return $reason ? "missing prerequisite: $reason" : 'exit status 77';
}

sub classify {
    my ($exit, $timed_out, $is_xfail, $log) = @_;
    my ($label, $reason);
    if ($timed_out)     { $label = 'FAIL'; $reason = 'timed out' }
    elsif ($exit == 0)  { $label = 'PASS' }
    elsif ($exit == 77) { $label = 'SKIP'; $reason = skip_reason($log) }
    else                { $label = 'FAIL'; $reason = "exit status $exit" }
    if ($is_xfail) {
        return ('XPASS', $reason) if $label eq 'PASS';
        return ('XFAIL', $reason) if $label eq 'FAIL';
    }
    return ($label, $reason);
}

sub read_log {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text // '';
}

# ------------------------------------------------------------------- main

sub main {
    parse_args();
    my $manifest_path = $opt{manifest} // find_manifest();
    my $manifest = load_manifest($manifest_path);

    my ($commit, $tag) = verify_reference($manifest);
    my $tests_dir = manifest_path($manifest, 'reference_tests_dir');
    my ($tests, $inventory_xfail) = read_inventory($tests_dir);
    crosscheck_expected_failures($manifest, $inventory_xfail);

    my %known = map { $_ => 1 } @$tests;
    for my $name (@{ $opt{select} }) {
        $known{$name} or die "Unknown test: $name\nRun --list for the inventory.\n";
    }

    if ($opt{list}) {
        print "Manifest: $manifest_path ($tag)\n";
        for my $test (@$tests) {
            print $inventory_xfail->{$test} ? 'XFAIL ' : '      ',
                  $test, "\n";
        }
        printf "%d tests\n", scalar @$tests;
        return 0;
    }

    my ($target, $target_name) = resolve_target();
    my $version = first_line_of($target, '--version');

    my $log_dir = catdir($opt{log_dir}, $target_name);
    remove_tree($log_dir);
    make_path($log_dir);

    my $work = catdir($ROOT, 'build', 'work.' . $$);
    make_path(catdir($work, 'tests'));

    print "Target:         $target ($version)\n";
    print "GNU reference:  $tag ($commit)\n";
    print "Manifest:       $manifest_path\n";
    print "Logs:           $log_dir\n";
    print "Tests:          " . scalar(@$tests) . "\n\n";

    my @results;
    for my $test (@$tests) {
        next if @{ $opt{select} } && !(grep { $_ eq $test } @{ $opt{select} });
        my $log = catfile($log_dir, "$test.log");
        my $env = {
            srcdir           => $tests_dir,
            abs_top_builddir => $work,
            PATCH            => $target,
        };
        my ($exit, $timed_out) = run_test(
            script  => catfile($tests_dir, $test),
            env     => $env,
            log     => $log,
            work    => $work,
            timeout => $opt{timeout},
        );
        my ($label, $reason) = classify(
            $exit, $timed_out, $inventory_xfail->{$test}, $log
        );
        push @results, {
            name   => $test,
            label  => $label,
            reason => $reason,
        };
        printf "%-6s %s%s\n", $label, $test,
               defined $reason ? "  ($reason)" : '';
    }

    my %count;
    $count{ $_->{label} }++ for @results;
    printf "\n%d tests: %d passed, %d failed, %d skipped, "
         . "%d expected failures, %d unexpected passes\n",
        scalar @results,
        map { $count{$_} // 0 } qw(PASS FAIL SKIP XFAIL XPASS);

    remove_tree($work) unless $opt{keep};

    my @unexpected = grep { $_->{label} =~ /\A(?:FAIL|XPASS|SKIP)\z/ } @results;
    if (@unexpected) {
        print "Unexpected results:\n";
        printf "  %-6s %s (%s)\n", $_->{label}, $_->{name}, $_->{reason} // ''
            for @unexpected;
        print "Verdict: FAIL\n";
        return 1;
    }
    print "Verdict: PASS\n";
    return 0;
}

exit main();
