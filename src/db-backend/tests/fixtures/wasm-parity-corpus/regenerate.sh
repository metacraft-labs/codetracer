#!/usr/bin/env bash
# WASM cross-modality parity corpus (M45) — recording pipeline.
#
# Produces four real browser recordings, one per corpus module. For each
# it writes
#
#   modules/<name>/<program>.ct/          the browser recording
#   modules/<name>/module/<name>.wasm     the ORIGINAL, uninstrumented
#                                         module — what the offline
#                                         replay is driven against
#                                         (spec §6.1)
#   modules/<name>/expected.json          what the page observed
#
# under `$CT_RECORDING_OUT_DIR` (the fixture directory when run by hand),
# plus `modules/<name>/page/<name>.instrumented.wasm(+.manifest.json)` —
# what the browser loaded — which stays beside the sources because the
# page is served from there.
#
# Nothing is committed. This script used to end by copying each fresh
# recording into `codetracer-wasm-recorder`'s testdata; that stage is
# gone, because it made the two repos agree by construction and kept them
# agreeing after the producer had moved.
#
# Nothing here fabricates trace content. If a prerequisite is missing the
# script fails loudly rather than emitting a placeholder: a plausible
# fake recording is far worse than an absent one, because it makes the
# checks that consume it report success without exercising anything.
#
# Prerequisites are checked BEFORE anything is deleted.
#
#     ./regenerate.sh [module ...]     (default: all four)
#
# Exit codes:
#   0   every requested recording was written
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was written
#   1   a stage ran and failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

WASM_INSTRUMENTER="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
export CODETRACER_WASM_INSTRUMENTER_PATH="$WASM_INSTRUMENTER"

# Where the four recordings land. Nothing here is committed: each
# recording and the ORIGINAL module the offline replay drives it against
# are produced in the same run, so they cannot describe different builds,
# and a change in `ct-instrument` or the browser recorder re-makes both.
OUT_DIR="${CT_RECORDING_OUT_DIR:-$FIXTURE_DIR}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
export CT_RECORDING_OUT_DIR="$OUT_DIR"

PREVIEW_PORT="${CORPUS_PREVIEW_PORT:-4182}"
RECORD_WEB_PORT="${CORPUS_RECORD_WEB_PORT:-9232}"

# module-name : recording-program-name
ALL_MODULES=(loop_digest pair_stats vault_apply tick_ledger)
program_of() {
	case "$1" in
	loop_digest) echo "loop-digest" ;;
	pair_stats) echo "pair-stats" ;;
	vault_apply) echo "vault-apply" ;;
	tick_ledger) echo "tick-ledger" ;;
	*)
		echo "unknown module: $1" >&2
		exit 1
		;;
	esac
}

MODULES=("$@")
[ ${#MODULES[@]} -gt 0 ] || MODULES=("${ALL_MODULES[@]}")

echo "[regenerate] WASM parity corpus"
echo "[regenerate] fixture:      $FIXTURE_DIR"
echo "[regenerate] instrumenter: $WASM_INSTRUMENTER"
echo "[regenerate] modules:      ${MODULES[*]}"
echo

# ---------------------------------------------------------------------------
# Prerequisites, collected in full so one run tells the operator
# everything that is missing.
# ---------------------------------------------------------------------------
missing=()

require_bin() {
	command -v "$1" >/dev/null 2>&1 || missing+=("- $1 not on PATH ($2)")
}

require_bin rustc "builds the corpus modules"
require_bin clang "assembles pair_stats' multi-value wrapper"
require_bin node "runs the static server and the headless driver"

if ! grep -qx 'wasm32-unknown-unknown' <<<"$(rustc --print target-list 2>/dev/null)"; then
	missing+=("- rustc cannot target wasm32-unknown-unknown")
fi

CT_INSTRUMENT_BIN="${CT_INSTRUMENT_BIN:-}"
if [ -z "$CT_INSTRUMENT_BIN" ]; then
	for candidate in \
		"$WASM_INSTRUMENTER/target/release/ct-instrument" \
		"$WASM_INSTRUMENTER/target/debug/ct-instrument"; do
		if [ -x "$candidate" ]; then
			CT_INSTRUMENT_BIN="$candidate"
			break
		fi
	done
fi
if [ -z "$CT_INSTRUMENT_BIN" ] && command -v ct-instrument >/dev/null 2>&1; then
	CT_INSTRUMENT_BIN="$(command -v ct-instrument)"
fi
if [ -z "$CT_INSTRUMENT_BIN" ]; then
	missing+=("- ct-instrument not found (cargo build --release -p ct-instrument-cli in $WASM_INSTRUMENTER)")
fi

RECORD_WEB_BIN="${CODETRACER_RECORD_WEB_BIN:-}"
if [ -z "$RECORD_WEB_BIN" ]; then
	for candidate in \
		"$CODETRACER_ROOT/src/backend-manager/target/release/session-manager" \
		"$CODETRACER_ROOT/src/backend-manager/target/debug/session-manager" \
		"$CODETRACER_ROOT/src/build-debug/bin/session-manager"; do
		if [ -x "$candidate" ]; then
			RECORD_WEB_BIN="$candidate"
			break
		fi
	done
fi
if [ -z "$RECORD_WEB_BIN" ]; then
	missing+=("- session-manager not built (cargo build in $CODETRACER_ROOT/src/backend-manager)")
fi

if [ ! -d "$WASM_INSTRUMENTER/recorder-runtime" ]; then
	missing+=("- the instrumenter's recorder-runtime/ is not present at $WASM_INSTRUMENTER")
fi

if ! node -e 'require("node:module").createRequire(process.argv[1]).resolve("playwright")' \
	"$CODETRACER_ROOT/package.json" >/dev/null 2>&1; then
	missing+=("- playwright is not installed in $CODETRACER_ROOT/node_modules")
fi

if [ ${#missing[@]} -gt 0 ]; then
	echo "[regenerate] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	echo
	echo "[regenerate] nothing was written. Install the above and re-run."
	exit 75
fi

echo "[regenerate] using ct-instrument: $CT_INSTRUMENT_BIN"
echo "[regenerate] using record-web:    $RECORD_WEB_BIN"
echo

cleanup_pids=()

# Drop an already-reaped pid, so the exit trap cannot later signal a
# *recycled* process group that happens to have been given the same number.
forget_pid() {
	local target="$1" pid
	local kept=()
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		[ "$pid" = "$target" ] || kept+=("$pid")
	done
	cleanup_pids=("${kept[@]:-}")
}

cleanup() {
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
	done
	cleanup_pids=()
}

# Everything started below is `setsid`-detached, so it sits in its own
# session where no terminal SIGHUP and no `kill -- -<our pgid>` can reach
# it. This trap is therefore the only reaper in the system, and it is worth
# being explicit about when it runs.
#
# Naming INT/TERM/HUP is deliberate but is *not* what fixes the orphaned
# daemons, and it would be misleading to imply otherwise: bash already runs
# an `EXIT` trap when the shell dies on an untrapped SIGTERM, including
# while it is blocked in a foreground command. This was measured, not
# assumed. What the explicit traps buy is that the reaping no longer
# depends on that subtlety, and that a signalled run exits 128+signo
# instead of whatever the default disposition produces.
#
# The real gap is SIGKILL — a CI step timeout, `timeout(1)` escalation, an
# OOM kill — where no trap of any kind can run. That is why `record-web`
# also stands itself down after an idle period (`--idle-timeout`, default
# 10 minutes), which is the only defence that survives this script being
# killed outright.
on_signal() {
	trap - EXIT
	cleanup
	# Conventional 128+signo, so a caller can tell a signalled run from a
	# failed one.
	exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

wait_for_port() {
	local port="$1" label="$2"
	for _ in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			exec 3<&- 3>&-
			return 0
		fi
		sleep 0.2
	done
	echo "[regenerate] $label never bound 127.0.0.1:$port" >&2
	return 1
}

wait_for_port_free() {
	local port="$1"
	for _ in $(seq 1 100); do
		if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			return 0
		fi
		exec 3<&- 3>&-
		sleep 0.2
	done
	echo "[regenerate] 127.0.0.1:$port never became free" >&2
	return 1
}

for port in "$PREVIEW_PORT" "$RECORD_WEB_PORT"; do
	if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
		exec 3<&- 3>&-
		echo "[regenerate] 127.0.0.1:$port is already in use." >&2
		exit 1
	fi
done

# ---------------------------------------------------------------------------
# Build one module.
#
# Every module is a single dependency-free `#![no_std]` file, so `rustc`
# is invoked directly rather than through cargo: there is no manifest to
# resolve, no lock file to pin, and no `target/` tree to gitignore. The
# `-C debuginfo=2` is the load-bearing flag — it is the DWARF the offline
# replay turns into per-line steps and locals, and the reason a corpus of
# DWARF-less modules could not have witnessed anything.
# ---------------------------------------------------------------------------
build_module() {
	local name="$1"
	local dir="$FIXTURE_DIR/modules/$name"
	local out="$dir/build"
	rm -rf "$out"
	mkdir -p "$out"

	local common=(
		--target wasm32-unknown-unknown
		--edition 2021
		--crate-type cdylib
		--crate-name "$name"
		-C debuginfo=2
		-C opt-level=0
	)
	local extra=()
	case "$name" in
	pair_stats)
		# The multi-value export lives in WebAssembly assembly; see
		# `wrap.s` and `lld-explicit-exports` for why both are needed.
		clang --target=wasm32-unknown-unknown -mmultivalue \
			-c "$dir/wrap.s" -o "$out/wrap.o" 2>&1 |
			grep -v 'argument unused during compilation' || true
		[ -f "$out/wrap.o" ] || {
			echo "[regenerate] clang did not assemble wrap.s" >&2
			exit 1
		}
		extra=(
			-C target-feature=+multivalue
			-C "linker=$FIXTURE_DIR/lld-explicit-exports"
			-C "link-arg=$out/wrap.o"
			-C link-arg=--export=sample_pair
			-C link-arg=--no-check-features
		)
		;;
	vault_apply)
		# `--import-memory` is what makes `env.memory` an import rather
		# than a definition, and therefore what makes this module's
		# starting state host-supplied (spec §3.3). The reduced stack
		# size only keeps the memory — and so the recorded state — small.
		extra=(
			-C link-arg=--import-memory
			-C link-arg=-zstack-size=65536
		)
		;;
	esac

	# Built from inside the module directory so the path DWARF records
	# is `<module dir>/lib.rs` rather than something depending on where
	# this script was run from.
	(cd "$dir" && rustc "${common[@]}" "${extra[@]}" -o "$out/$name.wasm" lib.rs)
	[ -f "$out/$name.wasm" ] || {
		echo "[regenerate] rustc did not produce $out/$name.wasm" >&2
		exit 1
	}
}

# ---------------------------------------------------------------------------
# Record one module in a real headless browser.
# ---------------------------------------------------------------------------
record_module() {
	local name="$1"
	local program
	program="$(program_of "$name")"
	local dir="$FIXTURE_DIR/modules/$name"
	local out_dir="$OUT_DIR/modules/$name"
	mkdir -p "$out_dir"

	echo "[regenerate] === $name ($program) ==="

	# Everything checked; only now is anything removed.
	rm -rf "$out_dir/$program.ct" \
		"$out_dir/module/$name.wasm" \
		"$out_dir/expected.json" \
		"$dir/page/$name.instrumented.wasm" \
		"$dir/page/$name.instrumented.wasm.manifest.json"

	echo "[regenerate]   1/4 building lib.rs -> wasm32-unknown-unknown"
	build_module "$name"
	local raw="$dir/build/$name.wasm"

	# The ORIGINAL module is what the offline replay runs (spec §6.1),
	# and it has to be *this* build: the recording pins export names,
	# import indices and — for `vault_apply` — absolute linear-memory
	# offsets, so a module compiled by a different toolchain no longer
	# describes it. Producing it in the same run as the recording is what
	# guarantees that, and removes the zstd step that only existed to fit
	# a *committed* module under the repo's 500 KB cap.
	mkdir -p "$out_dir/module"
	cp -f "$raw" "$out_dir/module/$name.wasm"

	echo "[regenerate]   2/4 instrumenting with ct-instrument"
	"$CT_INSTRUMENT_BIN" "$raw" \
		--output "$dir/page/$name.instrumented.wasm" \
		--manifest "$dir/page/$name.instrumented.wasm.manifest.json" \
		--source-path "lib.rs"

	echo "[regenerate]   3/4 recording in headless Chromium"
	local out
	out="$(mktemp -d)"
	setsid "$RECORD_WEB_BIN" record-web \
		--bind "127.0.0.1:$RECORD_WEB_PORT" \
		--out-dir "$out" \
		--workdir "$dir" &
	local daemon=$!
	cleanup_pids+=("$daemon")
	wait_for_port "$RECORD_WEB_PORT" "record-web" || exit 1

	setsid node "$FIXTURE_DIR/serve.mjs" "$PREVIEW_PORT" "$name" &
	local serve=$!
	cleanup_pids+=("$serve")
	wait_for_port "$PREVIEW_PORT" "the static server" || exit 1

	node "$FIXTURE_DIR/drive.mjs" "$PREVIEW_PORT" "$RECORD_WEB_PORT" "$name"

	kill -INT "$daemon" >/dev/null 2>&1 || true
	wait "$daemon" 2>/dev/null || true
	forget_pid "$daemon"
	kill "$serve" >/dev/null 2>&1 || true
	wait "$serve" 2>/dev/null || true
	forget_pid "$serve"
	wait_for_port_free "$RECORD_WEB_PORT" || exit 1
	wait_for_port_free "$PREVIEW_PORT" || exit 1

	if [ ! -d "$out/$program.ct" ]; then
		echo "[regenerate] record-web did not produce $program.ct" >&2
		ls -la "$out" >&2 || true
		exit 1
	fi
	cp -R "$out/$program.ct" "$out_dir/$program.ct"
	rm -rf "$out"

	if [ "$name" = "vault_apply" ] && [ ! -f "$out_dir/$program.ct/boundary_state.json" ]; then
		echo "[regenerate] $program.ct carries no boundary_state.json." >&2
		echo "[regenerate] vault_apply exists to exercise spec §3.3/§3.4;" >&2
		echo "[regenerate] a recording without the sidecar is not one." >&2
		exit 1
	fi

	# There used to be a fourth stage here that copied each fresh
	# recording, module, manifest and source into
	# `codetracer-wasm-recorder/cmd/wazero/testdata/boundary-log/`.
	# That is the mechanism this work removes. It turned that repo's
	# committed corpus into a *cache of this pipeline's output*: the two
	# repos then agreed by construction, and the agreement kept holding
	# after the producer changed, because the last sync had frozen it.
	# The recorder repo now keeps its corpus as a deliberately captured
	# vector set and checks it against this pipeline with an explicit
	# cross-repo comparison — see that repo's
	# `scripts/verify-vectors-against-producer.sh`.

	echo
}

for module in "${MODULES[@]}"; do
	record_module "$module"
done

echo "[regenerate] done. Now run ./verify.sh"
