#!/usr/bin/env bash
set -euo pipefail
unset CDPATH

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/src"

# shellcheck source=tools/build/codetracer_flags.env
source "${SCRIPT_DIR}/codetracer_flags.env"

SUPPORTED_TARGETS=(
  "ct"
  "ct-wrapper"
  "db-backend-record"
  "js:index"
  "js:server-index"
  "js:subwindow"
  "js:ui"
  "js:middleware"
)

usage() {
  cat <<'EOF'
Usage: build_codetracer.sh --target <name> [options]

Targets:
  ct                Nim C build for the Codetracer CLI binary.
  ct-wrapper        Nim C build for the wrapper binary exposed as `ct`.
  db-backend-record Nim C build for the db-backend recording helper.
  js:index          Nim JS build for frontend/index.nim (renderer entrypoint).
  js:server-index   Nim JS build for frontend/index.nim (server bundle).
  js:subwindow      Nim JS build for frontend/subwindow.nim.
  js:ui             Nim JS build for frontend/ui_js.nim.

Options:
  --profile <debug|release>     Build profile (default: debug).
  --output-dir <path>           Directory for the final artefact (defaults depend on target/profile).
  --output <path>               Explicit output file path (overrides --output-dir and default name).
  --nimcache <path>             Override Nim cache directory (default: <output-dir>/.nimcache/<target>).
  --extra-define <define>       Additional -d:<define> to pass to Nim (may be repeated).
  --extra-flag <flag>           Additional flag appended to the Nim command (may be repeated).
  --dry-run                     Print the resolved command without executing it.
  --list-targets                Print the supported targets and exit.
  -h, --help                    Show this help text.

Examples:
  build_codetracer.sh --target ct --profile debug --output-dir ./out/bin
  build_codetracer.sh --target js:index --output ./out/js/index.js --dry-run
EOF
}

list_targets() {
  printf '%s\n' "${SUPPORTED_TARGETS[@]}"
}

# Globals populated by resolve_target.
target_kind=""
target_source=""
target_output_name=""
target_specific_flags=()

resolve_target() {
  local target="$1"
  target_specific_flags=()
  case "$target" in
    ct)
      target_kind="nim-c"
      target_source="${SRC_DIR}/ct/codetracer.nim"
      target_output_name="codetracer"
      target_specific_flags=(
        "${CODERACER_NIM_BINARY_SHARED_FLAGS[@]}"
        "-d:ctEntrypoint"
      )
      ;;
    ct-wrapper)
      target_kind="nim-c"
      target_source="${SRC_DIR}/ct/ct_wrapper.nim"
      target_output_name="ct"
      target_specific_flags=(
        "${CODERACER_NIM_BINARY_SHARED_FLAGS[@]}"
      )
      ;;
    db-backend-record)
      target_kind="nim-c"
      target_source="${SRC_DIR}/ct/db_backend_record.nim"
      target_output_name="db-backend-record"
      target_specific_flags=(
        "${CODERACER_NIM_BINARY_SHARED_FLAGS[@]}"
      )
      ;;
    js:index)
      target_kind="nim-js"
      target_source="${SRC_DIR}/frontend/index.nim"
      target_output_name="index.js"
      target_specific_flags=(
        "${CODERACER_NIM_JS_SHARED_FLAGS[@]}"
        "-d:ctIndex"
        "-d:nodejs"
        "--sourcemap:on"
      )
      ;;
    js:server-index)
      target_kind="nim-js"
      target_source="${SRC_DIR}/frontend/index.nim"
      target_output_name="server_index.js"
      target_specific_flags=(
        "${CODERACER_NIM_JS_SHARED_FLAGS[@]}"
        "-d:ctIndex"
        "-d:server"
        "-d:nodejs"
        "--sourcemap:on"
      )
      ;;
    js:subwindow)
      target_kind="nim-js"
      target_source="${SRC_DIR}/frontend/subwindow.nim"
      target_output_name="subwindow.js"
      target_specific_flags=(
        "${CODERACER_NIM_JS_SHARED_FLAGS[@]}"
        "-d:chronicles_enabled=off"
        "-d:ctRenderer"
        "--debugInfo:on"
        "--lineDir:on"
        "--hotCodeReloading:on"
        "--sourcemap:on"
      )
      ;;
    js:ui)
      target_kind="nim-js"
      target_source="${SRC_DIR}/frontend/ui_js.nim"
      target_output_name="ui.js"
      target_specific_flags=(
        "${CODERACER_NIM_JS_SHARED_FLAGS[@]}"
        "-d:chronicles_enabled=off"
        "-d:ctRenderer"
        "--debugInfo:on"
        "--lineDir:on"
        "--hotCodeReloading:on"
      )
      ;;
    js:middleware)
      target_kind="nim-js"
      target_source="${SRC_DIR}/frontend/middleware.nim"
      target_output_name="middleware.js"
      target_specific_flags=(
        "${CODERACER_NIM_JS_SHARED_FLAGS[@]}"
        "-d:ctInExtension"
      )
      ;;
    *)
      echo "Error: unsupported target '${target}'" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
}

profile_flags() {
  local profile="$1"
  case "$profile" in
    debug) printf '%s\n' "${CODERACER_NIM_PROFILE_DEBUG_FLAGS[@]}";;
    release) printf '%s\n' "${CODERACER_NIM_PROFILE_RELEASE_FLAGS[@]}";;
    *)
      echo "Error: unsupported profile '${profile}'" >&2
      exit 1
      ;;
  esac
}

print_command() {
  local -a cmd=("$@")
  printf '[cmd]'
  for token in "${cmd[@]}"; do
    printf ' %q' "$token"
  done
  printf '\n'
}

main() {
  local profile="debug"
  local target=""
  local output_dir=""
  local nimcache=""
  local explicit_output=""
  local dry_run=0
  local list_only=0
  local -a extra_defines=()
  local -a extra_flags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)
        target="${2:-}"
        [[ -n "$target" ]] || { echo "Error: --target expects a value" >&2; exit 1; }
        shift 2
        ;;
      --profile)
        profile="${2:-}"
        [[ -n "$profile" ]] || { echo "Error: --profile expects a value" >&2; exit 1; }
        shift 2
        ;;
      --output-dir)
        output_dir="${2:-}"
        [[ -n "$output_dir" ]] || { echo "Error: --output-dir expects a value" >&2; exit 1; }
        shift 2
        ;;
      --output)
        explicit_output="${2:-}"
        [[ -n "$explicit_output" ]] || { echo "Error: --output expects a value" >&2; exit 1; }
        shift 2
        ;;
      --nimcache)
        nimcache="${2:-}"
        [[ -n "$nimcache" ]] || { echo "Error: --nimcache expects a value" >&2; exit 1; }
        shift 2
        ;;
      --extra-define)
        extra_defines+=("${2:-}")
        shift 2
        ;;
      --extra-flag)
        extra_flags+=("${2:-}")
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --list-targets)
        list_only=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if (( list_only )); then
    list_targets
    exit 0
  fi

  if [[ -z "$target" ]]; then
    echo "Error: --target is required" >&2
    echo >&2
    usage >&2
    exit 1
  fi

  resolve_target "$target"

  local output_path=""
  if [[ -n "$explicit_output" ]]; then
    output_path="${explicit_output}"
    if [[ -z "$output_dir" ]]; then
      output_dir="$(dirname "${output_path}")"
    fi
  else
    if [[ -z "$output_dir" ]]; then
      case "$target_kind" in
        nim-c) output_dir="${REPO_ROOT}/build/${profile}/bin" ;;
        nim-js) output_dir="${REPO_ROOT}/build/${profile}/js" ;;
        *) output_dir="${REPO_ROOT}/build/${profile}/out" ;;
      esac
    fi
    output_path="${output_dir}/${target_output_name}"
  fi

  if [[ -z "$nimcache" ]]; then
    local sanitized_target="${target//[:\/]/_}"
    nimcache="${output_dir}/.nimcache/${sanitized_target}"
  fi

  local -a cmd=("nim")
  cmd+=("${CODERACER_NIM_COMMON_FLAGS[@]}")
  local -a profile_specific=()
  mapfile -t profile_specific < <(profile_flags "$profile")
  cmd+=("${profile_specific[@]}")

  case "$target_kind" in
    nim-c) cmd+=("${target_specific_flags[@]}") ;;
    nim-js) cmd+=("${target_specific_flags[@]}") ;;
  esac

  for def in "${extra_defines[@]}"; do
    cmd+=("-d:${def}")
  done
  cmd+=("${extra_flags[@]}")

  local output_dirname
  output_dirname="$(dirname "${output_path}")"

  if (( ! dry_run )); then
    mkdir -p "$output_dirname"
    mkdir -p "$nimcache"
  fi

  cmd+=("--nimcache:${nimcache}")
  cmd+=("--out:${output_path}")

  if [[ "$target_kind" == "nim-js" ]]; then
    cmd+=("js")
  else
    cmd+=("c")
  fi

  cmd+=("$target_source")

  if (( dry_run )); then
    print_command "${cmd[@]}"
  else
    print_command "${cmd[@]}"
    "${cmd[@]}"
  fi
}

main "$@"
