#!/usr/bin/env bash

set -e

WANTED_NODE_VERSION="20" # LTS version - major version only

if command -v node &>/dev/null; then
	NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
	if [ "$NODE_VERSION" == "$WANTED_NODE_VERSION" ]; then
		echo "Node.js v$NODE_VERSION.x is already installed"
		exit 0
	else
		echo "Node.js v$NODE_VERSION.x present, but we need v$WANTED_NODE_VERSION.x! installing..."
	fi
else
	echo "Node.js is missing! installing..."
fi

if [ "$os" == "mac" ]; then
	# Install Node.js v20 LTS via brew
	brew install node@20
	brew link --overwrite --force node@20
else
	echo "Node.js installation on non-macOS platforms needs to be implemented"
	exit 1
fi
