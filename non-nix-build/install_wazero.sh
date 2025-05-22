#!/usr/bin/env bash

set -e

: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"

out=$(PWD=$(realpath ../../) ../find_git_hash_from_lockfile.py wazero)
commit=$(echo "${out}" | grep -v "github.com")
repo=$(echo "${out}" | grep "github.com")
folder="codetracer-wasm-recorder"

mkdir "${folder}" || echo "Folder already exists"
cd "${folder}"
if [ $(git rev-parse HEAD) != "${commit}" ]; then
  cd ../
  rm -rf "${folder}"
  git clone "${repo}"
  cd "${folder}"
  git checkout "$commit"
  go build cmd/wazero/wazero.go
  cp ./wazero $BIN_DIR/
fi

