# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

my $first = <<'PATCH';
--- a
+++ a
@@ -1 +1 @@
-old-a
+new-a
PATCH
my $reject = <<'PATCH';
--- b
+++ b
@@ -1 +1 @@
-missing-b
+new-b
PATCH
my $second = <<'PATCH';
--- a
+++ a
@@ -1 +1 @@
-new-a
+newer-a
PATCH

return [
    {
        name => 'workflow.partial-reject-backup',
        args => ['-b', '-p0'], reference_exit => 1,
        stdin => $first . $reject,
        files => { a => "old-a\n", b => "old-b\n" },
    },
    {
        name => 'workflow.earlier-output-before-malformed-patch',
        args => ['-p0'], reference_exit => 0,
        stdin => $first . "not a patch\n",
        files => { a => "old-a\n" },
    },
    {
        name => 'workflow.repeat-same-file-backup',
        args => ['-b', '-p0'], reference_exit => 0,
        stdin => $first . $second,
        files => { a => "old-a\n" },
    },
    {
        name => 'workflow.dry-run-multiple-files',
        args => ['--dry-run', '-p0'], reference_exit => 0,
        stdin => $first . $first,
        files => { a => "old-a\n" },
    },
    {
        name => 'workflow.output-and-reject-files',
        args => ['-p0', '-o', 'combined.out', '-r', 'combined.rej'],
        reference_exit => 1,
        stdin => $first . $reject,
        files => { a => "old-a\n", b => "old-b\n" },
    },
];
