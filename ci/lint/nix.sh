#!/usr/bin/env bash

set -e

nix flake check \
	--override-input codetracer-trace-format path:./libs/codetracer-trace-format
