#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/camel-patch-runner-timeout.$$
mkdir "$tmp"
trap 'rm -rf "$tmp"' 0 HUP INT TERM

cat > "$tmp/patch" <<'SH'
#!/bin/sh
if [ "${1-}" = "--version" ]; then
    printf 'GNU patch 2.8\n'
    exit 0
fi
trap 'exit 1' TERM
sleep 3
exit 1
SH
chmod +x "$tmp/patch"

set +e
perl "$root/tools/test.pl" --patch "$tmp/patch" \
    --test context-format --timeout 1 >"$tmp/output" 2>&1
status=$?
set -e

if [ "$status" -ne 1 ] || ! grep -F 'FAIL   context-format  (timed out)' "$tmp/output" >/dev/null; then
    cat "$tmp/output"
    exit 1
fi

if grep -F 'XFAIL  context-format' "$tmp/output" >/dev/null; then
    cat "$tmp/output"
    exit 1
fi
