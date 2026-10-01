# SPDX-FileCopyrightText: 2026 Canonical Ltd
# SPDX-License-Identifier: GPL-3.0-or-later

use strict;
use warnings;

use Time::Local qw(timegm);

my $old_time = timegm(5, 4, 3, 2, 0, 120) + 0.123456;
my $patch = <<'PATCH';
--- a/f	2020-01-02 03:04:05.123456 +0000
+++ b/f	2020-01-03 04:05:06.654321 +0000
@@ -1 +1 @@
-old
+new
PATCH
my $matching_patch = $patch;
$matching_patch =~ s/03:04:05\.123456/03:04:05.125000/;
my $matching_time = timegm(5, 4, 3, 2, 0, 120) + 0.125;

my @cases;
for my $spec (
    [ 'set-time-matching-fractional', ['-T', '-p1'], $matching_time, $matching_patch, 1 ],
    [ 'set-time-decimal-fraction-rounding', ['-T', '-p1'], $old_time, $patch, 0 ],
    [ 'set-time-mismatch', ['-T', '-p1'], $old_time + 1, $patch, 0 ],
    [ 'set-time-force-overrides-mismatch', ['-T', '-f', '-p1'], $old_time + 1, $patch, 1 ],
    [ 'set-utc-force-fractional', ['-Z', '-f', '-p1'], $old_time + 1, $patch, 1 ],
) {
    push @cases, {
        name => "metadata.$spec->[0]", args => $spec->[1], reference_exit => 0,
        files => { f => { content => "old\n", mtime_sec => int($spec->[2]),
                         mtime_nsec => int(($spec->[2] - int($spec->[2])) * 1e9 + 0.5) } },
        stdin => $spec->[3],
        compare_mtime => $spec->[4] ? ['f'] : [],
        compare_mtime_nsec => $spec->[4] ? ['f'] : [],
    };
}

return \@cases;
