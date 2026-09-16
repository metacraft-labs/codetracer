# shellcheck shell=bash
#
# wasm-engine-freshness.sh — assert that the db-backend WASM replay engine on
# disk was built FROM THE SOURCES IN THIS TREE, not merely that a .wasm exists.
#
# WHY THIS EXISTS
# ---------------
# `src/db-backend/wasm-testing/pkg/` is a build output. It is gitignored
# (`.gitignore`: `*.wasm`, and `browser-replay/.gitignore`: `dist/`), so it is
# never checked in, never updated by `git pull`, and never noticed when it goes
# stale. It survives every branch switch, every rebase and every worktree
# `cp`, because nothing in git's model touches it.
#
# The gates that read it asked "is there a .wasm, and is it bigger than a
# megabyte?". That is an EXISTENCE check standing in for a FRESHNESS check —
# the same substitution catalogued for three other clusters in 464b8f296
# ("Every site here asked 'does this artefact exist?' where it needed to ask
# 'is this artefact of THIS source?'").
#
# MEASURED, not hypothesised. On 2026-09-06, in a worktree checked out at
# origin/dev (1006b5ab1) with the engine from 2026-08-31 09:30 copied in —
# 42 commits to src/db-backend later, and a binary differing from the current
# tree's by 79,304 bytes — `ci/test/worker-backend-wasm-e2e.sh` reported:
#
#     worker/WASM e2e: 19 passed, 0 failed
#     === e2e OK ===
#
# Nineteen assertions about a replay engine, all green, none of them about the
# engine in the tree. That is the reason this file exists.
#
# WHY NOT MTIME
# -------------
# The obvious check — "is the .wasm newer than the newest source?" — is the one
# to avoid, and blocktracer 6f106f2 paid for the lesson: a bundle's mtime is not
# when it was built. A build that emits unchanged bytes may not rewrite the
# output file at all, so the artefact keeps its old mtime through a complete,
# successful build. The gate then fires on a tree that has just built
# correctly, and the remedy it prints — "rebuild" — cannot clear it. In that
# gate's own words: a gate whose own remedy cannot clear it is not a gate, it
# is a wall.
#
# So this file compares CONTENT, and the artefact carries a stamp of the
# content it was built from:
#
#   * `build_wasm.sh` writes `pkg/.engine-stamp` as its last act, recording
#     the digest of the inputs it built from and the sha256 of the .wasm it
#     produced.
#   * A gate recomputes the input digest from the tree it is standing in and
#     compares. It also checks the recorded sha256 against the .wasm actually
#     on disk, which catches a stamp that has been separated from its binary
#     (copying `pkg/` between worktrees does exactly that).
#
# The remedy therefore ALWAYS clears the gate, including in the byte-identical
# case that defeats mtime: the stamp is rewritten from the current tree on
# every build, whether or not the emitted wasm changed. There is no state in
# which "run the remedy" leaves the assertion still failing.
#
# WHAT IS COVERED, AND WHAT IS NOT
# --------------------------------
# The digest covers the inputs `build_wasm.sh` actually compiles:
#
#   * every file under `src/db-backend/src/`,
#   * `src/db-backend/{Cargo.toml,Cargo.lock,build.rs,build_wasm.sh}`,
#   * every local path-dependency crate named in `src/db-backend/Cargo.toml`,
#     which resolves both the in-repo `src/libs/*` crates and the sibling
#     `codetracer-trace-format/*` crates,
#   * the sibling `codetracer-native-recorder` emulator inputs, whose
#     `build_wasm_api.sh` generates the C that `build.rs` consumes.
#
# A root that is absent digests as the literal string `absent`, so an engine
# built WITH a sibling present and checked WITHOUT it reports a mismatch. That
# is correct: the engine was built from inputs the checker cannot see.
#
# NOT covered: the toolchain (rustc, wasm-pack, clang, the nix shell). A
# toolchain change with identical sources will not be caught here. Say so
# rather than implying total coverage.
#
# USAGE
# -----
#   source ci/lib/wasm-engine-freshness.sh
#   wasm_engine_write_stamp "$REPO_ROOT"     # build_wasm.sh, after wasm-pack
#   wasm_engine_assert_fresh "$REPO_ROOT"    # any gate, before it measures
#
# `wasm_engine_assert_fresh` prints the reason and the remedy and returns 1; it
# does not exit, so callers keep control of their own failure reporting.

# Portable sha256 over stdin. Linux ships `sha256sum`, macOS ships `shasum`.
wasm_engine__sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}

wasm_engine__sha256_file() {
	if [ ! -f "$1" ]; then
		printf 'absent\n'
		return 0
	fi
	wasm_engine__sha256_stdin <"$1"
}

# Emit `<sha256>\t<label>` lines for every file under a directory, with paths
# made relative to that directory so the digest does not depend on where the
# checkout lives. A missing directory emits a single `absent` line, so its
# absence is itself part of the digest.
wasm_engine__digest_tree() {
	local root="$1" label="$2"
	if [ ! -d "$root" ]; then
		printf 'absent\t%s\n' "$label"
		return 0
	fi
	# `sort` before hashing: readdir order is not stable across filesystems,
	# and an unstable order would make the digest differ between two identical
	# trees — a false red, which is the failure mode this file exists to avoid.
	(
		cd "$root" || exit 1
		find . -type f -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' f; do
			printf '%s\t%s/%s\n' "$(wasm_engine__sha256_file "$f")" "$label" "${f#./}"
		done
	)
}

wasm_engine__digest_file() {
	local path="$1" label="$2"
	printf '%s\t%s\n' "$(wasm_engine__sha256_file "$path")" "$label"
}

# Resolve the local `path = "..."` dependencies of src/db-backend/Cargo.toml.
# They are relative to that manifest's directory, and they cover both the
# in-repo crates (`../../libs/...`) and the sibling trace-format crates
# (`../../../codetracer-trace-format/...`).
wasm_engine__local_path_dependencies() {
	local manifest="$1" backend_dir
	backend_dir="$(dirname "$manifest")"
	[ -f "$manifest" ] || return 0
	sed -n 's/.*path *= *"\([^"]*\)".*/\1/p' "$manifest" |
		LC_ALL=C sort -u |
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			printf '%s\n' "$backend_dir/$rel"
		done
}

# The emulator half. `build_wasm.sh` runs
# `codetracer-native-recorder/ct_emulator/build_wasm_api.sh` to regenerate the
# C inputs that `build.rs` compiles, so those Nim sources are build inputs of
# the wasm just as surely as the Rust is.
wasm_engine__native_recorder_modules="ct_emulator ct_time_model ct_events ct_instrument ct_recorder ct_replayer ct_loader"

wasm_engine__digest_native_recorder() {
	local recorder_root="$1" module
	if [ ! -d "$recorder_root" ]; then
		printf 'absent\trecorder\n'
		return 0
	fi
	wasm_engine__digest_file \
		"$recorder_root/ct_emulator/build_wasm_api.sh" "recorder/build_wasm_api.sh"
	for module in $wasm_engine__native_recorder_modules; do
		wasm_engine__digest_tree "$recorder_root/$module/src" "recorder/$module/src"
		# .nimble / .nims sit at the module root, not under src/.
		if [ -d "$recorder_root/$module" ]; then
			find "$recorder_root/$module" -maxdepth 1 -type f \
				\( -name '*.nimble' -o -name '*.nims' \) -print0 |
				LC_ALL=C sort -z | while IFS= read -r -d '' f; do
				wasm_engine__digest_file "$f" "recorder/$module/$(basename "$f")"
			done
		fi
	done
}

# The whole input identity, as one hex digest.
wasm_engine_input_digest() {
	local repo_root="$1"
	local backend="$repo_root/src/db-backend"
	local manifest="$backend/Cargo.toml"
	local workspace_root dep
	workspace_root="$(cd "$repo_root/.." && pwd)"

	{
		wasm_engine__digest_tree "$backend/src" "db-backend/src"
		wasm_engine__digest_file "$manifest" "db-backend/Cargo.toml"
		wasm_engine__digest_file "$backend/Cargo.lock" "db-backend/Cargo.lock"
		wasm_engine__digest_file "$backend/build.rs" "db-backend/build.rs"
		wasm_engine__digest_file "$backend/build_wasm.sh" "db-backend/build_wasm.sh"

		wasm_engine__local_path_dependencies "$manifest" | while IFS= read -r dep; do
			local name
			name="$(basename "$dep")"
			wasm_engine__digest_tree "$dep/src" "dep/$name/src"
			wasm_engine__digest_file "$dep/Cargo.toml" "dep/$name/Cargo.toml"
			wasm_engine__digest_file "$dep/build.rs" "dep/$name/build.rs"
		done

		wasm_engine__digest_native_recorder "$workspace_root/codetracer-native-recorder"
	} | LC_ALL=C sort | wasm_engine__sha256_stdin
}

wasm_engine_pkg_dir() {
	printf '%s/src/db-backend/wasm-testing/pkg\n' "$1"
}

wasm_engine_stamp_path() {
	printf '%s/.engine-stamp\n' "$(wasm_engine_pkg_dir "$1")"
}

# Written by build_wasm.sh as its last act, and copied alongside the engine by
# browser-replay/build-dist.sh.
wasm_engine_write_stamp() {
	local repo_root="$1"
	local pkg
	pkg="$(wasm_engine_pkg_dir "$repo_root")"
	local wasm="$pkg/db_backend_bg.wasm"

	if [ ! -f "$wasm" ]; then
		echo "wasm-engine-freshness: cannot stamp — $wasm does not exist" >&2
		return 1
	fi

	{
		echo "# Written by src/db-backend/build_wasm.sh. Read by"
		echo "# ci/lib/wasm-engine-freshness.sh. Do not edit by hand: the only"
		echo "# way to make this file true again is to rebuild the engine."
		echo "input_digest=$(wasm_engine_input_digest "$repo_root")"
		echo "wasm_sha256=$(wasm_engine__sha256_file "$wasm")"
		echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		echo "built_from=$repo_root"
		echo "git_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
	} >"$pkg/.engine-stamp"

	echo "wasm-engine-freshness: stamped $pkg/.engine-stamp"
}

wasm_engine__stamp_field() {
	sed -n "s/^$2=//p" "$1" | head -1
}

wasm_engine__remedy() {
	printf '  cd %s/src/db-backend && bash build_wasm.sh\n' "$1"
	printf '(add CODETRACER_WASM_BUILD_CLEAN=0 to keep the existing cargo target dir)\n'
}

# The assertion, over an arbitrary directory holding an engine + its stamp.
# `browser-replay/dist/pkg` is a second copy of the artefact, carried there by
# build-dist.sh along with the stamp, so it is checked the same way.
# Returns 0 when the engine in that directory was built from this tree.
wasm_engine_assert_dir_fresh() {
	local repo_root="$1"
	local pkg="$2"
	local stamp="$pkg/.engine-stamp"
	local wasm="$pkg/db_backend_bg.wasm"

	local required
	for required in "$wasm" "$pkg/db_backend.js"; do
		if [ ! -f "$required" ]; then
			echo "STALE ENGINE: missing $required" >&2
			echo "The WASM engine is a build output and is not checked in. Build it:" >&2
			wasm_engine__remedy "$repo_root" >&2
			return 1
		fi
	done

	if [ ! -f "$stamp" ]; then
		echo "STALE ENGINE: $stamp does not exist." >&2
		echo "The engine in $pkg was built without a stamp, so there is no way to" >&2
		echo "tell which sources it came from. An unstamped engine is exactly the" >&2
		echo "one that goes green against a month-old build. Rebuild it:" >&2
		wasm_engine__remedy "$repo_root" >&2
		return 1
	fi

	local recorded_wasm actual_wasm
	recorded_wasm="$(wasm_engine__stamp_field "$stamp" wasm_sha256)"
	actual_wasm="$(wasm_engine__sha256_file "$wasm")"
	if [ "$recorded_wasm" != "$actual_wasm" ]; then
		echo "STALE ENGINE: the stamp does not describe the binary next to it." >&2
		echo "  stamp records: $recorded_wasm" >&2
		echo "  on disk:       $actual_wasm" >&2
		echo "This is what copying pkg/ between checkouts produces. Rebuild:" >&2
		wasm_engine__remedy "$repo_root" >&2
		return 1
	fi

	local recorded_inputs actual_inputs
	recorded_inputs="$(wasm_engine__stamp_field "$stamp" input_digest)"
	actual_inputs="$(wasm_engine_input_digest "$repo_root")"
	if [ "$recorded_inputs" != "$actual_inputs" ]; then
		echo "STALE ENGINE: built from different sources than this tree has." >&2
		echo "  engine built from inputs: $recorded_inputs" >&2
		echo "  this tree's inputs:       $actual_inputs" >&2
		echo "  engine built at:          $(wasm_engine__stamp_field "$stamp" built_at)" >&2
		echo "  engine built from:        $(wasm_engine__stamp_field "$stamp" built_from)" >&2
		echo "  engine built at git HEAD: $(wasm_engine__stamp_field "$stamp" git_head)" >&2
		echo "Measuring through it would grade code that is not in this tree." >&2
		wasm_engine__remedy "$repo_root" >&2
		return 1
	fi

	echo "  engine:  $wasm"
	echo "           built from this tree (inputs ${actual_inputs:0:12}, wasm ${actual_wasm:0:12})"
	return 0
}

# The common case: the engine wasm-pack writes, at
# src/db-backend/wasm-testing/pkg.
wasm_engine_assert_fresh() {
	wasm_engine_assert_dir_fresh "$1" "$(wasm_engine_pkg_dir "$1")"
}

# Runnable directly, for probing a checkout by hand:
#   bash ci/lib/wasm-engine-freshness.sh [assert|digest|stamp] [repo-root]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	wasm_engine__cmd="${1:-assert}"
	wasm_engine__root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	case "$wasm_engine__cmd" in
	assert) wasm_engine_assert_fresh "$wasm_engine__root" ;;
	digest) wasm_engine_input_digest "$wasm_engine__root" ;;
	stamp) wasm_engine_write_stamp "$wasm_engine__root" ;;
	*)
		echo "usage: $0 [assert|digest|stamp] [repo-root]" >&2
		exit 2
		;;
	esac
fi
