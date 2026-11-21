#!/usr/bin/env bash
# measure-engines.sh — the engine measurement of Extensibility-Model.md §11.9
# (wasmtime against wasmi), on the machine it runs on.
#
#   measure-engines.sh [--module <plugin.wasm>]... [--jobs N]
#
# 1. Builds `ct-wasm-engine-bench` (both engines) in release and runs it:
#    compile and instantiation time, per-call cost, the cost of each deadline
#    mechanism (none / epoch / fuel), cut-off latency, memory per instance.
# 2. Builds `ct-wasm-engine-probe` once per engine, alone, and reports its
#    stripped size: what that engine adds to a host binary.
#
# Needs cargo (the codetracer dev shell). Writes into $CT_ENGINE_TARGET
# (default: ./target beside this script).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${CT_ENGINE_TARGET:-${here}/target}"
jobs=""
modules=()
while [ $# -gt 0 ]; do
	case "$1" in
	--module) modules+=(--module "$2"); shift 2 ;;
	--jobs) jobs="-j$2"; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

echo "== host"
uname -a
if command -v sysctl >/dev/null 2>&1; then sysctl -n machdep.cpu.brand_string 2>/dev/null || true; fi
[ -r /proc/cpuinfo ] && grep -m1 'model name' /proc/cpuinfo || true
cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime
rustc --version
git -C "${here}" rev-parse HEAD 2>/dev/null || true

cd "${here}"
echo "== build the bench (both engines)"
cargo build --locked --release ${jobs} --target-dir "${target}/both" --bin ct-wasm-engine-bench

echo "== build one probe per engine"
for engine in wasmtime wasmi; do
	cargo build --locked --release ${jobs} --target-dir "${target}/${engine}" \
		--no-default-features --features "${engine}" --bin ct-wasm-engine-probe
done

echo "== bench"
"${target}/both/release/ct-wasm-engine-bench" ${modules[@]+"${modules[@]}"}

echo "== binary size (stripped, release, the probe alone)"
for engine in wasmtime wasmi; do
	bin="${target}/${engine}/release/ct-wasm-engine-probe"
	size=$(wc -c <"${bin}" | tr -d ' ')
	echo "   probe[${engine}]                      ${size} bytes"
done
