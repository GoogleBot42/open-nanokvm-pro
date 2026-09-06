#!/bin/sh
# Simulate a web-bundle redeploy on the device, for the cdp_swap.py test (#71).
# Run ON the device:  probe-marker.sh {v1|v2|restore|show}
#
# Edits ONLY the live tmpfs tree; /kvmapp stays pristine and is the restore
# source. Every edit ends with `touch -d @1`, because that is what a real
# deploy leaves behind: the bundle is copied out of the Nix store, whose
# mtimes are all 1970-01-01T00:00:01Z. Keeping that constant is the point --
# it is why an If-Modified-Since revalidation can return a stale 304.
set -e
LIVE=/dev/shm/kvmapp/server/web/index.html
GOLD=/kvmapp/server/web/index.html
MARK='<meta name="cache-probe" content='

case "${1:-show}" in
v1)
	cp "$GOLD" "$LIVE.new"
	sed -i "s|<title>|$MARK\"v1\" />\n    <title>|" "$LIVE.new"
	touch -d @1 "$LIVE.new"
	mv "$LIVE.new" "$LIVE"
	;;
v2)
	sed -i 's|content="v1"|content="v2"|' "$LIVE"
	touch -d @1 "$LIVE"
	;;
restore)
	cp "$GOLD" "$LIVE.new"
	touch -d @1 "$LIVE.new"
	mv "$LIVE.new" "$LIVE"
	;;
esac

echo "live: $(md5sum "$LIVE" | cut -d' ' -f1) size=$(stat -c %s "$LIVE") mtime=$(stat -c %Y "$LIVE")"
echo "gold: $(md5sum "$GOLD" | cut -d' ' -f1) size=$(stat -c %s "$GOLD") mtime=$(stat -c %Y "$GOLD")"
grep -o 'cache-probe" content="[^"]*"' "$LIVE" || echo "(no marker)"
