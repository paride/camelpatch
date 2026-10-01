#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
actual=$(perl "$root/patch.pl" --version)
expected=$(printf '%s\n' \
    'Camel patch 2.8' \
    'Copyright: 2026 Canonical Ltd.' \
    '' \
    'License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>.' \
    'This is free software: you are free to change and redistribute it.' \
    'There is NO WARRANTY, to the extent permitted by law.')

if [ "$actual" != "$expected" ]; then
    printf '%s\n' 'Unexpected --version output:' "$actual" >&2
    exit 1
fi
