# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

use Time::Local qw(timegm);

my $old_time = timegm(5, 4, 3, 2, 0, 120) + 0.125;
my $patch = <<'PATCH';
--- a/f	2020-01-02 03:04:05.125000 +0000
+++ b/f	2020-01-03 04:05:06.750000 +0000
@@ -1 +1 @@
-old
+new
PATCH

my @cases;
for my $spec (
    [ 'set-time-matching-fractional', ['-T', '-p1'], $old_time, 1 ],
    [ 'set-time-mismatch', ['-T', '-p1'], $old_time + 1, 0 ],
    [ 'set-time-force-overrides-mismatch', ['-T', '-f', '-p1'], $old_time + 1, 1 ],
) {
    push @cases, {
        name => "metadata.$spec->[0]", args => $spec->[1], reference_exit => 0,
        files => { f => { content => "old\n", mtime => $spec->[2] } },
        stdin => $patch,
        compare_mtime => $spec->[3] ? ['f'] : [],
        compare_mtime_nsec => $spec->[3] ? ['f'] : [],
    };
}

return \@cases;
