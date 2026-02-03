#!/usr/bin/env bash

set -e

WANTED_RUST_VERSION="1.87.0-nightly" # This should be relaxed a bit somehow

: "${DEPS_DIR:=$PWD/deps}"

# Ensure CARGO_HOME is set for rustup commands
: "${CARGO_HOME:=$DEPS_DIR/cargo}"
: "${RUSTUP_HOME:=$DEPS_DIR/rustup}"

export RUSTUP_INIT_SKIP_PATH_CHECK=yes

if command -v rustc &>/dev/null; then
	RUST_VERSION=$(rustc --version | cut -d' ' -f2)
	if [ "$RUST_VERSION" == "$WANTED_RUST_VERSION" ]; then
		echo "Rust $RUST_VERSION is already installed"
		# Ensure rustup has a default toolchain set
		if command -v rustup &>/dev/null; then
			echo "Setting rustup default to nightly..."
			rustup default nightly
		fi
		exit 0
	else
		echo "Rust $RUST_VERSION present, but we need $WANTED_RUST_VERSION! installing..."
	fi
else
	echo rust is missing! installing...
fi

curl --proto '=https' --tlsv1.2 -sf https://sh.rustup.rs | sh -s -- --no-modify-path -y --default-toolchain nightly

# shellcheck source=/dev/null
source "$CARGO_HOME"/env # adds rustc to our PATH

# Ensure default is set after installation
rustup default nightly
