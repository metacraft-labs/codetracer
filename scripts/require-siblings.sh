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
# where the relative-path assumption does not hold. It is NOT the answer to a
# misplaced worktree -- see the `misplaced worktree` section below, which is the
# one case where this script keeps talking even when the hatch is set.
#
# See: codetracer-specs/Working-with-the-CodeTracer-Repos.md
#      AGENTS.md -- its opening section, on where a checkout or worktree has to live
# =============================================================================
set -euo pipefail

repo_root="${1:-}"
if [ -z "$repo_root" ]; then
	repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
workspace_root="$(cd "$repo_root/.." && pwd)"

# -----------------------------------------------------------------------------
# The misplaced-worktree case.
#
# `workspace_root` is the checkout's PARENT, and that is not an accident this
# script could route around: `config.nims` (`repoRoot.parentDir()`),
# `src/Tuprules.tup` (`$(ROOT)/../<sibling>`), `src/db-backend/Cargo.toml`
# (`path = "../../../..."`), `build.rs` and `.envrc` all reach siblings by the
# same relative path. The parent directory of a checkout IS the workspace root,
# for four independent resolvers, and only one of them reads anything this
# script could set.
#
# So a `git worktree` has to be created BESIDE the sibling repos -- directly
# under the workspace root -- exactly like the main checkout. A worktree made in
# a subdirectory (`<workspace>/.agent-wt/<name>` is the one that keeps happening)
# has that subdirectory as its parent, finds no siblings there, and produces a
# missing-sibling report that reads as a broken or half-cloned workspace. It is
# neither: the repos are all present, one directory further up.
#
# This is worth detecting SPECIFICALLY because the generic remedies below are
# actively wrong for it -- `repro ws enable` / `git clone` into the parent would
# build a SECOND workspace inside a scratch directory, cloning gigabytes to
# duplicate repos that are already on disk, and would then drift from the real
# one. The remedy is to move the worktree, and nothing else.
#
# `main_workspace_root` answers "where does the main checkout of this repo
# live?". For a linked worktree, `--git-common-dir` is the MAIN checkout's
# `.git`, so its grandparent is the true workspace root. Empty when this is not
# a linked worktree (or when git cannot answer), in which case none of the
# messages below fire and the generic report stands.
# -----------------------------------------------------------------------------
main_workspace_root=""
main_repo_name=""
# What the worktree test actually READ, kept so the diagnostics below can print
# their inputs rather than only their verdict. `worktree_test_note` records why
# the test came out negative, for the near-miss report.
git_common_dir_value=""
main_repo_root_value=""
worktree_test_note="git is unavailable, so the worktree test did not run"
detect_main_workspace_root() {
	local common_dir main_repo_root
	command -v git >/dev/null 2>&1 || return 0
	worktree_test_note='`git rev-parse --git-common-dir` gave no answer here (not a git checkout?)'
	common_dir="$(cd "$repo_root" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 0
	[ -n "$common_dir" ] || return 0
	case "$common_dir" in
	/*) ;;
	*) common_dir="$repo_root/$common_dir" ;;
	esac
	common_dir="$(cd "$common_dir" 2>/dev/null && pwd)" || return 0
	git_common_dir_value="$common_dir"
	main_repo_root="$(cd "$common_dir/.." 2>/dev/null && pwd)" || return 0
	main_repo_root_value="$main_repo_root"
	worktree_test_note="this IS the main checkout ($main_repo_root), not a linked worktree"
	# Same directory => this IS the main checkout, not a linked worktree.
	[ "$main_repo_root" != "$repo_root" ] || return 0
	main_workspace_root="$(cd "$main_repo_root/.." 2>/dev/null && pwd)" || return 0
	main_repo_name="${main_repo_root##*/}"
	# A worktree that is already beside the siblings is correctly placed.
	if [ "$main_workspace_root" = "$workspace_root" ]; then
		worktree_test_note="this is a linked worktree, but it is ALREADY beside the siblings ($workspace_root)"
		main_workspace_root=""
		main_repo_name=""
	else
		worktree_test_note=""
	fi
}
detect_main_workspace_root

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
	'isonim|src/isonim.nim|ISONIM_SRC|the reactive UI framework the whole renderer is written against — hundreds of `import isonim/...` sites across the frontend; count them with: grep -rl "import isonim/" --include=*.nim src | wc -l . Also the source `build-tailwind.sh` extracts utility classes from'
	'nim-agents|src/nim_agents.nim||`import nim_agents` in src/frontend/viewmodel/agent_service.nim and the agentic-session UI'
	"nim-agent-harbor|src/nim_agent_harbor.nim||the session/worktree backend nim_agents is written against; passed unconditionally by src/Tuprules.tup:79"
	"nim-acp|src||the Agent Client Protocol bindings src/Tuprules.tup:78 puts on the Nim search path"
	"nim-everywhere|src||the patched Nim 2.x distribution src/Tuprules.tup:77 puts on the Nim search path"
	'codetracer-trace-format-nim|src/codetracer_ct_print_lib.nim|CODETRACER_TRACE_FORMAT_NIM_SRC|`ct print` (src/ct/cli/print_trace.nim) imports codetracer_trace_writer/* and codetracer_ct_print_lib'
	'codetracer-trace-format|codetracer_trace_types/Cargo.toml||every `path = "../../../codetracer-trace-format/..."` dependency in src/db-backend/Cargo.toml resolves through it (grep -c that path in the manifest for how many); cargo cannot even parse the manifest without them'
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
missing_rows=()
missing_report=""

# The verdict below is a CONJUNCTION -- this checkout is a linked worktree whose
# main checkout lives elsewhere, AND every sibling missing from this parent is
# present under that other workspace root. A conjunction that reports only its
# verdict is the kind of instrument nobody can falsify, so this pass records
# WHICH HALF HELD, per sibling, and every report below prints the paths it
# probed rather than asserting a conclusion about them.
#
# ALL rather than ANY is deliberate: if even one sibling is missing from the
# real workspace too, the workspace is genuinely incomplete and the generic
# report is the honest one. The partial case still gets a note -- see
# `report_partial_misplacement` -- because silence there would be the same
# unfalsifiable failure in the other direction.
mw_present=() # "name|probe" found under the main workspace root
mw_absent=()  # "name|probe" missing there too
classify_missing_against_workspace() {
	local row name probe
	mw_present=()
	mw_absent=()
	[ -n "$main_workspace_root" ] || return 0
	[ ${#missing_rows[@]} -gt 0 ] || return 0
	for row in "${missing_rows[@]}"; do
		IFS='|' read -r name probe _ _ <<<"$row"
		if sibling_dir_has_probe "$main_workspace_root/$name" "$probe"; then
			mw_present+=("$name|$probe")
		else
			mw_absent+=("$name|$probe")
		fi
	done
}

misplacement_explains_everything() {
	[ -n "$main_workspace_root" ] || return 1
	[ ${#mw_present[@]} -gt 0 ] || return 1
	[ ${#mw_absent[@]} -eq 0 ] || return 1
	return 0
}

# The evidence block. Printed by BOTH the full and the partial report, so the
# reader always sees the two paths that were compared for each repo -- the one
# that was not there, and the one that was.
print_measured_siblings() {
	local entry name probe
	echo "  measured -- each sibling missing from this parent, re-probed under the workspace:"
	for entry in ${mw_present[@]+"${mw_present[@]}"}; do
		IFS='|' read -r name probe <<<"$entry"
		echo "    * $name  -- FOUND up there"
		echo "        not here: $workspace_root/$name/$probe"
		echo "        found:    $main_workspace_root/$name/$probe"
	done
	for entry in ${mw_absent[@]+"${mw_absent[@]}"}; do
		IFS='|' read -r name probe <<<"$entry"
		echo "    * $name  -- ALSO MISSING up there"
		echo "        not here: $workspace_root/$name/$probe"
		echo "        nor:      $main_workspace_root/$name/$probe"
	done
	echo
	echo "  worktree test:  git rev-parse --git-common-dir  (run in $repo_root)"
	echo "                  -> $git_common_dir_value"
	echo "                  whose checkout is $main_repo_root_value,"
	echo "                  which is not this directory, so this is a LINKED WORKTREE."
	echo
}

# The near miss. Reached when this IS a misplaced worktree but the workspace it
# came from is itself incomplete, so moving the worktree alone will not fix the
# build. Both facts are true and the reader needs both; printing only the
# generic report here would hide the location half entirely.
report_partial_misplacement() {
	cat <<EOF

NOTE -- BOTH THINGS ARE TRUE HERE, and neither alone is the whole fix.

  this worktree:  $repo_root
  its parent:     $workspace_root
  the workspace:  $main_workspace_root

${#mw_present[@]} of the ${#missing_names[@]} missing repo(s) ARE present under the workspace root, so this
checkout is a worktree outside the workspace and moving it is part of the fix
(see AGENTS.md -- its opening section, on where a checkout or worktree has to live). But
${#mw_absent[@]} of them cannot be found there either, so that workspace is genuinely
incomplete and the remedies above are needed as well -- run them against
$main_workspace_root, NOT against $workspace_root.

EOF
	print_measured_siblings
}

# The one diagnostic this script exists to add: name the location, not the
# repos. Printed on failure, and also on the CODETRACER_SKIP_SIBLING_CHECK path,
# where suppressing it would hand the caller the opaque late failure the hatch
# is usually reached for in the first place.
report_misplaced_worktree() {
	local worktree_name="${repo_root##*/}"
	cat <<EOF
THIS IS A WORKTREE IN THE WRONG PLACE. It is not a broken or half-cloned
checkout: all ${#missing_names[@]} of the repos named above are present, one directory further up.

  this worktree:  $repo_root
  its parent:     $workspace_root
                  ^ searched for siblings, because this is where the build looks
  the workspace:  $main_workspace_root
                  ^ where the main checkout and every sibling actually are

EOF
	print_measured_siblings
	cat <<EOF
A checkout of this repo -- INCLUDING A WORKTREE -- must sit directly under the
workspace root, beside the sibling repos. The parent directory of a checkout is
the workspace root by definition for four independent resolvers, none of which
can be redirected per-worktree: Nim (\`config.nims\`, \`src/Tuprules.tup\`), Cargo
(\`src/db-backend/Cargo.toml\` path dependencies), cc (\`src/db-backend/build.rs\`)
and direnv (\`.envrc\`). Moving the worktree is the only thing that fixes all four.

Move this one:

    git worktree move $repo_root \\
        $main_workspace_root/$worktree_name

or create the next one in the right place to begin with:

    git -C $main_workspace_root/$main_repo_name worktree add \\
        $main_workspace_root/<name> <branch>

Do NOT reach for CODETRACER_SKIP_SIBLING_CHECK=1 here, and do NOT clone the
siblings into $workspace_root.
The first only deletes this message -- the build still cannot see the siblings,
and fails minutes later naming a MODULE (\`cannot open file: runquota_process\`)
rather than the location. The second builds a second workspace inside a scratch
directory, duplicating repos that are already on disk and free to drift from them.

See AGENTS.md -- its opening section, on where a checkout or worktree has to live.
EOF
}

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
	missing_rows+=("$row")
	describe_missing "$name" "$probe" "$overrides" "$reason"
done

# Classify once, so every report below prints the same measurements.
classify_missing_against_workspace

# The escape hatch is honoured HERE rather than at the top of the script, so
# that the one diagnosis it cannot help with still gets said. A misplaced
# worktree is precisely the case where setting this variable converts a clear
# failure into `cannot open file: <module>` several minutes later -- the exact
# outcome the whole file exists to prevent -- so it warns and continues to exit
# 0. Every other layout the hatch is meant for stays silent, as before.
if [ -n "${CODETRACER_SKIP_SIBLING_CHECK:-}" ]; then
	if [ ${#missing_names[@]} -gt 0 ] && misplacement_explains_everything; then
		{
			echo "CODETRACER_SKIP_SIBLING_CHECK=1 is set, so this is a WARNING and the build continues."
			echo "It will not succeed. Read this anyway:"
			echo
			printf '%s' "$missing_report"
			report_misplaced_worktree
		} >&2
	fi
	exit 0
fi

# -----------------------------------------------------------------------------
# Was the dev shell ever entered HERE?
#
# This file's whole subject is "the workspace is incomplete, and the compiler
# will misattribute that later". A fresh `git worktree` is incomplete in a
# SECOND way that produces the same class of misattribution, and it is not about
# siblings at all:
#
#   * `.envrc` is what runs `git submodule update --init --recursive`, and it is
#     blocked per-directory until `direnv allow` is run there. A worktree it has
#     never run in has NO initialised submodules, so `libs/*` are empty
#     directories and the build dies on `cannot open file: <module>` -- the
#     exact symptom, and the exact misattribution, that the sibling tables above
#     exist to pre-empt.
#   * `.pre-commit-config.yaml` is a devshell-GENERATED SYMLINK into /nix/store
#     rather than a tracked file, so it is absent too, and `git commit` behaves
#     differently here than in the main checkout.
#
# Both were MEASURED in a fresh worktree of this repository: before
# `direnv allow`, `git submodule status` prefixed every entry with `-` and
# `.pre-commit-config.yaml` did not exist; after it, both were in place.
#
# The check itself lives in `scripts/toolchain-pins.sh --devshell-init`, because
# the question it answers -- "did the environment that answers `nim` actually
# initialise in this directory?" -- is that guard's subject, and one
# implementation is better than two that can drift. This is the call site,
# because this is the script every build driver already runs first.
#
# SEVERITY IS SPLIT, deliberately, and along the line this file already draws:
# a build that fails BECAUSE of the preflight is worse than no preflight, so
# only the condition that genuinely stops a build is hard. Uninitialised
# submodules stop it. A missing pre-commit symlink does not, so it warns.
devshell_guard="$repo_root/scripts/toolchain-pins.sh"
if [ -f "$devshell_guard" ]; then
	devshell_report=""
	devshell_rc=0
	devshell_report="$(bash "$devshell_guard" --devshell-init 2>&1)" || devshell_rc=$?
	if [ "$devshell_rc" -ne 0 ]; then
		# Ask the one question that decides severity here rather than trusting
		# the delegate's single exit code to mean the same thing forever.
		uninit_submodules=0
		if command -v git >/dev/null 2>&1; then
			# `grep -c` PRINTS 0 and EXITS 1 when nothing matches -- the same
			# trap ci/test/renderer-pane-parity.sh's `in_bundle` documents. Under
			# this file's `set -euo pipefail` (line 62) `pipefail` propagates that
			# 1 out of the pipeline and `-e` then kills the SCRIPT, at an
			# assignment, before a single line of the report below is printed.
			#
			# That is not a hypothetical. It took out `launcher-recorder-e2e
			# (desktop edge)`: every arm reported only
			#
			#   bash scripts/build-once.sh
			#   error: Recipe `build-once` failed on line 5 with exit code 1
			#
			# 0.45s apart with NOTHING in between, and the several-hundred-line
			# "N required sibling repo(s) are missing" report that the same run
			# printed a day earlier had simply vanished from the log. A CI
			# checkout is precisely the case that triggers it: actions/checkout
			# lands the submodules, so the count is zero, so `grep -c` fails --
			# a guard that goes silent exactly when the thing it guards is
			# healthy, while some OTHER precondition is the real failure.
			#
			# Capture, then default only if the capture is genuinely empty; a
			# trailing `|| echo 0` would emit "0\n0" and break the comparison.
			uninit_submodules="$(git -C "$repo_root" submodule status 2>/dev/null | grep -c '^-' | tr -d ' ')" || true
			[ -n "$uninit_submodules" ] || uninit_submodules=0
		fi
		if [ "${uninit_submodules:-0}" -gt 0 ]; then
			{
				echo "Cannot start the CodeTracer build: the dev shell has never initialised this checkout."
				echo
				printf '%s\n' "$devshell_report"
				echo
				echo "  this repo: $repo_root"
				echo
				echo "$uninit_submodules submodule(s) are uninitialised, and the Nim build resolves"
				echo "libs/* through them. It would run for minutes and then fail with"
				echo '`cannot open file: <module>`, naming a module rather than this cause --'
				echo "which is the same misattribution the sibling check above exists to prevent."
				echo
				echo "    cd $repo_root && direnv allow"
				echo
				echo "or, without direnv:"
				echo
				echo "    git -C $repo_root submodule update --init --recursive"
				echo
				echo "CODETRACER_SKIP_SIBLING_CHECK=1 bypasses this along with everything else"
				echo "above, and the build will still not succeed."
			} >&2
			exit 1
		fi
		{
			echo "scripts/require-siblings.sh: the dev shell has not fully initialised this checkout."
			printf '%s\n' "$devshell_report"
			echo "  The BUILD continues -- nothing above stops a compile. Commits made from"
			echo "  here will not run the same hooks as the main checkout."
			echo "  remedy: cd $repo_root && direnv allow"
		} >&2
	fi
else
	# Say so rather than pass silently. A delegated check whose delegate is
	# missing is an unrun check, and an unrun check that reports nothing is
	# indistinguishable from one that found nothing.
	echo "scripts/require-siblings.sh: NOTE -- $devshell_guard is absent, so the" >&2
	echo "  dev-shell-initialisation check did NOT run. Uninitialised submodules in a" >&2
	echo '  fresh worktree will surface later as `cannot open file: <module>`.' >&2
fi

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
		if [ -n "$main_workspace_root" ]; then
			# A linked worktree outside the workspace. Cloning into this parent
			# is the wrong advice here for the same reason as below, so give the
			# location first and let the hard failure (if any) spell it out.
			echo "  one of these is why. NOTE this checkout is a worktree at"
			echo "  $repo_root, outside the workspace at"
			echo "  $main_workspace_root -- if these siblings are"
			echo "  present there, MOVE THE WORKTREE rather than cloning them again here."
		else
			echo "  one of these is why -- clone it under $workspace_root, or re-run with"
			echo "  CODETRACER_STRICT_SIBLING_CHECK=1 to make this a hard failure."
		fi
	} >&2
fi

if [ ${#missing_names[@]} -eq 0 ]; then
	exit 0
fi

if misplacement_explains_everything; then
	# The workspace is complete; this checkout is outside it. Say THAT, and do
	# not print the generic remedies -- `repro ws enable` and `git clone` into
	# this parent directory would both make the situation worse, by building a
	# duplicate workspace around a worktree that only needs to be moved.
	{
		echo "Cannot start the CodeTracer build: ${#missing_names[@]} required sibling repo(s) are missing from"
		echo "this checkout's parent directory."
		echo
		printf '%s' "$missing_report"
		report_misplaced_worktree
	} >&2
	exit 1
fi

# Where the remedies below should be RUN. Normally this checkout's parent, which
# is the workspace. But in the near-miss case -- a misplaced worktree whose real
# workspace is itself incomplete -- cloning into this parent would still be
# building a duplicate workspace in the wrong place, so the commands are aimed at
# the real one and `report_partial_misplacement` explains why.
remedy_root="$workspace_root"
if [ -n "$main_workspace_root" ] && [ ${#mw_present[@]} -gt 0 ]; then
	remedy_root="$main_workspace_root"
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
	echo "    cd $remedy_root && repro ws enable codetracer"
	echo
	echo "or clone the missing repos by hand:"
	echo
	for name in "${missing_names[@]}"; do
		echo "    git clone $sibling_remote_org/$name $remedy_root/$name"
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
	# Say why the misplaced-worktree diagnosis did NOT fire, so a negative
	# verdict is as checkable as a positive one. Exactly one of these two runs:
	# `worktree_test_note` is set when the location test itself came out
	# negative, and empty when it came out positive -- in which case this is the
	# near miss, and the sibling half is what did not hold.
	if [ -n "$worktree_test_note" ]; then
		echo
		echo "Not reported as a misplaced worktree, because $worktree_test_note."
	else
		report_partial_misplacement
	fi
} >&2
exit 1
