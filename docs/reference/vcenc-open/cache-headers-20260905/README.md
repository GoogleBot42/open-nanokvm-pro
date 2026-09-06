# Web-bundle cache headers — #71, device-proven 2026-09-05

The Go server used to hand the Vite bundle to `gin-contrib/static` →
`http.FileServer`, which sets no `Cache-Control` and no `ETag`. The only
validator was `Last-Modified`, and every bundle file is copied out of the Nix
store, whose mtimes are all `1970-01-01T00:00:01Z`. As found on the device:

```
$ curl -skI https://127.0.0.1/
HTTP/2 200
accept-ranges: bytes
content-type: text/html; charset=utf-8
last-modified: Thu, 01 Jan 1970 00:00:01 GMT
content-length: 456
```

That is two bugs, not one:

1. **No explicit freshness + a 56-year-old validator = heuristic freshness
   measured in years** (RFC 9111 §4.2.2 suggests ~10% of the document's age).
   Opening the UI reuses the cached `index.html` without contacting the device
   at all — and since the chunk names inside it are content-hashed, the browser
   then runs an old bundle and never requests the new chunks.
2. **The mtime never changes across deploys**, so even a forced revalidation is
   answered with a stale `304`. `If-Modified-Since: Thu, 01 Jan 1970 00:00:01
   GMT` still matches the *new* file. This is why F5 did not rescue Jeremy and
   only disabling the cache did.

The fix (`pkgs/nanokvm-server/web-static.go.in`, wired in as step 11 of
`pkgs/nanokvm-server.nix`) replaces the static middleware with a handler that
keeps the same routing gate and changes only the caching policy: content-hashed
`assets/` files get `public, max-age=31536000, immutable`; everything else,
`index.html` first, gets `no-cache` plus a strong sha256 **content** ETag. The
fake `Last-Modified` is suppressed; a file with a genuine mtime keeps it.

## What was run

Device: server binary only, deployed to both trees; the web bundle was never
redeployed (`assets/index-Bg_C9wJe.js` before and after). Backup of the previous
binary: `/root/pre71/NanoKVM-Server` (md5 `6a8cd3ef…`, byte-identical to a
`nix build .#nanokvm-server` of `main`). New binary md5 `516e77ad…`.

| file | what it is |
|---|---|
| `curl-matrix.txt` | `harness/curl-matrix.sh` run on the device against the fixed server |
| `cdp-cache-broken.txt` | headless Chromium, warm profile, **old** binary |
| `cdp-cache-fixed.txt` | same run, **new** binary |
| `swap-broken.txt` | redeploy-while-warm test, **old** binary |
| `swap-fixed.txt` | same test, **new** binary |

## Result 1 — headers and conditional requests (`curl-matrix.txt`)

`/`, `/index.html`, `/sipeed.ico`, `/mockServiceWorker.js` → `cache-control:
no-cache` + a 32-hex content ETag, no `Last-Modified`. `assets/index-*.js|css` →
`public, max-age=31536000, immutable` + an ETag of `"<filename hash>-<size>"`.
`If-None-Match` with the current ETag → `304 0B`, with a stale one → `200`.
`If-Modified-Since` → `200`, never a stale `304`. Routing is unchanged from
upstream (`/desktop` 404, `/assets` 301, `/assets/` 404, `/kvm` 302); API
responses carry no `Cache-Control` or `ETag`.

The one deliberate routing change: `/index.html` used to be a `301` to `/` and
is now served directly, so it gets the index treatment.

## Result 2 — a real warm browser (`cdp-cache-*.txt`)

`harness/cdp_cache.py`, headless Chromium 152, one profile, **cache enabled**,
three phases: cold load, navigate away and back, F5.

| phase | old binary | new binary |
|---|---|---|
| A cold | `/` network 627 B, assets network | `/` network 639 B, assets network |
| B open again | **`/` disk-cache, 0 B — the device is never asked** | `/` network **39 B** (a 304), assets **disk-cache 0 B** |
| C F5 | `/` network 38 B, assets disk-cache | `/` network 39 B, assets disk-cache |

Phase B is the bug and the fix in one line. CDP reports `status: 200` for a
revalidated entry because Chrome surfaces the merged cache entry; the 39-byte
`encodedDataLength` against a 456-byte body is the 304.

**Chromium will not write a response to its HTTP cache if the certificate had an
error**, so `--ignore-certificate-errors` (what the other harnesses use) makes
*everything* look uncacheable and hides the result entirely. `cdp_cache.py` and
`cdp_swap.py` therefore pin the device cert as trusted with
`--ignore-certificate-errors-spki-list` (`harness/spki.sh` regenerates the pin).

## Result 3 — deploy while the browser is warm (`swap-*.txt`)

`harness/cdp_swap.py`: load the UI, edit `index.html` on the device (marker
`v1`→`v2`, same file size, mtime forced back to `@1` exactly as a real
store-sourced deploy leaves it — `harness/probe-marker.sh`), then open the page
again and reload.

| step | old binary | new binary |
|---|---|---|
| 1 cold load | v1 | v1 |
| 2 open again (warm) | **disk-cache, v1 — stale** | network, **v2** |
| 3 F5 (warm) | **network, still v1 — a stale 304** | network, **v2** |

The marker edit keeps the file size identical, so this also demonstrates the
ETag is derived from content, not from stat data.

## Device state afterwards

`nanokvm` active, `kvmcomm` inactive, web 200, bundle still
`assets/index-Bg_C9wJe.js`, `index.html` md5 identical to `/kvmapp`'s in both
trees, new server binary in both trees, `/root/pre71/` intact. Stream mode is
in-memory only (`common.GetScreen().StreamType`, no read endpoint, no
persistence), so the final `systemctl restart nanokvm` returns it to the
compile-time default it was found at.
