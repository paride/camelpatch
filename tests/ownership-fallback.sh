#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/camel-patch-ownership.$$
mkdir "$tmp"
trap 'sudo -n chmod -R u+rwx "$tmp" 2>/dev/null || :; sudo -n rm -rf "$tmp" 2>/dev/null || rm -rf "$tmp"' 0 HUP INT TERM

if ! command -v setpriv >/dev/null || ! sudo -n true 2>/dev/null; then
    printf '%s\n' 'This regression requires setpriv and passwordless sudo.' >&2
    exit 77
fi
sudo -n chown root:1000 "$tmp"
sudo -n chmod 2777 "$tmp"

cat > "$tmp/change.diff" <<'PATCH'
--- f
+++ f
@@ -1 +1 @@
-old
+new
PATCH
cp "$root/patch.pl" "$tmp/patch.pl"
chmod 0644 "$tmp/patch.pl"

for target in reference camel; do
    mkdir "$tmp/$target"
    printf 'old\n' > "$tmp/$target/f"
    chmod 0664 "$tmp/$target/f"
    sudo -n chown root:1000 "$tmp/$target"
    sudo -n chmod 2777 "$tmp/$target"
    sudo -n chown 1001:113 "$tmp/$target/f"
    cp "$tmp/change.diff" "$tmp/$target/change.diff"
done

(cd "$tmp/reference" && sudo -n setpriv --reuid=65534 --regid=65534 --groups=113 \
    /bin/sh -c 'exec /usr/bin/patch -p0 < "$1"' sh "$tmp/reference/change.diff")
(cd "$tmp/camel" && sudo -n setpriv --reuid=65534 --regid=65534 --groups=113 \
    /bin/sh -c 'exec /usr/bin/perl "$1" -p0 < "$2"' sh \
    "$tmp/patch.pl" "$tmp/camel/change.diff")

for target in reference camel; do
    owner=$(stat -c '%u:%g' "$tmp/$target/f")
    if [ "$owner" != '65534:113' ]; then
        printf '%s ownership was %s\n' "$target" "$owner" >&2
        exit 1
    fi
    if [ "$(cat "$tmp/$target/f")" != new ]; then
        printf '%s produced incorrect contents\n' "$target" >&2
        exit 1
    fi
done

cmp "$tmp/reference/f" "$tmp/camel/f"
