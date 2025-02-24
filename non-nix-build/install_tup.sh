#!/usr/bin/env bash

set -e

WANTED_TUP_REVISION=4247a523
WANTED_TUP_VERSION=v0.8-8
  
if command -v tup &> /dev/null; then
  TUP_VERSION=$(tup --version)
  if [ "$TUP_VERSION" == "tup $WANTED_TUP_VERSION-g$WANTED_TUP_REVISION" ]; then
    echo $TUP_VERSION is already installed
    exit 0
  else
    echo "$TUP_VERSION present, but we need $WANTED_TUP_VERSION-$WANTED_TUP_REVISION! installing..."
  fi
else
  echo tup is missing! installing...
fi

brew install pkg-config pcre2
: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"
rm -rf tup
git clone https://github.com/gittup/tup
cd tup
git checkout $WANTED_TUP_REVISION
./bootstrap.sh
cp ./tup $BIN_DIR/

