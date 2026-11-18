#!/usr/bin/env bash
#
# no-tup-left.sh -- no_tup_left: CodeTracer builds with
# Reprobuild only, and nothing in the repository still builds with, installs,
# provisions or invokes tup.
#
# WHAT IT HOLDS
# -------------
#   1. no tracked path is a tup file: `Tupfile`, `Tuprules.tup`, `Tupfile.ini`,
#      `tup.config`, or anything `*.tup` (git ls-files, so an untracked leftover
#      in a developer's checkout does not count and a committed one does);
#   2. the tup and FUSE helper scripts are gone (`ensure-tup.ps1`,
#      `install_tup.sh`, `require-tup-globs.sh`, `require-fuse-mount-helper.sh`);
#   3. no tracked text file invokes tup: no `tup <verb>` / `${TUP:-tup} <verb>`
#      command, no `tup` entry in a `uses:` list or a Nix package list;
#   4. no tracked text file still names a removed tup artefact: the Tupfile /
#      Tuprules.tup / tup.config files, the removed helper scripts, the removed
#      Windows pins, the `withTup` define. A reference to a file that no longer
#      exists is a reader that fails when it runs.
#
# Checks 3 and 4 read the whole tracked tree except `ALLOWED`, below, each of
# which is a dated record of what was true when it was written and says so.
#
# IT IS FALSIFIABLE. The scan is a function over a repository root, and it is run
# first over scratch repositories that each hold exactly one of the things it
# exists to find (a Tupfile, a workflow that runs `tup upd`, a recipe that
# declares tup, a script that reads Tuprules.tup, a leftover helper script) and
# a clean one; every dirty one must fail and the clean one must pass, or the
# test fails before it looks at the real tree. Leaving one tup file in the real
# tree fails it the same way.
#
# Pure bash and git; no toolchain; about a second.
#
#   bash ci/test/no-tup-left.sh

# The single-quoted strings below are literal regexes and literal fixture
# file contents; none of them is meant to expand.
# shellcheck disable=SC2016
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Paths (repo-relative, exact) that may still say "tup", with the reason.
#   * this file names everything it looks for;
#   * the Windows porting log and the spelling dictionary are dated records: the
#     log says what the Windows bootstrap did on the day an entry was written, and
#     the dictionary lists words, not commands.
ALLOWED=(
	"ci/test/no-tup-left.sh"
	"windows-porting-initiative-status.md"
	"project-words.txt"
)

# A tracked path that is a tup file.
TUP_FILE_RE='(^|/)(Tupfile|Tuprules\.tup|Tupfile\.ini|tup\.config)$|\.tup$'
# The helper scripts removed with tup.
REMOVED_HELPERS_RE='(^|/)(ensure-tup\.ps1|install_tup\.sh|require-tup-globs\.sh|require-fuse-mount-helper\.sh)$'
# `tup <verb>` as a command: at the start of a line or after a shell word
# boundary, optionally spelled `${TUP:-tup}` or `$TUP`. `build-<variant>` is the
# variant form (`tup build-debug`); a bare English "tup build" does not match.
TUP_INVOKE_RE='(^|[[:space:];&|(`'"'"'"])(\$\{TUP:-tup\}|\$TUP|tup)["'"'"']?[[:space:]]+(init|upd|monitor|generate|parse|variant|refactor|options|graph|build-[A-Za-z0-9_-]+)([^A-Za-z0-9_-]|$)'
# A `uses:` entry or a Nix package list entry for tup.
TUP_DECLARED_RE='^[[:space:]]*"tup[[:space:]>=<]|^[[:space:]]*tup$|pkgs\.tup([^A-Za-z0-9_-]|$)'
# Names of removed artefacts.
REMOVED_NAMES_RE='ensure-tup|install_tup|require-tup-globs|require-fuse-mount-helper|Tuprules|Tupfile|tup\.config|TUP_WINDOWS_SOURCE|TUP_WINDOWS_PREBUILT|TUP_PREBUILT|TUP_SOURCE|withTup|tup_preserve|ct_tup_'

# scan <root> [allowed-path...]: print one line per finding; return 1 if any.
scan() {
	local root="$1"
	shift
	local -a allowed=("$@")
	local found=0 path

	is_allowed() {
		local p="$1" a
		for a in "${allowed[@]+"${allowed[@]}"}"; do
			[ "$p" = "$a" ] && return 0
		done
		return 1
	}

	# 1 + 2: tracked paths.
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if [[ $path =~ $TUP_FILE_RE ]]; then
			echo "tup file tracked: $path"
			found=1
		fi
		if [[ $path =~ $REMOVED_HELPERS_RE ]]; then
			echo "tup helper script tracked: $path"
			found=1
		fi
	done < <(git -C "$root" ls-files)

	# 3 + 4: tracked text content.
	local line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="${line%%:*}"
		is_allowed "$path" && continue
		echo "tup invoked: $line"
		found=1
	done < <(git -C "$root" grep -n -I -E -e "$TUP_INVOKE_RE" -e "$TUP_DECLARED_RE" 2>/dev/null || true)
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		path="${line%%:*}"
		is_allowed "$path" && continue
		echo "removed tup artefact named: $line"
		found=1
	done < <(git -C "$root" grep -n -I -E -e "$REMOVED_NAMES_RE" 2>/dev/null || true)

	return "$found"
}

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/         /' >&2
	fi
}

work="$(mktemp -d "${TMPDIR:-/tmp}/no-tup.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

# make_repo <dir> [path=content...]: a scratch git repository tracking the given
# files. Content may contain newlines (printf %b).
make_repo() {
	local dir="$1" spec path content
	shift
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" config user.email t@t.local
	git -C "$dir" config user.name t
	printf 'clean\n' >"$dir/README.md"
	for spec in "$@"; do
		path="${spec%%=*}"
		content="${spec#*=}"
		mkdir -p "$dir/$(dirname "$path")"
		printf '%b' "$content" >"$dir/$path"
	done
	git -C "$dir" add -A
	git -C "$dir" commit -qm fixture
}

echo "no_tup_left:"

# --- the instrument: it finds what it exists to find, and passes a clean tree.
make_repo "$work/clean" \
	'justfile=build-once:\n  bash scripts/build-once.sh\n' \
	'repro.nim=package x:\n  uses:\n    "just >=1"\n    "nim >=1.6 <3.0"\n' \
	'docs/note.md=The retired tup build was replaced by Reprobuild.\nA bare tup build is gone.\n'
if out="$(scan "$work/clean")"; then
	t_pass "control: a repository with no tup in it passes"
else
	t_fail "control: a repository with no tup in it passes" "$out"
fi

expect_found() {
	local label="$1" needle="$2" dir="$work/$3"
	shift 3
	make_repo "$dir" "$@"
	local out
	if out="$(scan "$dir")"; then
		t_fail "$label" "the scan passed a repository that holds it"
	elif grep -qF -- "$needle" <<<"$out"; then
		t_pass "$label"
	else
		t_fail "$label" "the scan failed, but not on it: $out"
	fi
}
expect_found "a tracked Tupfile is found" "tup file tracked: src/Tupfile" tupfile \
	'src/Tupfile=: foreach *.c |> gcc %f |>\n'
expect_found "a tracked Tuprules.tup is found" "tup file tracked: src/Tuprules.tup" tuprules \
	'src/Tuprules.tup=NIM_BIN = nim\n'
expect_found "a tracked tup.config is found" "tup file tracked: src/build-debug/tup.config" tupconfig \
	'src/build-debug/tup.config=CONFIG_DEBUG=1\n'
expect_found "a workflow that runs 'tup upd' is found" "tup invoked: .github/workflows/ci.yml" workflow \
	'.github/workflows/ci.yml=steps:\n  - run: cd src && tup upd\n'
expect_found 'a script that runs ${TUP:-tup} build-debug is found' "tup invoked: scripts/build.sh" script \
	'scripts/build.sh=#!/usr/bin/env bash\n"${TUP:-tup}" build-debug\n'
expect_found "a recipe that declares tup in uses: is found" "tup invoked: repro.nim" uses \
	'repro.nim=package x:\n  uses:\n    "tup >=0"\n'
expect_found "a Nix shell that lists tup is found" "tup invoked: nix/shell.nix" nixlist \
	'nix/shell.nix=[\n    just\n    tup\n    fuse3\n  ]\n'
expect_found "a reader of Tuprules.tup is found" "removed tup artefact named: scripts/flags.py" reader \
	'scripts/flags.py=text = open("src/Tuprules.tup").read()\n'
expect_found "a leftover helper script is found" "tup helper script tracked: scripts/require-tup-globs.sh" helper \
	'scripts/require-tup-globs.sh=#!/usr/bin/env bash\nexit 0\n'
expect_found "the removed ensure-tup.ps1 being dot-sourced is found" "removed tup artefact named: env.ps1" dotsource \
	'env.ps1=. "$windowsDir/ensure-tup.ps1"\n'

# An allowlisted dated record may keep saying tup, and nothing else may.
make_repo "$work/allowed" 'windows-porting-initiative-status.md=- ran `tup upd` on 2026-02-09\n'
if out="$(scan "$work/allowed" "windows-porting-initiative-status.md")"; then
	t_pass "an allowlisted dated record may still say tup"
else
	t_fail "an allowlisted dated record may still say tup" "$out"
fi
if out="$(scan "$work/allowed")"; then
	t_fail "...and the same text is found when it is not allowlisted" "the scan passed it"
else
	t_pass "...and the same text is found when it is not allowlisted"
fi

# --- the real tree.
echo
echo "the repository at ${repo_root}:"
if out="$(scan "$repo_root" "${ALLOWED[@]}")"; then
	t_pass "no tup file, helper, invocation or removed-artefact reference is tracked"
else
	t_fail "tup is still in the repository" "$out"
fi

echo
echo "no_tup_left: ${passes} passed, ${failures} failed"
[ "$failures" -eq 0 ]
