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
my $patch_b = <<'PATCH';
--- b
+++ b
@@ -1 +1 @@
-old-b
+new-b
PATCH
my $malformed_hunk = <<'PATCH';
--- b
+++ b
@@ -x +x @@
-old-b
+new-b
PATCH

return [
    {
        name => 'workflow.partial-reject-backup',
        args => ['-b', '-p0'], reference_exit => 1,
        stdin => $first . $reject,
        files => { a => "old-a\n", b => "old-b\n" },
        expected_files => { a => "new-a\n", b => "old-b\n", 'a.orig' => "old-a\n" },
    },
    {
        name => 'workflow.earlier-output-before-malformed-patch',
        args => ['-p0'], reference_exit => 2,
        stdin => $first . $malformed_hunk,
        files => { a => "old-a\n", b => "old-b\n" },
        expected_files => { a => "new-a\n", b => "old-b\n" },
    },
    {
        name => 'workflow.repeat-same-file-backup',
        args => ['-b', '-p0'], reference_exit => 0,
        stdin => $first . $second,
        files => { a => "old-a\n" },
        expected_files => { a => "newer-a\n", 'a.orig' => "old-a\n" },
    },
    {
        name => 'workflow.dry-run-two-files',
        args => ['--dry-run', '-p0'], reference_exit => 0,
        stdin => $first . $patch_b,
        files => { a => "old-a\n", b => "old-b\n" },
        expected_files => { a => "old-a\n", b => "old-b\n" },
    },
    {
        name => 'workflow.output-and-reject-files',
        args => ['-p0', '-o', 'combined.out', '-r', 'combined.rej'],
        reference_exit => 1,
        stdin => $first . $reject,
        files => { a => "old-a\n", b => "old-b\n" },
        expected_files => {
            a => "old-a\n", b => "old-b\n",
            'combined.out' => "new-a\nold-b\n",
            'combined.rej' => "--- b\n+++ b\n@@ -1 +1 @@\n-missing-b\n+new-b\n",
        },
    },
];
