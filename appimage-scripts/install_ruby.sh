#!/usr/bin/env bash

APP_DIR="${APP_DIR:-.}"

# Install Ruby
RUBY="$(dirname "$(dirname "$(which ruby)")")"
echo "${RUBY}"

mkdir -p "${APP_DIR}/ruby"

cp -Lr --no-preserve=ownership "${RUBY}"/* "${APP_DIR}"/ruby
chmod -R +x "${APP_DIR}/ruby"
