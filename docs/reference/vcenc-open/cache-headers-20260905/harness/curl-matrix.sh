#!/bin/sh
# Cache-header matrix for the web bundle (#71). Run ON the device:
#   sh curl-matrix.sh
# Everything goes to https://127.0.0.1, which the server treats as
# authenticated, so no token is needed.

H=https://127.0.0.1
C="curl -sk"

ASSET=$($C $H/ | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1)
echo "served bundle: $ASSET"
echo

hdrs() {
	echo "=== HEAD $1"
	$C -I "$H$1" | tr -d '\r' | grep -viE '^(date|strict-transport|x-content-type|x-frame|accept-ranges):' | sed '/^$/d;s/^/    /'
	echo
}

# --- 1. no-cache group: index.html, /, and every non-hashed file ------------
hdrs /
hdrs /index.html
hdrs /sipeed.ico
hdrs /mockServiceWorker.js

# --- 2. immutable group: content-hashed Vite assets -------------------------
hdrs "/$ASSET"
hdrs /assets/index-DrlLKa8f.css

# --- 3. conditional requests ------------------------------------------------
echo "=== conditional requests"
ETAG=$($C -I $H/ | tr -d '\r' | awk -F': ' '/^[Ee]tag/{print $2}')
AETAG=$($C -I "$H/$ASSET" | tr -d '\r' | awk -F': ' '/^[Ee]tag/{print $2}')
echo "    index etag = $ETAG"
echo "    asset etag = $AETAG"
p() { printf '    %-46s -> %s\n' "$1" "$2"; }
p "GET / (no validator)" \
  "$($C -o /dev/null -w '%{http_code} %{size_download}B' $H/)"
p "GET / If-None-Match: <current>" \
  "$($C -o /dev/null -H "If-None-Match: $ETAG" -w '%{http_code} %{size_download}B' $H/)"
p "GET / If-None-Match: <stale>" \
  "$($C -o /dev/null -H 'If-None-Match: \"stale\"' -w '%{http_code} %{size_download}B' $H/)"
p "GET / If-Modified-Since: now" \
  "$($C -o /dev/null -H 'If-Modified-Since: Sun, 06 Sep 2026 00:00:00 GMT' -w '%{http_code} %{size_download}B' $H/)"
p "GET asset If-None-Match: <current>" \
  "$($C -o /dev/null -H "If-None-Match: $AETAG" -w '%{http_code} %{size_download}B' "$H/$ASSET")"
p "GET asset Range: bytes=0-99" \
  "$($C -o /dev/null -H 'Range: bytes=0-99' -w '%{http_code} %{size_download}B' "$H/$ASSET")"
echo

# --- 4. routing unchanged ---------------------------------------------------
echo "=== routing (must match upstream)"
for p in / /index.html /desktop /assets /assets/ /kvm; do
	printf '    %-46s -> %s\n' "GET $p" \
	  "$($C -o /dev/null -w '%{http_code} %{size_download}B' "$H$p")"
done
echo

# --- 5. API responses untouched ---------------------------------------------
echo "=== API (no Cache-Control / ETag may appear)"
$C -D- -o /dev/null $H/api/streamer/local | tr -d '\r' \
  | grep -viE '^(date|strict-transport|x-content-type|x-frame):' | sed '/^$/d;s/^/    /'
