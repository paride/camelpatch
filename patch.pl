#!/usr/bin/perl
#
# Camel patch -- apply a diff file to an original.
#
# A self-contained Perl implementation of GNU patch, targeting exact
# observable compatibility with GNU patch 2.8.  See README.md and
# AGENTS.md for the compatibility contract, exclusions, and testing.
#
# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-FileContributor: Paride Legovini <paride@ubuntu.com>
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

use Fcntl qw(O_WRONLY O_RDWR O_RDONLY O_CREAT O_EXCL O_TRUNC O_APPEND);
use Errno qw(ENOENT EEXIST EXDEV EPERM EACCES ELOOP);
use Time::HiRes qw(stat lstat utime);
use Time::Local qw(timegm timelocal);

use constant {
    EXIT_SUCCESS => 0,
    EXIT_FAILURE => 1,
    EXIT_TROUBLE => 2,
    NO_DIFF          => 0,
    CONTEXT_DIFF     => 1,
    NORMAL_DIFF      => 2,
    ED_DIFF          => 3,
    NEW_CONTEXT_DIFF => 4,
    UNI_DIFF         => 5,
    GIT_BINARY_DIFF  => 6,
    OLD              => 0,
    NEW              => 1,
    INDEX            => 2,
    NONE             => -1,
    VERBOSITY_DEFAULT => 0,
    SILENT            => 1,
    VERBOSE           => 2,
    FILE_ID_UNKNOWN       => 0,
    FILE_ID_CREATED       => 1,
    FILE_ID_OVERWRITTEN   => 2,
    FILE_ID_DELETE_LATER  => 3,
};

use constant PATCH_VERSION => '2.8';
use constant PRODUCT_NAME  => 'Camel patch';

# Diff format names for the "Looks like ... to me" message, indexed by enum diff.
use constant DIFF_NAMES => (
    undef, 'a context diff', 'a normal diff', 'an ed script',
    'a new-style context diff', 'a unified diff', 'a git binary diff',
);

binmode STDIN,  ':raw';
binmode STDOUT, ':raw';
binmode STDERR, ':raw';
STDOUT->autoflush(1);
STDERR->autoflush(1);

# ==========================================================================
# 1. Program state
# ==========================================================================
#
# The state mirrors GNU patch's globals.  Nearly all values are set by the
# command line and never change after option parsing, except the per-patch
# state near the end.

my $PROGRAM_NAME = $0;

# Command-line options.
my ($DRY_RUN, $FORCE, $BATCH, $NOREVERSE_FLAG);
my $REVERSE_FLAG = 0;
my $REVERSE_FLAG_SPECIFIED = 0;
my $POSIXLY_CORRECT;
my $SKIP_REST_OF_PATCH;
my $VERBOSITY    = VERBOSITY_DEFAULT;
my $STRIPPATH    = -1;
my $CANONICALIZE_WS;
my $MAXFUZZ      = 2;
my $SET_TIME;
my $SET_UTC;
my $FOLLOW_SYMLINKS;
my $NO_STRIP_TRAILING_CR;
my $DEBUG        = 0;
my $INNAME;
my $EXPLICIT_INNAME;
my $OUTFILE;
my $OUTNAME_IS_INNAME;         # output file is the input file, shared name
my $PATCHNAME;
my $REVISION;
my $DIFF_TYPE    = NO_DIFF;
my $OUTREJ_NAME;               # -r output; rejected hunks otherwise
my $MAKE_BACKUPS;
my $BACKUP_IF_MISMATCH;
my $BACKUP_IF_MISMATCH_SPECIFIED;
my $REMOVE_EMPTY_FILES;
my $ORIGPRAE;                  # -B backup prefix
my $ORIGBASE;                  # -Y backup basename prefix
my $ORIGSUFF;                  # -z backup suffix
my $VERSION_CONTROL;           # -V / PATCH_VERSION_CONTROL / VERSION_CONTROL
my $VERSION_CONTROL_CONTEXT;
my $BACKUP_TYPE;
my $SIMPLE_BACKUP_SUFFIX = '.orig';
my $PATCH_GET            = 0;  # legacy VCS retrieval: accepted, never acts
my $DO_DEFINES;                # -D NAME ifdef output
my $READ_ONLY_BEHAVIOR    = 'warn';   # ignore | warn | fail
my $REJECT_FORMAT         = NO_DIFF;  # reject file format; NO_DIFF = automatic
my $MERGE;
my $CONFLICT_STYLE;

# Quoting of file names in messages.
my $QUOTING_STYLE = 'shell';
my $SAY_TO_STDERR;             # set by -o -, which reroutes messages

# Patch source.  GNU reads the patch file into a temporary file when it is
# not seekable; we simply slurp the bytes and treat them identically.
my $PATCHFILE_DATA;
my $PATCHFILE_SIZE;
my $P_BASE;                    # file offset where the next patch is intuited
my $P_BLINE;                   # line number of $P_BASE
my $P_START;                   # file offset where the current patch starts
my $P_SLINE;                   # line number of $P_START
my $P_INPUT_LINE;              # current line number in the patch file
my $PFP_POS;                   # read offset into $PATCHFILE_DATA

# Per-patch parse state; see gnu-patch/src/pch.c for the C originals.
my $PATCHBUF;                  # current line from the patch file
my $HUNK_CAPACITY = 125;       # parser boundary used by context-format handling
my (@P_LINE, @P_LEN, @P_CHAR);
my ($P_FIRST, $P_NEWFIRST, $P_PTRN_LINES, $P_REPL_LINES, $P_MAX);
my $P_END = -1;
my ($P_PREFIX_CONTEXT, $P_SUFFIX_CONTEXT) = (0, 0);
my ($P_INDENT, $P_STRIP_TRAILING_CR, $P_PASS_COMMENTS_THROUGH) = (0, 0, 0);
my $P_RFC934_NESTING;
my $P_HUNK_BEG;
my $P_C_FUNCTION;
my $P_GIT_DIFF;
my @P_NAME;
my @P_TIMESTR;
my @P_TIMESTAMP;               # [seconds, nanoseconds], [-1, -1] when unknown
my @P_SHA1;
my @P_MODE;
my @P_COPY;
my @P_RENAME;
my @P_SAYS_NONEXISTENT;        # 0 existent, 1 probably empty, 2 nonexistent
my @INVALID_NAMES;

# Input file state; see gnu-patch/src/inp.c.
my $INERRNO;                   # errno of the last stat of $INNAME, or -1
my %INSTAT;                    # fields of the stat buffer of $INNAME
my $INVC;
my $INPUT_LINES;
my @I_LINES;                   # bytes of each line, including its newline
my $UNSAFE;                    # file names may point outside the work tree

# Output state; see gnu-patch/src/patch.c.
my $LAST_FROZEN_LINE = 0;
my $IN_OFFSET = 0;
my $OUT_OFFSET = 0;
my $OUTFP;
my $TTYFH;
my $OUT_AFTER_NEWLINE;
my $OUT_ZERO_OUTPUT;
my $REJFP;                     # reject file handle
my $TEMP_ATTEMPT_NAME;         # name of the last temp file attempt
my $TEMP_REJ_NAME;             # reject temp file path
my $TEMP_REJ_EXISTS;           # a reject temp file exists for this patch
my $OUTREJ_EXISTS;             # the -r reject file has been created
my @TEMP_FILES;                # paths to remove on fatal exit

# File identity table for backup and queued-output logic.
my %FILE_ID;                   # "dev,ino" => [type, queued_output]

# Deferred filesystem work for the whole patch input.
my @FILES_TO_DELETE;           # { name, st, backup }
my @FILES_TO_OUTPUT;           # { from_name, from_st, to, mode, backup }
my $MERGE_LAST_WHAT;           # last merge result kind, for run-on messages

# ==========================================================================
# 2. Diagnostics and user interaction
# ==========================================================================

my %ERRNO_TEXT = (
    1  => 'Operation not permitted',
    2  => 'No such file or directory',
    13 => 'Permission denied',
    17 => 'File exists',
    18 => 'Cross-device link',
    20 => 'Not a directory',
    21 => 'Is a directory',
    28 => 'No space left on device',
    30 => 'Read-only file system',
    36 => 'File name too long',
    39 => 'Directory not empty',
    40 => 'Too many levels of symbolic links',
    84 => 'Invalid or incomplete multibyte or wide character',
);

sub errno_text {
    my ($err) = @_;
    return $ERRNO_TEXT{$err + 0} // 'Unknown error ' . ($err + 0);
}

sub remove_temporary_files {
    for my $path (@TEMP_FILES) {
        next unless defined $path;
        unlink $path;
    }
}

sub fatal_exit {
    remove_temporary_files();
    output_files(undef, 1);
    exit EXIT_TROUBLE;
}

sub fatal {
    my ($message, @args) = @_;
    my $text = @args ? sprintf($message, @args) : $message;
    print STDERR $PROGRAM_NAME, ': **** ', $text, "\n";
    fatal_exit();
}

sub pfatal {
    my ($message, @args) = @_;
    my $text = @args ? sprintf($message, @args) : $message;
    my $err = $! + 0;
    my $detail = $err == 84 ? 'Invalid byte sequence' : errno_text($err);
    print STDERR $PROGRAM_NAME, ': **** ', $text, ' : ', $detail, "\n";
    fatal_exit();
}

sub read_fatal  { pfatal('read error') }
sub write_fatal { pfatal('write error') }

sub read_all {
    my ($fh) = @_;
    my $data = '';
    while (1) {
        my $got = sysread($fh, my $chunk, 65536);
        read_fatal() unless defined $got;
        last unless $got;
        $data .= $chunk;
    }
    return $data;
}

sub say {
    my $text = join '', @_;
    my $fh = $SAY_TO_STDERR ? \*STDERR : \*STDOUT;
    if (length $text) {
        print $fh $text or write_fatal();
    }
}

sub putline {
    my ($fh, @parts) = @_;
    print $fh join('', grep { defined } @parts), "\n"
        or write_fatal();
}

# Write to a handle, dying on a write error like GNU's Fputs/Fwrite.
sub fput {
    my ($fh, $text) = @_;
    print $fh $text or write_fatal() if length $text;
}

sub ask {
    my ($prompt) = @_;
    say($prompt);
    if (!defined $TTYFH) {
        # If standard output is not a tty, don't bother opening /dev/tty,
        # since it's unlikely that stdout will be seen by the tty user.
        if ($POSIXLY_CORRECT || -t STDOUT) {
            if (open my $fh, '<', '/dev/tty') { $TTYFH = $fh }
            else { $TTYFH = -1 }
        }
        else { $TTYFH = -1 }
    }
    if (!ref $TTYFH) {
        # No terminal at all -- default the answer.
        say("\n");
        return "\n";
    }
    my $answer = '';
    while (1) {
        my $got = sysread($TTYFH, my $chunk, 4096);
        if (!defined $got) {
            print STDERR $PROGRAM_NAME, ': tty read failed: ',
                errno_text($!), "\n";
            close $TTYFH;
            $TTYFH = -1;
            return "\n";
        }
        if ($got == 0) {
            say("EOF\n");
            return "\n";
        }
        $answer .= $chunk;
        last if $chunk =~ /\n\z/ || $got < 4096;
    }
    return $answer;
}

# Ask whether it is OK to reverse the current patch.
sub ok_to_reverse {
    my ($message) = @_;
    my $reverse = 0;

    if (!$NOREVERSE_FLAG && !($FORCE && $VERBOSITY == SILENT)) {
        say($message);
    }
    if ($NOREVERSE_FLAG) {
        say("  Skipping patch.\n");
        $SKIP_REST_OF_PATCH = 1;
    }
    elsif ($FORCE) {
        say("  Applying it anyway.\n") if $VERBOSITY != SILENT;
    }
    elsif ($BATCH) {
        say($REVERSE_FLAG ? "  Ignoring -R.\n" : "  Assuming -R.\n");
        $reverse = 1;
    }
    else {
        my $answer = ask($REVERSE_FLAG ? "  Ignore -R? [n] " : "  Assume -R? [n] ");
        if ($answer =~ /^y/) {
            $reverse = 1;
        }
        elsif (ask("Apply anyway? [n] ") !~ /^y/) {
            say("Skipping patch.\n") if $VERBOSITY != SILENT;
            $SKIP_REST_OF_PATCH = 1;
        }
    }
    return $reverse;
}

# ==========================================================================
# 3. Quoting of names in diagnostics
# ==========================================================================
#
# A faithful port of the gnulib quotearg styles that patch uses, assuming a
# single-byte locale (the C locale used by the test suite).

sub quotearg_buffer {
    my ($arg, $style_in) = @_;
    my $elide_outer_quotes = 0;
    my $style = $style_in;
    if ($style eq 'shell' || $style eq 'shell-escape'
        || $style eq 'c-maybe') {
        $elide_outer_quotes = 1;
    }

  render:
    my ($backslash_escapes, $shell_always, $quote_string) = (0, 0, '');
    if    ($style eq 'shell' || $style eq 'shell-escape') {
        $shell_always = 1;
        $backslash_escapes = $style eq 'shell-escape' ? 1 : 0;
    }
    elsif ($style eq 'shell-always')        { $shell_always = 1 }
    elsif ($style eq 'shell-escape-always') { $shell_always = 1; $backslash_escapes = 1 }
    elsif ($style eq 'c')                   { $quote_string = '"'; $backslash_escapes = 1 }
    elsif ($style eq 'c-maybe')             { $quote_string = '"'; $backslash_escapes = 1 }
    elsif ($style eq 'escape')              { $backslash_escapes = 1 }
    elsif ($style eq 'locale' || $style eq 'clocale') {
        $backslash_escapes = 1;
        my $out = "\x{2018}";
        my $len = length $arg;
        for (my $i = 0; $i < $len; $i++) {
            my $c = ord(substr($arg, $i, 1));
            my %simple = ("\a" => 'a', "\b" => 'b', "\f" => 'f',
                          "\n" => 'n', "\r" => 'r', "\t" => 't',
                          "\x0b" => 'v');
            my $byte = substr($arg, $i, 1);
            if    ($c == 0)            { $out .= '\\0' }
            elsif (exists $simple{$byte}) { $out .= '\\' . $simple{$byte} }
            elsif ($byte eq '\\')      { $out .= '\\\\' }
            else                       { $out .= $byte }
        }
        return $out . "\x{2019}";
    }
    else { $backslash_escapes = 0 }   # literal

    my $out = '';
    my $encountered_single_quote;
    my $all_c_and_shell_quote_compat = 1;
    my $pending_shell_escape_end;
    my $force;

    my $start_esc = sub {
        if ($elide_outer_quotes) { $force = 1; return }
        if ($shell_always && !$pending_shell_escape_end) {
            $out .= "'\$'";
            $pending_shell_escape_end = 1;
        }
        $out .= '\\';
    };
    my $end_esc = sub {
        if ($pending_shell_escape_end) {
            $out .= "''";
            $pending_shell_escape_end = 0;
        }
    };

    my $len = length $arg;
    my $qslen = length $quote_string;
    my $i = 0;
    while ($i < $len) {
        my $c = ord(substr($arg, $i, 1));
        my ($esc, $is_right_quote, $c_and_shell_quote_compat) = (undef, 0, 0);
        my $do_store_escape;

        if ($backslash_escapes
            && !$shell_always
            && $qslen
            && substr($arg, $i, $qslen) eq $quote_string) {
            if ($elide_outer_quotes) { $force = 1; last }
            $is_right_quote = 1;
        }

        if ($c == 0) {
            if ($backslash_escapes) {
                $start_esc->();
                if (!$shell_always
                    && $i + 1 < $len
                    && ord(substr($arg, $i + 1, 1)) >= ord '0'
                    && ord(substr($arg, $i + 1, 1)) <= ord '9') {
                    $out .= '00';
                }
                $c = ord '0';
            }
        }
        elsif ($c == ord '?') {
            if ($shell_always) {
                if ($elide_outer_quotes) { $force = 1; last }
            }
        }
        elsif ($c == ord "\a") { $esc = 'a'; goto c_escape }
        elsif ($c == ord "\b") { $esc = 'b'; goto c_escape }
        elsif ($c == ord "\f") { $esc = 'f'; goto c_escape }
        elsif ($c == ord "\n") { $esc = 'n'; goto c_and_shell_escape }
        elsif ($c == ord "\r") { $esc = 'r'; goto c_and_shell_escape }
        elsif ($c == ord "\t") { $esc = 't'; goto c_and_shell_escape }
        elsif ($c == 0x0b)     { $esc = 'v'; goto c_escape }
        elsif ($c == ord '\\') {
            # Never escape a backslash in the shell styles.
            if ($shell_always) {
                if ($elide_outer_quotes) { $force = 1; last }
                goto store_c;
            }
            if ($backslash_escapes && $elide_outer_quotes && $qslen) {
                goto store_c;
            }
            goto c_escape;
        }
        elsif ($c == ord "'") {
            $encountered_single_quote = 1;
            $c_and_shell_quote_compat = 1;
            if ($shell_always) {
                if ($elide_outer_quotes) { $force = 1; last }
                $out .= "'\\''";
                $pending_shell_escape_end = 0;
            }
        }
        elsif ($c == ord '{' || $c == ord '}') {
            if ($len != 1) { $c_and_shell_quote_compat = 1 }
            else { goto shell_special }
        }
        elsif ($c == ord '#' || $c == ord '~') {
            if ($i != 0) { $c_and_shell_quote_compat = 1 }
            else { goto shell_special }
        }
        elsif ($c == ord ' ') {
            $c_and_shell_quote_compat = 1;
            goto shell_special;
        }
        elsif ($c == ord '!' || $c == ord '"' || $c == ord '$'
               || $c == ord '&' || $c == ord '(' || $c == ord ')'
               || $c == ord '*' || $c == ord ';' || $c == ord '<'
               || $c == ord '=' || $c == ord '>' || $c == ord '['
               || $c == ord '^' || $c == ord '`' || $c == ord '|') {
          shell_special:
            if ($shell_always) {
                if ($elide_outer_quotes) { $force = 1; last }
            }
        }
        elsif (chr($c) =~ /[0-9A-Za-z\]\_]/ || $c == ord '%' || $c == ord '+'
               || $c == ord ',' || $c == ord '-' || $c == ord '.'
               || $c == ord '/' || $c == ord ':') {
            $c_and_shell_quote_compat = 1;
        }
        else {
            # Unprintable or other byte (single-byte locale).
            my $printable = chr($c) =~ /[ -~]/;
            $c_and_shell_quote_compat = $printable;
            if ($backslash_escapes && !$printable) {
                $start_esc->();
                $out .= chr(ord('0') + ($c >> 6));
                $out .= chr(ord('0') + (($c >> 3) & 7));
                $c = ord('0') + ($c & 7);
                $do_store_escape = 1;
            }
            elsif ($is_right_quote) {
                $out .= '\\';
                $is_right_quote = 0;
            }
        }

        $start_esc->() if $do_store_escape;

      store_c:
        $end_esc->();
        $out .= chr $c;
        $all_c_and_shell_quote_compat &&= $c_and_shell_quote_compat;
        $i++;
        next;

      c_and_shell_escape:
        if ($shell_always && $elide_outer_quotes) {
            $force = 1;
            last;
        }
        # fall through
      c_escape:
        if ($backslash_escapes) {
            $c = ord $esc;
            $start_esc->();
        }
        goto store_c;
    }

    if ($out eq '' && $shell_always && $elide_outer_quotes) {
        $force = 1;
    }

    if ($force) {
        my $forced_style = $style;
        if ($style eq 'shell-escape') { $forced_style = 'shell-escape-always' }
        elsif ($style eq 'shell')     { $forced_style = 'shell-always' }
        elsif ($style eq 'c-maybe')   { $forced_style = 'c' }
        return quotearg_buffer($arg, $forced_style);
    }

    # Strings commonly containing an apostrophe, and otherwise safe for both
    # C and the shell, are more readable double-quoted.
    if ($shell_always && !$elide_outer_quotes && $encountered_single_quote) {
        if ($all_c_and_shell_quote_compat) {
            return quotearg_buffer($arg, 'c');
        }
    }

    return "'$out'" if $shell_always && !$elide_outer_quotes;
    return "\"$out\"" if $style eq 'c' && !$elide_outer_quotes;
    return $out;
}

sub quotearg        { quotearg_buffer($_[0], $QUOTING_STYLE) }
sub quotearg_style  { my ($style, $arg) = @_; quotearg_buffer($arg, $style) }
sub quotearg_n      { quotearg($_[1]) }

# ==========================================================================
# 4. Option parsing
# ==========================================================================

sub numeric_string {
    my ($string, $negative_allowed, $argtype_msgid) = @_;
    my $value = 0;
    my $negative = substr($string, 0, 1) eq '-';
    my $overflow = 0;
    my $body = $string;
    $body =~ s/^[-+]//;

    fatal("%s %s is not a number", $argtype_msgid, quotearg($string))
        if $body eq '' || $body =~ /[^0-9]/;
    for my $digit (split //, $body) {
        $overflow = 1 if $value > (9223372036854775807 - $digit) / 10;
        $value = $value * 10 + $digit;
    }
    $value = -$value if $negative;
    fatal("%s %s is negative", $argtype_msgid, quotearg($string))
        if $value < 0 && !$negative_allowed;
    if ($overflow) {
        return $negative ? -9223372036854775808 : 9223372036854775807;
    }
    return $value;
}

sub argmatch {
    # Match VALUE against a list of full names, accepting unambiguous
    # abbreviations.  Return the index, -1 for no match, -2 for ambiguous.
    my ($value, $args) = @_;
    my @matches;
    for my $i (0 .. $#$args) {
        return $i if $args->[$i] eq $value;
        push @matches, $i if index($args->[$i], $value) == 0;
    }
    return -1 unless @matches;
    return -2 if @matches > 1;
    return $matches[0];
}

sub argmatch_invalid {
    my ($context, $value, $problem) = @_;
    if ($problem == -1) {
        print STDERR $PROGRAM_NAME, ': invalid argument ',
            quotearg($value), " for ", quotearg($context), "\n";
    }
    else {
        print STDERR $PROGRAM_NAME, ': ambiguous argument ',
            quotearg($value), " for ", quotearg($context), "\n";
    }
}

my @QUOTING_STYLE_ARGS = (
    'literal', 'shell', 'shell-always', 'shell-escape',
    'shell-escape-always', 'c', 'c-maybe', 'escape', 'locale', 'clocale',
);

my @BACKUP_ARGS = ('existing', 'nil', 'numbered', 't', 'simple', 'never');
my @BACKUP_VALS = ('existing', 'existing', 'numbered', 'numbered',
                   'simple', 'simple');

sub set_quoting_style {
    ($QUOTING_STYLE) = @_;
}

sub get_version {
    # Resolve the backup naming method from the -V argument or environment.
    my ($context, $version) = @_;
    return 'existing' unless defined $version && $version ne '';
    my $match = argmatch($version, \@BACKUP_ARGS);
    if ($match < 0) {
        print STDERR 'patch: ', $match == -1 ? 'invalid' : 'ambiguous',
            ' argument ', quotearg_style('shell-always', $version), ' for ',
            quotearg_style('shell-always', $context), "\n",
            "Valid arguments are:\n",
            "  - 'none', 'off'\n",
            "  - 'simple', 'never'\n",
            "  - 'existing', 'nil'\n",
            "  - 'numbered', 't'\n";
        fatal_exit();
    }
    return $BACKUP_VALS[$match];
}

use constant OPTION_HELP => (
    'Input options:',
    '',
    '  -p NUM  --strip=NUM  Strip NUM leading components from file names.',
    '  -F LINES  --fuzz LINES  Set the fuzz factor to LINES for inexact matching.',
    '  -l  --ignore-whitespace  Ignore white space changes between patch and input.',
    '',
    '  -c  --context  Interpret the patch as a context difference.',
    '  -e  --ed  Interpret the patch as an ed script.',
    '  -n  --normal  Interpret the patch as a normal difference.',
    '  -u  --unified  Interpret the patch as a unified difference.',
    '',
    '  -N  --forward  Ignore patches that appear to be reversed or already applied.',
    '  -R  --reverse  Assume patches were created with old and new files swapped.',
    '',
    '  -i PATCHFILE  --input=PATCHFILE  Read patch from PATCHFILE instead of stdin.',
    '',
    'Output options:',
    '',
    '  -o FILE  --output=FILE  Output patched files to FILE.',
    '  -r FILE  --reject-file=FILE  Output rejects to FILE.',
    '',
    '  -D NAME  --ifdef=NAME  Make merged if-then-else output using NAME.',
    '  --merge  Merge using conflict markers instead of creating reject files.',
    '  -E  --remove-empty-files  Remove output files that are empty after patching.',
    '',
    '  -Z  --set-utc  Set times of patched files, assuming diff uses UTC (GMT).',
    '  -T  --set-time  Likewise, assuming local time.',
    '',
    '  --quoting-style=WORD   output file names using quoting style WORD.',
    "    Valid WORDs are: literal, shell, shell-always, c, escape.",
    "    Default is taken from QUOTING_STYLE env variable, or 'shell' if unset.",
    '',
    'Backup and version control options:',
    '',
    '  -b  --backup  Back up the original contents of each file.',
    '  --backup-if-mismatch  Back up if the patch does not match exactly.',
    '  --no-backup-if-mismatch  Back up mismatches only if otherwise requested.',
    '',
    '  -V STYLE  --version-control=STYLE  Use STYLE version control.',
    "\tSTYLE is either 'simple', 'numbered', or 'existing'.",
    '  -B PREFIX  --prefix=PREFIX  Prepend PREFIX to backup file names.',
    '  -Y PREFIX  --basename-prefix=PREFIX  Prepend PREFIX to backup file basenames.',
    '  -z SUFFIX  --suffix=SUFFIX  Append SUFFIX to backup file names.',
    '',
    '  -g NUM  --get=NUM  Get files from RCS etc. if positive; ask if negative.',
    '',
    'Miscellaneous options:',
    '',
    '  -t  --batch  Ask no questions; skip bad-Prereq patches; assume reversed.',
    '  -f  --force  Like -t, but ignore bad-Prereq patches, and assume unreversed.',
    '  -s  --quiet  --silent  Work silently unless an error occurs.',
    '  --verbose  Output extra information about the work being done.',
    '  --dry-run  Do not actually change any files; just print what would happen.',
    '  --posix  Conform to the POSIX standard.',
    '',
    '  -d DIR  --directory=DIR  Change the working directory to DIR first.',
    "  --reject-format=FORMAT  Create 'context' or 'unified' rejects.",
    '  --binary  Read and write data in binary mode.',
    "  --read-only=BEHAVIOR  How to handle read-only input files: 'ignore' that they",
    "                        are read-only, 'warn' (default), or 'fail'.",
    '',
    '  -v  --version  Output version info.',
    '  --help  Output this help.',
    '',
    'Report Camel patch bugs to the project maintainers.',
);

sub usage {
    my ($stream, $status) = @_;
    if ($status != EXIT_SUCCESS) {
        print $stream $PROGRAM_NAME,
            ": Try '$PROGRAM_NAME --help' for more information.\n"
            or write_fatal();
    }
    else {
        print $stream "Usage: $PROGRAM_NAME [OPTION]... [ORIGFILE [PATCHFILE]]\n\n"
            or write_fatal();
        print $stream "$_\n" for OPTION_HELP;
    }
    exit $status;
}

sub version {
    print PRODUCT_NAME, ' ', PATCH_VERSION, "\n",
        "Copyright 1989-2025 Free Software Foundation, Inc.\n",
        "Copyright 1984-1988 Larry Wall\n\n",
        "License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.\n",
        "This is free software: you are free to change and redistribute it.\n",
        "There is NO WARRANTY, to the extent permitted by law.\n";
}

# A faithful port of GNU getopt_long for patch's option set.  Handles the
# permutation of option arguments past file operands, abbreviation of long
# option names, attached and separate arguments, and glibc's diagnostics.

my @LONGOPTS = (
    [ 'backup',            'no_argument',       'b' ],
    [ 'prefix',            'required_argument', 'B' ],
    [ 'context',           'no_argument',       'c' ],
    [ 'directory',         'required_argument', 'd' ],
    [ 'ifdef',             'required_argument', 'D' ],
    [ 'ed',                'no_argument',       'e' ],
    [ 'remove-empty-files', 'no_argument',      'E' ],
    [ 'force',             'no_argument',       'f' ],
    [ 'fuzz',              'required_argument', 'F' ],
    [ 'get',               'required_argument', 'g' ],
    [ 'input',             'required_argument', 'i' ],
    [ 'ignore-whitespace', 'no_argument',       'l' ],
    [ 'merge',             'optional_argument',  undef ],
    [ 'normal',            'no_argument',       'n' ],
    [ 'forward',           'no_argument',       'N' ],
    [ 'output',            'required_argument', 'o' ],
    [ 'strip',             'required_argument', 'p' ],
    [ 'reject-file',       'required_argument', 'r' ],
    [ 'reverse',           'no_argument',       'R' ],
    [ 'quiet',             'no_argument',       's' ],
    [ 'silent',            'no_argument',       's' ],
    [ 'batch',             'no_argument',       't' ],
    [ 'set-time',          'no_argument',       'T' ],
    [ 'unified',           'no_argument',       'u' ],
    [ 'version',           'no_argument',       'v' ],
    [ 'version-control',   'required_argument', 'V' ],
    [ 'debug',             'required_argument', 'x' ],
    [ 'basename-prefix',   'required_argument', 'Y' ],
    [ 'suffix',            'required_argument', 'z' ],
    [ 'set-utc',           'no_argument',       'Z' ],
    [ 'dry-run',           'no_argument',       undef ],
    [ 'verbose',           'no_argument',       undef ],
    [ 'binary',            'no_argument',       undef ],
    [ 'help',              'no_argument',       undef ],
    [ 'backup-if-mismatch', 'no_argument',      undef ],
    [ 'no-backup-if-mismatch', 'no_argument',   undef ],
    [ 'posix',             'no_argument',       undef ],
    [ 'quoting-style',     'required_argument', undef ],
    [ 'reject-format',     'required_argument', undef ],
    [ 'read-only',         'required_argument', undef ],
    [ 'follow-symlinks',   'no_argument',       undef ],
);

sub get_some_switches {
    # Parse command line options the way GNU getopt_long does, and process
    # each switch and file name operand.  Exits on errors.
    my @argv = @_;
    my $optind = 0;
    my $optarg;
    my $end_of_options;
    my $short_position = 0;
    my $require_order = $POSIXLY_CORRECT;

    # Returns the [key, arg] for the option at $optind, advancing $optind;
    # returns undef when the element is a file operand, and the string
    # 'done' for the '--' terminator.
    my $read_option = sub {
        my $token = $argv[$optind];
        return undef if !defined $token;
        if (length($token) < 2 || substr($token, 0, 1) ne '-') {
            return undef;
        }
        if ($token eq '--') { $optind++; return 'done' }

        if (substr($token, 0, 2) eq '--') {
            my $name = substr $token, 2;
            my $value;
            if ($name =~ /\A([^=]*)=(.*)\z/s) { ($name, $value) = ($1, $2) }
            my ($exact) = grep { $_->[0] eq $name } @LONGOPTS;
            my @candidates = grep { index($_->[0], $name) == 0 } @LONGOPTS;
            if (!$exact && @candidates > 1) {
                print STDERR $PROGRAM_NAME,
                    ": option '$token' is ambiguous; possibilities:",
                    join('', map { " '--$_->[0]'" } @candidates), "\n";
                return '?';
            }
            my $entry = $exact // $candidates[0];
            if (!$entry) {
                print STDERR $PROGRAM_NAME, ": unrecognized option '$token'\n";
                return '?';
            }
            my ($long, $takes, $short) = @$entry;
            if ($takes eq 'no_argument') {
                if (defined $value) {
                    print STDERR $PROGRAM_NAME,
                        ": option '--$long' doesn't allow an argument\n";
                    return '?';
                }
                $optarg = undef;
            }
            elsif (defined $value) {
                $optarg = $value;
            }
            elsif ($takes eq 'required_argument' && $optind + 1 < @argv) {
                $optarg = $argv[++$optind];
            }
            elsif ($takes eq 'required_argument') {
                print STDERR $PROGRAM_NAME,
                    ": option '--$long' requires an argument\n";
                return '?';
            }
            else {
                $optarg = undef;
            }
            $optind++;
            return [$short // "L$long", $optarg];
        }

        # A short option cluster.
        my $cluster = substr $token, 1;
        my $pos = $short_position;
        while ($pos < length $cluster) {
            my $c = substr $cluster, $pos, 1;
            $pos++;
            unless (index('bBcdDeEfFgilnNoprRstTuvVxYzZ', $c) >= 0) {
                print STDERR $PROGRAM_NAME, ": invalid option -- '$c'\n";
                return '?';
            }
            my $takes = index('BdDFgiprVoxYz', $c) >= 0 ? 1 : 0;
            if ($takes) {
                if ($pos < length $cluster) {
                    $optarg = substr $cluster, $pos;
                }
                elsif ($optind + 1 < @argv) {
                    $optarg = $argv[++$optind];
                }
                else {
                    print STDERR $PROGRAM_NAME,
                        ": option requires an argument -- '$c'\n";
                    return '?';
                }
                $optind++;
                $short_position = 0;
                return [$c, $optarg];
            }
            $short_position = $pos;
            if ($pos >= length $cluster) { $optind++; $short_position = 0 }
            return [$c, undef];
        }
        $optind++;
        return [undef, undef];   # a bare "-"
    };

    # Process one switch; mirrors the case statement of GNU patch.
    my $process_switch = sub {
        my ($c, $arg) = @_;
        $arg = '' unless defined $arg;
        if ($c =~ /^L/) {
            my $long = substr $c, 1;
            if    ($long eq 'dry-run')     { $DRY_RUN = 1 }
            elsif ($long eq 'verbose')     { $VERBOSITY = VERBOSE }
            elsif ($long eq 'binary')      { $NO_STRIP_TRAILING_CR = 1 }
            elsif ($long eq 'help')        { usage(\*STDOUT, EXIT_SUCCESS) }
            elsif ($long eq 'backup-if-mismatch') {
                $BACKUP_IF_MISMATCH = 1;
                $BACKUP_IF_MISMATCH_SPECIFIED = 1;
            }
            elsif ($long eq 'no-backup-if-mismatch') {
                $BACKUP_IF_MISMATCH = 0;
                $BACKUP_IF_MISMATCH_SPECIFIED = 1;
            }
            elsif ($long eq 'posix')       { $POSIXLY_CORRECT = 1 }
            elsif ($long eq 'quoting-style') {
                my $i = argmatch($arg, \@QUOTING_STYLE_ARGS);
                if ($i < 0) {
                    argmatch_invalid('quoting style', $arg, $i);
                    usage(\*STDERR, EXIT_TROUBLE);
                }
                set_quoting_style($QUOTING_STYLE_ARGS[$i]);
            }
            elsif ($long eq 'reject-format') {
                if    ($arg eq 'context') { $REJECT_FORMAT = NEW_CONTEXT_DIFF }
                elsif ($arg eq 'unified') { $REJECT_FORMAT = UNI_DIFF }
                else { usage(\*STDERR, EXIT_TROUBLE) }
            }
            elsif ($long eq 'read-only') {
                if    ($arg eq 'ignore') { $READ_ONLY_BEHAVIOR = 'ignore' }
                elsif ($arg eq 'warn')   { $READ_ONLY_BEHAVIOR = 'warn' }
                elsif ($arg eq 'fail')   { $READ_ONLY_BEHAVIOR = 'fail' }
                else { usage(\*STDERR, EXIT_TROUBLE) }
            }
            elsif ($long eq 'follow-symlinks') { $FOLLOW_SYMLINKS = 1 }
            elsif ($long eq 'merge') {
                $MERGE = 1;
                if ($arg ne '') {
                    if    ($arg eq 'merge') { $CONFLICT_STYLE = 'merge' }
                    elsif ($arg eq 'diff3') { $CONFLICT_STYLE = 'diff3' }
                    else { usage(\*STDERR, EXIT_TROUBLE) }
                }
                else {
                    $CONFLICT_STYLE = 'merge';
                }
            }
            return;
        }
        if    ($c eq 'b') {
            $MAKE_BACKUPS = 1;
            # Special hack for backward compatibility with CVS 1.9.  If the
            # last 4 args are '-b SUFFIX ORIGFILE PATCHFILE', treat '-b' as
            # if it were '-b -z'.
            if ($optind < @argv - 2
                && $argv[$optind - 1] eq '-b'
                && !($argv[$optind] =~ /^-.+/)
                && !($argv[$optind + 1] =~ /^-.+/)
                && !($argv[$optind + 2] =~ /^-.+/)) {
                $optarg = $argv[$optind++];
                say("warning: the '-b $optarg' option is obsolete; "
                    . "use '-b -z $optarg' instead\n")
                    if $VERBOSITY != SILENT;
                $ORIGSUFF = backup_file_name_option('suffix', $optarg);
            }
        }
        elsif ($c eq 'B') { $ORIGPRAE = backup_file_name_option('prefix', $arg) }
        elsif ($c eq 'c') { $DIFF_TYPE = CONTEXT_DIFF }
        elsif ($c eq 'd') {
            chdir($arg)
                or pfatal("Can't change to directory %s", quotearg($arg));
        }
        elsif ($c eq 'D') { $DO_DEFINES = $arg }
        elsif ($c eq 'e') { $DIFF_TYPE = ED_DIFF }
        elsif ($c eq 'E') { $REMOVE_EMPTY_FILES = 1 }
        elsif ($c eq 'f') { $FORCE = 1 }
        elsif ($c eq 'F') { $MAXFUZZ = numeric_string($arg, 0, 'fuzz factor') }
        elsif ($c eq 'g') {
            $PATCH_GET = numeric_string($arg, 1, 'get option value');
        }
        elsif ($c eq 'i') { $PATCHNAME = $arg }
        elsif ($c eq 'l') { $CANONICALIZE_WS = 1 }
        elsif ($c eq 'n') { $DIFF_TYPE = NORMAL_DIFF }
        elsif ($c eq 'N') { $NOREVERSE_FLAG = 1 }
        elsif ($c eq 'o') { $OUTFILE = $arg }
        elsif ($c eq 'p') { $STRIPPATH = numeric_string($arg, 0, 'strip count') }
        elsif ($c eq 'r') { $OUTREJ_NAME = $arg }
        elsif ($c eq 'R') {
            $REVERSE_FLAG = 1;
            $REVERSE_FLAG_SPECIFIED = 1;
        }
        elsif ($c eq 's') { $VERBOSITY = SILENT }
        elsif ($c eq 't') { $BATCH = 1 }
        elsif ($c eq 'T') { $SET_TIME = 1 }
        elsif ($c eq 'u') { $DIFF_TYPE = UNI_DIFF }
        elsif ($c eq 'v') { version(); exit EXIT_SUCCESS }
        elsif ($c eq 'V') {
            $VERSION_CONTROL = $arg;
            $VERSION_CONTROL_CONTEXT = '--version-control or -V option';
        }
        elsif ($c eq 'x') { $DEBUG = numeric_string($arg, 1, 'debugging option') }
        elsif ($c eq 'Y') { $ORIGBASE = backup_file_name_option('basename prefix', $arg) }
        elsif ($c eq 'z') { $ORIGSUFF = backup_file_name_option('suffix', $arg) }
        elsif ($c eq 'Z') { $SET_UTC = 1 }
        else {
            die "internal: unhandled option $c\n";
        }
    };

    while (!$end_of_options && $optind < @argv) {
        my $result = $read_option->();
        if (!defined $result) {
            last if $require_order;
            # GNU permutation: look ahead for the next option and move it
            # behind the operands seen so far.
            my $j = $optind;
            while (++$j < @argv) {
                my $token = $argv[$j];
                next if length($token) < 2 || substr($token, 0, 1) ne '-';
                my $separate_argument = 0;
                if ($token =~ /\A--([^=]+)\z/ && $token ne '--') {
                    my $name = $1;
                    my ($entry) = grep { $_->[0] eq $name } @LONGOPTS;
                    if (!$entry) {
                        my @matches = grep { index($_->[0], $name) == 0 } @LONGOPTS;
                        $entry = $matches[0] if @matches == 1;
                    }
                    $separate_argument = $entry && $entry->[1] eq 'required_argument';
                }
                elsif (substr($token, 0, 2) ne '--') {
                    for my $position (1 .. length($token) - 1) {
                        my $letter = substr($token, $position, 1);
                        if (index('BdDFgiprVoxYz', $letter) >= 0) {
                            $separate_argument = $position == length($token) - 1;
                            last;
                        }
                    }
                }
                my $count = $separate_argument && $j + 1 < @argv ? 2 : 1;
                my @option = splice(@argv, $j, $count);
                splice(@argv, $optind, 0, @option);
                last;
            }
            last if $j >= @argv;   # only operands remain
            $result = $read_option->();
        }
        if ($result eq 'done') {
            $end_of_options = 1;
            last;
        }
        if ($result eq '?') {
            usage(\*STDERR, EXIT_TROUBLE);
        }
        my ($key, $arg) = @$result;
        next unless defined $key;
        $process_switch->($key, $arg);
    }

    # Process any file name args.
    if ($optind < @argv) {
        $INNAME = $argv[$optind++];
        $EXPLICIT_INNAME = 1;
        $INVC = -1;
        if ($optind < @argv) {
            $PATCHNAME = $argv[$optind++];
            if ($optind < @argv) {
                print STDERR $PROGRAM_NAME, ': ',
                    quotearg($argv[$optind]), ": extra operand\n";
                usage(\*STDERR, EXIT_TROUBLE);
            }
        }
    }
}

sub backup_file_name_option {
    my ($option_type, $arg) = @_;
    fatal('backup %s is empty', $option_type) if $arg eq '';
    return $arg;
}

# ==========================================================================
# 5. Reading the patch file
# ==========================================================================
#
# GNU reads the patch file through pfp with fseeko; we keep the whole patch
# input in memory and use offsets.  pget_line is a line-level port of the C
# original, including indentation stripping, RFC 934 encapsulation, trailing
# CR stripping, comment skipping, and NUL byte diagnosis.

sub re_patch {
    ($P_FIRST, $P_NEWFIRST, $P_PTRN_LINES, $P_REPL_LINES) = (0, 0, 0, 0);
    $P_END = -1;
    $P_MAX = 0;
    $P_INDENT = 0;
    $P_STRIP_TRAILING_CR = 0;
}

sub ensure_hunk_capacity {
    my ($needed) = @_;
    while ($needed + 1 >= $HUNK_CAPACITY) {
        $HUNK_CAPACITY = int($HUNK_CAPACITY * 1.5) + 1;
    }
}

sub open_patch_file {
    my ($filename) = @_;
    if (!defined $filename || $filename eq '' || $filename eq '-') {
        $PATCHFILE_DATA = read_all(\*STDIN);
    }
    else {
        open my $fh, '<:raw', $filename
            or pfatal("Can't open patch file %s", quotearg($filename));
        $PATCHFILE_DATA = read_all($fh);
        close $fh;
    }
    $PATCHFILE_SIZE = length $PATCHFILE_DATA;
    next_intuit_at(0, 1);
}

sub next_intuit_at {
    my ($file_pos, $file_line) = @_;
    ($P_BASE, $P_BLINE) = ($file_pos, $file_line);
}

sub skip_to {
    my ($file_pos, $file_line) = @_;
    if (($VERBOSITY == VERBOSE || !defined $INNAME) && $P_BASE < $file_pos) {
        say("The text leading up to this was:\n--------------------------\n");
        my $pos = $P_BASE;
        while ($pos < $file_pos) {
            my $nl = index($PATCHFILE_DATA, "\n", $pos);
            my $line = substr($PATCHFILE_DATA, $pos,
                              ($nl < 0 ? $PATCHFILE_SIZE : $nl + 1) - $pos);
            say('|', $line);
            $pos = $nl < 0 ? $PATCHFILE_SIZE : $nl + 1;
        }
        say("--------------------------\n");
    }
    $PFP_POS = $file_pos;
    $P_INPUT_LINE = $file_line - 1;
}

sub is_space_byte { my $b = substr $_[0], 0, 1; $b =~ /[ \t\n\v\f\r]/ }

sub pget_line {
    my ($indent, $rfc934_nesting, $strip_trailing_cr,
        $pass_comments_through, $allow_nul) = @_;
    my $got_invalid_byte;
    my $line;
    my $c;

    do {
        my $i = 0;
        while (1) {
            if ($PFP_POS >= $PATCHFILE_SIZE) { return 0 }
            $c = substr($PATCHFILE_DATA, $PFP_POS, 1);
            $PFP_POS++;
            last if $indent <= $i;
            if    ($c eq ' ' || $c eq 'X') { $i++ }
            elsif ($c eq "\t")             { $i = ($i + 8) & ~7 }
            else { $got_invalid_byte = 1 if $c eq "\0" && !$allow_nul }
        }

        $i = 0;
        $line = '';

        while ($c eq '-' && 0 <= --$rfc934_nesting) {
            if ($PFP_POS >= $PATCHFILE_SIZE) {
                say("patch unexpectedly ends in middle of line\n");
                return 0;
            }
            $c = substr($PATCHFILE_DATA, $PFP_POS, 1);
            $PFP_POS++;
            if ($c ne ' ') {
                $i = 1;
                $line = '-';
                $got_invalid_byte = 1 if $c eq "\0" && !$allow_nul;
                last;
            }
            if ($PFP_POS >= $PATCHFILE_SIZE) {
                say("patch unexpectedly ends in middle of line\n");
                return 0;
            }
            $c = substr($PATCHFILE_DATA, $PFP_POS, 1);
            $PFP_POS++;
        }

        while (1) {
            $line .= $c;
            $got_invalid_byte = 1 if $c eq "\0" && !$allow_nul;
            last if $c eq "\n";
            if ($PFP_POS >= $PATCHFILE_SIZE) {
                say("patch unexpectedly ends in middle of line\n");
                return 0;
            }
            $c = substr($PATCHFILE_DATA, $PFP_POS, 1);
            $PFP_POS++;
        }

        $P_INPUT_LINE++;
    }
    while (substr($line, 0, 1) eq '#' && !$pass_comments_through);

    fatal("patch line %d contains NUL byte", $P_INPUT_LINE)
        if $got_invalid_byte;

    if ($strip_trailing_cr && 2 <= length($line)
        && substr($line, length($line) - 2, 1) eq "\r") {
        $line = substr($line, 0, length($line) - 2) . "\n";
    }
    $PATCHBUF = $line;
    return length $line;
}

sub get_line {
    my ($allow_nul) = @_;
    return pget_line($P_INDENT, $P_RFC934_NESTING, $P_STRIP_TRAILING_CR,
                     $P_PASS_COMMENTS_THROUGH, $allow_nul);
}

sub incomplete_line {
    # Peek at the next patch line; if it begins with a backslash, consume
    # it (through its newline) and return true.
    return 0 if $PFP_POS >= $PATCHFILE_SIZE;
    return 0 unless substr($PATCHFILE_DATA, $PFP_POS, 1) eq '\\';
    my $nl = index($PATCHFILE_DATA, "\n", $PFP_POS);
    $PFP_POS = $nl < 0 ? $PATCHFILE_SIZE : $nl + 1;
    return 1;
}

# ==========================================================================
# 6. Hunk accessors
# ==========================================================================

sub pch_says_nonexistent { $P_SAYS_NONEXISTENT[$_[0]] // 0 }
sub pch_name             { $_[0] == NONE ? undef : $P_NAME[$_[0]] }
sub pch_copy             { $P_COPY[OLD] && $P_COPY[NEW] }
sub pch_rename           { $P_RENAME[OLD] && $P_RENAME[NEW] }
sub pch_first            { $P_FIRST }
sub pch_ptrn_lines       { $P_PTRN_LINES }
sub pch_newfirst         { $P_NEWFIRST }
sub pch_repl_lines       { $P_REPL_LINES }
sub pch_end              { $P_END }
sub pch_prefix_context   { $P_PREFIX_CONTEXT }
sub pch_suffix_context   { $P_SUFFIX_CONTEXT }
sub pch_line_len         { $P_LEN[$_[0]] }
sub pch_char             { $P_CHAR[$_[0]] }
sub pfetch               { $P_LINE[$_[0]] }
sub pch_hunk_beg         { $P_HUNK_BEG }
sub pch_c_function       { $P_C_FUNCTION }
sub pch_git_diff         { $P_GIT_DIFF }
sub pch_timestr          { $P_TIMESTR[$_[0]] }
sub pch_mode             { $P_MODE[$_[0]] }

sub pch_write_line {
    my ($line, $fh) = @_;
    my $text = substr($P_LINE[$line], 0, $P_LEN[$line]);
    my $after_newline = length($text) > 0
        && substr($text, length($text) - 1, 1) eq "\n";
    fput($fh, $text);
    return $after_newline;
}

sub malformed {
    fatal("malformed patch at line %d: %s", $P_INPUT_LINE, $PATCHBUF);
}

sub scan_linenum {
    # Parse a line number from a string, returning (next_offset, number).
    my ($string, $offset) = @_;
    my $n = 0;
    my $overflow = 0;
    my $pos = $offset;
    $pos++ while substr($string, $pos, 1) =~ /[ \t\n\v\f\r]/;
    my $digits_start = $pos;
    while (substr($string, $pos, 1) =~ /[0-9]/) {
        my $digit = substr($string, $pos, 1);
        $overflow = 1 if $n > (9223372036854775807 - $digit) / 10;
        $n = $n * 10 + $digit;
        $pos++;
    }
    if ($pos == $digits_start) {
        fatal("missing line number at line %d: %s", $P_INPUT_LINE, $PATCHBUF);
    }
    if ($overflow) {
        fatal("line number %s is too large at line %d: %s",
              substr($string, $digits_start, $pos - $digits_start),
              $P_INPUT_LINE, $PATCHBUF);
    }
    $pos++ while substr($string, $pos, 1) =~ /[ \t\n\v\f\r]/;
    return ($pos, $n);
}

# ==========================================================================
# 7. File names, timestamps, and patch headers
# ==========================================================================

sub c_isdigit { substr($_[0], 0, 1) =~ /[0-9]/ }
sub c_isblank { substr($_[0], 0, 1) =~ /[ \t]/ }

sub parse_c_string {
    # Decode a C string literal starting at $offset in $text; return
    # (decoded_bytes, next_offset) or (undef, next_offset) on failure.
    my ($text, $offset) = @_;
    my $out = '';
    my $pos = $offset + 1;         # skip the opening quote
    while (1) {
        my $c = substr($text, $pos, 1);
        if ($c eq '') { return (undef, $pos) }
        $pos++;
        if ($c eq '"') { return ($out, $pos) }
        if ($c ne '\\') { $out .= $c; next }
        my $e = substr($text, $pos, 1);
        $pos++;
        my %simple = (a => "\a", b => "\b", f => "\f",
                      n => "\n", r => "\r", t => "\t",
                      v => "\x0b");
        if    (exists $simple{$e}) { $out .= $simple{$e} }
        elsif ($e eq '\\' || $e eq '"') { $out .= $e }
        elsif ($e =~ /[0-3]/) {
            my $acc = ord($e) - ord('0');
            for (1 .. 2) {
                my $d = substr($text, $pos, 1);
                if ($d !~ /[0-7]/) { return (undef, $pos) }
                $acc = ($acc << 3) | (ord($d) - ord('0'));
                $pos++;
            }
            return (undef, $pos) if $acc == 0;
            $out .= chr $acc;
        }
        else { return (undef, $pos) }
    }
}

sub strip_leading_slashes {
    # Strip up to $strip_leading leading slash groups from $name (in place);
    # a negative count strips all.  Return success.
    my ($name, $strip_leading) = @_;
    my $s = $strip_leading;
    my $p = 0;
    my $n = 0;
    my $len = length $name;
    while ($p < $len) {
        if (substr($name, $p, 1) eq '/') {
            $p++ while substr($name, $p + 1, 1) eq '/';
            if ($strip_leading < 0 || --$s >= 0) { $n = $p + 1 }
        }
        $p++;
    }
    if (($strip_leading < 0 || $s <= 0) && $n < $len) {
        $_[0] = substr($name, $n);
        return 1;
    }
    return 0;
}

my %CTIME_MONTHS = (
    Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5,
    Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11,
);

sub parse_datetime {
    # Parse the timestamp formats GNU diff emits, plus traditional ctime.
    # Return [seconds, nanoseconds] or undef.
    my ($text) = @_;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;

    my ($sec, $nsec) = (undef, 0);

    if ($text =~ /\A
        (\d{4})-(\d{2})-(\d{2})[T ]
        (\d{2}):(\d{2}):(\d{2})(\.\d+)?
        (?:[ ]([+-]\d{2}):?(\d{2})|Z)?
        \z
    /x) {
        my ($y, $mo, $d, $h, $mi, $s, $frac, $tzh, $tzm) =
            ($1, $2, $3, $4, $5, $6, $7, $8, $9);
        eval {
            $sec = timegm(0, 0, 0, $d, $mo - 1, $y)
                 + $h * 3600 + $mi * 60 + $s;
        };
        return undef if $@;
        if (defined $frac) {
            $nsec = substr($frac, 1) . '000000000';
            $nsec = substr($nsec, 0, 9);
        }
        if (defined $tzh) {
            my $offset = ($tzh =~ /^\-/ ? -1 : 1)
                * (abs($tzh) * 3600 + $tzm * 60);
            $sec -= $offset;
        }
        else {
            # No zone: interpret in local time.
            eval {
                my $local = timelocal(0, 0, 0, $d, $mo - 1, $y)
                          + $h * 3600 + $mi * 60 + $s;
                $sec = $local;
            };
            return undef if $@;
        }
    }
    elsif ($text =~ /\A
        (Mon|Tue|Wed|Thu|Fri|Sat|Sun)[ ]
        (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[ ]+
        (\d{1,2})[ ]
        (\d{2}):(\d{2}):(\d{2})[ ]
        (\d{4})
        \z
    /x) {
        my ($wday, $mon, $d, $h, $mi, $s, $y) = ($1, $2, $3, $4, $5, $6, $7);
        my $mo = $CTIME_MONTHS{$mon};
        eval { $sec = timelocal(0, $mi, $h, $d, $mo, $y) };
        return undef if $@;
    }
    else {
        return undef;
    }
    return [$sec, $nsec];
}

sub fetchname {
    # Parse a header file name (and optional timestamp) from $at.
    # $name_slot and $timestr_slot are indices into @P_NAME/@P_TIMESTR;
    # $stamp_ref is a reference to a [sec, nsec] pair, or undef.
    my ($at, $strip_leading, $name_slot, $timestr_slot, $stamp_ref) = @_;
    my ($name, $timestr);
    my $stamp = [-1, -1];

    my $pos = 0;
    $pos++ while $pos < length($at) && is_space_byte(substr($at, $pos, 1));

    my $t;
    if (substr($at, $pos, 1) eq '"') {
        (my $decoded, my $end) = parse_c_string($at, $pos);
        if (!defined $decoded) {
            say("ignoring malformed filename ", quotearg($at), "\n")
                if $DEBUG & 128;
            return;
        }
        ($name, $t) = ($decoded, $end);
    }
    else {
        $t = $pos;
        while ($t < length $at) {
            my $byte = substr($at, $t, 1);
            if (is_space_byte($byte)) {
                # Allow file names with internal spaces, but only if a tab
                # separates the file name from the date.
                my $u = $t;
                $u++ while substr($at, $u, 1) ne "\t"
                          && is_space_byte(substr($at, $u + 1, 1));
                if (substr($at, $u, 1) ne "\t"
                    && index(substr($at, $u + 1),
                             defined $stamp_ref ? "\t" : "\n") >= 0) {
                    $t++;
                    next;
                }
                last;
            }
            $t++;
        }
        $name = substr($at, $pos, $t - $pos);
    }

    # Names are C strings: truncation at the first NUL byte.
    my $nul = index($name, "\0");
    $name = substr($name, 0, $nul) if $nul >= 0;

    # If the name is "/dev/null", ignore the name and mark the file as
    # being nonexistent.
    if ($name eq '/dev/null') {
        return unless defined $stamp_ref;
        $$stamp_ref = [0, 0];
        return;
    }

    # Ignore the name if it doesn't have enough slashes to strip off.
    if (!strip_leading_slashes($name, $strip_leading)) {
        return;
    }

    if (defined $timestr_slot) {
        my $u = length $at;
        $u-- if $u != $t && substr($at, $u - 1, 1) eq "\n";
        $u-- if $u != $t && substr($at, $u - 1, 1) eq "\r";
        $P_TIMESTR[$timestr_slot] = substr($at, $t, $u - $t);
    }

    if ($t < length($at) && substr($at, $t, 1) ne "\n") {
        return unless defined $stamp_ref;
        my $parsed = parse_datetime(substr($at, $t));
        if (defined $parsed && !($SET_TIME || $SET_UTC)) {
            my ($sec) = @$parsed;
            # The head says a file is nonexistent if its timestamp is the
            # epoch; allow for the range of local time offsets.
            if (-25 * 3600 < $sec && $sec < 26 * 3600) {
                $parsed = [0, 0];
            }
        }
        $stamp = $parsed if defined $parsed;
    }

    $P_NAME[$name_slot] = $name;
    $$stamp_ref = $stamp if defined $stamp_ref;
}

sub parse_name {
    # Parse a name from $text at $offset; return (name, next_offset) or
    # (undef, next_offset).
    my ($text, $offset, $strip_leading) = @_;
    my ($name, $end);
    my $pos = $offset;
    $pos++ while $pos < length($text) && is_space_byte(substr($text, $pos, 1));
    if (substr($text, $pos, 1) eq '"') {
        ($name, $end) = parse_c_string($text, $pos);
        return (undef, $end) unless defined $name;
    }
    else {
        $end = $pos;
        $end++ while $end < length $text
            && !is_space_byte(substr($text, $end, 1));
        $name = substr($text, $pos, $end - $pos);
    }
    my $nul = index($name, "\0");
    $name = substr($name, 0, $nul) if $nul >= 0;
    if (!strip_leading_slashes($name, $strip_leading)) {
        return (undef, $end);
    }
    return ($name, $end);
}

sub fetchmode {
    # Scan a Git-style mode; return the mode_t value or 0 on failure.
    my ($str) = @_;
    my $len = length $str;
    my $i = 0;
    $i++ while $i < $len && is_space_byte(substr($str, $i, 1));
    my $mode = 0;
    for (my $s = 0; $s < 6; $s++) {
        my $byte = substr($str, $i, 1);
        return 0 unless $byte =~ /[0-7]/;
        $mode = ($mode << 3) + ord($byte) - ord('0');
        $i++;
    }
    my $byte = substr($str, $i, 1);
    $i++ if $byte eq "\r";
    return 0 unless substr($str, $i, 1) eq "\n";

    # Check the file type, and convert Git's numbering if needed.
    my $file_type;
    my $type_bits = $mode >> 9;
    if    ($type_bits == 0100) { $file_type = 0100000 }   # S_IFREG
    elsif ($type_bits == 0120) { $file_type = 0120000 }   # S_IFLNK
    else                       { return 0 }

    my $m = $file_type | ($mode & 0777);
    fatal("mode %.6s treated as missing at line %d: %s",
          substr($str, 0, 6), $P_INPUT_LINE, $PATCHBUF)
        unless $m;
    return $m;
}

sub sha1_says_nonexistent {
    my ($sha1) = @_;
    return 2 if $sha1 =~ /\A0*\z/;
    my $empty_sha1 = 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391';
    for my $i (0 .. length($sha1) - 1) {
        return 0 if substr($sha1, $i, 1) ne substr($empty_sha1, $i, 1);
    }
    return 1;
}

sub skip_hex_digits {
    my ($text, $pos) = @_;
    my $start = $pos;
    $pos++ while $pos < length($text) && substr($text, $pos, 1) =~ /[0-9a-f]/;
    return $start < $pos ? $pos : undef;
}

sub name_is_valid {
    my ($name) = @_;
    my $i = 0;
    for my $invalid (@INVALID_NAMES) {
        last if !defined $invalid;
        return 0 if $invalid eq $name;
        $i++;
    }
    my $is_valid = filename_is_safe($name);

    # Allow any filename if we are in the filesystem root.
    if (!$is_valid && cwd_is_root()) {
        $is_valid = 1;
    }

    if (!$is_valid && $i < 2) {
        say("Ignoring potentially dangerous file name ", quotearg($name), "\n");
        $INVALID_NAMES[$i] = $name;
    }
    return $is_valid;
}

sub filename_is_safe {
    # True if NAME is relative and free of ".." components.
    my ($name) = @_;
    return 0 if substr($name, 0, 1) eq '/';
    my $pos = 0;
    my $len = length $name;
    while ($pos < $len) {
        if (substr($name, $pos, 1) eq '.') {
            $pos++;
            if (substr($name, $pos, 1) eq '.') {
                $pos++;
                my $next = substr($name, $pos, 1);
                return 0 if $next eq '' || $next eq '/';
            }
        }
        $pos++ while $pos < $len && substr($name, $pos, 1) ne '/';
        $pos++ while substr($name, $pos, 1) eq '/';
    }
    return 1;
}

sub cwd_is_root {
    my ($root_dev, $root_ino) = (stat('/'))[0, 1];
    my ($cwd_dev, $cwd_ino) = (stat('.'))[0, 1];
    return defined $root_dev && defined $cwd_dev
        && $root_dev == $cwd_dev && $root_ino == $cwd_ino;
}

sub prefix_components {
    # Count the path name components in FILENAME's prefix; with $checkdirs,
    # count only existing directories.
    my ($filename, $checkdirs) = @_;
    my $count = 0;
    my $len = length $filename;
    return $count unless $len;
    my $f = 0;
    while (1) {
        $f++;
        last if $f >= $len;
        if (substr($filename, $f, 1) eq '/'
            && substr($filename, $f - 1, 1) ne '/') {
            if ($checkdirs) {
                last unless -d substr($filename, 0, $f);
            }
            $count++;
        }
    }
    return $count;
}

# ==========================================================================
# 8. Finding the next patch and its file names
# ==========================================================================

sub there_is_another_patch {
    my ($need_header, $p_file_type_ref) = @_;

    if ($P_BASE != 0 && $P_BASE >= $PATCHFILE_SIZE) {
        say("done\n") if $VERBOSITY == VERBOSE;
        return 0;
    }
    say("Hmm...") if $VERBOSITY == VERBOSE;
    $DIFF_TYPE = intuit_diff_type($need_header, $p_file_type_ref);
    if ($DIFF_TYPE == NO_DIFF) {
        if ($VERBOSITY == VERBOSE) {
            say($P_BASE
                ? "  Ignoring the trailing garbage.\ndone\n"
                : "  I can't seem to find a patch in there anywhere.\n");
        }
        if (!$P_BASE && $PATCHFILE_SIZE) {
            fatal("Only garbage was found in the patch input.");
        }
        return 0;
    }
    if ($SKIP_REST_OF_PATCH) {
        $PFP_POS = $P_START;
        $P_INPUT_LINE = $P_SLINE - 1;
        return 1;
    }
    if ($VERBOSITY == VERBOSE) {
        my $looks = $P_BASE == 0 ? 'L' : 'The next patch l';
        say("  ${looks}ooks like ", (DIFF_NAMES())[$DIFF_TYPE],
            " to me...\n");
    }

    $P_STRIP_TRAILING_CR = 0 if $NO_STRIP_TRAILING_CR;

    if ($VERBOSITY != SILENT) {
        if ($P_INDENT) {
            say("(Patch is indented $P_INDENT space",
                $P_INDENT == 1 ? '' : 's', ".)\n");
        }
        if ($P_STRIP_TRAILING_CR) {
            say("(Stripping trailing CRs from patch; use --binary to disable.)\n");
        }
        if (!$INNAME) {
            say("can't find file to patch at input line $P_SLINE\n");
            if ($DIFF_TYPE != ED_DIFF && $DIFF_TYPE != NORMAL_DIFF) {
                say($STRIPPATH < 0
                    ? "Perhaps you should have used the -p or --strip option?\n"
                    : "Perhaps you used the wrong -p or --strip option?\n");
            }
        }
    }

    skip_to($P_START, $P_SLINE);
    while (!$INNAME) {
        if ($FORCE || $BATCH) {
            say("No file to patch.  Skipping patch.\n");
            $SKIP_REST_OF_PATCH = 1;
            return 1;
        }
        my $answer = ask("File to patch: ");
        my $answerlen = length $answer;
        if (1 < $answerlen && substr($answer, $answerlen - 1, 1) eq "\n") {
            $INNAME = substr($answer, 0, $answerlen - 1);
            $INERRNO = stat_file($INNAME, \%INSTAT);
            if ($INERRNO) {
                print STDERR $INNAME;
                putline(\*STDERR, ': ', errno_text($INERRNO));
                undef $INNAME;
            }
            else {
                $INVC = -1;
            }
        }
        if (!$INNAME) {
            if (substr(ask("Skip this patch? [y] "), 0, 1) ne 'n') {
                say("Skipping patch.\n") if $VERBOSITY != SILENT;
                $SKIP_REST_OF_PATCH = 1;
                return 1;
            }
        }
    }
    return 1;
}

sub maybe_reverse {
    my ($name, $nonexistent, $is_empty) = @_;
    $nonexistent = $nonexistent ? 1 : 0;
    $is_empty = $is_empty ? 1 : 0;
    my $looks_reversed =
        (!$is_empty ? 1 : 0) < pch_says_nonexistent($REVERSE_FLAG ^ $is_empty);

    # Allow creating and deleting empty files when we know that they are
    # empty: in the "diff --git" format, the index header tells us.
    if ($is_empty
        && pch_says_nonexistent($REVERSE_FLAG ^ $nonexistent) == 1
        && pch_says_nonexistent(!$REVERSE_FLAG ^ $nonexistent) == 2) {
        return 0;
    }

    if ($looks_reversed) {
        $REVERSE_FLAG = $REVERSE_FLAG
            ^ ok_to_reverse("The next patch"
                            . ($REVERSE_FLAG ? ", when reversed," : '')
                            . " would "
                            . ($nonexistent ? 'delete'
                               : $is_empty ? 'empty out'
                               : 'create')
                            . " the file " . quotearg($name) . ",\nwhich "
                            . ($nonexistent ? 'does not exist'
                               : $is_empty ? 'is already empty'
                               : 'already exists') . "!");
    }
    return $looks_reversed;
}

sub get_ed_command_letter {
    # Is the line a valid 'ed' command for patch input?  Return the command
    # letter, or '' if not.
    my ($line) = @_;
    my $p = 0;
    my $pair = 0;
    my $len = length $line;

    if ($p < $len && c_isdigit(substr($line, $p, 1))) {
        $p++ while $p < $len && c_isdigit(substr($line, $p, 1));
        if (substr($line, $p, 1) eq ',') {
            $p++;
            return '' unless $p < $len && c_isdigit(substr($line, $p, 1));
            $p++ while $p < $len && c_isdigit(substr($line, $p, 1));
            $pair = 1;
        }
    }

    my $letter = substr($line, $p, 1);
    $p++;

    if ($letter eq 'a' || $letter eq 'i') { return '' if $pair }
    elsif ($letter eq 'c' || $letter eq 'd') { }
    elsif ($letter eq 's') {
        return '' unless substr($line, $p, 4) eq '/.//';
        $p += 4;
    }
    else { return '' }

    $p++ while $p < $len && c_isblank(substr($line, $p, 1));
    return $letter if substr($line, $p, 1) eq "\n";
    return '';
}

sub says_nonexistent_from_timestamp {
    my ($stamp) = @_;
    return 1 + !($stamp->[0] ? 1 : 0);
}

sub names_or_epoch_ok {
    my ($which) = @_;
    my $name = defined $P_NAME[$which] ? $P_NAME[$which] : '';
    my $sec = $P_TIMESTAMP[$which][0];
    return $name ne '' || $sec == 0;
}

sub intuit_diff_type {
    my ($need_header, $p_file_type_ref) = @_;
    my ($this_line, $previous_line) = (0, 0);
    my $first_command_line = -1;
    my $first_ed_command_letter = '';
    my $fcl_line = 0;
    my $this_is_a_command = 0;
    my $stars_this_line = 0;
    my $extended_headers = 0;
    my $i = NONE;
    my (@st, @stat_errno, @version_controlled);
    my $retval;
    my $file_type;
    my $indent = 0;

    undef @P_NAME;
    undef @INVALID_NAMES;
    undef @P_TIMESTR;
    undef @P_SHA1;
    $P_GIT_DIFF = 0;
    for my $which (OLD, NEW) {
        $P_MODE[$which] = 0;
        $P_COPY[$which] = 0;
        $P_RENAME[$which] = 0;
    }

    # Ed and normal format patches don't have filename headers.
    if ($DIFF_TYPE == ED_DIFF || $DIFF_TYPE == NORMAL_DIFF) {
        $need_header = 0;
    }

    @version_controlled[OLD, NEW, INDEX] = (-1, -1, -1);
    $P_RFC934_NESTING = 0;
    @P_TIMESTAMP[OLD, NEW] = ([-1, -1], [-1, -1]);
    @P_SAYS_NONEXISTENT[OLD, NEW] = (0, 0);
    $PFP_POS = $P_BASE;
    $P_INPUT_LINE = $P_BLINE - 1;
    while (1) {
        my $t;
        $previous_line = $this_line;
        my $last_line_was_command = $this_is_a_command;
        my $stars_last_line = $stars_this_line;
        my $indent_last_line = $indent;
        my $strip_trailing_cr;

        $indent = 0;
        $this_line = $PFP_POS;
        my $chars_read = pget_line(0, 0, 0, 0, 0);
        if (!$chars_read) {
            if ($first_ed_command_letter ne '') {
                # Nothing but deletes!?
                ($P_START, $P_SLINE) = ($first_command_line, $fcl_line);
                $retval = ED_DIFF;
                goto scan_exit;
            }
            else {
                ($P_START, $P_SLINE) = ($this_line, $P_INPUT_LINE);
                if ($extended_headers) {
                    # Patch contains no hunks; any diff type will do.
                    $retval = UNI_DIFF;
                    goto scan_exit;
                }
                return NO_DIFF;
            }
        }
        $strip_trailing_cr = 2 <= $chars_read
            && substr($PATCHBUF, $chars_read - 2, 1) eq "\r";
        my $s = 0;
        $s++ while $s < length $PATCHBUF
            && (c_isblank(substr($PATCHBUF, $s, 1))
                || substr($PATCHBUF, $s, 1) eq 'X');
        {
            my $col = 0;
            my $p = 0;
            while ($p < length $PATCHBUF
                   && (c_isblank(substr($PATCHBUF, $p, 1))
                       || substr($PATCHBUF, $p, 1) eq 'X')) {
                if (substr($PATCHBUF, $p, 1) eq "\t") {
                    $col = ($col + 8) & ~7;
                }
                else { $col++ }
                $p++;
            }
            $indent = $col;
        }
        if (c_isdigit(substr($PATCHBUF, $s, 1))) {
            $t = $s + 1;
            $t++ while $t < length $PATCHBUF
                && (c_isdigit(substr($PATCHBUF, $t, 1))
                    || substr($PATCHBUF, $t, 1) eq ',');
            my $byte = substr($PATCHBUF, $t, 1);
            if ($byte eq 'd' || $byte eq 'c' || $byte eq 'a') {
                $t++;
                $t++ while $t < length $PATCHBUF
                    && (c_isdigit(substr($PATCHBUF, $t, 1))
                        || substr($PATCHBUF, $t, 1) eq ',');
                $t++ while c_isblank(substr($PATCHBUF, $t, 1));
                $t++ if substr($PATCHBUF, $t, 1) eq "\r";
                $this_is_a_command = substr($PATCHBUF, $t, 1) eq "\n" ? 1 : 0;
            }
        }
        if (!$need_header
            && $first_command_line < 0
            && ((my $ed_command_letter = get_ed_command_letter(
                     substr($PATCHBUF, $s)))
                || $this_is_a_command)) {
            $first_command_line = $this_line;
            $first_ed_command_letter = $ed_command_letter;
            $fcl_line = $P_INPUT_LINE;
            $P_INDENT = $indent;        # assume this for now
            $P_STRIP_TRAILING_CR = $strip_trailing_cr;
        }
        if (!$stars_last_line
            && substr($PATCHBUF, $s, 3) eq '***'
            && c_isblank(substr($PATCHBUF, $s + 3, 1))) {
            my $stamp = $P_TIMESTAMP[OLD];
            fetchname(substr($PATCHBUF, $s + 4), $STRIPPATH, OLD, OLD,
                      \$P_TIMESTAMP[OLD]);
            $need_header = 0;
        }
        elsif (substr($PATCHBUF, $s, 3) eq '+++'
               && c_isblank(substr($PATCHBUF, $s + 3, 1))) {
            # Swapped with NEW when the hunk header is found.
            fetchname(substr($PATCHBUF, $s + 4), $STRIPPATH, OLD, OLD,
                      \$P_TIMESTAMP[OLD]);
            $need_header = 0;
            $P_STRIP_TRAILING_CR = $strip_trailing_cr;
        }
        elsif (substr($PATCHBUF, $s, 6) eq 'Index:') {
            fetchname(substr($PATCHBUF, $s + 6), $STRIPPATH, INDEX, undef, undef);
            $need_header = 0;
            $P_STRIP_TRAILING_CR = $strip_trailing_cr;
        }
        elsif (substr($PATCHBUF, $s, 7) eq 'Prereq:') {
            my $pos = $s + 7;
            $pos++ while is_space_byte(substr($PATCHBUF, $pos, 1));
            my $word = substr($PATCHBUF, $pos);
            my $k = 0;
            while ($k < length $word) {
                if (is_space_byte(substr($word, $k, 1))) {
                    my $v = $k + 1;
                    $v++ while is_space_byte(substr($word, $v, 1));
                    if ($v < length $word) {
                        say("Prereq: with multiple words at line "
                            . "$P_SLINE of patch\n");
                    }
                    last;
                }
                $k++;
            }
            $REVISION = $k ? substr($word, 0, $k) : undef;
        }
        elsif (substr($PATCHBUF, $s, 11) eq 'diff --git ') {
            if ($extended_headers) {
                ($P_START, $P_SLINE) = ($this_line, $P_INPUT_LINE);
                # Patch contains no hunks; any diff type will do.
                $retval = UNI_DIFF;
                goto scan_exit;
            }

            undef @P_NAME[OLD, NEW];
            my $u;
            (my $name_old, $u) = parse_name($PATCHBUF, $s + 11, $STRIPPATH);
            my $name_new;
            if (defined $name_old && is_space_byte(substr($PATCHBUF, $u, 1))) {
                ($name_new, $u) = parse_name($PATCHBUF, $u, $STRIPPATH);
            }
            if (defined $name_new) {
                my $w = $u;
                $w++ while $w < length $PATCHBUF
                    && is_space_byte(substr($PATCHBUF, $w, 1));
                if ($w >= length $PATCHBUF) {
                    @P_NAME[OLD, NEW] = ($name_old, $name_new);
                }
            }
            $P_GIT_DIFF = 1;
            $need_header = 0;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 6) eq 'index ') {
            my $u = skip_hex_digits($PATCHBUF, $s + 6);
            if (defined $u
                && substr($PATCHBUF, $u, 2) eq '..') {
                my $v = skip_hex_digits($PATCHBUF, $u + 2);
                if (defined $v) {
                    my $after = substr($PATCHBUF, $v, 1);
                    if ($after eq '' || is_space_byte($after)) {
                        $P_SHA1[OLD] = substr($PATCHBUF, $s + 6, $u - ($s + 6));
                        $P_SHA1[NEW] = substr($PATCHBUF, $u + 2, $v - ($u + 2));
                        $P_SAYS_NONEXISTENT[OLD]
                            = sha1_says_nonexistent($P_SHA1[OLD]);
                        $P_SAYS_NONEXISTENT[NEW]
                            = sha1_says_nonexistent($P_SHA1[NEW]);
                        my $w = $v;
                        $w++ while $w < length $PATCHBUF
                            && is_space_byte(substr($PATCHBUF, $w, 1));
                        if ($w < length $PATCHBUF) {
                            my $mode_str = substr($PATCHBUF, $w);
                            $P_MODE[OLD] = $P_MODE[NEW] = fetchmode($mode_str);
                        }
                        $extended_headers = 1;
                    }
                }
            }
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 9) eq 'old mode ') {
            $P_MODE[OLD] = fetchmode(substr($PATCHBUF, $s + 9));
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 9) eq 'new mode ') {
            $P_MODE[NEW] = fetchmode(substr($PATCHBUF, $s + 9));
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 18) eq 'deleted file mode ') {
            $P_MODE[OLD] = fetchmode(substr($PATCHBUF, $s + 18));
            $P_SAYS_NONEXISTENT[NEW] = 2;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 14) eq 'new file mode ') {
            $P_MODE[NEW] = fetchmode(substr($PATCHBUF, $s + 14));
            $P_SAYS_NONEXISTENT[OLD] = 2;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 12) eq 'rename from ') {
            # Git leaves out the prefix in the file name here, so we can
            # only note the operation.
            $P_RENAME[OLD] = 1;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 10) eq 'rename to ') {
            $P_RENAME[NEW] = 1;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 10) eq 'copy from ') {
            $P_COPY[OLD] = 1;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 8) eq 'copy to ') {
            $P_COPY[NEW] = 1;
            $extended_headers = 1;
        }
        elsif ($P_GIT_DIFF && substr($PATCHBUF, $s, 16) eq 'GIT binary patch') {
            ($P_START, $P_SLINE) = ($this_line, $P_INPUT_LINE);
            $retval = GIT_BINARY_DIFF;
            goto scan_exit;
        }
        else {
            $t = $s;
            $t += 2 while substr($PATCHBUF, $t, 2) eq '- ';
            if (substr($PATCHBUF, $t, 3) eq '---'
                && c_isblank(substr($PATCHBUF, $t + 3, 1))) {
                my $timestamp = [-1, -1];
                fetchname(substr($PATCHBUF, $t + 4), $STRIPPATH, NEW, NEW,
                          \$timestamp);
                $need_header = 0;
                if ($timestamp->[1] >= 0) {
                    $P_TIMESTAMP[NEW] = $timestamp;
                    $P_RFC934_NESTING = ($t - $s) >> 1;
                }
                $P_STRIP_TRAILING_CR = $strip_trailing_cr;
            }
        }
        if ($need_header) { next }
        if (($DIFF_TYPE == NO_DIFF || $DIFF_TYPE == ED_DIFF)
            && $first_command_line >= 0
            && $PATCHBUF eq ".\n") {
            ($P_START, $P_SLINE) = ($first_command_line, $fcl_line);
            $retval = ED_DIFF;
            goto scan_exit;
        }
        if (($DIFF_TYPE == NO_DIFF || $DIFF_TYPE == UNI_DIFF)
            && substr($PATCHBUF, $s, 4) eq '@@ -') {

            # 'p_name', 'p_timestr', and 'p_timestamp' are backwards; swap.
            my $ti = $P_TIMESTAMP[OLD];
            $P_TIMESTAMP[OLD] = $P_TIMESTAMP[NEW];
            $P_TIMESTAMP[NEW] = $ti;
            @P_NAME[OLD, NEW] = @P_NAME[NEW, OLD];
            @P_TIMESTR[OLD, NEW] = @P_TIMESTR[NEW, OLD];

            my $p = $s + 4;
            if (substr($PATCHBUF, $p, 1) eq '0'
                && !c_isdigit(substr($PATCHBUF, $p + 1, 1))) {
                $P_SAYS_NONEXISTENT[OLD]
                    = says_nonexistent_from_timestamp($P_TIMESTAMP[OLD]);
            }
            $p++ while substr($PATCHBUF, $p, 1) ne ' '
                && substr($PATCHBUF, $p, 1) ne "\n";
            $p++ while substr($PATCHBUF, $p, 1) eq ' ';
            if (substr($PATCHBUF, $p, 1) eq '+'
                && substr($PATCHBUF, $p + 1, 1) eq '0'
                && !c_isdigit(substr($PATCHBUF, $p + 2, 1))) {
                $P_SAYS_NONEXISTENT[NEW]
                    = says_nonexistent_from_timestamp($P_TIMESTAMP[NEW]);
            }
            $P_INDENT = $indent;
            ($P_START, $P_SLINE) = ($this_line, $P_INPUT_LINE);
            $retval = UNI_DIFF;
            if (!(names_or_epoch_ok(OLD) && names_or_epoch_ok(NEW))
                && !$P_NAME[INDEX] && $need_header) {
                say("missing header for unified diff at line "
                    . "$P_SLINE of patch\n");
            }
            goto scan_exit;
        }
        $stars_this_line = substr($PATCHBUF, $s, 8) eq '********' ? 1 : 0;
        if (($DIFF_TYPE == NO_DIFF
             || $DIFF_TYPE == CONTEXT_DIFF
             || $DIFF_TYPE == NEW_CONTEXT_DIFF)
            && $stars_last_line && $indent_last_line == $indent
            && substr($PATCHBUF, $s, 3) eq '***'
            && c_isblank(substr($PATCHBUF, $s + 3, 1))) {
            my $p = $s + 4;
            $p++ while c_isblank(substr($PATCHBUF, $p, 1));
            if (substr($PATCHBUF, $p, 1) eq '0'
                && !c_isdigit(substr($PATCHBUF, $p + 1, 1))) {
                $P_SAYS_NONEXISTENT[OLD]
                    = says_nonexistent_from_timestamp($P_TIMESTAMP[OLD]);
            }
            # A new context diff has a '*' just before the newline.
            $p++ while substr($PATCHBUF, $p, 1) ne "\n";
            $P_INDENT = $indent;
            $P_STRIP_TRAILING_CR = $strip_trailing_cr;
            ($P_START, $P_SLINE) = ($previous_line, $P_INPUT_LINE - 1);
            $retval = substr($PATCHBUF, $p - 1, 1) eq '*'
                ? NEW_CONTEXT_DIFF : CONTEXT_DIFF;

            # Scan the first hunk to see whether the file contents appear
            # to have been deleted.
            {
                my $saved_p_base = $P_BASE;
                my $saved_p_bline = $P_BLINE;
                $PFP_POS = $previous_line;
                $P_INPUT_LINE -= 2;
                if (another_hunk($retval, 0)
                    && !$P_REPL_LINES && $P_NEWFIRST == 1) {
                    $P_SAYS_NONEXISTENT[NEW]
                        = says_nonexistent_from_timestamp($P_TIMESTAMP[NEW]);
                }
                next_intuit_at($saved_p_base, $saved_p_bline);
            }

            if (!(names_or_epoch_ok(OLD) && names_or_epoch_ok(NEW))
                && !$P_NAME[INDEX] && $need_header) {
                say("missing header for context diff at line "
                    . "$P_SLINE of patch\n");
            }
            goto scan_exit;
        }
        if (($DIFF_TYPE == NO_DIFF || $DIFF_TYPE == NORMAL_DIFF)
            && $last_line_was_command
            && (substr($PATCHBUF, $s, 2) eq '< '
                || substr($PATCHBUF, $s, 2) eq '> ')) {
            ($P_START, $P_SLINE) = ($previous_line, $P_INPUT_LINE - 1);
            $P_INDENT = $indent;
            $retval = NORMAL_DIFF;
            goto scan_exit;
        }
    }

  scan_exit:

    # The old, new, or both file types may be defined.  When both are,
    # they must agree, or else we do not know the file type.
    $file_type = $P_MODE[OLD] & 0170000;
    if ($file_type) {
        my $new_file_type = $P_MODE[NEW] & 0170000;
        if ($new_file_type && $file_type != $new_file_type) {
            $file_type = 0;
        }
    }
    else {
        $file_type = $P_MODE[NEW] & 0170000;
        $file_type = 0100000 if !$file_type;   # S_IFREG
    }
    $$p_file_type_ref = $file_type;

    # To intuit the name of the file to patch, use the POSIX algorithm with
    # the GNU modifications described in the reference source.

    $i = NONE;

    if (!$INNAME) {
        my $i0 = NONE;

        if (!$POSIXLY_CORRECT && (defined $P_NAME[OLD] || defined $P_NAME[NEW])
            && defined $P_NAME[INDEX]) {
            undef $P_NAME[INDEX];
        }

        for ($i = OLD; $i <= INDEX; $i++) {
            next unless defined $P_NAME[$i];
            if ($i0 != NONE && $P_NAME[$i0] eq $P_NAME[$i]) {
                # Same name as before; reuse the stat results.
                $stat_errno[$i] = $stat_errno[$i0];
                if (!$stat_errno[$i]) { $st[$i] = $st[$i0] }
            }
            else {
                $st[$i] = {};
                $stat_errno[$i] = stat_file($P_NAME[$i], $st[$i]);
                if (!$stat_errno[$i]) {
                    if (lookup_file_id($st[$i]) == FILE_ID_DELETE_LATER) {
                        $stat_errno[$i] = 2;   # ENOENT
                    }
                    elsif ($POSIXLY_CORRECT && name_is_valid($P_NAME[$i])) {
                        last;
                    }
                }
            }
            $i0 = $i;
        }

        if (!$POSIXLY_CORRECT) {
            # The best of all existing files.
            $i = best_name(\@P_NAME, \@stat_errno);

            if ($i == NONE && $PATCH_GET) {
                # Legacy VCS retrieval is an approved exclusion; behave as
                # if no version-control master exists.
                my $nope = NONE;
                for ($i = OLD; $i <= INDEX; $i++) {
                    next unless defined $P_NAME[$i];
                    $nope = $i;
                }
                $i = NONE;
            }

            if ($i0 != NONE
                && ($i == NONE
                    || ($st[$i]{mode} & 0170000) == $file_type)
                && maybe_reverse($P_NAME[$i == NONE ? $i0 : $i],
                                 $i == NONE,
                                 $i == NONE || $st[$i]{size} == 0)
                && $i == NONE) {
                $i = $i0;
            }

            if ($i == NONE && pch_says_nonexistent($REVERSE_FLAG)) {
                my (@newdirs, $newdirs_min, @above_minimum);
                $newdirs_min = 9223372036854775807;
                for ($i = OLD; $i <= INDEX; $i++) {
                    next unless defined $P_NAME[$i];
                    $newdirs[$i] = prefix_components($P_NAME[$i], 0)
                                 - prefix_components($P_NAME[$i], 1);
                    if ($newdirs[$i] < $newdirs_min) {
                        $newdirs_min = $newdirs[$i];
                    }
                }
                for ($i = OLD; $i <= INDEX; $i++) {
                    next unless defined $P_NAME[$i];
                    $above_minimum[$i] = $newdirs_min < $newdirs[$i] ? 1 : 0;
                }
                # The best of the filenames creating the fewest directories.
                $i = best_name(\@P_NAME, \@above_minimum);
            }
        }
    }

    if ((pch_rename() || pch_copy())
        && !$INNAME
        && !(($i == OLD || $i == NEW)
             && $P_NAME[$REVERSE_FLAG] && $P_NAME[!$REVERSE_FLAG]
             && name_is_valid($P_NAME[$REVERSE_FLAG])
             && name_is_valid($P_NAME[!$REVERSE_FLAG]))) {
        say('Cannot ', pch_rename() ? 'rename' : 'copy',
            " file without two valid file names\n");
        $SKIP_REST_OF_PATCH = 1;
    }

    if ($i == NONE) {
        if ($INNAME) {
            $INERRNO = stat_file($INNAME, \%INSTAT);
            if ($INERRNO || ($INSTAT{mode} & 0170000) == $file_type) {
                maybe_reverse($INNAME, $INERRNO,
                              $INERRNO || $INSTAT{size} == 0);
            }
        }
        else {
            $INERRNO = -1;
        }
    }
    else {
        $INNAME = $P_NAME[$i];
        $INERRNO = $stat_errno[$i];
        $INVC = $version_controlled[$i];
        %INSTAT = %{ $st[$i] };
    }

    return $retval;
}

sub best_name {
    # Return the index of the best of the candidate names, or NONE.
    my ($names, $ignore) = @_;
    my (@components, @basename_len, @len);
    my ($components_min, $basename_len_min, $len_min) =
        (9223372036854775807) x 3;

    for my $i (OLD .. INDEX) {
        next unless defined $names->[$i] && !$ignore->[$i];
        # Take the names with the fewest prefix components.
        $components[$i] = prefix_components($names->[$i], 0);
        if ($components_min < $components[$i]) { next }
        $components_min = $components[$i];

        # Of those, take the names with the shortest basename.
        my $base = $names->[$i];
        $base =~ s{.*/}{};
        $basename_len[$i] = length $base;
        if ($basename_len_min < $basename_len[$i]) { next }
        $basename_len_min = $basename_len[$i];

        # Of those, take the shortest names.
        $len[$i] = length $names->[$i];
        if ($len_min < $len[$i]) { next }
        $len_min = $len[$i];
    }

    # Of those, take the first valid name.
    for my $i (OLD .. INDEX) {
        if (defined $names->[$i]
            && !$ignore->[$i]
            && name_is_valid($names->[$i])
            && $components[$i] == $components_min
            && $basename_len[$i] == $basename_len_min
            && $len[$i] == $len_min) {
            return $i;
        }
    }
    return NONE;
}

# ==========================================================================
# 9. Hunk parsing
# ==========================================================================

sub another_hunk {
    my ($difftype, $rev) = @_;
    my $context = 0;

    # Perl owns the arrays; discard previous hunk state without simulating C
    # allocation/free bookkeeping.
    @P_LINE = ();
    @P_LEN = ();
    @P_CHAR = ();
    $P_END = -1;
    $P_C_FUNCTION = undef;

    $P_MAX = $HUNK_CAPACITY;
    if ($difftype == CONTEXT_DIFF || $difftype == NEW_CONTEXT_DIFF) {
        return another_hunk_context($difftype, $rev, $context);
    }
    elsif ($difftype == UNI_DIFF) {
        return another_hunk_unified($difftype, $rev, $context);
    }
    else {
        return another_hunk_normal($difftype, $rev, $context);
    }
}

sub another_hunk_context {
    my ($difftype, $rev, $context) = @_;
    my $line_beginning = $PFP_POS;
    my $repl_beginning = 0;
    my $fillcnt = 0;
    my ($fillsrc, $filldst) = (0, 0);
    my $ptrn_spaces_eaten = 0;
    my $some_context = 0;
    my $repl_could_be_missing = 1;
    my ($ptrn_missing, $repl_missing) = (0, 0);
    my $repl_backtrack_position = 0;
    my ($repl_patch_line, $repl_context) = (0, 0);
    my ($ptrn_prefix_context, $ptrn_suffix_context, $repl_prefix_context)
        = (-1, -1, -1);
    my ($ptrn_copiable, $repl_copiable) = (0, 0);
    my $chars_read;

    $chars_read = get_line(0);
    if ($chars_read <= 8 || substr($PATCHBUF, 0, 8) ne '********') {
        next_intuit_at($line_beginning, $P_INPUT_LINE);
        return 0;
    }
    my $s = 0;
    $s++ while substr($PATCHBUF, $s, 1) eq '*';
    if (c_isblank(substr($PATCHBUF, $s, 1))) {
        my $start = $s;
        $s++ while substr($PATCHBUF, $s, 1) ne "\n";
        $P_C_FUNCTION = substr($PATCHBUF, $start, $s - $start);
    }
    $P_HUNK_BEG = $P_INPUT_LINE + 1;
    while ($P_END < $P_MAX) {
        $chars_read = get_line(1);
        if (!$chars_read) {
            if ($repl_beginning && $repl_could_be_missing) {
                $repl_missing = 1;
                goto hunk_done;
            }
            if ($P_MAX - $P_END < 4) {
                # Assume blank lines got chopped.
                $PATCHBUF = "  \n";
                $chars_read = 3;
            }
            else {
                fatal("unexpected end of file in patch");
            }
        }
        $P_END++;
        fatal("unterminated hunk starting at line %d; giving up at line %d: %s",
              $P_HUNK_BEG, $P_INPUT_LINE, $PATCHBUF)
            if $P_END == $HUNK_CAPACITY;
        $P_CHAR[$P_END] = substr($PATCHBUF, 0, 1);
        $P_LEN[$P_END] = 0;
        $P_LINE[$P_END] = undef;
        my $c0 = substr($PATCHBUF, 0, 1);
        if ($c0 eq '*') {
            if (substr($PATCHBUF, 0, 8) eq '********') {
                if ($repl_beginning && $repl_could_be_missing) {
                    $repl_missing = 1;
                    goto hunk_done;
                }
                else {
                    fatal("unexpected end of hunk at line %d", $P_INPUT_LINE);
                }
            }
            if ($P_END != 0) {
                if ($repl_beginning && $repl_could_be_missing) {
                    $repl_missing = 1;
                    goto hunk_done;
                }
                fatal("unexpected '***' at line %d: %s",
                      $P_INPUT_LINE, $PATCHBUF);
            }
            $context = 0;
            $P_LEN[$P_END] = $chars_read;
            $P_LINE[$P_END] = $PATCHBUF;
            my $p = 0;
            $p++ while $p < $chars_read && !c_isdigit(substr($PATCHBUF, $p, 1));
            ($p, $P_FIRST) = scan_linenum($PATCHBUF, $p);
            if (substr($PATCHBUF, $p, 1) eq ',') {
                (my $q, my $last) = scan_linenum($PATCHBUF, $p + 1);
                if ($P_FIRST == 0 && $last == 0) { $P_FIRST = 1 }
                $P_PTRN_LINES = $last - $P_FIRST + 1;
                malformed() if $P_PTRN_LINES < 0;
            }
            elsif ($P_FIRST) { $P_PTRN_LINES = 1 }
            else {
                $P_PTRN_LINES = 0;
                $P_FIRST = 1;
            }
            $P_MAX = $P_PTRN_LINES + 6;
            ensure_hunk_capacity($P_MAX);
            $P_MAX = $HUNK_CAPACITY;
        }
        elsif ($c0 eq '-') {
            if (substr($PATCHBUF, 1, 1) ne '-') { goto change_line }
            if ($ptrn_prefix_context < 0) { $ptrn_prefix_context = $context }
            $ptrn_suffix_context = $context;
            if ($repl_beginning
                || $P_END <= 0
                || ($P_END != $P_PTRN_LINES + 1
                    + ($P_CHAR[$P_END - 1] eq "\n" ? 1 : 0))) {
                if ($P_END == 1) {
                    # 'Old' lines were omitted.  Set up to fill them in
                    # from 'new' context lines.
                    $ptrn_missing = 1;
                    $P_END = $P_PTRN_LINES + 1;
                    ($ptrn_prefix_context, $ptrn_suffix_context) = (-1, -1);
                    $fillsrc = $P_END + 1;
                    $filldst = 1;
                    $fillcnt = $P_PTRN_LINES;
                }
                elsif (!$repl_beginning) {
                    fatal("%s '---' at line %d; check line numbers at line %d",
                          $P_END <= $P_PTRN_LINES ? 'Premature' : 'Overdue',
                          $P_INPUT_LINE, $P_HUNK_BEG);
                }
                elsif (!$repl_could_be_missing) {
                    fatal("duplicate '---' at line %d; check line numbers at line %d",
                          $P_INPUT_LINE, $P_HUNK_BEG + $repl_beginning);
                }
                else {
                    $repl_missing = 1;
                    goto hunk_done;
                }
            }
            $repl_beginning = $P_END;
            $repl_backtrack_position = $PFP_POS;
            $repl_patch_line = $P_INPUT_LINE;
            $repl_context = $context;
            $P_LEN[$P_END] = $chars_read;
            $P_LINE[$P_END] = $PATCHBUF;
            $P_CHAR[$P_END] = '=';
            my $p = 0;
            $p++ while $p < $chars_read && !c_isdigit(substr($PATCHBUF, $p, 1));
            ($p, $P_NEWFIRST) = scan_linenum($PATCHBUF, $p);
            if (substr($PATCHBUF, $p, 1) eq ',') {
                (my $q, my $last) = scan_linenum($PATCHBUF, $p + 1);
                $P_REPL_LINES = $last - $P_NEWFIRST + 1;
                malformed() if $P_REPL_LINES < 0;
            }
            elsif ($P_NEWFIRST) { $P_REPL_LINES = 1 }
            else {
                $P_REPL_LINES = 0;
                $P_NEWFIRST = 1;
            }
            $P_MAX = $P_REPL_LINES + $P_END;
            ensure_hunk_capacity($P_MAX);
            if ($P_REPL_LINES != $ptrn_copiable
                && ($P_PREFIX_CONTEXT != 0
                    || $context != 0
                    || $P_REPL_LINES != 1)) {
                $repl_could_be_missing = 0;
            }
            $context = 0;
        }
        elsif ($c0 eq '+' || $c0 eq '!') {
            $repl_could_be_missing = 0;
          change_line:
            my $p = 1;
            $chars_read--;
            if (substr($PATCHBUF, 1, 1) eq "\n" && $CANONICALIZE_WS) {
                $PATCHBUF = substr($PATCHBUF, 0, 1) . " \n";
                $chars_read = 2;
            }
            if (c_isblank(substr($PATCHBUF, 1, 1))) {
                $p = 2;
                $chars_read--;
            }
            elsif ($repl_beginning && $repl_could_be_missing) {
                $repl_missing = 1;
                goto hunk_done;
            }
            if (!$repl_beginning) {
                $ptrn_prefix_context = $context if $ptrn_prefix_context < 0;
            }
            else {
                $repl_prefix_context = $context if $repl_prefix_context < 0;
            }
            $chars_read--
                if 1 < $chars_read
                && $P_END == ($repl_beginning ? $P_MAX : $P_PTRN_LINES)
                && incomplete_line();
            $P_LEN[$P_END] = $chars_read;
            $P_LINE[$P_END] = substr($PATCHBUF, $p, $chars_read);
            $context = 0;
        }
        elsif ($c0 eq "\t" || $c0 eq "\n") {
            # Assume spaces got eaten.
            my $p = 0;
            if ($c0 eq "\t") { $chars_read-- }
            if ($repl_beginning && $repl_could_be_missing
                && (!$ptrn_spaces_eaten || $difftype == NEW_CONTEXT_DIFF)) {
                $repl_missing = 1;
                goto hunk_done;
            }
            $chars_read--
                if 1 < $chars_read
                && $P_END == ($repl_beginning ? $P_MAX : $P_PTRN_LINES)
                && incomplete_line();
            $P_LEN[$P_END] = $chars_read;
            $P_LINE[$P_END] = substr($PATCHBUF, 0, $chars_read);
            if ($P_END != $P_PTRN_LINES + 1) {
                $ptrn_spaces_eaten = 1 if $repl_beginning;
                $some_context = 1;
                $context++;
                if ($repl_beginning) { $repl_copiable++ }
                else { $ptrn_copiable++ }
                $P_CHAR[$P_END] = ' ';
            }
        }
        elsif ($c0 eq ' ') {
            my $p = 1;
            $chars_read--;
            if (substr($PATCHBUF, 1, 1) eq "\n" && $CANONICALIZE_WS) {
                $PATCHBUF = substr($PATCHBUF, 0, 1) . "\n";
                $chars_read = 2;
            }
            if (c_isblank(substr($PATCHBUF, 1, 1))) {
                $p = 2;
                $chars_read--;
            }
            elsif ($repl_beginning && $repl_could_be_missing) {
                $repl_missing = 1;
                goto hunk_done;
            }
            $some_context = 1;
            $context++;
            if ($repl_beginning) { $repl_copiable++ }
            else { $ptrn_copiable++ }
            $chars_read--
                if 1 < $chars_read
                && $P_END == ($repl_beginning ? $P_MAX : $P_PTRN_LINES)
                && incomplete_line();
            $P_LEN[$P_END] = $chars_read;
            $P_LINE[$P_END] = substr($PATCHBUF, $p, $chars_read);
        }
        else {
            if ($repl_beginning && $repl_could_be_missing) {
                $repl_missing = 1;
                goto hunk_done;
            }
            malformed();
        }
    }

  hunk_done:
    if ($P_END >= 0 && !$repl_beginning) {
        fatal("no '---' found in patch at line %d", $P_HUNK_BEG);
    }

    if ($repl_missing) {
        # Reset state back to just after the '---'.
        $P_INPUT_LINE = $repl_patch_line;
        $context = $repl_context;
        for (my $p_end = $P_END - 1; $p_end > $repl_beginning; $p_end--) {
            $P_LINE[$p_end] = undef;
        }
        $PFP_POS = $repl_backtrack_position;

        # Redundant 'new' context lines were omitted - set up to fill them
        # in from the old file context.
        $fillsrc = 1;
        $filldst = $repl_beginning + 1;
        $fillcnt = $P_REPL_LINES;
        $P_END = $P_MAX;
    }
    elsif (!$ptrn_missing && $ptrn_copiable != $repl_copiable) {
        fatal("context mangled in hunk at line %d", $P_HUNK_BEG);
    }
    elsif (!$some_context && $fillcnt == 1) {
        # The first hunk was a null hunk with no context and we were
        # expecting one line -- fix it up.
        while ($filldst < $P_END) {
            $P_LINE[$filldst] = $P_LINE[$filldst + 1];
            $P_CHAR[$filldst] = $P_CHAR[$filldst + 1];
            $P_LEN[$filldst] = $P_LEN[$filldst + 1];
            $filldst++;
        }
        $P_END--;
        $P_FIRST++;
        $fillcnt = 0;
        $P_PTRN_LINES = 0;
    }

    $P_PREFIX_CONTEXT =
        ($repl_prefix_context < 0
         || (0 <= $ptrn_prefix_context
             && $ptrn_prefix_context < $repl_prefix_context))
        ? $ptrn_prefix_context : $repl_prefix_context;
    $P_SUFFIX_CONTEXT =
        (0 <= $ptrn_suffix_context && $ptrn_suffix_context < $context)
        ? $ptrn_suffix_context : $context;
    if ($P_PREFIX_CONTEXT < 0 || $P_SUFFIX_CONTEXT < 0) {
        fatal("replacement text or line numbers mangled in hunk at line %d",
              $P_HUNK_BEG);
    }

    if ($difftype == CONTEXT_DIFF
        && ($fillcnt
            || ($P_FIRST > 1
                && $P_PREFIX_CONTEXT + $P_SUFFIX_CONTEXT < $ptrn_copiable))) {
        if ($VERBOSITY == VERBOSE) {
            say("(Fascinating -- this is really a new-style context diff but without\n"
                . "the telltale extra asterisks on the *** line that usually indicate\n"
                . "the new style...)\n");
        }
        $DIFF_TYPE = $difftype = NEW_CONTEXT_DIFF;
    }

    # If there were omitted context lines, fill them in now.
    if ($fillcnt) {
        while ($fillcnt-- > 0) {
            while ($fillsrc <= $P_END && $fillsrc != $repl_beginning
                   && $P_CHAR[$fillsrc] ne ' ') {
                $fillsrc++;
            }
            if ($P_END < $fillsrc || $fillsrc == $repl_beginning) {
                fatal("replacement text or line numbers mangled in hunk at line %d",
                      $P_HUNK_BEG);
            }
            $P_LINE[$filldst] = $P_LINE[$fillsrc];
            $P_CHAR[$filldst] = $P_CHAR[$fillsrc];
            $P_LEN[$filldst] = $P_LEN[$fillsrc];
            $fillsrc++; $filldst++;
        }
        while ($fillsrc <= $P_END && $fillsrc != $repl_beginning) {
            fatal("replacement text or line numbers mangled in hunk at line %d",
                  $P_HUNK_BEG)
                if $P_CHAR[$fillsrc] eq ' ';
            $fillsrc++;
        }
    }

    if ($rev) {
        pch_swap();
    }
    $P_CHAR[$P_END + 1] = '^';
    return 1;
}

sub another_hunk_unified {
    my ($difftype, $rev, $context) = @_;
    my $line_beginning = $PFP_POS;
    my $ch = "\0";

    my $chars_read = get_line(0);
    if ($chars_read <= 4 || substr($PATCHBUF, 0, 4) ne '@@ -') {
        next_intuit_at($line_beginning, $P_INPUT_LINE);
        return 0;
    }
    my ($p, $first) = scan_linenum($PATCHBUF, 4);
    $P_FIRST = $first;
    if (substr($PATCHBUF, $p, 1) eq ',') {
        ($p, my $nlines) = scan_linenum($PATCHBUF, $p + 1);
        malformed() if $P_FIRST >= 9223372036854775807 - $nlines;
        $P_PTRN_LINES = $nlines;
    }
    else {
        $P_PTRN_LINES = 1;
    }
    $p++ if substr($PATCHBUF, $p, 1) eq ' ';
    malformed() unless substr($PATCHBUF, $p, 1) eq '+';
    ($p, $P_NEWFIRST) = scan_linenum($PATCHBUF, $p + 1);
    if (substr($PATCHBUF, $p, 1) eq ',') {
        ($p, my $nlines) = scan_linenum($PATCHBUF, $p + 1);
        malformed() if $P_NEWFIRST >= 9223372036854775807 - $nlines;
        $P_REPL_LINES = $nlines;
    }
    else {
        $P_REPL_LINES = 1;
    }
    $p++ if substr($PATCHBUF, $p, 1) eq ' ';
    malformed() unless substr($PATCHBUF, $p, 1) eq '@';
    $p++;
    if (substr($PATCHBUF, $p, 1) eq '@' && substr($PATCHBUF, $p + 1, 1) eq ' ') {
        my $start = $p + 1;
        my $q = $start;
        $q++ while substr($PATCHBUF, $q, 1) ne "\n";
        $P_C_FUNCTION = substr($PATCHBUF, $start, $q - $start);
    }
    $P_FIRST++ if !$P_PTRN_LINES;      # do append rather than insert
    $P_NEWFIRST++ if !$P_REPL_LINES;
    $P_MAX = $P_PTRN_LINES + $P_REPL_LINES + 1;
    my $fillsrc = 1;
    my $filldst = $fillsrc + $P_PTRN_LINES;
    $P_END = $filldst + $P_REPL_LINES;
    my $header_old = sprintf("*** %d,%d ****\n",
                             $P_FIRST, $P_FIRST + $P_PTRN_LINES - 1);
    $P_LEN[0] = length $header_old;
    $P_LINE[0] = $header_old;
    $P_CHAR[0] = '*';
    my $header_new = sprintf("--- %d,%d ----\n",
                             $P_NEWFIRST, $P_NEWFIRST + $P_REPL_LINES - 1);
    $P_LEN[$filldst] = length $header_new;
    $P_LINE[$filldst] = $header_new;
    $P_CHAR[$filldst++] = '=';
    $P_PREFIX_CONTEXT = -1;
    $P_HUNK_BEG = $P_INPUT_LINE + 1;
    while ($fillsrc <= $P_PTRN_LINES || $filldst <= $P_END) {
        $chars_read = get_line(1);
        if (!$chars_read) {
            if ($P_MAX - $filldst < 3) {
                # Assume blank lines got chopped.
                $PATCHBUF = " \n";
                $chars_read = 2;
            }
            else {
                fatal("unexpected end of file in patch");
            }
        }
        my $s;
        if (substr($PATCHBUF, 0, 1) eq "\t" || substr($PATCHBUF, 0, 1) eq "\n") {
            $ch = ' ';    # assume the space got eaten
            $s = $PATCHBUF;
        }
        else {
            $ch = substr($PATCHBUF, 0, 1);
            $chars_read--;
            $s = substr($PATCHBUF, 1, $chars_read);
        }
        if ($ch eq '-') {
            if ($fillsrc > $P_PTRN_LINES) {
                $P_END = $filldst - 1;
                malformed();
            }
            $chars_read--
                if $fillsrc == $P_PTRN_LINES && incomplete_line();
            $P_CHAR[$fillsrc] = $ch;
            $P_LINE[$fillsrc] = $s;
            $P_LEN[$fillsrc++] = $chars_read;
        }
        elsif ($ch eq '=' || $ch eq ' ') {
            $ch = ' ' if $ch eq '=';
            if ($fillsrc > $P_PTRN_LINES) {
                while (--$filldst > $P_PTRN_LINES) {
                    $P_LINE[$filldst] = undef;
                }
                $P_END = $fillsrc - 1;
                malformed();
            }
            $context++;
            $chars_read--
                if $fillsrc == $P_PTRN_LINES && incomplete_line();
            $P_CHAR[$fillsrc] = $ch;
            $P_LINE[$fillsrc] = $s;
            $P_LEN[$fillsrc++] = $chars_read;
            if ($filldst > $P_END) {
                while (--$filldst > $P_PTRN_LINES) {
                    $P_LINE[$filldst] = undef;
                }
                $P_END = $fillsrc - 1;
                malformed();
            }
            $chars_read--
                if $filldst == $P_END && incomplete_line();
            $P_CHAR[$filldst] = $ch;
            $P_LINE[$filldst] = $s;
            $P_LEN[$filldst++] = $chars_read;
        }
        elsif ($ch eq '+') {
            if ($filldst > $P_END) {
                while (--$filldst > $P_PTRN_LINES) {
                    $P_LINE[$filldst] = undef;
                }
                $P_END = $fillsrc - 1;
                malformed();
            }
            $chars_read--
                if $filldst == $P_END && incomplete_line();
            $P_CHAR[$filldst] = $ch;
            $P_LINE[$filldst] = $s;
            $P_LEN[$filldst++] = $chars_read;
        }
        else {
            $P_END = $filldst;
            malformed();
        }

        if ($ch ne ' ') {
            $P_PREFIX_CONTEXT = $context if $P_PREFIX_CONTEXT < 0;
            $context = 0;
        }
    }
    malformed() if $P_PREFIX_CONTEXT < 0;
    $P_SUFFIX_CONTEXT = $context;

    if ($rev) {
        pch_swap();
    }
    $P_CHAR[$P_END + 1] = '^';
    return 1;
}

sub another_hunk_normal {
    my ($difftype, $rev, $context) = @_;
    my $line_beginning = $PFP_POS;

    $P_PREFIX_CONTEXT = $P_SUFFIX_CONTEXT = 0;
    my $chars_read = get_line(0);
    my $invalid_line = $chars_read <= 0;
    my $s = 0;
    if (!$invalid_line) {
        $s++ while c_isblank(substr($PATCHBUF, $s, 1));
    }
    if ($invalid_line || !c_isdigit(substr($PATCHBUF, $s, 1))) {
        next_intuit_at($line_beginning, $P_INPUT_LINE);
        return 0;
    }
    ($s, $P_FIRST) = scan_linenum($PATCHBUF, $s);
    if (substr($PATCHBUF, $s, 1) eq ',') {
        ($s, my $last) = scan_linenum($PATCHBUF, $s + 1);
        my $diff = $last - $P_FIRST;
        malformed() unless -1 <= $diff;
        $P_PTRN_LINES = $diff + 1;
    }
    else {
        $P_PTRN_LINES = substr($PATCHBUF, $s, 1) ne 'a' ? 1 : 0;
    }
    my $hunk_type = substr($PATCHBUF, $s, 1);
    $P_FIRST++ if $hunk_type eq 'a';   # do append rather than insert
    ($s, my $min) = scan_linenum($PATCHBUF, $s + 1);
    my $max;
    if (substr($PATCHBUF, $s, 1) eq ',') {
        ($s, $max) = scan_linenum($PATCHBUF, $s + 1);
    }
    else {
        $max = $min;
    }
    malformed() if $min > $max;
    $min++ if $hunk_type eq 'd';
    $P_NEWFIRST = $min;
    $P_REPL_LINES = $max - $min + 1;
    $P_END = $P_PTRN_LINES + $P_REPL_LINES + 1;
    my $header_old = sprintf("*** %d,%d\n",
                             $P_FIRST, $P_FIRST + $P_PTRN_LINES - 1);
    $P_LEN[0] = length $header_old;
    $P_LINE[0] = $header_old;
    $P_CHAR[0] = '*';

    my $i;
    for ($i = 1; $i <= $P_PTRN_LINES; $i++) {
        $chars_read = get_line(1);
        if (!$chars_read) {
            fatal("unexpected end of file in patch at line %d", $P_INPUT_LINE);
        }
        if (!(substr($PATCHBUF, 0, 1) eq '<' && c_isblank(substr($PATCHBUF, 1, 1)))) {
            fatal("'< ' followed by space or tab expected at line %d of patch",
                  $P_INPUT_LINE);
        }
        $chars_read -= 2 + ($i == $P_PTRN_LINES && incomplete_line());
        $P_LEN[$i] = $chars_read;
        $P_LINE[$i] = substr($PATCHBUF, 2, $chars_read);
        $P_CHAR[$i] = '-';
    }
    if ($hunk_type eq 'c') {
        $chars_read = get_line(1);
        if (!$chars_read) {
            fatal("unexpected end of file in patch at line %d", $P_INPUT_LINE);
        }
        fatal("'---' expected at line %d of patch", $P_INPUT_LINE)
            if substr($PATCHBUF, 0, 1) ne '-';
    }
    my $header_new = sprintf("--- %d,%d\n", $min, $max);
    $P_LEN[$i] = length $header_new;
    $P_LINE[$i] = $header_new;
    $P_CHAR[$i] = '=';
    for ($i++; $i <= $P_END; $i++) {
        $chars_read = get_line(1);
        if (!$chars_read) {
            fatal("unexpected end of file in patch at line %d", $P_INPUT_LINE);
        }
        if (!(substr($PATCHBUF, 0, 1) eq '>' && c_isblank(substr($PATCHBUF, 1, 1)))) {
            fatal("'> ' followed by space or tab expected at line %d of patch",
                  $P_INPUT_LINE);
        }
        $chars_read -= 2 + ($i == $P_END && incomplete_line());
        $P_LEN[$i] = $chars_read;
        $P_LINE[$i] = substr($PATCHBUF, 2, $chars_read);
        $P_CHAR[$i] = '+';
    }

    if ($rev) {
        pch_swap();
    }
    $P_CHAR[$P_END + 1] = '^';
    return 1;
}

sub pch_swap {
    my $blankline = 0;

    my $oldfirst = $P_FIRST;
    $P_FIRST = $P_NEWFIRST;
    $P_NEWFIRST = $oldfirst;

    my (@tp_line, @tp_len, @tp_char);
    @tp_line = @P_LINE;
    @tp_len = @P_LEN;
    @tp_char = @P_CHAR;

    # Turn the new into the old.
    my $i = $P_PTRN_LINES + 1;
    if ($tp_char[$i] eq "\n") {
        $blankline = 1;
        $i++;
    }
    my $n = 0;
    for (; $i <= $P_END; $i++, $n++) {
        $P_LINE[$n] = $tp_line[$i];
        $P_CHAR[$n] = $tp_char[$i];
        $P_CHAR[$n] = '-' if $P_CHAR[$n] eq '+';
        $P_LEN[$n] = $tp_len[$i];
    }
    if ($blankline) {
        $i = $P_PTRN_LINES + 1;
        $P_LINE[$n] = $tp_line[$i];
        $P_CHAR[$n] = $tp_char[$i];
        $P_LEN[$n] = $tp_len[$i];
        $n++;
    }
    $P_LINE[0] = $tp_line[0];
    $P_CHAR[0] = '*';
    $P_LEN[0] = $tp_len[0];
    $P_LINE[0] =~ s/-/*/g if defined $P_LINE[0];

    # Turn the old into the new.
    $tp_char[0] = '=';
    $tp_line[0] =~ s/\*/-/g if defined $tp_line[0];
    for ($i = 0, my $m = $n; $m <= $P_END; $i++, $m++) {
        $P_LINE[$m] = $tp_line[$i];
        $P_CHAR[$m] = $tp_char[$i];
        $P_CHAR[$m] = '+' if $P_CHAR[$m] eq '-';
        $P_LEN[$m] = $tp_len[$i];
    }
    my $tmp = $P_PTRN_LINES;
    $P_PTRN_LINES = $P_REPL_LINES;
    $P_REPL_LINES = $tmp;
    $P_CHAR[$P_END + 1] = '^';
}

sub pch_normalize {
    my ($format) = @_;
    my $old = 1;
    my $new = $P_PTRN_LINES + 1;

    $new++ while $P_CHAR[$new] eq '=' || $P_CHAR[$new] eq "\n";

    if ($format == UNI_DIFF) {
        for (; $old <= $P_PTRN_LINES; $old++) {
            $P_CHAR[$old] = '-' if $P_CHAR[$old] eq '!';
        }
        for (; $new <= $P_END; $new++) {
            $P_CHAR[$new] = '+' if $P_CHAR[$new] eq '!';
        }
    }
    else {
        while ($old <= $P_PTRN_LINES) {
            if ($P_CHAR[$old] eq '-') {
                if ($new <= $P_END && $P_CHAR[$new] eq '+') {
                    do {
                        $P_CHAR[$old] = '!';
                        $old++;
                    }
                    while ($old <= $P_PTRN_LINES && $P_CHAR[$old] eq '-');
                    do {
                        $P_CHAR[$new] = '!';
                        $new++;
                    }
                    while ($new <= $P_END && $P_CHAR[$new] eq '+');
                }
                else {
                    do {
                        $old++;
                    }
                    while ($old <= $P_PTRN_LINES && $P_CHAR[$old] eq '-');
                }
            }
            elsif ($new <= $P_END && $P_CHAR[$new] eq '+') {
                do {
                    $new++;
                }
                while ($new <= $P_END && $P_CHAR[$new] eq '+');
            }
            else {
                $old++;
                $new++;
            }
        }
    }
}

# ==========================================================================
# 10. Input file handling
# ==========================================================================

sub stat_file {
    my ($filename, $st_ref) = @_;
    my @st = $FOLLOW_SYMLINKS ? stat($filename) : lstat($filename);
    if (defined $st[0]) {
        %$st_ref = (
            dev => $st[0], ino => $st[1], mode => $st[2], nlink => $st[3],
            uid => $st[4], gid => $st[5], size => $st[7], mtime => $st[9],
            atime => $st[8], mtime_nsec => $st[14] // 0,
            atime_nsec => $st[13] // 0,
        );
        return 0;
    }
    return 0 + $!;
}

sub insert_file_id {
    my ($st, $type) = @_;
    my $key = ($st->{dev} // 0) . ',' . ($st->{ino} // 0);
    $FILE_ID{$key} //= [ FILE_ID_UNKNOWN, 0 ];
    $FILE_ID{$key}[0] = $type;
}

sub lookup_file_id {
    my ($st) = @_;
    my $entry = $FILE_ID{($st->{dev} // 0) . ',' . ($st->{ino} // 0)};
    return defined $entry ? $entry->[0] : FILE_ID_UNKNOWN;
}

sub set_queued_output {
    my ($st, $queued) = @_;
    my $key = ($st->{dev} // 0) . ',' . ($st->{ino} // 0);
    $FILE_ID{$key} //= [ FILE_ID_UNKNOWN, 0 ];
    $FILE_ID{$key}[1] = $queued;
}

sub has_queued_output {
    my ($st) = @_;
    my $entry = $FILE_ID{($st->{dev} // 0) . ',' . ($st->{ino} // 0)};
    return defined $entry ? $entry->[1] : 0;
}

sub report_revision {
    my ($found_revision) = @_;
    my $rev = quotearg($REVISION);

    if ($found_revision) {
        say("Good.  This file appears to be the $rev version.\n")
            if $VERBOSITY == VERBOSE;
    }
    elsif ($FORCE) {
        say("Warning: this file doesn't appear to be the $rev version "
            . "-- patching anyway.\n")
            if $VERBOSITY != SILENT;
    }
    elsif ($BATCH) {
        fatal("This file doesn't appear to be the $rev version -- aborting.");
    }
    else {
        if (ask("This file doesn't appear to be the $rev version "
                . "-- patch anyway? [n] ") !~ /^y/) {
            fatal("aborted");
        }
    }
}

sub get_input_file {
    my ($filename, $outname, $file_type) = @_;
    my $elsewhere = $filename ne $outname;

    if ($INERRNO == -1) {
        $INERRNO = stat_file($filename, \%INSTAT);
    }

    # Perhaps look for RCS or SCCS versions: legacy VCS retrieval is an
    # approved exclusion, so no version control system is ever consulted.

    if ($INERRNO) {
        $INSTAT{mode} = 0666;
        $INSTAT{size} = 0;
    }
    elsif (!((($file_type & 0170000) == 0100000
              || ($file_type & 0170000) == 0120000)
             && ($file_type & 0170000) == ($INSTAT{mode} & 0170000))) {
        say('File ', quotearg($filename), ' is not a ',
            ($file_type & 0170000) == 0120000 ? 'symbolic link' : 'regular file',
            " -- refusing to patch\n");
        return 0;
    }
    return 1;
}

sub scan_input {
    my ($filename, $file_type, $ifh) = @_;
    my $size = $INSTAT{size} // 0;
    my $buffer = '';

    if ($size) {
        if (($file_type & 0170000) == 0100000) {
            my $buffered = 0;
            while ($size - $buffered != 0) {
                my $got = sysread($ifh, $buffer, $size - $buffered, $buffered);
                read_fatal() unless defined $got;
                if ($got == 0) {
                    # The file may have shrunk.
                    $size = $buffered;
                    last;
                }
                $buffered += $got;
            }
        }
        else {
            # A symbolic link: read its target.
            my $target = readlink $filename;
            if (!defined $target) {
                pfatal("can't read %s %s", 'symbolic link', quotearg($filename));
            }
            $buffer = $target;
            $size = length $target;
        }
    }

    # Scan the buffer and build the line index.
    my @lines = ('');   # index 0 unused, matching GNU's 1-based lines
    my $pos = 0;
    while (1) {
        my $nl = index($buffer, "\n", $pos);
        if ($nl < 0) {
            push @lines, substr($buffer, $pos) if $pos < length $buffer;
            last;
        }
        push @lines, substr($buffer, $pos, $nl + 1 - $pos);
        $pos = $nl + 1;
    }
    $INPUT_LINES = $#lines;
    @I_LINES = @lines;

    if (defined $REVISION) {
        my $rev = $REVISION;
        my $revlen = length $rev;
        my $found_revision = 0;
        if ($revlen <= $size) {
            my $from = 0;
            while (1) {
                $from = index($buffer, $rev, $from);
                last if $from < 0;
                my $before = $from == 0 ? "\0" : substr($buffer, $from - 1, 1);
                my $after = $from + $revlen >= length $buffer
                    ? "\0" : substr($buffer, $from + $revlen, 1);
                if (($from == 0 || $before =~ /\s/)
                    && ($from + $revlen >= length $buffer || $after =~ /\s/)) {
                    $found_revision = 1;
                    last;
                }
                $from++;
            }
        }
        report_revision($found_revision);
    }
}

sub ifetch {
    my ($line) = @_;
    return ('', 0) unless 1 <= $line && $line <= $INPUT_LINES;
    my $text = $I_LINES[$line];
    return ($text, length $text);
}

# ==========================================================================
# 11. Hunk matching and application
# ==========================================================================

sub locate_hunk {
    my ($fuzz) = @_;
    my $first_guess = pch_first() + $IN_OFFSET;
    my $pat_lines = pch_ptrn_lines();
    my $prefix_context = pch_prefix_context();
    my $suffix_context = pch_suffix_context();
    my $context = $prefix_context > $suffix_context
        ? $prefix_context : $suffix_context;
    my $prefix_fuzz = $fuzz + $prefix_context - $context;
    my $suffix_fuzz = $fuzz + $suffix_context - $context;
    my $max_where = $INPUT_LINES - ($pat_lines - $suffix_fuzz) + 1;
    my $min_where = $LAST_FROZEN_LINE + 1;
    my $max_pos_offset = $max_where - $first_guess;
    my $max_neg_offset = $first_guess - $min_where;
    my $max_offset = $max_pos_offset > $max_neg_offset
        ? $max_pos_offset : $max_neg_offset;
    my $min_offset;

    return $first_guess if !$pat_lines;   # null range matches always

    # Do not try lines <= 0.
    if ($first_guess <= $max_neg_offset) {
        $max_neg_offset = $first_guess - 1;
    }

    if ($prefix_fuzz < 0 && pch_first() <= 1) {
        # Can only match the start of the file.
        if ($suffix_fuzz < 0) {
            # Can only match the entire file.
            if ($pat_lines != $INPUT_LINES || $prefix_context < $LAST_FROZEN_LINE) {
                return 0;
            }
        }
        my $offset = 1 - $first_guess;
        if ($LAST_FROZEN_LINE <= $prefix_context
            && $offset <= $max_pos_offset
            && patch_match($first_guess, $offset, 0, $suffix_fuzz)) {
            $IN_OFFSET += $offset;
            return $first_guess + $offset;
        }
        return 0;
    }
    elsif ($prefix_fuzz < 0) {
        $prefix_fuzz = 0;
    }

    if ($suffix_fuzz < 0) {
        # Can only match the end of the file.
        my $offset = $first_guess - ($INPUT_LINES - $pat_lines + 1);
        if ($offset <= $max_neg_offset
            && patch_match($first_guess, -$offset, $prefix_fuzz, 0)) {
            $IN_OFFSET -= $offset;
            return $first_guess - $offset;
        }
        return 0;
    }

    $min_offset = $max_pos_offset < 0 ? $first_guess - $max_where
                : $max_neg_offset < 0 ? $first_guess - $min_where
                : 0;
    for (my $offset = $min_offset; $offset <= $max_offset; $offset++) {
        if ($offset <= $max_pos_offset
            && patch_match($first_guess, $offset, $prefix_fuzz, $suffix_fuzz)) {
            say("Offset changing from $IN_OFFSET to ", $IN_OFFSET + $offset, "\n")
                if $DEBUG & 1;
            $IN_OFFSET += $offset;
            return $first_guess + $offset;
        }
        if ($offset <= $max_neg_offset
            && patch_match($first_guess, -$offset, $prefix_fuzz, $suffix_fuzz)) {
            say("Offset changing from $IN_OFFSET to ", $IN_OFFSET - $offset, "\n")
                if $DEBUG & 1;
            $IN_OFFSET -= $offset;
            return $first_guess - $offset;
        }
    }
    return 0;
}

sub patch_match {
    my ($base, $offset, $prefix_fuzz, $suffix_fuzz) = @_;
    my $pat_lines = pch_ptrn_lines() - $suffix_fuzz;

    for (my $pline = 1 + $prefix_fuzz; $pline <= $pat_lines; $pline++) {
        my ($itext, $isize) = ifetch($pline - 1 + $base + $offset);
        if ($CANONICALIZE_WS) {
            return 0 unless similar($itext, $isize,
                                    pfetch($pline), pch_line_len($pline));
        }
        else {
            my $plen = pch_line_len($pline);
            return 0 if $isize != $plen
                || $itext ne substr(pfetch($pline), 0, $plen);
        }
    }
    return 1;
}

sub similar {
    # Do two lines match with canonicalized white space?
    my ($a, $alen, $b, $blen) = @_;

    # Ignore presence or absence of trailing newlines.
    $alen -= $alen && substr($a, $alen - 1, 1) eq "\n" ? 1 : 0;
    $blen -= $blen && substr($b, $blen - 1, 1) eq "\n" ? 1 : 0;

    my ($ia, $ib) = (0, 0);
    while (1) {
        if ($ib >= $blen || substr($b, $ib, 1) =~ /[ \t]/) {
            $ib++ while $ib < $blen && substr($b, $ib, 1) =~ /[ \t]/;
            if ($ia < $alen) {
                return 0 unless substr($a, $ia, 1) =~ /[ \t]/;
                $ia++;
                $ia++ while $ia < $alen && substr($a, $ia, 1) =~ /[ \t]/;
            }
            return $alen - $ia == $blen - $ib ? 1 : 0
                if $ia >= $alen || $ib >= $blen;
        }
        elsif ($ia >= $alen || substr($a, $ia, 1) ne substr($b, $ib, 1)) {
            return 0;
        }
        else {
            $ia++;
            $ib++;
        }
    }
}

sub check_line_endings {
    my ($where) = @_;
    my $p = pfetch(1) // '';
    my $size = pch_line_len(1) // 0;
    return 0 unless $size;
    my $patch_crlf = 2 <= $size
        && substr($p, $size - 2, 2) eq "\r\n";

    return 0 unless $INPUT_LINES;
    $where = $INPUT_LINES if $where > $INPUT_LINES;
    my ($itext, $isize) = ifetch($where);
    return 0 unless $isize;
    my $input_crlf = 2 <= $isize
        && substr($itext, $isize - 2, 2) eq "\r\n";
    return $patch_crlf != $input_crlf ? 1 : 0;
}

sub copy_till {
    my ($lastline) = @_;
    my $frozen = $LAST_FROZEN_LINE;

    if ($frozen > $lastline) {
        say("misordered hunks! output would be garbled\n");
        return 0;
    }
    while ($frozen < $lastline) {
        $frozen++;
        my ($text, $size) = ifetch($frozen);
        if ($size) {
            fput($OUTFP, "\n") if !$OUT_AFTER_NEWLINE;
            fput($OUTFP, $text);
            $OUT_AFTER_NEWLINE = substr($text, $size - 1, 1) eq "\n" ? 1 : 0;
            $OUT_ZERO_OUTPUT = 0;
        }
    }
    $LAST_FROZEN_LINE = $frozen;
    return 1;
}

sub spew_output {
    if ($DEBUG & 256) {
        say("il=$INPUT_LINES lfl=$LAST_FROZEN_LINE\n");
    }
    if ($LAST_FROZEN_LINE < $INPUT_LINES) {
        return 0 unless copy_till($INPUT_LINES);
    }
    return 1;
}

sub ifdef_line {
    # GNU concatenates "after_newline + not_defined" style constants: the
    # leading newline is skipped when the output is already at line start.
    my ($constant) = @_;
    return $OUT_AFTER_NEWLINE ? substr($constant, 1) : $constant;
}

sub apply_hunk {
    my ($where) = @_;
    my $old = 1;
    my $lastline = pch_ptrn_lines();
    my $new = $lastline + 1;
    my $def_state = 'OUTSIDE';
    my $R_do_defines = $DO_DEFINES;
    my $pat_end = pch_end();

    $where--;
    $new++ while $P_CHAR[$new] eq '=' || $P_CHAR[$new] eq "\n";

    while ($old <= $lastline) {
        if ($P_CHAR[$old] eq '-') {
            return 0 unless copy_till($where + $old - 1);
            if ($R_do_defines) {
                if ($def_state eq 'OUTSIDE') {
                    putline($OUTFP, ifdef_line("\n#ifndef "), $R_do_defines);
                    $def_state = 'IN_IFNDEF';
                }
                elsif ($def_state eq 'IN_IFDEF') {
                    fput($OUTFP, ifdef_line("\n#else\n"));
                    $def_state = 'IN_ELSE';
                }
                $OUT_AFTER_NEWLINE = pch_write_line($old, $OUTFP);
                $OUT_ZERO_OUTPUT = 0;
            }
            $LAST_FROZEN_LINE++;
            $old++;
        }
        elsif ($new > $pat_end) {
            last;
        }
        elsif ($P_CHAR[$new] eq '+') {
            return 0 unless copy_till($where + $old - 1);
            if ($R_do_defines) {
                if ($def_state eq 'IN_IFNDEF') {
                    fput($OUTFP, ifdef_line("\n#else\n"));
                    $def_state = 'IN_ELSE';
                }
                elsif ($def_state eq 'OUTSIDE') {
                    putline($OUTFP, ifdef_line("\n#ifdef "), $R_do_defines);
                    $def_state = 'IN_IFDEF';
                }
            }
            $OUT_AFTER_NEWLINE = pch_write_line($new, $OUTFP);
            $OUT_ZERO_OUTPUT = 0;
            $new++;
        }
        elsif ($P_CHAR[$new] ne $P_CHAR[$old]) {
            mangled_patch($old, $new);
        }
        elsif ($P_CHAR[$new] eq '!') {
            return 0 unless copy_till($where + $old - 1);
            if ($R_do_defines) {
                putline($OUTFP, substr("\n#ifndef ", 1), $R_do_defines);
                $def_state = 'IN_IFNDEF';
            }

            do {
                if ($R_do_defines) {
                    $OUT_AFTER_NEWLINE = pch_write_line($old, $OUTFP);
                }
                $LAST_FROZEN_LINE++;
                $old++;
            }
            while ($old <= $lastline && $P_CHAR[$old] eq '!');

            if ($R_do_defines) {
                fput($OUTFP, ifdef_line("\n#else\n"));
                $def_state = 'IN_ELSE';
            }

            do {
                $OUT_AFTER_NEWLINE = pch_write_line($new, $OUTFP);
                $new++;
            }
            while ($new <= $pat_end && $P_CHAR[$new] eq '!');
            $OUT_ZERO_OUTPUT = 0;
        }
        else {
            $old++;
            $new++;
            if ($R_do_defines && $def_state ne 'OUTSIDE') {
                fput($OUTFP, ifdef_line("\n#endif\n"));
                $OUT_AFTER_NEWLINE = 1;
                $def_state = 'OUTSIDE';
            }
        }
    }
    if ($new <= $pat_end && $P_CHAR[$new] eq '+') {
        return 0 unless copy_till($where + $old - 1);
        if ($R_do_defines) {
            if ($def_state eq 'OUTSIDE') {
                putline($OUTFP, ifdef_line("\n#ifdef "), $R_do_defines);
                $def_state = 'IN_IFDEF';
            }
            elsif ($def_state eq 'IN_IFNDEF') {
                fput($OUTFP, ifdef_line("\n#else\n"));
                $def_state = 'IN_ELSE';
            }
            $OUT_ZERO_OUTPUT = 0;
        }

        do {
            fput($OUTFP, "\n") if !$OUT_AFTER_NEWLINE;
            $OUT_AFTER_NEWLINE = pch_write_line($new, $OUTFP);
            $OUT_ZERO_OUTPUT = 0;
            $new++;
        }
        while ($new <= $pat_end && $P_CHAR[$new] eq '+');
    }
    if ($R_do_defines && $def_state ne 'OUTSIDE') {
        fput($OUTFP, ifdef_line("\n#endif\n"));
        $OUT_AFTER_NEWLINE = 1;
    }
    $OUT_OFFSET += pch_repl_lines() - pch_ptrn_lines();
    return 1;
}

sub mangled_patch {
    my ($old, $new) = @_;
    if ($DEBUG & 1) {
        say("oldchar = '", pch_char($old), "', newchar = '",
            pch_char($new), "'\n");
    }
    fatal("Out-of-sync patch, lines %d,%d -- mangled text or line numbers, maybe?",
          pch_hunk_beg() + $old, pch_hunk_beg() + $new);
}

# ==========================================================================
# 12. Reject files
# ==========================================================================

sub print_unidiff_range {
    my ($fp, $start, $count) = @_;
    if ($count == 0) {
        fput($fp, sprintf("%d,0", $start - 1));
    }
    elsif ($count == 1) {
        fput($fp, sprintf("%d", $start));
    }
    else {
        fput($fp, sprintf("%d,%d", $start, $count));
    }
}

sub print_header_line {
    my ($fp, $tag, $reverse) = @_;
    my $name = pch_name($reverse);
    my $timestr = pch_timestr($reverse);
    putline($fp, $tag, defined $name ? $name : '/dev/null', $timestr);
}

sub abort_hunk_unified {
    my ($header, $reverse) = @_;
    my $old = 1;
    my $lastline = pch_ptrn_lines();
    my $new = $lastline + 1;
    my $c_function = pch_c_function();

    if ($header) {
        if (defined pch_name(INDEX)) {
            putline($REJFP, 'Index: ', pch_name(INDEX));
        }
        print_header_line($REJFP, '--- ', $reverse);
        print_header_line($REJFP, '+++ ', !$reverse);
    }

    # Add out_offset to guess the same as the previous successful hunk.
    fput($REJFP, '@@ -');
    print_unidiff_range($REJFP, pch_first() + $OUT_OFFSET, $lastline);
    fput($REJFP, ' +');
    print_unidiff_range($REJFP, pch_newfirst() + $OUT_OFFSET, pch_repl_lines());
    putline($REJFP, ' @@', $c_function);

    $new++ while $P_CHAR[$new] eq '=' || $P_CHAR[$new] eq "\n";

    if ($DIFF_TYPE != UNI_DIFF) {
        pch_normalize(UNI_DIFF);
    }

    while (1) {
        for (; $old <= $lastline && $P_CHAR[$old] eq '-'; $old++) {
            fput($REJFP, '-');
            pch_write_line($old, $REJFP);
        }
        for (; $new <= $P_END && $P_CHAR[$new] eq '+'; $new++) {
            fput($REJFP, '+');
            pch_write_line($new, $REJFP);
        }

        last if $old > $lastline;

        mangled_patch($old, $new) if $P_CHAR[$new] ne $P_CHAR[$old];

        fput($REJFP, ' ');
        pch_write_line($old, $REJFP);
        $old++;
        $new++;
    }
    mangled_patch($old, $new) if $P_CHAR[$new] ne '^';
}

sub abort_hunk_context {
    my ($header, $reverse) = @_;
    my $pat_end = pch_end();
    my $oldfirst = pch_first() + $OUT_OFFSET;
    my $newfirst = pch_newfirst() + $OUT_OFFSET;
    my $oldlast = $oldfirst + pch_ptrn_lines() - 1;
    my $newlast = $newfirst + pch_repl_lines() - 1;
    my $stars   = $DIFF_TYPE < NEW_CONTEXT_DIFF ? ''       : ' ****';
    my $minuses = $DIFF_TYPE < NEW_CONTEXT_DIFF ? ' -----' : ' ----';
    my $c_function = pch_c_function();

    if ($DIFF_TYPE == UNI_DIFF) {
        pch_normalize(NEW_CONTEXT_DIFF);
    }

    if ($header) {
        if (defined pch_name(INDEX)) {
            putline($REJFP, 'Index: ', pch_name(INDEX));
        }
        print_header_line($REJFP, '*** ', $reverse);
        print_header_line($REJFP, '--- ', !$reverse);
    }
    putline($REJFP, '***************', $c_function);

    for (my $i = 0; $i <= $pat_end; $i++) {
        my $ch = $P_CHAR[$i];
        if ($ch eq '*') {
            if ($oldlast < $oldfirst) {
                fput($REJFP, sprintf("*** 0%s\n", $stars));
            }
            elsif ($oldlast == $oldfirst) {
                fput($REJFP, sprintf("*** %d%s\n", $oldfirst, $stars));
            }
            else {
                fput($REJFP, sprintf("*** %d,%d%s\n", $oldfirst, $oldlast, $stars));
            }
        }
        elsif ($ch eq '=') {
            if ($newlast < $newfirst) {
                fput($REJFP, sprintf("--- 0%s\n", $minuses));
            }
            elsif ($newlast == $newfirst) {
                fput($REJFP, sprintf("--- %d%s\n", $newfirst, $minuses));
            }
            else {
                fput($REJFP, sprintf("--- %d,%d%s\n", $newfirst, $newlast, $minuses));
            }
        }
        elsif ($ch eq ' ' || $ch eq '-' || $ch eq '+' || $ch eq '!') {
            fput($REJFP, "$ch ");
            pch_write_line($i, $REJFP);
        }
        elsif ($ch eq "\n") {
            pch_write_line($i, $REJFP);
        }
        else {
            fatal("fatal internal error in abort_hunk_context");
        }
    }
}

sub abort_hunk {
    my ($outname, $header, $reverse) = @_;
    if (!$TEMP_REJ_EXISTS) {
        init_reject($outname);
    }
    if ($REJECT_FORMAT == UNI_DIFF
        || ($REJECT_FORMAT == NO_DIFF && $DIFF_TYPE == UNI_DIFF)) {
        abort_hunk_unified($header, $reverse);
    }
    else {
        abort_hunk_context($header, $reverse);
    }
}

sub init_reject {
    my ($outname) = @_;
    my ($path, $fh) = make_tempfile('r', $outname, 1, 0666);
    $TEMP_REJ_NAME = $path;
    $TEMP_REJ_EXISTS = 1;
    push @TEMP_FILES, $path;
    $REJFP = $fh;
    $REJFP->autoflush(1);
}

# ==========================================================================
# 13. Filesystem operations
# ==========================================================================

sub make_tempfile {
    # Create a temporary file.  With a real name, the file is created next
    # to it (unless dry-run); otherwise in the temp directory.  Returns
    # (path, handle) on success and (undef, undef) on a name failure, with
    # $! set to ELOOP or EXDEV like GNU's safe path traversal.
    my ($letter, $real_name, $want_handle, $mode) = @_;
    my $template;
    my $dir = $ENV{TMPDIR} || $ENV{TMP} || $ENV{TEMP} || '/tmp';

    if (defined $real_name && !$DRY_RUN) {
        # Use the real name sans any newlines in the last component,
        # followed by ".", LETTER, and 6 random chars.
        my $base = $real_name;
        $base =~ s{.*/}{};
        my $dirpart = substr($real_name, 0, length($real_name) - length($base));
        $base =~ s/\n//g;
        $template = $dirpart . $base . '.' . $letter . 'XXXXXX';
        # GNU traverses each directory component of a relative name
        # without following symlinks; a name may therefore fail with ELOOP
        # (symlink, or recursion beyond the step limit) or EXDEV (".."
        # beyond the working tree, or an absolute symlink outside it).
        if ($dirpart ne '' && !$UNSAFE && substr($dirpart, 0, 1) ne '/') {
            if (!traverse_directory_chain($dirpart)) {
                my $errno = $! + 0;
                return (undef, undef) if $errno == 40 || $errno == 18;
                # ENOENT and the like fall through to the open loop below,
                # which retries once after creating the directories, like
                # GNU's try_safe_open.
            }
        }
    }
    else {
        $template = $dir . '/p' . $letter . 'XXXXXX';
    }

    # GNU uses try_tempname: six random characters.  Filenames with a
    # newline in the last component are invalid for creation.
    my $template_base = $template;
    my $last_component = $template_base;
    $last_component =~ s{.*/}{};
    if (index($last_component, "\n") >= 0) { $! = 84; return (undef, undef) }

    for (1 .. 100000) {
        my $suffix = sprintf('%06d', int(rand(1000000)));
        my $candidate = $template_base . $suffix;
        $TEMP_ATTEMPT_NAME = $candidate;
        my $flags = O_WRONLY | O_CREAT | O_EXCL | O_TRUNC;
        if (sysopen(my $fh, $candidate, $flags, $mode // 0600)) {
            close $fh if !$want_handle;
            return ($candidate, $want_handle ? $fh : undef);
        }
        next if $!{EEXIST};
        if ($!{ENOENT}) {
            makedirs($candidate);
            if (sysopen(my $fh, $candidate, $flags, $mode // 0600)) {
                close $fh if !$want_handle;
                return ($candidate, $want_handle ? $fh : undef);
            }
        }
        # Other errors propagate to the caller, which decides between a
        # diagnostic and skipping the patch (ELOOP, EXDEV, EILSEQ...).
        return (undef, undef);
    }
    fatal("too many temporary files");
}

sub traverse_directory_chain {
    # Port of GNU's safe-path directory traversal for a relative directory
    # prefix ending in "/".  Returns normally on success; on failure sets
    # $! to ELOOP or EXDEV (or ENOENT for missing components) and returns.
    my ($dirpart) = @_;
    my @pending = grep { length } split m{/}, $dirpart;
    my $prefix = '';
    my @stack;
    my $steps = 0;
    my ($cwd_dev, $cwd_ino) = (stat('.'))[0, 1];

    while (1) {
        if (!@pending) {
            last unless @stack;
            @pending = grep { length } split m{/}, pop @stack;
            next;
        }
        my $component = shift @pending;
        $steps++;
        if ($steps > 1024) { $! = 40; return }   # ELOOP
        next if $component eq '.';
        if ($component eq '..') {
            if ($prefix eq '') { $! = 18; return }   # EXDEV
            $prefix =~ s{[^/]+/$}{};
            next;
        }
        my $probe = $prefix eq '' ? $component : "$prefix$component";
        my @st = lstat $probe;
        if (!defined $st[0]) { $! = 2; return }   # ENOENT
        if (($st[2] & 0170000) == 0120000) {
            my $target = readlink $probe;
            if (!defined $target) { $! = 40; return }
            if (substr($target, 0, 1) eq '/') {
                # Absolute target: usable only where it points back into
                # the working tree.
                my $end = length $target;
                my $match;
                while (1) {
                    my @pst = stat substr($target, 0, $end);
                    if (defined $pst[0]
                        && $pst[0] == $cwd_dev && $pst[1] == $cwd_ino) {
                        $match = $end;
                        last;
                    }
                    $end--;
                    last if $end <= 0;
                    $end-- while $end > 0 && substr($target, $end - 1, 1) ne '/';
                    $end-- while $end > 1 && substr($target, $end - 1, 1) eq '/';
                }
                if (!defined $match) { $! = 18; return }   # EXDEV
                my $remainder = substr($target, $match);
                $remainder =~ s{/+\z}{};
                unshift @pending, grep { length } split m{/}, $remainder
                    if length $remainder;
            }
            else {
                # Relative target: continue inside the current directory.
                unshift @pending, grep { length } split m{/}, $target;
            }
            next;
        }
        $prefix = "$probe/";
    }
    return 1;
}

sub makedirs {
    # Make sure we'll have the directories to create a file; ignore errors.
    my ($name) = @_;
    my $filename = $name;
    my @positions;
    my $pos = 0;
    my $component_start = 0;
    while ($pos < length $filename) {
        my $slash = index($filename, '/', $pos);
        last if $slash < 0;
        # Treat multiple slashes as if they were one slash.
        $pos = $slash + 1;
        $pos++ while substr($filename, $pos, 1) eq '/';
        # Ignore slashes at the end of the path.
        last if $pos >= length $filename;
        # "." and ".." need not be tested.
        my $component = substr($filename, $component_start, $slash - $component_start);
        unless ($component eq '.' || $component eq '..') {
            push @positions, $slash;
        }
        $component_start = $pos;
    }
    for my $p (@positions) {
        mkdir substr($filename, 0, $p), 0777;
    }
}

sub removedirs {
    # Remove empty ancestor directories of FILENAME; ignore errors.
    my ($name) = @_;
    my $filename = $name;
    my $len = length $filename;
    for (my $i = $len; $i != 0; $i--) {
        if (substr($filename, $i, 1) eq '/') {
            my $prev = substr($filename, $i - 1, 1);
            next if $prev eq '/';
            next if $prev eq '.'
                && ($i == 1
                    || substr($filename, $i - 2, 1) eq '/'
                    || (substr($filename, $i - 2, 1) eq '.'
                        && ($i == 2 || substr($filename, $i - 3, 1) eq '/')));
            my $dir = substr($filename, 0, $i);
            if ((rmdir $dir) && $VERBOSITY == VERBOSE) {
                say("Removed empty directory ", quotearg($dir), "\n");
            }
        }
    }
}

sub find_backup_file_name {
    my ($file, $type) = @_;
    my $suffix = $SIMPLE_BACKUP_SUFFIX;

    my $dirname = '';
    my $name = $file;
    if ($file =~ m{^(.*/)([^/]*)\z}) {
        ($dirname, $name) = ($1, $2);
    }
    my $searchdir = $dirname eq '' ? '.' : $dirname;

    if ($type eq 'numbered'
        || ($type eq 'existing'
            && -e "$file.~1~")) {
        # Numbered backup: find the highest version suffix in use.
        my $highest = 0;
        if (opendir my $dh, $searchdir) {
            my $prefix = quotemeta("$name.~");
            for my $entry (readdir $dh) {
                if ($entry =~ /\A$prefix([0-9]+)~\z/) {
                    $highest = $1 if $1 > $highest;
                }
            }
            closedir $dh;
        }
        return "$dirname$name.~" . ($highest + 1) . '~';
    }

    # Simple backup.
    return "$file$suffix";
}

sub backup_name_for {
    # Compose the backup name honoring -B/-Y/-z; returns
    # ($bakname, $try_makedirs_errno).
    my ($to) = @_;
    if (defined $ORIGPRAE || defined $ORIGBASE || defined $ORIGSUFF) {
        my $p = $ORIGPRAE // '';
        my $b = $ORIGBASE // '';
        my $s = $ORIGSUFF // '';
        my $dir = $to;
        $dir =~ s{[^/]*\z}{};
        my $base = substr($to, length $dir);
        my $bakname = "$p$dir$b$base$s";
        my $try_makedirs_errno = 0;
        if ((defined $ORIGPRAE
             && (index($ORIGPRAE, '/') >= 0 || index($to, '/') >= 0))
            || (defined $ORIGBASE && index($ORIGBASE, '/') >= 0)) {
            $try_makedirs_errno = 2;   # ENOENT
        }
        return ($bakname, $try_makedirs_errno);
    }
    return (find_backup_file_name($to, $BACKUP_TYPE), 0);
}

sub create_backup {
    my ($to, $to_st, $leave_original) = @_;
    if (defined $to_st && !(($to_st->{mode} & 0170000) == 0100000
                            || ($to_st->{mode} & 0170000) == 0120000)) {
        fatal("File %s is not a %s -- refusing to create backup",
              $to, ($to_st->{mode} & 0170000) == 0120000
                   ? 'symbolic link' : 'regular file');
    }

    if (defined $to_st && lookup_file_id($to_st) == FILE_ID_CREATED) {
        if ($DEBUG & 4) {
            say("File ", quotearg($to), " already seen\n");
        }
        return;
    }

    my ($bakname, $try_makedirs_errno) = backup_name_for($to);

    if (!defined $to_st) {
        # Create an empty backup file.
        $try_makedirs_errno = 2;
        unlink $bakname;
        my $flags = O_WRONLY | O_CREAT | O_EXCL | O_TRUNC;
        while (1) {
            if (sysopen(my $fh, $bakname, $flags, 0666)) {
                close $fh or pfatal("Can't close file %s", quotearg($bakname));
                last;
            }
            if ($! + 0 != $try_makedirs_errno) {
                pfatal("Can't create file %s", quotearg($bakname));
            }
            makedirs($bakname);
            $try_makedirs_errno = 0;
        }
    }
    elsif ($leave_original) {
        copy_file($to, $to_st, { name => $bakname }, 0,
                  $to_st->{mode}, 'times+ids+mode', $try_makedirs_errno == 0);
    }
    else {
        while (!rename($to, $bakname)) {
            if ($! + 0 == $try_makedirs_errno) {
                makedirs($bakname);
                $try_makedirs_errno = 0;
            }
            elsif ($!{EXDEV}) {
                copy_file($to, $to_st, { name => $bakname }, 0,
                          $to_st->{mode}, 'times+ids+mode',
                          $try_makedirs_errno == 0);
                unlink $to;
                last;
            }
            else {
                pfatal("Can't rename file %s to %s",
                       quotearg_n(0, $to), quotearg_n(1, $bakname));
            }
        }
    }
}

sub set_file_attributes {
    my ($to, $attr, $from, $st, $mode, $new_time) = @_;
    my $is_symlink = ($mode & 0170000) == 0120000;
    my $kind = $is_symlink ? 'symbolic link' : 'file';

    if ($attr =~ /times/) {
        my ($atime, $mtime);
        if (defined $new_time) {
            my $t = $new_time->[0] + $new_time->[1] / 1e9;
            ($atime, $mtime) = ($t, $t);
        }
        else {
            $atime = $st->{atime} + ($st->{atime_nsec} // 0) / 1e9;
            $mtime = $st->{mtime} + ($st->{mtime_nsec} // 0) / 1e9;
        }
        if (!utime($atime, $mtime, $to)) {
            pfatal("Failed to set the timestamps of %s %s",
                   $kind, quotearg($to));
        }
    }
    if ($attr =~ /ids/) {
        my $uid = $> == $st->{uid} ? -1 : $st->{uid};
        my $egid = $) + 0;
        my $gid = $egid == $st->{gid} ? -1 : $st->{gid};
        if (($uid != -1 || $gid != -1)
            && !chown($uid, $gid, $to)
            && !($!{EPERM} || $!{EACCES})) {
            pfatal("Failed to set the %s of %s %s",
                   $uid == -1 ? 'owner' : 'owning group', $kind, quotearg($to));
        }
    }
    if ($attr =~ /mode/) {
        # The "diff --git" format does not store the file permissions of
        # symlinks, so don't try to set symlink file permissions.
        if (!$is_symlink && !chmod($mode & 07777, $to)) {
            pfatal("Failed to set the permissions of %s %s",
                   $kind, quotearg($to));
        }
    }
}

sub copy_file {
    # Copy a file.  $outto is { name, stat_to? }; $attr is a string of
    # 'tims', 'ids', 'mode' flags.
    my ($from, $from_st, $outto, $to_flags, $mode, $attr, $dir_known) = @_;
    my $to = $outto->{name};

    if (($mode & 0170000) == 0120000) {
        my $target = readlink $from;
        pfatal("Can't read symbolic link %s", $from) unless defined $target;
        if (!symlink $target, $to) {
            if ($!{ENOENT} && !$dir_known) {
                makedirs($to);
            }
            symlink $target, $to
                or pfatal("Can't create %s %s", 'symbolic link', $to);
        }
        if (defined $outto->{stat_to}) {
            my $lst = {};
            pfatal("Can't get file attributes of %s %s", 'symbolic link', $to)
                if stat_file($to, $lst);
            %{ $outto->{stat_to} } = %$lst;
        }
        return;
    }

    # Regular file copy.
    $to_flags //= 0;
    my $fh;
    my $created = 0;
    my $open_flags = O_WRONLY | O_CREAT | O_TRUNC | $to_flags;
    my $open_mode = ($mode & 07777) | 0600;
    while (1) {
        if (sysopen($fh, $to, $open_flags, $open_mode)) {
            $created = 1;
            last;
        }
        if ($!{ENOENT} && !$dir_known) {
            makedirs($to);
            $dir_known = 1;
            next;
        }
        pfatal("Can't create file %s", quotearg($to));
    }
    binmode $fh, ':raw';
    open my $src, '<:raw', $from or pfatal("Can't reopen file %s", quotearg($from));
    my $data = read_all($src);
    close $src;
    print $fh $data or write_fatal();
    close $fh or write_fatal();
    set_file_attributes($to, $attr, $from, $from_st, $mode, undef);
    if (defined $outto->{stat_to}) {
        my $st = {};
        pfatal("Can't get file attributes of %s %s", 'file', $to)
            if stat_file($to, $st);
        %{ $outto->{stat_to} } = %$st;
    }
}

sub move_file {
    # Move a file $from (named; $from_st is its status if known) to $to,
    # renaming if possible and copying if necessary.  If $from is undef,
    # remove $to.  Back up $to if $backup is true.
    my ($from, $from_st, $to, $mode, $backup) = @_;
    my $st_to = {};
    my $to_errno = stat_file($to, $st_to);
    if ($backup) {
        create_backup($to, $to_errno ? undef : $st_to, 0);
    }
    if (!$to_errno) {
        insert_file_id($st_to, FILE_ID_OVERWRITTEN);
    }

    if (defined $from) {
        if (($mode & 0170000) == 0120000) {
            # $from contains the contents of the symlink we have patched;
            # convert that back into a symlink.
            open my $fh, '<:raw', $from
                or pfatal("Can't reopen file %s", quotearg($from));
            my $buffer = read_all($fh);
            close $fh;
            my $to_dir_known_to_exist = 0;
            if (!$backup) {
                if (unlink $to) { $to_dir_known_to_exist = 1 }
            }
            {
                my $last_component = $to;
                $last_component =~ s{.*/}{};
                $! = 84 if index($last_component, "\n") >= 0;
            }
            unless (symlink $buffer, $to) {
                if ($!{ENOENT} && !$to_dir_known_to_exist) {
                    makedirs($to);
                    symlink $buffer, $to
                        or pfatal("Can't create %s %s", 'symbolic link', $to);
                }
                else {
                    pfatal("Can't create %s %s", 'symbolic link', $to);
                }
            }
            my $lst = {};
            pfatal("Can't get file attributes of %s %s", 'symbolic link', $to)
                if stat_file($to, $lst);
            insert_file_id($lst, FILE_ID_CREATED);
        }
        else {
            if ($DEBUG & 4) {
                say("Renaming file ", quotearg_n(0, $from), ' to ',
                    quotearg_n(1, $to), "\n");
            }
            my $last_component = $to;
            $last_component =~ s{.*/}{};
            if (index($last_component, "\n") >= 0) {
                $! = 84;
                pfatal("Can't rename file %s to %s",
                       quotearg_n(0, $from), quotearg_n(1, $to));
            }
            if (!rename($from, $to)) {
                my $to_dir_known_to_exist = 0;
                my $rename_errno = $! + 0;
                if ($rename_errno == 2 && ($to_errno == -1 || $to_errno == 2)) {
                    makedirs($to);
                    $to_dir_known_to_exist = 1;
                    if (rename($from, $to)) {
                        insert_file_id($from_st, FILE_ID_CREATED)
                            if defined $from_st;
                        return;
                    }
                    $rename_errno = $! + 0;
                }
                if ($rename_errno == 18) {   # EXDEV
                    my $tost = {};
                    copy_file($from, $from_st,
                              { name => $to, stat_to => $tost }, 0,
                              $mode, '', $to_dir_known_to_exist);
                    insert_file_id($tost, FILE_ID_CREATED);
                    return;
                }
                pfatal("Can't rename file %s to %s",
                       quotearg_n(0, $from), quotearg_n(1, $to));
            }
            # Mark the temporary file as created for the backup logic.
            insert_file_id($from_st, FILE_ID_CREATED) if defined $from_st;
        }
    }
    elsif (!$backup) {
        if ($DEBUG & 4) {
            say("Removing file ", quotearg($to), "\n");
        }
        my $unlinked = unlink $to;
        if (!$unlinked && !$!{ENOENT}) {
            pfatal("Can't remove file %s", quotearg($to));
        }
    }
}

# ==========================================================================
# 14. Deferred output placement
# ==========================================================================

sub output_file_now {
    my ($from_name, $from_st, $to, $mode, $backup) = @_;
    if (!defined $to) {
        if ($backup) {
            create_backup($from_name, $from_st, 1);
        }
    }
    else {
        move_file($from_name, $from_st, $to, $mode, $backup);
    }
}

sub output_file {
    my ($from_name, $from_st, $to, $to_st, $mode, $backup) = @_;
    if (!defined $from_name) {
        # Remember which files should be deleted, and delete them only when
        # the entire patch input has been processed.
        my $st = $to_st;
        if (!defined $st) {
            $st = {};
            stat_file($to, $st);
        }
        push @FILES_TO_DELETE, { name => $to, st => $st, backup => $backup };
        insert_file_id($st, FILE_ID_DELETE_LATER);
    }
    elsif ($P_GIT_DIFF && pch_says_nonexistent($REVERSE_FLAG) != 2) {
        # In git-style diffs, the "before" state of each patch refers to
        # the initial state; queue the output so concatenated diffs are
        # processed one at a time.  Ownership of the temporary file moves
        # to the queue.
        push @FILES_TO_OUTPUT, {
            from_name => $from_name, from_st => $from_st,
            to => $to, mode => $mode, backup => $backup,
        };
        @TEMP_FILES = grep { $_ ne $from_name } @TEMP_FILES;
    }
    else {
        output_file_now($from_name, $from_st, $to, $mode, $backup);
    }
}

sub output_files {
    my ($st, $exiting) = @_;
    my @queue = @FILES_TO_OUTPUT;
    @FILES_TO_OUTPUT = ();
    for my $f (@queue) {
        output_file_now($f->{from_name}, $f->{from_st}, $f->{to},
                        $f->{mode}, $f->{backup});
        if ($f->{to}) {
            unlink $f->{from_name};
        }
        last if defined $st
            && $st->{dev} == $f->{from_st}{dev}
            && $st->{ino} == $f->{from_st}{ino};
    }
}

sub delete_files {
    for my $f (@FILES_TO_DELETE) {
        if (lookup_file_id($f->{st}) == FILE_ID_DELETE_LATER) {
            my $mode = $f->{st}{mode};
            if ($VERBOSITY == VERBOSE) {
                say('Removing ',
                    ($mode & 0170000) == 0120000 ? 'symbolic link' : 'file',
                    ' ', quotearg($f->{name}), "\n");
            }
            move_file(undef, undef, $f->{name}, $mode, $f->{backup});
            removedirs($f->{name});
        }
    }
}

# ==========================================================================
# 15. The main loop
# ==========================================================================

sub create_output_file {
    my ($name) = @_;
    my $mode = $INSTAT{mode} // 0;
    $mode = ($mode | 0600) & ~0111;
    my $fh;
    my $dir_known = 0;
    while (1) {
        # Creating a file whose name has a newline in its last component
        # fails like GNU's safe_open unless the file already exists.
        my $last_component = $name;
        $last_component =~ s{.*/}{};
        if (index($last_component, "\n") >= 0 && !-e $name) {
            $! = 84;
            pfatal("Can't create file %s", quotearg($name));
        }
        if (sysopen($fh, $name, O_WRONLY | O_CREAT | O_TRUNC, $mode)) {
            last;
        }
        if ($!{ENOENT}) {
            my $last_component = $name;
            $last_component =~ s{.*/}{};
            if (index($last_component, "\n") >= 0) {
                $! = 84;
                pfatal("Can't create file %s", quotearg($name));
            }
        }
        if ($!{ENOENT} && !$dir_known) {
            makedirs($name);
            $dir_known = 1;
            next;
        }
        pfatal("Can't create file %s", quotearg($name));
    }
    binmode $fh, ':raw';
    return $fh;
}

sub open_outfile {
    my ($name) = @_;
    if ($name ne '-') {
        return create_output_file($name);
    }
    else {
        # Send output to standard output, and messages to standard error.
        open my $ofp, '>&', \*STDOUT
            or pfatal("Failed to duplicate standard output");
        $ofp->autoflush(1);
        $SAY_TO_STDERR = 1;
        return $ofp;
    }
}

sub init_output {
    $OUTFP = undef;
    $OUT_AFTER_NEWLINE = 1;
    $OUT_ZERO_OUTPUT = 1;
}

sub do_ed_script {
    # Apply an ed script patch by executing the accepted command subset on
    # a copy of the input, the way GNU's invocation of ed would.
    my ($input_name, $output_path, $ofp) = @_;

    my $dry = $DRY_RUN || $SKIP_REST_OF_PATCH;

    # Collect the ed script from the patch file.
    my @script;
    while (1) {
        my $beginning_of_this_line = $PFP_POS;
        my $chars_read = get_line(0);
        if (!$chars_read) {
            next_intuit_at($beginning_of_this_line, $P_INPUT_LINE);
            last;
        }
        my $ed_command_letter = get_ed_command_letter($PATCHBUF);
        if ($ed_command_letter ne '') {
            push @script, $PATCHBUF unless $dry;
            if ($ed_command_letter ne 'd' && $ed_command_letter ne 's') {
                $P_PASS_COMMENTS_THROUGH = 1;
                while ((my $chars2 = get_line(1)) != 0) {
                    push @script, $PATCHBUF unless $dry;
                    last if $chars2 == 2 && $PATCHBUF eq ".\n";
                }
                $P_PASS_COMMENTS_THROUGH = 0;
            }
        }
        else {
            next_intuit_at($beginning_of_this_line, $P_INPUT_LINE);
            last;
        }
    }
    return if $dry;

    # GNU copies the input to the output file before ed runs; when the
    # input does not exist, ed starts with an empty buffer.
    if ($INERRNO != 2) {
        copy_file($input_name, \%INSTAT, { name => $output_path }, 0,
                  $INSTAT{mode}, '', 1);
    }

    # Load the output content and execute the script.
    my @lines = ('');      # 1-based; ed's current line starts at 0
    if (-f $output_path) {
        open my $fh, '<:raw', $output_path
            or pfatal("Can't open file %s", quotearg($output_path));
        my $data = read_all($fh);
        close $fh;
        my $pos = 0;
        while (1) {
            my $nl = index($data, "\n", $pos);
            if ($nl < 0) {
                push @lines, substr($data, $pos) if $pos < length $data;
                last;
            }
            push @lines, substr($data, $pos, $nl + 1 - $pos);
            $pos = $nl + 1;
        }
    }

    my $current = 0;       # ed's current line, 1-based; 0 for an empty buffer
    my $failed = 0;
    my $i = 0;
    my @text_lines;
    while ($i <= $#script) {
        my $command = $script[$i];
        $i++;
        my ($addr1, $addr2, $letter, $valid) = parse_ed_command($command);
        if (!$valid) { $failed = 1; last }
        my $count = $#lines;   # number of lines in the buffer
        if ($letter eq 'a' || $letter eq 'i') {
            my $addr = defined $addr1 ? $addr1 : $current;
            if ($addr < 0 || $addr > $count) { $failed = 1; last }
            # Collect the replacement text from the script.
            @text_lines = ();
            while ($i <= $#script && $script[$i] ne ".\n") {
                push @text_lines, $script[$i];
                $i++;
            }
            $i++ if $i <= $#script;   # skip the "." terminator
            splice(@lines, $addr + 1, 0, @text_lines);
            $current = $addr + scalar(@text_lines);
        }
        elsif ($letter eq 'c') {
            my $from = defined $addr1 ? $addr1 : $current;
            my $to = defined $addr2 ? $addr2 : $from;
            if ($from < 1 || $to < $from || $to > $count) { $failed = 1; last }
            @text_lines = ();
            while ($i <= $#script && $script[$i] ne ".\n") {
                push @text_lines, $script[$i];
                $i++;
            }
            $i++ if $i <= $#script;
            splice(@lines, $from, $to - $from + 1, @text_lines);
            $current = $to - ($to - $from + 1) + scalar(@text_lines);
        }
        elsif ($letter eq 'd') {
            my $from = defined $addr1 ? $addr1 : $current;
            my $to = defined $addr2 ? $addr2 : $from;
            if ($from < 1 || $to < $from || $to > $count) { $failed = 1; last }
            splice(@lines, $from, $to - $from + 1);
            $current = $to > $#lines ? $#lines : $to;
        }
        elsif ($letter eq 's') {
            my $from = defined $addr1 ? $addr1 : $current;
            my $to = defined $addr2 ? $addr2 : $from;
            if ($from < 1 || $to < $from || $to > $count) { $failed = 1; last }
            for my $line_no ($from .. $to) {
                my $dot = index($lines[$line_no], '.');
                if ($dot >= 0) {
                    substr($lines[$line_no], $dot, 1) = '';
                }
            }
            $current = $to;
        }
        else {
            $failed = 1;
            last;
        }
    }
    fatal('%s FAILED', 'ed') if $failed;

    # Write the buffer back to the output file.
    open my $out, '>:raw', $output_path
        or pfatal("Can't create file %s", quotearg($output_path));
    shift @lines;
    print $out join('', @lines) or write_fatal();
    close $out or write_fatal();

    if (defined $ofp) {
        open my $ifp, '<:raw', $output_path
            or pfatal("can't open '%s'", $output_path);
        my $data = read_all($ifp);
        close $ifp;
        fput($ofp, $data);
    }
}

sub parse_ed_command {
    # Parse an ed command line the way GNU's acceptor does, and return
    # ($addr1, $addr2, $letter, $valid).  Addresses are numbers or undef.
    my ($command) = @_;
    my $pos = 0;
    my $len = length $command;
    my $addr1;
    my $addr2;
    my $pair = 0;

    if ($pos < $len && c_isdigit(substr($command, $pos, 1))) {
        my $start = $pos;
        $pos++ while $pos < $len && c_isdigit(substr($command, $pos, 1));
        $addr1 = substr($command, $start, $pos - $start) + 0;
        if (substr($command, $pos, 1) eq ',') {
            $pos++;
            return (undef, undef, '', 0)
                unless $pos < $len && c_isdigit(substr($command, $pos, 1));
            my $start2 = $pos;
            $pos++ while $pos < $len && c_isdigit(substr($command, $pos, 1));
            $addr2 = substr($command, $start2, $pos - $start2) + 0;
            $pair = 1;
        }
    }

    my $letter = substr($command, $pos, 1);
    $pos++;

    if ($letter eq 'a' || $letter eq 'i') { return (undef, undef, '', 0) if $pair }
    elsif ($letter eq 'c' || $letter eq 'd') { }
    elsif ($letter eq 's') {
        return (undef, undef, '', 0)
            unless substr($command, $pos, 4) eq '/.//';
        $pos += 4;
    }
    else { return (undef, undef, '', 0) }

    $pos++ while $pos < $len && c_isblank(substr($command, $pos, 1));
    return (undef, undef, '', 0) unless substr($command, $pos, 1) eq "\n";
    return ($addr1, $addr2, $letter, 1);
}

sub context_matches_file {
    my ($old, $where) = @_;
    my ($itext, $isize) = ifetch($where);
    return 0 unless $isize;
    if ($CANONICALIZE_WS) {
        return similar(pfetch($old), pch_line_len($old), $itext, $isize);
    }
    return $isize == pch_line_len($old)
        && $itext eq substr(pfetch($old), 0, $isize) ? 1 : 0;
}

sub bestmatch {
    # Greedy LCS/SES (Myers 1986, figure 2), as in GNU's bestmatch.h.
    # Returns the number of changes; sets $$py_ref to the matched prefix
    # length in y (or -1 when no match was found within the bounds).
    my ($xoff, $xlim, $yoff, $ylim, $min, $max, $py_ref) = @_;
    my $dmin = $xoff - $ylim;
    my $dmax = $xlim - $yoff;
    my $fmid = $xoff - $yoff;
    my ($fmin, $fmax) = ($fmid, $fmid);
    my $ymax = -1;
    my $c;
    my %fd;
    my $fmid_plus_2_min;

    if ($min) {
        $fmid_plus_2_min = $fmid + 2 * $min;
        $min += $yoff;
        if ($min > $ylim) {
            return $max + 1;
        }
    }
    else {
        $fmid_plus_2_min = 0;   # disable this check
    }
    $min = $ylim unless defined $py_ref;

    # Handle the exact-match case.
    while ($xoff < $xlim && $yoff < $ylim
           && context_matches_file($xoff, $yoff)) {
        $xoff++;
        $yoff++;
    }
    if ($xoff == $xlim && $yoff >= $min
        && $xoff + $yoff >= $fmid_plus_2_min) {
        $ymax = $yoff;
        $c = 0;
    }
    else {
        $fd{$fmid} = $xoff;
        for ($c = 1; $c <= $max; $c++) {
            if ($fmin > $dmin) { $fd{--$fmin - 1} = -1 }
            else { $fmin++ }
            if ($fmax < $dmax) { $fd{++$fmax + 1} = -1 }
            else { $fmax-- }
            for (my $d = $fmax; $d >= $fmin; $d -= 2) {
                my $x = $fd{$d - 1} < $fd{$d + 1} ? $fd{$d + 1} : $fd{$d - 1} + 1;
                my $y = $x - $d;
                while ($x < $xlim && $y < $ylim && context_matches_file($x, $y)) {
                    $x++;
                    $y++;
                }
                $fd{$d} = $x;
                if ($x == $xlim && $y >= $min
                    && $x + $y - $c >= $fmid_plus_2_min) {
                    $ymax = $y if $ymax < $y;
                    last if $y == $ylim;
                }
            }
            last if $ymax != -1;
        }
    }

    $$py_ref = $ymax if defined $py_ref;
    return $c;
}

my $TOO_EXPENSIVE = 9223372036854775807;

sub diff_diag {
    # Find the midpoint of the shortest edit script; port of diffseq.h's
    # diag() with GNU merge's settings (USE_HEURISTIC, find_minimal false).
    my ($xoff, $xlim, $yoff, $ylim, $find_minimal, $ctxt) = @_;
    my ($fd, $bd) = ($ctxt->{fdiag}, $ctxt->{bdiag});
    my $dmin = $xoff - $ylim;
    my $dmax = $xlim - $yoff;
    my $fmid = $xoff - $yoff;
    my $bmid = $xlim - $ylim;
    my ($fmin, $fmax) = ($fmid, $fmid);
    my ($bmin, $bmax) = ($bmid, $bmid);
    my $odd = ($fmid - $bmid) & 1;
    my %part;

    $fd->{$fmid} = $xoff;
    $bd->{$bmid} = $xlim;

    my $c;
    for ($c = 1;; $c++) {
        my $big_snake = 0;

        # Extend the top-down search by an edit step in each diagonal.
        if ($fmin > $dmin) { $fd->{--$fmin - 1} = -1 }
        else { $fmin++ }
        if ($fmax < $dmax) { $fd->{++$fmax + 1} = -1 }
        else { $fmax-- }
        for (my $d = $fmax; $d >= $fmin; $d -= 2) {
            my $tlo = $fd->{$d - 1};
            my $thi = $fd->{$d + 1};
            my $x0 = $tlo < $thi ? $thi : $tlo + 1;
            my $y = $x0 - $d;
            my $x = $x0;
            while ($x < $xlim && $y < $ylim
                   && context_matches_file($x, $y)) {
                $x++;
                $y++;
            }
            $big_snake = 1 if $x - $x0 > 20;
            $fd->{$d} = $x;
            if ($odd && $bmin <= $d && $d <= $bmax && $bd->{$d} <= $x) {
                return (xmid => $x, ymid => $y,
                        lo_minimal => 1, hi_minimal => 1);
            }
        }

        # Extend the bottom-up search.
        if ($bmin > $dmin) { $bd->{--$bmin - 1} = $TOO_EXPENSIVE }
        else { $bmin++ }
        if ($bmax < $dmax) { $bd->{++$bmax + 1} = $TOO_EXPENSIVE }
        else { $bmax-- }
        for (my $d = $bmax; $d >= $bmin; $d -= 2) {
            my $tlo = $bd->{$d - 1};
            my $thi = $bd->{$d + 1};
            my $x0 = $tlo < $thi ? $tlo : $thi - 1;
            my $y = $x0 - $d;
            my $x = $x0;
            while ($xoff < $x && $yoff < $y
                   && context_matches_file($x - 1, $y - 1)) {
                $x--;
                $y--;
            }
            $big_snake = 1 if $x0 - $x > 20;
            $bd->{$d} = $x;
            if (!$odd && $fmin <= $d && $d <= $fmax && $x <= $fd->{$d}) {
                return (xmid => $x, ymid => $y,
                        lo_minimal => 1, hi_minimal => 1);
            }
        }

        # Heuristic: check occasionally for a diagonal that has made lots
        # of progress compared with the edit distance.
        next if $c <= 200;
        next unless $big_snake && $ctxt->{heuristic};
        {
            my $best = 0;
            for (my $d = $fmax; $d >= $fmin; $d -= 2) {
                my $dd = $d - $fmid;
                my $x = $fd->{$d};
                my $y = $x - $d;
                my $v = ($x - $xoff) * 2 - $dd;
                my $absdd = $dd < 0 ? -$dd : $dd;
                if ($v > 12 * ($c + $absdd)) {
                    if ($v > $best
                        && $xoff + 20 <= $x && $x < $xlim
                        && $yoff + 20 <= $y && $y < $ylim) {
                        # Insist that it end with a significant snake.
                        my $k = 1;
                        $k++ while context_matches_file($x - $k, $y - $k);
                        if ($k == 20) {
                            $best = $v;
                            return (xmid => $x, ymid => $y,
                                    lo_minimal => 1, hi_minimal => 0);
                        }
                    }
                }
            }
        }
        {
            my $best = 0;
            for (my $d = $bmax; $d >= $bmin; $d -= 2) {
                my $dd = $d - $bmid;
                my $x = $bd->{$d};
                my $y = $x - $d;
                my $v = ($xlim - $x) * 2 + $dd;
                my $absdd = $dd < 0 ? -$dd : $dd;
                if ($v > 12 * ($c + $absdd)) {
                    if ($v > $best
                        && $xoff < $x && $x <= $xlim - 20
                        && $yoff < $y && $y <= $ylim - 20) {
                        my $k = 0;
                        $k++ while context_matches_file($x + $k, $y + $k);
                        if ($k == 19) {
                            $best = $v;
                            return (xmid => $x, ymid => $y,
                                    lo_minimal => 0, hi_minimal => 1);
                        }
                    }
                }
            }
        }
    }
}

sub diff_compareseq {
    # Port of diffseq.h's compareseq() for GNU merge's settings.
    my ($xoff, $xlim, $yoff, $ylim, $find_minimal, $ctxt) = @_;

    while (1) {
        # Slide down the bottom initial diagonal.
        $xoff++, $yoff++
            while $xoff < $xlim && $yoff < $ylim
            && context_matches_file($xoff, $yoff);

        # Slide up the top initial diagonal.
        $xlim--, $ylim--
            while $xoff < $xlim && $yoff < $ylim
            && context_matches_file($xlim - 1, $ylim - 1);

        # Handle simple cases.
        if ($xoff == $xlim) {
            while ($yoff < $ylim) {
                $ctxt->{ychar}[$yoff] = '+';
                $yoff++;
            }
            return 0;
        }
        if ($yoff == $ylim) {
            while ($xoff < $xlim) {
                $ctxt->{xchar}[$xoff] = '-';
                $xoff++;
            }
            return 0;
        }

        my %part = diff_diag($xoff, $xlim, $yoff, $ylim, $find_minimal, $ctxt);

        my ($xoff1, $xlim1, $yoff1, $ylim1, $find_minimal1);
        my ($xoff2, $xlim2, $yoff2, $ylim2, $find_minimal2);
        if (($xlim + $ylim) - ($part{xmid} + $part{ymid})
            < ($part{xmid} + $part{ymid}) - ($xoff + $yoff)) {
            # The second problem is smaller, so do it first.
            ($xoff1, $xlim1, $yoff1, $ylim1)
                = ($part{xmid}, $xlim, $part{ymid}, $ylim);
            $find_minimal1 = $part{hi_minimal};
            ($xoff2, $xlim2, $yoff2, $ylim2)
                = ($xoff, $part{xmid}, $yoff, $part{ymid});
            $find_minimal2 = $part{lo_minimal};
        }
        else {
            ($xoff1, $xlim1, $yoff1, $ylim1)
                = ($xoff, $part{xmid}, $yoff, $part{ymid});
            $find_minimal1 = $part{lo_minimal};
            ($xoff2, $xlim2, $yoff2, $ylim2)
                = ($part{xmid}, $xlim, $part{ymid}, $ylim);
            $find_minimal2 = $part{hi_minimal};
        }

        return 1
            if diff_compareseq($xoff1, $xlim1, $yoff1, $ylim1,
                               $find_minimal1, $ctxt);

        ($xoff, $xlim, $yoff, $ylim, $find_minimal)
            = ($xoff2, $xlim2, $yoff2, $ylim2, $find_minimal2);
    }
}

sub compute_changes {
    my ($xmin, $xmax, $ymin, $ymax, $ctxt) = @_;
    my $diags = $xmax + $ymax + 3;
    my $fdiag = {};
    my $bdiag = {};
    $ctxt->{fdiag} = $fdiag;
    $ctxt->{bdiag} = $bdiag;
    $ctxt->{heuristic} = 1;
    $ctxt->{too_expensive} = $TOO_EXPENSIVE;
    diff_compareseq($xmin, $xmax, $ymin, $ymax, 0, $ctxt);
}

sub print_linerange {
    my ($from, $to) = @_;
    if ($to <= $from) {
        say(sprintf("%d", $from));
    }
    else {
        say(sprintf("%d-%d", $from, $to));
    }
}

sub merge_result {
    my ($first_result_ref, $hunk, $what, $from, $to) = @_;
        if ($$first_result_ref && $what) {
        say(sprintf("Hunk #%d %s at ", $hunk, $what));
        $MERGE_LAST_WHAT = $what;
    }
    elsif (!$what) {
        if (!$$first_result_ref) {
            say(".\n");
            $MERGE_LAST_WHAT = undef;
        }
        return;
    }
    elsif ($MERGE_LAST_WHAT eq $what) {
        say(',');
    }
    else {
        say(sprintf(', %s at ', $what));
    }

    print_linerange($from + $OUT_OFFSET, $to + $OUT_OFFSET);
    $$first_result_ref = 0;
}

sub merge_hunk {
    my ($hunk, $where, $somefailed_ref) = @_;
    my $first_result = 1;
    my $already_applied;
    my $old = 1;
    my $firstold = pch_ptrn_lines();
    my $new = $firstold + 1;

    # Convert '!' markers into '-' and '+' to simplify things here.
    pch_normalize(UNI_DIFF);

    while ($P_CHAR[$new] eq '=' || $P_CHAR[$new] eq "\n") {
        $new++;
    }

    my $matched;
    my $applies_cleanly;
    if ($where) {
        $applies_cleanly = 1;
        $matched = pch_ptrn_lines();
    }
    else {
        $where = locate_merge(\$matched);
        $applies_cleanly = 0;
    }

    my $in = $firstold + 2;
    my @oldin;
    $oldin[0] = '*';
    $oldin[$in - 1] = '=';
    $oldin[$in + $matched] = '^';
    for my $n (1 .. $in - 2) { $oldin[$n] = ' ' }
    for my $n ($in .. $in + $matched - 1) { $oldin[$n] = ' ' }
    my $ctxt = {
        xchar => [], ychar => [],
    };
    compute_changes($old, $in - 1, $where, $where + $matched, $ctxt);
    for my $x ($old .. $in - 2) {
        $oldin[$x] = $ctxt->{xchar}[$x] if defined $ctxt->{xchar}[$x];
    }
    for my $y ($where .. $where + $matched - 1) {
        $oldin[$in + $y - $where] = $ctxt->{ychar}[$y]
            if defined $ctxt->{ychar}[$y];
    }

    if ($LAST_FROZEN_LINE < $where - 1) {
        return 0 unless copy_till($where - 1);
    }

    my $firstin;
    my $lastwhere;
  merge_loop:
    for (;;) {
        $firstold = $old;
        my $firstnew = $new;
        my $firstin = $in;

        if ($P_CHAR[$old] eq '-' || $P_CHAR[$new] eq '+') {
            while ($P_CHAR[$old] eq '-') {
                if ($oldin[$old] eq '-' || $oldin[$in] eq '+') {
                    goto conflict;
                }
                elsif ($oldin[$old] eq ' ') {
                    $in++;
                }
                $old++;
            }
            goto conflict if $oldin[$old] eq '-' || $oldin[$in] eq '+';
            $new++ while $P_CHAR[$new] eq '+';

            my $lines = $new - $firstnew;
            if ($VERBOSITY == VERBOSE
                || ($VERBOSITY != SILENT && !$applies_cleanly)) {
                merge_result(\$first_result, $hunk, 'merged',
                             $where, $where + $lines - 1);
            }
            $LAST_FROZEN_LINE += ($old - $firstold);
            $where += ($old - $firstold);
            $OUT_OFFSET += $new - $firstnew;

            if ($firstnew < $new) {
                while ($firstnew < $new) {
                    $OUT_AFTER_NEWLINE = pch_write_line($firstnew, $OUTFP);
                    $firstnew++;
                }
                $OUT_ZERO_OUTPUT = 0;
            }
        }
        elsif ($P_CHAR[$old] eq ' ') {
            if ($oldin[$old] eq '-') {
                while ($P_CHAR[$old] eq ' ') {
                    last if $oldin[$old] ne '-';
                    if ($P_CHAR[$new] eq '+') {
                        goto conflict;
                    }
                    $old++;
                    $new++;
                }
                goto conflict if $P_CHAR[$old] eq '-' || $P_CHAR[$new] eq '+';
            }
            elsif ($oldin[$in] eq '+') {
                $in++ while $oldin[$in] eq '+';

                # Take these lines from the input file.
                $where += $in - $firstin;
                return 0 unless copy_till($where - 1);
            }
            elsif ($oldin[$old] eq ' ') {
                while ($P_CHAR[$old] eq ' '
                       && $oldin[$old] eq ' '
                       && $P_CHAR[$new] eq ' '
                       && $oldin[$in] eq ' ') {
                    $old++;
                    $new++;
                    $in++;
                }

                # Take these lines from the input file.
                $where += ($in - $firstin);
                return 0 unless copy_till($where - 1);
            }
        }
        else {
            # Nothing more left to merge.
            last merge_loop;
        }
        next merge_loop;

      conflict:
        # Find the end of the conflict.
        while (1) {
            if ($P_CHAR[$old] eq '-') {
                $in++ while $oldin[$in] eq '+';
                if ($oldin[$old] eq ' ') {
                    $in++;
                }
                $old++;
            }
            elsif ($oldin[$old] eq '-') {
                $new++ while $P_CHAR[$new] eq '+';
                if ($P_CHAR[$old] eq ' ') {
                    $new++;
                }
                $old++;
            }
            elsif ($P_CHAR[$new] eq '+') {
                $new++ while $P_CHAR[$new] eq '+';
            }
            elsif ($oldin[$in] eq '+') {
                $in++ while $oldin[$in] eq '+';
            }
            else {
                last;
            }
        }

        # Output common prefix lines.
        for ($lastwhere = $where;
             $firstin < $in && $firstnew < $new
             && context_matches_file($firstnew, $lastwhere);
             $firstin++, $firstnew++, $lastwhere++) {
        }
        $already_applied = ($firstin == $in && $firstnew == $new) ? 1 : 0;
        if ($already_applied) {
            merge_result(\$first_result, $hunk, 'already applied',
                         $where, $lastwhere - 1);
        }
        if ($CONFLICT_STYLE eq 'diff3') {
            my $common_prefix = $lastwhere - $where;

            # Forget about common prefix lines.
            $firstin -= $common_prefix;
            $firstnew -= $common_prefix;
            $lastwhere -= $common_prefix;
        }
        if ($where != $lastwhere) {
            $where = $lastwhere;
            return 0 unless copy_till($where - 1);
        }

        if (!$already_applied) {
            my $common_suffix = 0;

            if ($CONFLICT_STYLE eq 'merge') {
                # Remember common suffix lines.
                for ($lastwhere = $where + ($in - $firstin);
                     $firstin < $in && $firstnew < $new
                     && context_matches_file($new - 1, $lastwhere - 1);
                     $in--, $new--, $lastwhere--, $common_suffix++) {
                }
            }

            my $lines = 3 + ($in - $firstin) + ($new - $firstnew);
            if ($CONFLICT_STYLE eq 'diff3') {
                $lines += 1 + ($old - $firstold);
            }
            merge_result(\$first_result, $hunk, 'NOT MERGED',
                         $where, $where + $lines - 1);
            $OUT_OFFSET += $lines - ($in - $firstin);

            fput($OUTFP, ifdef_line("\n<<<<<<<\n"));
            $OUT_AFTER_NEWLINE = 1;
            if ($firstin < $in) {
                $where += ($in - $firstin);
                return 0 unless copy_till($where - 1);
            }

            if ($CONFLICT_STYLE eq 'diff3') {
                fput($OUTFP, ifdef_line("\n|||||||\n"));
                $OUT_AFTER_NEWLINE = 1;
                while ($firstold < $old) {
                    $OUT_AFTER_NEWLINE = pch_write_line($firstold, $OUTFP);
                    $firstold++;
                }
            }

            fput($OUTFP, ifdef_line("\n=======\n"));
            $OUT_AFTER_NEWLINE = 1;
            while ($firstnew < $new) {
                $OUT_AFTER_NEWLINE = pch_write_line($firstnew, $OUTFP);
                $firstnew++;
            }
            fput($OUTFP, ifdef_line("\n>>>>>>>\n"));
            $OUT_AFTER_NEWLINE = 1;
            $OUT_ZERO_OUTPUT = 0;

            # Output common suffix lines.
            if ($common_suffix) {
                $where += $common_suffix;
                return 0 unless copy_till($where - 1);
                $in += $common_suffix;
                $new += $common_suffix;
            }
            $$somefailed_ref = 1;
        }
    }
    merge_result(\$first_result, 0, 0, 0, 0);

    return 1;
}

sub locate_merge {
    my ($matched_ref) = @_;
    my $first_guess = pch_first() + $IN_OFFSET;
    my $pat_lines = pch_ptrn_lines();
    my $context_lines = count_context_lines();
    my $max_where = $INPUT_LINES - $pat_lines + $context_lines + 1;
    my $min_where = $LAST_FROZEN_LINE + 1;
    my $max_pos_offset = $max_where - $first_guess;
    my $max_neg_offset = $first_guess - $min_where;
    my $max_offset = $max_pos_offset > $max_neg_offset
        ? $max_pos_offset : $max_neg_offset;
    my $where = $first_guess;
    my $max_matched = 0;
    my $match_until_eof;

    if ($context_lines == 0) {
        # locate_hunk() already tried that
        $$matched_ref = 0;
        $where = $min_where if $where < $min_where;
        return $where;
    }

    # Allow at most CONTEXT_LINES lines to be replaced (replacing counts as
    # insert + delete), and require the remaining MIN lines to match.
    my $min = $pat_lines - $context_lines;
    my $max = 2 * $context_lines;

    say("locating merge: min=$min max=$max ") if $DEBUG & 1;

    # Hunks from the start or end of the file have less context.  Anchor
    # them to the start or end, trying to make up for this disadvantage.
    my $offset = pch_suffix_context() - pch_prefix_context();
    if ($offset > 0 && pch_first() <= 1) {
        $max_pos_offset = 0;
    }
    $match_until_eof = $offset < 0 ? 1 : 0;

    # Do not try lines <= 0.
    if ($first_guess <= $max_neg_offset) {
        $max_neg_offset = $first_guess - 1;
    }

    for ($offset = 0; $offset <= $max_offset; $offset++) {
        if ($offset <= $max_pos_offset) {
            my $guess = $first_guess + $offset;
            my $last;
            my $changes = bestmatch(1, $pat_lines + 1, $guess,
                                    $INPUT_LINES + 1,
                                    $match_until_eof
                                        ? $INPUT_LINES - $guess + 1 : $min,
                                    $max, \$last);
            if ($changes <= $max && $max_matched < $last - $guess) {
                $max_matched = $last - $guess;
                $where = $guess;
                if ($changes == 0) { last }
                $min = $last - $guess;
                $max = $changes - 1;
            }
        }
        if (0 < $offset && $offset <= $max_neg_offset) {
            my $guess = $first_guess - $offset;
            my $last;
            my $changes = bestmatch(1, $pat_lines + 1, $guess,
                                    $INPUT_LINES + 1,
                                    $match_until_eof
                                        ? $INPUT_LINES - $guess + 1 : $min,
                                    $max, \$last);
            if ($changes <= $max && $max_matched < $last - $guess) {
                $max_matched = $last - $guess;
                $where = $guess;
                if ($changes == 0) { last }
                $min = $last - $guess;
                $max = $changes - 1;
            }
        }
    }
    if ($DEBUG & 1) {
        say("where=$where matched=$max_matched changes=", $max + 1, "\n");
    }

    $$matched_ref = $max_matched;
    $where = $min_where if $where < $min_where;
    return $where;
}

sub count_context_lines {
    my $lastold = pch_ptrn_lines();
    my $context = 0;
    for (my $old = 1; $old <= $lastold; $old++) {
        $context++ if $P_CHAR[$old] eq ' ';
    }
    return $context;
}

sub main {
    my $somefailed = 0;
    my $skip_reject_file = 0;
    my $apply_empty_patch = 0;
    my $file_type = 0;
    my $have_git_diff = 0;
    my %tmpoutst = (size => -1);

    my $val = $ENV{QUOTING_STYLE};
    if (defined $val) {
        my $i = argmatch($val, \@QUOTING_STYLE_ARGS);
        set_quoting_style($i < 0 ? 'shell' : $QUOTING_STYLE_ARGS[$i]);
    }

    $POSIXLY_CORRECT = defined $ENV{POSIXLY_CORRECT};
    my $env_patch_get = $ENV{PATCH_GET};
    $PATCH_GET = defined $env_patch_get
        ? numeric_string($env_patch_get, 1, 'PATCH_GET value') : 0;

    my $env_suffix = $ENV{SIMPLE_BACKUP_SUFFIX};
    $SIMPLE_BACKUP_SUFFIX = (defined $env_suffix && $env_suffix ne '')
        ? $env_suffix : '.orig';

    if (defined($VERSION_CONTROL = $ENV{PATCH_VERSION_CONTROL})) {
        $VERSION_CONTROL_CONTEXT = '$PATCH_VERSION_CONTROL';
    }
    elsif (defined($VERSION_CONTROL = $ENV{VERSION_CONTROL})) {
        $VERSION_CONTROL_CONTEXT = '$VERSION_CONTROL';
    }

    # Parse switches and file names.
    get_some_switches(@ARGV);

    # Make time conversion assume that context diff headers use UTC.
    $ENV{TZ} = 'UTC0' if $SET_UTC;

    $BACKUP_IF_MISMATCH = !$POSIXLY_CORRECT
        unless $BACKUP_IF_MISMATCH_SPECIFIED;
    $BACKUP_TYPE = get_version($VERSION_CONTROL_CONTEXT, $VERSION_CONTROL)
        if $MAKE_BACKUPS || $BACKUP_IF_MISMATCH;

    init_output();
    if ($OUTFILE) {
        $OUTFP = open_outfile($OUTFILE);
    }

    # When the file to patch is specified on the command line, allow that
    # file to lie outside the current working tree.
    $UNSAFE = 1 if $INNAME;

    if ($INNAME && $OUTFILE) {
        # When an input and an output filename is given and the patch is
        # empty, copy the input file to the output file.
        $apply_empty_patch = 1;
        $file_type = 0100000;
        $INERRNO = -1;
    }
    open_patch_file($PATCHNAME);
    while (there_is_another_patch(!($INNAME || $POSIXLY_CORRECT),
                                  \$file_type)
           || $apply_empty_patch) {
        my ($hunk, $failed, $mismatch, $outname) = (0, 0, 0, undef);

        if ($SKIP_REST_OF_PATCH) {
            $somefailed = 1;
        }

        if ($have_git_diff != pch_git_diff()) {
            if ($have_git_diff) {
                output_files(undef, 0);
                $INERRNO = -1;
            }
            $have_git_diff = !$have_git_diff;
        }

        if (defined $REJFP) {
            close $REJFP or write_fatal();
            $REJFP = undef;
            $TEMP_REJ_EXISTS = 0;
        }

        if (!$SKIP_REST_OF_PATCH && !$file_type) {
            my $old_mode = pch_mode($REVERSE_FLAG) & 0170000;
            my $new_mode = pch_mode(!$REVERSE_FLAG) & 0170000;
            say('File ', quotearg($INNAME),
                sprintf(": can't change file type from %#o to %#o.\n",
                        $old_mode, $new_mode));
            $SKIP_REST_OF_PATCH = 1;
            $somefailed = 1;
        }

        if (!$SKIP_REST_OF_PATCH) {
            $OUTNAME_IS_INNAME = 0;
            if ($OUTFILE) {
                $outname = $OUTFILE;
            }
            elsif (pch_copy() || pch_rename()) {
                $outname = pch_name(!$REVERSE_FLAG);
            }
            else {
                $outname = $INNAME;
                $OUTNAME_IS_INNAME = 1;
            }
        }

        if (pch_git_diff() && !$SKIP_REST_OF_PATCH) {
            # Try to recognize concatenated git diffs based on the SHA1
            # hashes in the headers.
            my $outstat = {};
            my $outerrno;
            if ($OUTNAME_IS_INNAME) {
                if ($INERRNO == -1) {
                    $INERRNO = stat_file($INNAME, \%INSTAT);
                }
                %$outstat = %INSTAT;
                $outerrno = $INERRNO;
            }
            else {
                $outerrno = stat_file($outname, $outstat);
            }

            if (!$outerrno) {
                if (has_queued_output($outstat)) {
                    output_files($outstat, 0);
                    $outerrno = stat_file($outname, $outstat);
                    $INERRNO = -1;
                }
                if (!$outerrno) {
                    set_queued_output($outstat, 1);
                }
            }
        }

        if (!$SKIP_REST_OF_PATCH) {
            if (!get_input_file($INNAME, $outname, $file_type)) {
                $SKIP_REST_OF_PATCH = 1;
                $somefailed = 1;
            }
        }

        if ($READ_ONLY_BEHAVIOR ne 'ignore'
            && !$INERRNO
            && ($INSTAT{mode} & 0170000) != 0120000
            && !-w $INNAME) {
            say('File ', quotearg($INNAME), ' is read-only; ');
            if ($READ_ONLY_BEHAVIOR eq 'warn') {
                say("trying to patch anyway\n");
            }
            else {
                say("refusing to patch\n");
                $SKIP_REST_OF_PATCH = 1;
                $somefailed = 1;
            }
        }

        $tmpoutst{size} = -1;
        my $tmpout;
        my $tmpoutfh;
        ($tmpout, $tmpoutfh) = make_tempfile('o', $outname, 1,
                                             ($INSTAT{mode} // 0) & 0777);
        if (!defined $tmpout) {
            my $errno = $! + 0;
            if ($DIFF_TYPE == ED_DIFF || !($errno == 40 || $errno == 18)) {
                pfatal("Can't create temporary file %s",
                       quotearg($TEMP_ATTEMPT_NAME));
            }
            say('Invalid file name ', quotearg($outname),
                " -- skipping patch\n");
            $SKIP_REST_OF_PATCH = 1;
            $skip_reject_file = 1;
            $somefailed = 1;
        }
        else {
            push @TEMP_FILES, $tmpout;
        }
        if (!$OUTFILE) {
            init_output();
        }
        my $ifh;

        if ($DIFF_TYPE == ED_DIFF) {
            $OUT_ZERO_OUTPUT = 0;
            $somefailed = 1 if $SKIP_REST_OF_PATCH;
            do_ed_script($INNAME, $tmpout, $OUTFP);
            if (!$DRY_RUN && !$OUTFILE && !$SKIP_REST_OF_PATCH) {
                my @st = stat $tmpout;
                pfatal('%s', $tmpout) unless @st;
                $tmpoutst{size} = $st[7];
                $OUT_ZERO_OUTPUT = $st[7] == 0 ? 1 : 0;
            }
        }
        else {
            my $apply_anyway = $MERGE;   # don't try to reverse when merging

            if (!$SKIP_REST_OF_PATCH && $DIFF_TYPE == GIT_BINARY_DIFF) {
                say('File ', quotearg($outname),
                    ": git binary diffs are not supported.\n");
                $SKIP_REST_OF_PATCH = 1;
                $somefailed = 1;
            }
            # Initialize the patched file.
            if (!$SKIP_REST_OF_PATCH && !$OUTFILE) {
                $OUTFP = $tmpoutfh;
                $OUTFP->autoflush(1);
                # $OUTFP now owns the temporary file.
            }
            else {
                # When writing to a single output file (-o FILE), always
                # pretend that the output file ends in a newline.
                $OUT_AFTER_NEWLINE = 1;
            }

            # Find out where all the lines are.
            if (!$SKIP_REST_OF_PATCH) {
                if (($file_type & 0170000) == 0100000 && $INSTAT{size} != 0) {
                    open $ifh, '<:raw', $INNAME
                        or pfatal("Can't open file %s", quotearg($INNAME));
                }

                scan_input($INNAME, $file_type, $ifh);

                if ($VERBOSITY != SILENT) {
                    my $renamed = ($INNAME // '') ne ($outname // '');
                    my $skip_rename = !$renamed && pch_rename();
                    say(($DRY_RUN ? 'checking' : 'patching'), ' ',
                        ($file_type & 0170000) == 0120000
                            ? 'symbolic link' : 'file',
                        ' ', quotearg($outname),
                        $renamed || $skip_rename ? ' ' : "\n");
                    if ($renamed || $skip_rename) {
                        say('(', $skip_rename ? 'already ' : '',
                            pch_copy() ? 'copied'
                            : pch_rename() ? 'renamed' : 'read',
                            ' from ',
                            !$skip_rename ? $INNAME
                            : pch_name($INNAME eq (pch_name(OLD) // "\1")),
                            ")\n");
                    }
                }
            }

            # Apply each hunk of patch.
            while (another_hunk($DIFF_TYPE, $REVERSE_FLAG)) {
                my ($where, $fuzz) = (0, 0);
                my $mymaxfuzz;

                if ($MERGE) {
                    # When in merge mode, don't apply with fuzz.
                    $mymaxfuzz = 0;
                }
                else {
                    my $prefix_context = pch_prefix_context();
                    my $suffix_context = pch_suffix_context();
                    my $context = $prefix_context > $suffix_context
                        ? $prefix_context : $suffix_context;
                    $mymaxfuzz = $MAXFUZZ < $context ? $MAXFUZZ : $context;
                }

                $hunk++;
                if (!$SKIP_REST_OF_PATCH) {
                    my $incr_fuzz;
                    do {
                        $incr_fuzz = 1;
                        $where = locate_hunk($fuzz);
                        if (!$where || $fuzz || $IN_OFFSET) {
                            $mismatch = 1;
                        }
                        if ($hunk == 1 && !$where && !($FORCE || $apply_anyway)
                            && $REVERSE_FLAG == $REVERSE_FLAG_SPECIFIED) {
                            # DWIM for a reversed patch?
                            pch_swap();
                            # Try again.
                            $where = locate_hunk($fuzz);
                            if ($where
                                && ok_to_reverse(($REVERSE_FLAG
                                                  ? 'Unreversed'
                                                  : 'Reversed (or previously applied)')
                                                 . ' patch detected!')) {
                                $REVERSE_FLAG = !$REVERSE_FLAG;
                            }
                            else {
                                # Put it back to normal.
                                pch_swap();
                                if ($where) {
                                    $apply_anyway = 1;
                                    $incr_fuzz = 0;
                                    $where = 0;
                                }
                            }
                        }
                    }
                    while (!$SKIP_REST_OF_PATCH && !$where
                           && ($fuzz += $incr_fuzz) <= $mymaxfuzz);
                }

                my $newwhere = ($where ? $where : pch_first()) + $OUT_OFFSET;
                if ($SKIP_REST_OF_PATCH
                    || ($MERGE && !merge_hunk($hunk, $where, \$somefailed))
                    || (!$MERGE
                        && (($where == 1
                             && pch_says_nonexistent($REVERSE_FLAG) == 2
                             && $INSTAT{size})
                            || !$where
                            || !apply_hunk($where)))) {
                    abort_hunk($outname, !$failed, $REVERSE_FLAG)
                        unless $skip_reject_file;
                    $failed++;
                    if ($VERBOSITY == VERBOSE
                        || (!$SKIP_REST_OF_PATCH && $VERBOSITY != SILENT)) {
                        say(sprintf("Hunk #%d %s at %d%s.\n", $hunk,
                                    $SKIP_REST_OF_PATCH ? 'ignored' : 'FAILED',
                                    $newwhere,
                                    !$SKIP_REST_OF_PATCH
                                    && check_line_endings($newwhere)
                                        ? ' (different line endings)' : ''));
                    }
                }
                elsif (!$MERGE
                       && ($VERBOSITY == VERBOSE
                           || ($VERBOSITY != SILENT && ($fuzz || $IN_OFFSET)))) {
                    say(sprintf("Hunk #%d succeeded at %d", $hunk, $newwhere));
                    if ($fuzz) {
                        say(" with fuzz $fuzz");
                    }
                    if ($IN_OFFSET) {
                        say(sprintf(' (offset %d line%s)', $IN_OFFSET,
                                    $IN_OFFSET == 1 ? '' : 's'));
                    }
                    say(".\n");
                }
            }

            if (!$SKIP_REST_OF_PATCH) {
                # Finish spewing out the new file.
                if (!spew_output()) {
                    say("Skipping patch.\n");
                    $SKIP_REST_OF_PATCH = 1;
                }
                elsif (!$OUTFILE) {
                    my @st = stat $tmpout;
                    pfatal('%s', $tmpout) unless @st;
                    %tmpoutst = (size => $st[7], mode => $st[2],
                                 dev => $st[0], ino => $st[1]);
                }
            }
        }

        # Put the output where desired.
        my ($replace_file, $backup, $mode);
        if (!$SKIP_REST_OF_PATCH && !$OUTFILE) {
            $backup = $MAKE_BACKUPS
                || ($BACKUP_IF_MISMATCH && ($mismatch || $failed));
            if ($OUT_ZERO_OUTPUT
                && ($REMOVE_EMPTY_FILES
                    || (pch_says_nonexistent(!$REVERSE_FLAG) == 2
                        && !$POSIXLY_CORRECT)
                    || ($file_type & 0170000) == 0120000)) {
                if (!$DRY_RUN) {
                    output_file(undef, undef, $outname,
                                $OUTNAME_IS_INNAME ? \%INSTAT : undef,
                                $file_type | 0, $backup);
                }
            }
            else {
                if (!$OUT_ZERO_OUTPUT
                    && pch_says_nonexistent(!$REVERSE_FLAG) == 2
                    && ($REMOVE_EMPTY_FILES || !$POSIXLY_CORRECT)
                    && !($MERGE && $somefailed)) {
                    $mismatch = 1;
                    $somefailed = 1;
                    say('Not deleting file ', quotearg($outname),
                        " as content differs from patch\n")
                        if $VERBOSITY != SILENT;
                }

                if (!$DRY_RUN) {
                    my $old_mode = pch_mode($REVERSE_FLAG);
                    my $new_mode = pch_mode(!$REVERSE_FLAG);
                    my $set_mode = $new_mode && $old_mode != $new_mode;

                    # Avoid replacing files when nothing has changed.
                    if ($failed < $hunk || $DIFF_TYPE == ED_DIFF || $set_mode
                        || pch_copy() || pch_rename()) {
                        my $attr = '';
                        my $new_time = $P_TIMESTAMP[!$REVERSE_FLAG];

                        if (($SET_TIME || $SET_UTC) && $new_time->[1] >= 0) {
                            my $old_time = $P_TIMESTAMP[$REVERSE_FLAG];
                            if (!$FORCE && !$INERRNO
                                && pch_says_nonexistent($REVERSE_FLAG) != 2
                                && $old_time->[1] >= 0
                                && ($old_time->[0] != $INSTAT{mtime}
                                    || $old_time->[1] != $INSTAT{mtime_nsec})) {
                                say('Not setting time of file ',
                                    quotearg($outname),
                                    " (time mismatch)\n");
                            }
                            elsif (!$FORCE && ($mismatch || $failed)) {
                                say('Not setting time of file ',
                                    quotearg($outname),
                                    " (contents mismatch)\n");
                            }
                            else {
                                $attr .= 'times';
                            }
                        }

                        $mode = $file_type
                            | (($set_mode ? $new_mode : $INSTAT{mode}) & 0777);
                        if ($INERRNO) {
                            $attr .= '+mode' if $set_mode;
                            $attr =~ s/^\+//;
                            set_file_attributes($tmpout, $attr, undef, undef,
                                                $mode,
                                                $new_time->[1] >= 0
                                                    ? $new_time : undef);
                        }
                        else {
                            $attr = ($attr ? "$attr+" : '') . 'ids+mode';
                            set_file_attributes($tmpout, $attr, $INNAME,
                                                \%INSTAT, $mode,
                                                $new_time->[1] >= 0
                                                    ? $new_time : undef);
                        }

                        $replace_file = 1;
                    }
                    elsif ($backup) {
                        my $outstat = {};
                        if (stat_file($outname, $outstat)) {
                            say("Cannot stat file $outname, skipping backup\n");
                        }
                        else {
                            output_file($outname, $outstat, undef, undef,
                                        $file_type | 0, 1);
                        }
                    }
                }
            }
        }

        if (defined $ifh) {
            close $ifh or read_fatal();
        }

        if (!$OUTFILE && defined $OUTFP) {
            close $OUTFP or write_fatal();
            $OUTFP = undef;
        }

        if ($replace_file) {
            output_file($tmpout, \%tmpoutst, $outname, undef, $mode, $backup);
            if (pch_rename()) {
                output_file(undef, undef, $INNAME, \%INSTAT, $mode, $backup);
            }
        }

        if ($DIFF_TYPE != ED_DIFF) {
            if ($failed && !$skip_reject_file) {
                $somefailed = 1;
                close $REJFP or write_fatal() if defined $REJFP;
                $REJFP = undef;
                $TEMP_REJ_EXISTS = 0;
                say(sprintf('%d out of %d hunk%s %s', $failed, $hunk,
                            $hunk == 1 ? '' : 's',
                            $SKIP_REST_OF_PATCH ? 'ignored' : 'FAILED'));
                my $rejname = $OUTREJ_NAME;
                if (defined $outname && (!defined $rejname || $rejname ne '-')) {
                    my $rej = $rejname;
                    if (!defined $rejname) {
                        my $saved_suffix = $SIMPLE_BACKUP_SUFFIX;
                        $SIMPLE_BACKUP_SUFFIX = '.rej';
                        $rej = find_backup_file_name($outname, 'simple');
                        $SIMPLE_BACKUP_SUFFIX = $saved_suffix;
                        my $last = substr($rej, -1, 1);
                        if ($last eq '~') {
                            substr($rej, -1, 1) = '#';
                        }
                    }
                    if (!$DRY_RUN) {
                        say(' -- saving rejects to file ', quotearg($rej), "\n");
                        my $rejst = {};
                        stat_file($TEMP_REJ_NAME, $rejst);
                        if (defined $rejname) {
                            if (!$OUTREJ_EXISTS) {
                                copy_file($TEMP_REJ_NAME, $rejst,
                                          { name => $rejname }, 0,
                                          0100000 | 0666, '', 1);
                                $OUTREJ_EXISTS = 1;
                            }
                            else {
                                open my $src, '<:raw', $TEMP_REJ_NAME
                                    or pfatal("Can't reopen file %s",
                                              quotearg($TEMP_REJ_NAME));
                                open my $dst, '>>:raw', $rejname
                                    or pfatal("Can't reopen file %s",
                                              quotearg($rejname));
                                while (1) {
                                    my $got = sysread($src, my $chunk, 65536);
                                    read_fatal() unless defined $got;
                                    last unless $got;
                                    print $dst $chunk or write_fatal();
                                }
                                close $src;
                                close $dst or write_fatal();
                            }
                        }
                        else {
                            my $oldst = {};
                            my $olderrno = stat_file($rej, $oldst);
                            write_fatal() if $olderrno && $olderrno != 2;
                            if (!$olderrno && lookup_file_id($oldst) == FILE_ID_CREATED) {
                                open my $src, '<:raw', $TEMP_REJ_NAME
                                    or pfatal("Can't reopen file %s",
                                              quotearg($TEMP_REJ_NAME));
                                open my $dst, '>>:raw', $rej
                                    or pfatal("Can't reopen file %s",
                                              quotearg($rej));
                                while (1) {
                                    my $got = sysread($src, my $chunk, 65536);
                                    read_fatal() unless defined $got;
                                    last unless $got;
                                    print $dst $chunk or write_fatal();
                                }
                                close $src;
                                close $dst or write_fatal();
                            }
                            else {
                                move_file($TEMP_REJ_NAME, $rejst, $rej,
                                          0100000 | 0666, 0);
                            }
                        }
                    }
                    else {
                        say("\n");
                    }
                }
                else {
                    say("\n");
                }
            }
        }

        # Prepare for the next patch.
        re_patch();
        @I_LINES = ();
        $INPUT_LINES = 0;
        $LAST_FROZEN_LINE = 0;
        if ($INNAME && !$EXPLICIT_INNAME) {
            undef $INNAME;
        }
        $IN_OFFSET = 0;
        $OUT_OFFSET = 0;
        $DIFF_TYPE = NO_DIFF;
        undef $REVISION;
        $REVERSE_FLAG = $REVERSE_FLAG_SPECIFIED;
        $SKIP_REST_OF_PATCH = 0;
        $skip_reject_file = 0;
        $apply_empty_patch = 0;
        $TEMP_REJ_EXISTS = 0;
    }
    if (defined $OUTFP) {
        close $OUTFP or write_fatal();
        $OUTFP = undef;
    }

    remove_temporary_files();
    output_files(undef, 1);
    delete_files();
    return $somefailed ? EXIT_FAILURE : EXIT_SUCCESS;
}

exit main();
