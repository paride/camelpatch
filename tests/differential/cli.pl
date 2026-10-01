# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

my $patch = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-one\n+two\n";
my @cases;
for my $spec (
    [ 'short-clusters', ['-sfp1'], 0 ],
    [ 'cluster-attached-input', ['-sfiinput.diff', '-p1'], 0 ],
    [ 'long-abbreviation', ['--str=1', '--inp=input.diff'], 0 ],
    [ 'long-separate-argument', ['--strip', '1', '--input', 'input.diff'], 0 ],
    [ 'operand-permutation', ['f', '-s', '-p1'], 0 ],
    [ 'operand-permutation-two', ['f', '-p1', 'input.diff', '-s'], 0 ],
    [ 'permuted-separate-argument', ['f', '-p', '1', 'input.diff', '-s'], 0 ],
    [ 'permuted-input-argument', ['f', '-i', 'input.diff', '-p1'], 0 ],
    [ 'cluster-separate-argument', ['-sfp', '1'], 0 ],
    [ 'posix-option-keeps-permutation', ['--posix', 'f', '-p1'], 0 ],
    [ 'end-of-options', ['-p1', '--', 'f', 'input.diff'], 0 ],
    [ 'optional-merge-attached', ['--merge=diff3', '-p1', '-f'], 0 ],
    [ 'optional-merge-unattached', ['--merge', '-p1', '-f'], 0 ],
    [ 'unknown-short', ['-Q'], 2 ],
    [ 'unknown-long', ['--no-such-option'], 2 ],
    [ 'ambiguous-long', ['--re'], 2 ],
    [ 'missing-short-argument', ['-p'], 2 ],
    [ 'missing-long-argument', ['--strip'], 2 ],
    [ 'abbreviated-missing-argument', ['--str'], 2 ],
    [ 'unexpected-long-argument', ['--quiet=yes'], 2 ],
    [ 'extra-operand', ['f', 'input.diff', 'extra'], 2 ],
    [ 'negative-strip', ['-p-1'], 2 ],
    [ 'empty-strip', ['--strip='], 2 ],
    [ 'positive-strip', ['-p+1'], 0 ],
    [ 'numeric-overflow', ['--fuzz=999999999999999999999999', '-p1'], 0 ],
) {
    push @cases, {
        name => "cli.$spec->[0]", args => $spec->[1], reference_exit => $spec->[2],
        files => { f => "one\n", 'input.diff' => $patch }, stdin => $patch,
    };
}
push @cases, {
    name => 'cli.dash-filename', args => ['--', '-file'], reference_exit => 0,
    files => { '-file' => "one\n" }, stdin => "--- f\n+++ f\n@@ -1 +1 @@\n-one\n+two\n",
};
push @cases, {
    name => 'cli.directory-order', args => ['-d', 'sub', '-i', 'input.diff', '-p1'], reference_exit => 0,
    files => { 'sub/f' => "one\n", 'sub/input.diff' => $patch },
};
my $large_old = ('a' x 70000) . "\n";
my $large_new = ('b' x 70000) . "\n";
my $large_patch = "--- f\n+++ f\n@@ -1 +1 @@\n-$large_old+$large_new";
push @cases, {
    name => 'cli.large-patch-stdin', args => [], reference_exit => 0,
    files => { f => $large_old }, stdin => $large_patch,
};
push @cases, {
    name => 'cli.large-patch-file', args => ['-i', 'input.diff'], reference_exit => 0,
    files => { f => $large_old, 'input.diff' => $large_patch }, stdin => '',
};
return \@cases;
