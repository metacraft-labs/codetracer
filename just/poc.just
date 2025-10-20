set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

poc_file := justfile_directory() + "/poc.just"
repo_root := justfile_directory() + "/.."
src_dir := repo_root + "/src"
node_bin := repo_root + "/node_modules/.bin"
docs_dir := repo_root + "/docs"

# Aggregate entry point -----------------------------------------------------

default:
  @just --justfile {{poc_file}} help

help:
  @printf "Available proof-of-concept build recipes:\n\n"
  @just --justfile {{poc_file}} --list --unsorted | sed 's/^/  /'

# Workspace orchestration ---------------------------------------------------

workspace:prepare:
  mkdir -p {{repo_root}}/public/dist

workspace:ensure-node:
  if [ ! -x {{node_bin}}/webpack ]; then \
    printf '\nwebpack binary not found. install dependencies with `npm install`.\n' >&2; \
    exit 1; \
  fi

workspace:ensure-mdbook:
  if ! command -v mdbook >/dev/null 2>&1; then \
    printf '\nmdbook is required for docs recipes.\n' >&2; \
    exit 1; \
  fi

workspace:ensure-tup:
  if ! command -v tup >/dev/null 2>&1; then \
    printf '\ntup is required for application builds.\n' >&2; \
    exit 1; \
  fi

workspace:ensure-cargo:
  if ! command -v cargo >/dev/null 2>&1; then \
    printf '\ncargo is required for db-backend builds.\n' >&2; \
    exit 1; \
  fi

workspace:ensure-nix:
  if ! command -v nix >/dev/null 2>&1; then \
    printf '\nnix is required for packaging builds.\n' >&2; \
    exit 1; \
  fi

workspace:check := workspace:prepare workspace:ensure-node workspace:ensure-mdbook workspace:ensure-tup workspace:ensure-cargo

# Build recipes -------------------------------------------------------------

build:app := workspace:check
build:app:
  cd {{src_dir}}
  tup build-debug

build:frontend := workspace:prepare workspace:ensure-node
build:frontend:
  cd {{repo_root}}
  {{node_bin}}/webpack --progress

build:db-backend := workspace:ensure-cargo
build:db-backend:
  cd {{src_dir}}/db-backend
  cargo build

build:docs := workspace:ensure-mdbook
build:docs:
  cd {{docs_dir}}/book
  mdbook build

build:packages := workspace:ensure-node workspace:ensure-tup workspace:ensure-nix
build:packages:
  cd {{repo_root}}
  nix bundle --bundler github:NixOS/bundlers#toDEB --print-build-logs ".?submodules=1#codetracer"

build:all := build:app build:frontend build:db-backend build:docs
build:all:
  @printf "All build targets completed.\n"

# Continuous developer workflows -------------------------------------------

dev:watch := workspace:check
# Runs tup monitor and webpack watch in parallel for a development session.
dev:watch:
  cd {{src_dir}}
  tup monitor -a &
  TUP_PID=$!
  cd {{repo_root}}
  {{node_bin}}/webpack --watch --progress &
  WEBPACK_PID=$!
  trap 'kill $TUP_PID $WEBPACK_PID' INT TERM
  wait $TUP_PID $WEBPACK_PID

# Test recipes --------------------------------------------------------------

test:db-backend := workspace:ensure-cargo
test:db-backend:
  cd {{src_dir}}/db-backend
  cargo test

test:ui headless="0" := workspace:check
test:ui headless:
  cd {{repo_root}}/tsc-ui-tests
  if [ "{{headless}}" = "1" ]; then \
    env CODETRACER_DEV_TOOLS=0 npx playwright test --reporter=list --workers=1 --headed=false; \
  else \
    env CODETRACER_DEV_TOOLS=0 npx playwright test --reporter=list --workers=1; \
  fi

ci:full := build:all test:db-backend
ci:full:
  @printf "Continuous integration run completed.\n"

# Utility recipes -----------------------------------------------------------

lint:rust := workspace:ensure-cargo
lint:rust:
  cd {{src_dir}}/db-backend
  cargo clippy --all-targets --all-features -- -D warnings

format:rust := workspace:ensure-cargo
format:rust:
  cd {{src_dir}}/db-backend
  cargo fmt

clean:
  rm -rf {{repo_root}}/public/dist
  find {{src_dir}} -name build-debug -type d -prune -exec rm -rf {} +

