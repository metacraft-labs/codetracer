#!/usr/bin/env bash

APP_DIR="${APP_DIR:-.}"

# Install Ruby
RUBY="$(dirname "$(dirname "$(which ruby)")")"
echo "${RUBY}"

mkdir -p "${APP_DIR}/ruby"

cp -Lr --no-preserve=ownership "${RUBY}"/* "${APP_DIR}"/ruby
chmod -R 777 "${APP_DIR}/ruby"
