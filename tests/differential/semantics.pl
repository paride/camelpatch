# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

my $hunk = <<'PATCH';
--- f
+++ f
@@ -1 +1 @@
-old
+new
PATCH

my @cases;
for my $spec (
    [ 'prereq-found', "revision-1\n", "revision-1\nold\n", [], 0 ],
    [ 'prereq-missing-batch', "revision-1\n", "different\nold\n", ['-t'], 2 ],
    [ 'prereq-missing-force', "revision-1\n", "different\nold\n", ['-f'], 0 ],
    [ 'prereq-word-boundary', "revision-1\n", "xrevision-1x\nold\n", ['-t'], 2 ],
) {
    my ($name, $prereq, $content, $options, $expected) = @$spec;
    push @cases, {
        name => "prereq.$name", args => [@$options, '-p0'],
        stdin => "Prereq: $prereq" . $hunk,
        files => { f => $content }, reference_exit => $expected,
    };
}
push @cases, {
    name => 'prereq.missing-interactive-yes', args => ['-p0'],
    stdin => "Prereq: revision-1\n" . $hunk,
    tty_input => "y\n", files => { f => "different\nold\n" },
    reference_exit => 0,
};
push @cases, {
    name => 'prereq.missing-interactive-no', args => ['-p0'],
    stdin => "Prereq: revision-1\n" . $hunk,
    tty_input => "n\n", files => { f => "different\nold\n" },
    reference_exit => 2,
};
push @cases, {
    name => 'prereq.missing-interactive-eof', args => ['-p0'],
    stdin => "Prereq: revision-1\n" . $hunk,
    tty_input => "\x04", files => { f => "different\nold\n" },
    reference_exit => 2,
};

my $define_patch = <<'PATCH';
--- f
+++ f
@@ -1,3 +1,3 @@
 before
-old
+new
 after
PATCH
for my $spec (
    [ 'change', "before\nold\nafter\n", $define_patch ],
    [ 'insert', "before\nafter\n", <<'PATCH' ],
--- f
+++ f
@@ -1,2 +1,3 @@
 before
+added
 after
PATCH
    [ 'delete', "before\nremove\nafter\n", <<'PATCH' ],
--- f
+++ f
@@ -1,3 +1,2 @@
 before
-remove
 after
PATCH
) {
    my ($name, $content, $patch) = @$spec;
    push @cases, {
        name => "define.$name", args => ['-D', 'COND', '-p0'],
        stdin => $patch, files => { f => $content }, reference_exit => 0,
    };
}

for my $spec (
    [ 'address-boundary', "one\ntwo\n", "1c\nchanged\n.\n" ],
    [ 'delete-last-line', "one\ntwo\n", "2d\n" ],
    [ 'literal-dot', "one\ntwo\n", "1c\n.\n.\n" ],
    [ 'invalid-range', "one\ntwo\n", "3d\n", 2 ],
    [ 'truncated-text', "one\ntwo\n", "1a\nadded\n", 2 ],
) {
    my ($name, $content, $script, $expected) = @$spec;
    push @cases, {
        name => "ed.$name", args => ['-e', '-p0'],
        stdin => "--- f\n+++ f\n$script", files => { f => $content },
        (defined $expected ? (reference_exit => $expected) : ()),
    };
}

push @cases, {
    name => 'prompt.reverse-yes', args => ['-p0'],
    stdin => $hunk, tty_input => "y\n", files => { f => "new\n" },
    reference_exit => 0,
};
push @cases, {
    name => 'prompt.reverse-no-apply-yes', args => ['-p0'],
    stdin => $hunk, tty_input => "n\ny\n", files => { f => "one\n" },
    reference_exit => 1,
};

return \@cases;
