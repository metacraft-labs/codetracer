#!/usr/bin/env bash
# Build the complete browser-replay distribution.
# Produces browser-replay/dist/ containing everything needed for static deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

echo "=== Building Browser Replay Distribution ==="

# Step 1: Build WASM module
echo ">>> Building replay-server WASM module..."
cd "$REPO_ROOT/src/db-backend"
direnv exec "$REPO_ROOT" bash build_wasm.sh 2>&1 | tail -5
cd "$REPO_ROOT"

if [ ! -f "src/db-backend/wasm-testing/pkg/db_backend_bg.wasm" ]; then
	echo "ERROR: WASM build failed — no .wasm file produced"
	exit 1
fi

# `build_wasm.sh` above pipes through `tail -5`, so this script never sees its
# exit status. "A .wasm file is present" therefore proves only that SOME build
# once succeeded here — which, on a dev machine where dist/ and pkg/ are both
# gitignored and survive every branch switch, can be a build from another
# branch entirely. Assert the engine is this tree's before bundling it for
# deployment.
# shellcheck source=ci/lib/wasm-engine-freshness.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "$REPO_ROOT/ci/lib/wasm-engine-freshness.sh"
wasm_engine_assert_fresh "$REPO_ROOT" || {
	echo "ERROR: refusing to bundle an engine that is not this tree's (see above)" >&2
	exit 1
}

# Step 2: Create dist directory
echo ">>> Creating dist directory..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/pkg"

# Step 3: Copy app files
cp "$SCRIPT_DIR/app/index.html" "$DIST_DIR/"
cp "$SCRIPT_DIR/app/gateway-client.js" "$DIST_DIR/"
cp "$SCRIPT_DIR/app/worker.js" "$DIST_DIR/"
cp "$SCRIPT_DIR/app/transport-test.html" "$DIST_DIR/"

# Step 4: Copy WASM module
cp "$REPO_ROOT/src/db-backend/wasm-testing/pkg/db_backend.js" "$DIST_DIR/pkg/"
cp "$REPO_ROOT/src/db-backend/wasm-testing/pkg/db_backend_bg.wasm" "$DIST_DIR/pkg/"
# Carry the build stamp with the engine, so a reader of dist/ can tell which
# sources the bundle it is holding was built from. Without it, dist/pkg is a
# second untracked copy of the artefact with even less provenance than the
# first.
cp "$REPO_ROOT/src/db-backend/wasm-testing/pkg/.engine-stamp" "$DIST_DIR/pkg/"

# Step 5: Create a sample traces directory
mkdir -p "$DIST_DIR/traces"

# Step 6: Create a simple nginx config for the dist
cat >"$DIST_DIR/serve.conf" <<'NGINX_EOF'
# Minimal nginx config for serving the dist directory.
# Usage: nginx -c $(pwd)/serve.conf -p $(pwd)
worker_processes 1;
error_log /tmp/ct-dist-error.log;
pid /tmp/ct-dist.pid;
events { worker_connections 64; }
http {
    include mime.types;
    types { application/wasm wasm; }
    default_type application/octet-stream;
    server {
        listen 8080;
        root .;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Headers Range always;
        add_header Access-Control-Expose-Headers "Content-Range, Content-Length" always;
        location /traces/ { add_header Cache-Control "public, immutable" always; }
    }
}
NGINX_EOF

# Step 6b: Cloudflare Pages `_headers`.
#
# ide.codetracer.com serves this bundle as a CROSS-ORIGIN engine: the HTML
# page (e.g. blocktracer.org) lives on a different origin and loads worker.js
# + pkg/*.js + *.wasm from here. Three things must be permitted cross-origin:
#   * the ES-module `import` of worker.js (blob-bootstrap in gateway-client.js)
#     and pkg/db_backend.js — module fetches honour CORS,
#   * `WebAssembly.compileStreaming` of db_backend_bg.wasm — an ordinary CORS
#     fetch,
#   * whole-file `?trace=<url>` and Range fetches of `.ct` containers.
# So publish a permissive `Access-Control-Allow-Origin: *` for the engine
# assets. Cross-Origin-Resource-Policy: cross-origin lets the assets be
# embedded by a document on another origin. (Cloudflare Pages serves .wasm as
# application/wasm automatically, so no content-type override is needed.)
cat >"$DIST_DIR/_headers" <<'HEADERS_EOF'
# Cloudflare Pages headers — see browser-replay/build-dist.sh for rationale.
/*
  Access-Control-Allow-Origin: *
  Access-Control-Allow-Methods: GET, HEAD, OPTIONS
  Access-Control-Allow-Headers: Range
  Access-Control-Expose-Headers: Content-Range, Content-Length, Accept-Ranges
  Cross-Origin-Resource-Policy: cross-origin
HEADERS_EOF

# Step 7: Print summary
WASM_SIZE=$(wc -c <"$DIST_DIR/pkg/db_backend_bg.wasm" | tr -d ' ')
TOTAL_SIZE=$(du -sh "$DIST_DIR" | cut -f1)

echo ""
echo "=== Distribution built successfully ==="
echo "  Directory: $DIST_DIR"
echo "  WASM size: $WASM_SIZE bytes"
echo "  Total size: $TOTAL_SIZE"
echo ""
echo "  Files:"
find "$DIST_DIR" -type f | sort | while read -r f; do
	SIZE=$(wc -c <"$f" | tr -d ' ')
	echo "    ${f#"$DIST_DIR"/} ($SIZE bytes)"
done
echo ""
echo "  To serve locally:"
echo "    cd $DIST_DIR && python3 -m http.server 8080"
echo "  Or with nginx:"
echo "    nginx -c $DIST_DIR/serve.conf -p $DIST_DIR"
