#!/usr/bin/env bash

set -e

if command -v nargo &>/dev/null; then
	echo nargo is already installed
	exit 0
else
	echo nargo is missing! building...
fi

: "${DEPS_DIR:=$PWD/deps}"
cd "$DEPS_DIR"

out=$(PWD=$(realpath ../../) ../find_git_hash_from_lockfile.py noir)
commit=$(echo "${out}" | grep -v "github.com")
repo=$(echo "${out}" | grep "github.com")
folder="noir"

mkdir ${folder} || echo "Folder already exists"
cd "${folder}"
if [ "$(git rev-parse HEAD)" != "${commit}" ]; then
	cd ../
	rm -rf "${folder}"
	git clone "${repo}"
	cd "${folder}"
	git checkout "$commit"
	cargo build --release
	cp ./target/release/nargo "$BIN_DIR/"
fi
