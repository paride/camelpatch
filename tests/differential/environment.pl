# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

my $patch = "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-one\n+two\n";
my @cases;
for my $spec (
    [ 'suffix-default', {}, ['-b', '-p1'], 0 ],
    [ 'suffix-custom', { SIMPLE_BACKUP_SUFFIX => '.saved' }, ['-b', '-p1'], 0 ],
    [ 'suffix-empty', { SIMPLE_BACKUP_SUFFIX => '' }, ['-b', '-p1'], 0 ],
    [ 'suffix-option-precedence', { SIMPLE_BACKUP_SUFFIX => '.saved' }, ['-b', '-z.old', '-p1'], 0 ],
    [ 'numbered-backup', { PATCH_VERSION_CONTROL => 'numbered' }, ['-b', '-p1'], 0 ],
    [ 'version-control-fallback', { VERSION_CONTROL => 'numbered' }, ['-b', '-p1'], 0 ],
    [ 'version-control-precedence', { PATCH_VERSION_CONTROL => 'simple', VERSION_CONTROL => 'numbered' }, ['-b', '-p1'], 0 ],
    [ 'version-control-option-precedence', { PATCH_VERSION_CONTROL => 'numbered' }, ['-b', '-Vsimple', '-p1'], 0 ],
    [ 'version-control-abbreviation', { PATCH_VERSION_CONTROL => 'simp' }, ['-b', '-p1'], 0 ],
    [ 'version-control-invalid', { PATCH_VERSION_CONTROL => 'invalid' }, ['-b', '-p1'], 2 ],
    [ 'version-control-empty-precedence', { PATCH_VERSION_CONTROL => '', VERSION_CONTROL => 'numbered' }, ['-b', '-p1'], 0 ],
    [ 'version-control-zero-precedence', { PATCH_VERSION_CONTROL => '0', VERSION_CONTROL => 'numbered' }, ['-b', '-p1'], 2 ],
    [ 'get-zero', { PATCH_GET => '0' }, ['-p1'], 0 ],
    [ 'get-invalid', { PATCH_GET => 'bad' }, ['-p1'], 2 ],
    [ 'get-empty', { PATCH_GET => '' }, ['-p1'], 2 ],
    [ 'posix-empty-stops-permutation', { POSIXLY_CORRECT => '' }, ['f', '-p1'], 2 ],
) {
    push @cases, {
        name => "environment.$spec->[0]", env => $spec->[1], args => $spec->[2], reference_exit => $spec->[3],
        files => { f => "one\n" }, stdin => $patch,
    };
}
for my $style (qw(literal shell shell-always c escape)) {
    push @cases, {
        name => "environment.quoting-$style", env => { QUOTING_STYLE => $style },
        args => ['-p0'], reference_exit => 0, files => { 'a b' => "one\n" },
        stdin => "--- \"a b\"\n+++ \"a b\"\n@@ -1 +1 @@\n-one\n+two\n",
    };
}
push @cases, {
    name => 'environment.quoting-invalid-fallback', env => { QUOTING_STYLE => 'invalid' },
    args => ['-p1'], reference_exit => 0, files => { f => "one\n" }, stdin => $patch,
};
push @cases, {
    name => 'environment.quoting-option-precedence', env => { QUOTING_STYLE => 'c' },
    args => ['--quoting-style=literal', '-p1'], reference_exit => 0,
    files => { f => "one\n" }, stdin => $patch,
};
return \@cases;
