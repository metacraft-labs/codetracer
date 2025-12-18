#!/usr/bin/env bash

cd src/db-backend
#cargo build
cargo test --no-run
if timeout 5 cargo test dap_server_socket ; then
  exit 0
else
  echo "TIMEOUT!"
  exit 1
fi



