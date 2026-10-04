#!/usr/bin/env bash
# Start the development nginx server for browser replay testing.
#
# Generates nginx.conf from the template with environment-specific paths
# (mime.types location, absolute cert/data paths, QUIC support detection).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Generate certs if needed
bash "$SCRIPT_DIR/setup-certs.sh"

# Create directories
mkdir -p "$SCRIPT_DIR/traces"
mkdir -p "$SCRIPT_DIR/app"

# Check for nginx
if ! command -v nginx &>/dev/null; then
	echo "ERROR: nginx not found. Install via nix or your package manager."
	echo "  nix: nix-shell -p nginxMainline"
	exit 1
fi

# Detect nginx version
NGINX_VERSION=$(nginx -v 2>&1 | grep -oP '\d+\.\d+' | head -1)
echo "nginx version: $NGINX_VERSION"

# Find mime.types: check common locations
MIME_TYPES=""
NGINX_PREFIX=$(dirname "$(dirname "$(command -v nginx)")")
for candidate in \
	"$NGINX_PREFIX/conf/mime.types" \
	/etc/nginx/mime.types \
	/usr/local/etc/nginx/mime.types \
	/opt/homebrew/etc/nginx/mime.types; do
	if [ -f "$candidate" ]; then
		MIME_TYPES="$candidate"
		break
	fi
done

if [ -z "$MIME_TYPES" ]; then
	echo "ERROR: Cannot find mime.types. Searched:"
	echo "  $NGINX_PREFIX/conf/mime.types"
	echo "  /etc/nginx/mime.types"
	echo "  /usr/local/etc/nginx/mime.types"
	exit 1
fi
echo "mime.types: $MIME_TYPES"

# Detect QUIC support by testing the config
QUIC_LISTEN="        listen 8443 quic reuseport;"
HAS_QUIC=true
# The org development certificate (environment-domains-and-dev-certificates.md
# §5). `setup-certs.sh` above has already verified that all of this exists, is in
# date, covers MCL_SERVER_NAME and that the key matches -- so these are read, not
# checked again here. Keep the name in step with that script's SERVER_NAME.
MCL_SERVER_NAME=replay.codetracer.localhost
# Readiness marker for a supervisor (`repro up`). Under .repro/ because that is
# already gitignored state rather than part of the served tree.
READY_MARKER="$REPO_ROOT/.repro/browser-replay/ready"
MCL_LEAF_CRT=/etc/mcl-dev-certs/codetracer.localhost/fullchain.pem
MCL_LEAF_KEY=/etc/mcl-dev-certs/codetracer.localhost/key.pem

# Generate a minimal test config to check QUIC support
TEST_CONF=$(mktemp)
cat >"$TEST_CONF" <<TESTEOF
worker_processes 1;
pid /tmp/ct-browser-replay-quic-test.pid;
events { worker_connections 1; }
http {
    include $MIME_TYPES;
    server {
        listen 18443 ssl;
        listen 18443 quic reuseport;
        ssl_certificate $MCL_LEAF_CRT;
        ssl_certificate_key $MCL_LEAF_KEY;
    }
}
TESTEOF
if ! nginx -t -c "$TEST_CONF" 2>/dev/null; then
	echo "NOTE: nginx does not support QUIC — HTTP/3 disabled, HTTP/2 still active."
	QUIC_LISTEN="        # QUIC not supported by this nginx build"
	HAS_QUIC=false
fi
rm -f "$TEST_CONF"

# Generate nginx.conf from template
sed \
	-e "s|@MIME_TYPES@|$MIME_TYPES|g" \
	-e "s|@SCRIPT_DIR@|$SCRIPT_DIR|g" \
	-e "s|@MCL_LEAF_CRT@|$MCL_LEAF_CRT|g" \
	-e "s|@MCL_LEAF_KEY@|$MCL_LEAF_KEY|g" \
	-e "s|@MCL_SERVER_NAME@|$MCL_SERVER_NAME|g" \
	-e "s|@QUIC_LISTEN@|$QUIC_LISTEN|g" \
	"$SCRIPT_DIR/nginx.conf.template" >"$SCRIPT_DIR/nginx.conf"

CONF="$SCRIPT_DIR/nginx.conf"

echo "Starting nginx..."
echo "  Config:  $CONF"
echo "  Traces:  $SCRIPT_DIR/traces/"
echo "  App:     $SCRIPT_DIR/app/"
echo "  URL:     https://$MCL_SERVER_NAME:8443"
if [ "$HAS_QUIC" = true ]; then
	echo "  HTTP/3:  enabled"
else
	echo "  HTTP/3:  disabled (QUIC not available)"
fi
echo ""
echo "To stop: bash $SCRIPT_DIR/stop-server.sh"
echo ""

cd "$REPO_ROOT"

# --foreground: run nginx in the foreground and write a readiness marker once the
# port actually accepts a connection.
#
# This is the shape a SUPERVISOR needs, and `repro up` is one: it tracks the
# process it started, so a command that daemonises and returns looks like a
# service that died immediately. The marker is what `repro.nim` declares as the
# service's readiness, and it is written after a real connect rather than after
# the spawn, because nginx writes its pid file before it begins accepting -- so a
# pid-file probe would report ready while the first request still fails.
if [ "${1:-}" = "--foreground" ]; then
	rm -f "$READY_MARKER"
	nginx -c "$CONF" -p "$REPO_ROOT" -g 'daemon off;' &
	nginx_pid=$!
	# Propagate a stop to nginx rather than orphaning it.
	trap 'rm -f "$READY_MARKER"; kill "$nginx_pid" 2>/dev/null || true' TERM INT EXIT
	for _ in $(seq 1 100); do
		if (exec 3<>/dev/tcp/127.0.0.1/8443) 2>/dev/null; then
			mkdir -p "$(dirname "$READY_MARKER")"
			: >"$READY_MARKER"
			echo "nginx ready (marker: $READY_MARKER)"
			break
		fi
		kill -0 "$nginx_pid" 2>/dev/null || {
			echo "nginx exited before accepting on 8443" >&2
			exit 1
		}
		sleep 0.1
	done
	wait "$nginx_pid"
	exit $?
fi

nginx -c "$CONF" -p "$REPO_ROOT"
echo "nginx started."
