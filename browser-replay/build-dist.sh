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

# Step 2: Create dist directory
echo ">>> Creating dist directory..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/pkg"

# Step 3: Copy app files
cp "$SCRIPT_DIR/app/index.html" "$DIST_DIR/"
cp "$SCRIPT_DIR/app/worker.js" "$DIST_DIR/"
cp "$SCRIPT_DIR/app/transport-test.html" "$DIST_DIR/"

# Step 4: Copy WASM module
cp "$REPO_ROOT/src/db-backend/wasm-testing/pkg/db_backend.js" "$DIST_DIR/pkg/"
cp "$REPO_ROOT/src/db-backend/wasm-testing/pkg/db_backend_bg.wasm" "$DIST_DIR/pkg/"

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
find "$DIST_DIR" -type f | sort | while read f; do
	SIZE=$(wc -c <"$f" | tr -d ' ')
	echo "    $(echo "$f" | sed "s|$DIST_DIR/||") ($SIZE bytes)"
done
echo ""
echo "  To serve locally:"
echo "    cd $DIST_DIR && python3 -m http.server 8080"
echo "  Or with nginx:"
echo "    nginx -c $DIST_DIR/serve.conf -p $DIST_DIR"
