#!/usr/bin/env bash
# shellcheck disable=SC2016
# The diagnostics below quote identifiers, module names and shell commands in
# backticks for the reader.  They are prose, not command substitutions, so the
# single quotes are deliberate and SC2016 does not apply.
# =============================================================================
# Fail early, and by name, when a sibling repo the build resolves by RELATIVE
# PATH is not checked out next to this repo.
#
# CodeTracer is built inside a multi-repo workspace: `<workspace>/codetracer`
# sits next to `<workspace>/isonim`, `<workspace>/io-mon`, ... and both build
# drivers reach across by relative path:
#
#   * Nim   -- `src/Tuprules.tup:72-88` passes `--path:$(ROOT)/../<sibling>/src`
#              unconditionally, and `config.nims` adds the same directories
#              through `addPathIfDir`.
#   * Cargo -- `src/db-backend/Cargo.toml` declares `path = "../../../
#              codetracer-trace-format/<crate>"` dependencies.
#   * cc    -- `src/db-backend/build.rs` compiles the Nim MCR emulator out of
#              `../../../codetracer-native-recorder/ct_emulator`.
#
# None of those three fails usefully when the directory is simply absent:
#
#   * `nim --path:<missing dir>` is silently ignored. The build proceeds for
#     minutes and then dies on `cannot open file: shm_gset/transport` -- naming
#     a MODULE, not the repo that was supposed to provide it.
#     `config.nims:74-77` already documents that exact symptom.
#   * `addPathIfDir` drops the entry by design, producing the same class of
#     late, misattributed error.
#   * `build.rs` used to print one easily-missed `cargo:warning` and skip its
#     `cargo:rustc-link-lib` emit, which turned into 81 undefined `mcr*`
#     symbols at the final link step. (It now panics; see build.rs.)
#
# Every one of those failures reads as "the source is broken" when the real
# cause is "the workspace is incomplete". This check exists to say so at the
# point where it is still cheap to act on. It does not, and cannot, fetch the
# missing repos -- that is `repro ws enable` / `git clone`.
#
# Relationship to `scripts/detect-siblings.sh`: that script is ADVISORY and
# covers a DISJOINT set of repos -- the RUNTIME recorder siblings (`ct-mcr`,
# the ruby/js/php/blockchain recorders, `nargo`, ...) whose absence only makes
# tests skip. It is never called by the build scripts. The repos listed below
# are the BUILD-TIME source siblings: without them nothing compiles at all.
# Keep the two lists separate for that reason; a repo that appears in both is
# listed here only for what the *build* needs from it.
#
# Run:  bash scripts/require-siblings.sh [REPO_ROOT]
# Lane: called by scripts/build-once.sh before any other build step (including
#       build-tailwind.sh, which itself extracts over isonim's sources), so it
#       runs in every job that builds the frontend -- `just build-once`,
#       `just build`, `dev-build`, `cross-process-linux`.
#
# Escape hatch: CODETRACER_SKIP_SIBLING_CHECK=1 bypasses the whole check, for
# exotic layouts (vendored source trees, Nix builds that pre-stage the paths)
# where the relative-path assumption does not hold.
#
# See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
# =============================================================================
set -euo pipefail

if [ -n "${CODETRACER_SKIP_SIBLING_CHECK:-}" ]; then
	exit 0
fi

repo_root="${1:-}"
if [ -z "$repo_root" ]; then
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
workspace_root="$(cd "$repo_root/.." && pwd)"

# The remote every sibling below lives on. Kept as one variable so a fork /
# mirror only has to be changed in one place.
sibling_remote_org="${CODETRACER_SIBLING_REMOTE_ORG:-https://github.com/metacraft-labs}"

# -----------------------------------------------------------------------------
# The tables.
#
#   <repo name>|<probe path, relative to the repo>|<override env vars>|<what breaks>
#
# The probe is a file (not just the directory) wherever one exists, so a repo
# that was cloned but whose submodules/LFS objects never landed is caught too.
#
# The override env vars are the ones the BUILD ALREADY READS (`config.nims`
# lines 52-80, `scripts/detect-siblings.sh`) -- this script deliberately
# invents no new names. Empty means "no override exists; the relative path is
# the only way in".
#
# ## Why two tiers, and how membership was decided
#
# A preflight that fails a build which would otherwise have SUCCEEDED is worse
# than no preflight at all, so "required" is not a judgement call here. It is
# the set that CI already treats as mandatory -- the repos cloned by
# `.github/actions/setup-db-backend-siblings` (codetracer-trace-format,
# codetracer-trace-format-nim, codetracer-native-recorder) and by
# `.github/actions/setup-isonim-siblings` (isonim, nim-everywhere, nim-acp,
# nim-agent-harbor, nim-agents) -- intersected with what a build here has
# actually been observed to need.
#
# `runquota` was added to that tier after issue #641. `src/ct/codetracer.nim`
# imports `../ct_test/ct_test`, which reaches `src/ct_test/process_exec.nim` ->
# `import runquota_process`, so every `ct` build needs it somehow.
#
# The two build drivers get it from different places, and that is the whole
# reason this entry is worded the way it is:
#
#   * tup (the Linux default) takes its Nim search path from
#     `src/Tuprules.tup`'s NIM_REPO_PATH_FLAGS, whose runquota entries are
#     `$(ROOT)/../runquota/...`. Tup also sanitizes the environment down to that
#     file's `export` list, which does NOT name RUNQUOTA_SRC. On this driver the
#     sibling checkout is the ONLY way in.
#   * reprobuild (Darwin/Windows, opt-in on Linux) resolves runquota as a nix
#     flake input, with RUNQUOTA_SRC as its repo-path alias (`repro.nim`'s
#     CodeTracerNixSiblingInputs / CodeTracerRepoEnvAliases). This driver does
#     not strictly need a checkout at all.
#
# The override column is nonetheless left EMPTY, i.e. the checkout is required
# on both drivers. Honouring RUNQUOTA_SRC here would make this check pass on the
# strength of a variable tup strips, and hand the tup lane back precisely the
# `cannot open file: runquota_process` that this entry exists to pre-empt --
# a false green on the one driver that actually needed the warning. Requiring
# the checkout keeps ONE workspace-completeness rule that holds on every driver,
# which is also how every other `--path` sibling in NIM_REPO_PATH_FLAGS is
# handled. The cost is that a reprobuild-only build now wants a checkout it
# could have done without; CODETRACER_SKIP_SIBLING_CHECK=1 is the escape hatch.
#
# All four jobs that reach `just build-once` (visual-replay-regression-gate,
# test-ui-tests, viewmodel-tests, cross-process-linux) provision it in
# .github/workflows/codetracer.yml.
#
# Everything else the source references across a relative path goes in the
# advisory tier: a warning naming the module that will fail to resolve, and a
# zero exit. `isonim-tui` / `isonim-gpui` / `nim-termctl` / `nim-pty` are on
# `src/Tuprules.tup`'s `--path` list but builds succeed without them, and the
# io-mon family (io-mon, nim-stackable-hooks, nim-shm-queue, nim-shm-gset) is
# reached from `src/ct_test/incremental/*` yet is NOT provisioned by any CI
# job -- promoting either group would break lanes that are green today.
#
# CODETRACER_STRICT_SIBLING_CHECK=1 promotes the advisory tier to required,
# for a lane that means to assert a complete workspace.
# -----------------------------------------------------------------------------
required_siblings=(
	'isonim|src/isonim.nim|ISONIM_SRC|the reactive UI framework the whole renderer is written against (223 `import isonim/...` sites); also the source `build-tailwind.sh` extracts utility classes from'
	'nim-agents|src/nim_agents.nim||`import nim_agents` in src/frontend/viewmodel/agent_service.nim and the agentic-session UI'
	"nim-agent-harbor|src/nim_agent_harbor.nim||the session/worktree backend nim_agents is written against; passed unconditionally by src/Tuprules.tup:79"
	"nim-acp|src||the Agent Client Protocol bindings src/Tuprules.tup:78 puts on the Nim search path"
	"nim-everywhere|src||the patched Nim 2.x distribution src/Tuprules.tup:77 puts on the Nim search path"
	'codetracer-trace-format-nim|src/codetracer_ct_print_lib.nim|CODETRACER_TRACE_FORMAT_NIM_SRC|`ct print` (src/ct/cli/print_trace.nim) imports codetracer_trace_writer/* and codetracer_ct_print_lib'
	'codetracer-trace-format|codetracer_trace_types/Cargo.toml||five `path = "../../../codetracer-trace-format/..."` dependencies in src/db-backend/Cargo.toml; cargo cannot even parse the manifest without them'
	'codetracer-native-recorder|ct_emulator/src/ct_emulator/emulator_wasm_api.nim|CT_CODETRACER_NATIVE_RECORDER_SIBLING|src/db-backend/build.rs compiles the Nim MCR emulator from ct_emulator/ and links it as lib${CT_MCR_EMULATOR_LINK_NAME}.so; without it the db-backend link fails with 81 undefined `mcr*` symbols'
	# Override column deliberately empty -- see the RUNQUOTA_SRC discussion in
	# the tier notes above. Accepting the env var here would green this check on
	# the tup driver, which strips it.
	'runquota|libs/runquota_process/src/runquota_process.nim||`import runquota_process` in src/ct_test/process_exec.nim, reached from EVERY `ct` build via src/ct/codetracer.nim -> ../ct_test/ct_test; src/Tuprules.tup puts libs/runquota_*/src on the Nim search path'
)

advisory_siblings=(
	# Probe the FORMAT module, not the `io_mon` umbrella -- the umbrella is a
	# false green. Nothing in this repo imports `io_mon`: the only io-mon
	# imports are `io_mon/depfile` (io_mon_capture.nim:83 and the two
	# test_io_mon_* modules beside it), and io_mon_capture.nim:83 says in so
	# many words why it must stay off the umbrella (fs_snoop's by-value
	# `=destroy`, which the refc `ct` build rejects).
	#
	# The distinction is not cosmetic. `src/io_mon.nim` has existed in io-mon
	# forever; `src/io_mon/depfile.nim` only since io-mon cfd2514 (2026-08-27).
	# A pin older than that satisfies the umbrella probe, so this tier stayed
	# SILENT and the missing module surfaced instead as
	# `cannot open file: io_mon/depfile` from the Nim compiler, ~2000 lines
	# into the build -- which is exactly how the published workspace lock for
	# codetracer 0039436d (io-mon pinned at 8b6d0b9b, 2026-07-31) shipped a
	# tree that could not build `ct`. Probing the module the source actually
	# imports turns that into this warning, by name, before any compile.
	'io-mon|src/io_mon/depfile.nim|IO_MON_SRC|`import io_mon/depfile` in src/ct_test/incremental/{io_mon_capture,test_io_mon_launched_binaries,test_io_mon_readfiles_materialized}.nim, reached from `ct` via src/ct_test/incremental_cli:78'
	'nim-stackable-hooks|src/stackable_hooks.nim|NIM_STACKABLE_HOOKS_SRC|`import stackable_hooks/propagation` in src/ct_test/incremental/io_mon_capture.nim'
	"nim-shm-queue|src/shm_queue.nim|SHM_QUEUE_SRC|io-mon's dependency queue imports \`shm_queue\`"
	"nim-shm-gset|src/shm_gset.nim|SHM_GSET_SRC|io-mon's writer imports \`shm_gset/transport\` (the symptom config.nims:74-77 documents)"
	"isonim-tui|src||src/Tuprules.tup:73 puts it on the Nim search path"
	"isonim-gpui|src||src/Tuprules.tup:74 puts it on the Nim search path"
	"nim-termctl|src||src/Tuprules.tup:75 puts it on the Nim search path"
	"nim-pty|src||src/Tuprules.tup:76 puts it on the Nim search path"
)

if [ -n "${CODETRACER_STRICT_SIBLING_CHECK:-}" ]; then
	required_siblings+=("${advisory_siblings[@]}")
	advisory_siblings=()
fi

# True when \$1 resolves the sibling identified by the probe \$2.
#
# The override vars are consumed by config.nims as MODULE DIRECTORIES
# (\`ISONIM_SRC=<repo>/src\`), while CT_CODETRACER_NATIVE_RECORDER_SIBLING names
# a REPO ROOT. Accept either shape rather than forcing callers to know which
# convention a given var follows: probe the path as given, and -- when the
# table's probe is itself under \`src/\` -- also probe it with that prefix
# stripped, which is exactly the module-directory case.
sibling_dir_has_probe() {
	local dir="$1" probe="$2"
	if [ -z "$dir" ]; then
		return 1
	fi
	if [ -e "$dir/$probe" ]; then
		return 0
	fi
	case "$probe" in
	src/*)
		if [ -e "$dir/${probe#src/}" ]; then
			return 0
		fi
		;;
	esac
	return 1
}

# Resolve one sibling. Echoes the resolved directory on success; echoes
# nothing and returns 1 when neither an override nor the workspace sibling
# holds the probe.
resolve_sibling() {
	local name="$1" probe="$2" overrides="$3"
	local override_var override_dir candidate

	# Overrides first: an explicit path is a deliberate choice and must win
	# over an incidental workspace checkout of the same name.
	if [ -n "$overrides" ]; then
		while IFS= read -r override_var; do
			[ -n "$override_var" ] || continue
			override_dir="${!override_var:-}"
			if sibling_dir_has_probe "$override_dir" "$probe"; then
				printf '%s' "$override_dir"
				return 0
			fi
		done < <(printf '%s\n' "${overrides//,/$'\n'}")
	fi

	candidate="$workspace_root/$name"
	if sibling_dir_has_probe "$candidate" "$probe"; then
		printf '%s' "$candidate"
		return 0
	fi
	return 1
}

missing_names=()
missing_report=""

describe_missing() {
	local name="$1" probe="$2" overrides="$3" reason="$4"
	missing_report="${missing_report}  * ${name}"$'\n'
	missing_report="${missing_report}      expected:  ${workspace_root}/${name}/${probe}"$'\n'
	if [ -d "$workspace_root/$name" ]; then
		missing_report="${missing_report}      state:     the directory EXISTS but does not contain that file --"$'\n'
		missing_report="${missing_report}                 an incomplete clone, a wrong branch, or missing submodules."$'\n'
	else
		missing_report="${missing_report}      state:     not checked out"$'\n'
	fi
	if [ -n "$overrides" ]; then
		missing_report="${missing_report}      override:  ${overrides//,/ or }"$'\n'
	fi
	missing_report="${missing_report}      needed by: ${reason}"$'\n'
}

for row in "${required_siblings[@]}"; do
	IFS='|' read -r name probe overrides reason <<<"$row"
	if resolve_sibling "$name" "$probe" "$overrides" >/dev/null; then
		continue
	fi
	missing_names+=("$name")
	describe_missing "$name" "$probe" "$overrides" "$reason"
done

# Advisory tier: name what will fail to resolve, and let the build proceed.
# Anything here is something a build has been observed to survive without.
advisory_missing=()
for row in ${advisory_siblings[@]+"${advisory_siblings[@]}"}; do
	IFS='|' read -r name probe overrides reason <<<"$row"
	if resolve_sibling "$name" "$probe" "$overrides" >/dev/null; then
		continue
	fi
	advisory_missing+=("  * ${name}  -- ${reason}")
done

if [ ${#advisory_missing[@]} -gt 0 ]; then
	{
		echo "scripts/require-siblings.sh: ${#advisory_missing[@]} optional sibling repo(s) are missing."
		printf '%s\n' "${advisory_missing[@]}"
		echo '  The build continues. If it later fails with `cannot open file: <module>`,'
		echo "  one of these is why -- clone it under $workspace_root, or re-run with"
		echo "  CODETRACER_STRICT_SIBLING_CHECK=1 to make this a hard failure."
	} >&2
fi

if [ ${#missing_names[@]} -eq 0 ]; then
	exit 0
fi

{
	echo "Cannot start the CodeTracer build: ${#missing_names[@]} required sibling repo(s) are missing."
	echo
	echo "  workspace root: $workspace_root"
	echo "  this repo:      $repo_root"
	echo
	printf '%s' "$missing_report"
	echo "Fix it by completing the workspace. Either let reprobuild converge it:"
	echo
	echo "    cd $workspace_root && repro ws enable codetracer"
	echo
	echo "or clone the missing repos by hand:"
	echo
	for name in "${missing_names[@]}"; do
		echo "    git clone $sibling_remote_org/$name $workspace_root/$name"
	done
	echo
	cat <<'EOF'
Why this is checked here rather than left to the compiler: `nim` SILENTLY
IGNORES a `--path` that does not exist, and `config.nims`' `addPathIfDir`
drops it by design. The build would otherwise run for minutes and then fail
with `cannot open file: <module>` -- naming a module rather than the repo
that was meant to provide it. The cargo and build.rs paths degrade the same
way, into `failed to load manifest` and undefined `mcr*` symbols.

If your layout genuinely does not put these repos next to this one (a
vendored source tree, a Nix build that pre-stages the paths), set the
per-repo override shown above, or bypass the whole check with
CODETRACER_SKIP_SIBLING_CHECK=1.
EOF
} >&2
exit 1
