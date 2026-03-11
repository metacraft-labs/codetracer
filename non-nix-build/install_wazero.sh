#!/usr/bin/env bash

set -e

: "${DEPS_DIR:=$PWD/deps}"
cd "$DEPS_DIR"

out=$(PWD=$(realpath ../../) ../find_git_hash_from_lockfile.py wazero)
commit=$(echo "${out}" | grep -v "github.com")
repo=$(echo "${out}" | grep "github.com")
folder="codetracer-wasm-recorder"

mkdir "${folder}" || echo "Folder already exists"
cd "${folder}"
if [ "$(git rev-parse HEAD)" != "${commit}" ]; then
	cd ../
	rm -rf "${folder}"
	git clone "${repo}"
	cd "${folder}"
	git checkout "$commit"

	FFI_STAGE_DIR="$DEPS_DIR/trace-writer-ffi"
	if [ -d "$FFI_STAGE_DIR/lib" ] && [ -d "$FFI_STAGE_DIR/include" ]; then
		echo "Building wazero with CGO (trace-writer-ffi from $FFI_STAGE_DIR)"
		# Note: no CGO_CFLAGS needed — the wasm-recorder bundles its own
		# header (tracewriter/codetracer_trace_writer.h). We only provide
		# CGO_LDFLAGS for the library search path.
		CGO_ENABLED=1 \
			CGO_LDFLAGS="-L${FFI_STAGE_DIR}/lib" \
			go build cmd/wazero/wazero.go
	else
		echo "WARNING: trace-writer-ffi not staged at $FFI_STAGE_DIR, building without CGO"
		CGO_ENABLED=0 go build cmd/wazero/wazero.go
	fi

	cp ./wazero "$BIN_DIR/"
fi
