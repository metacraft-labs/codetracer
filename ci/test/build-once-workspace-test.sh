#!/usr/bin/env bash
# =============================================================================
# Contract: a CI job that runs `just build-once` provisions the workspace that
# `scripts/require-siblings.sh` requires, and the preflight that says so cannot
# fail silently.
#
# # Why this file exists
#
# `just build-once` -> `scripts/build-once.sh` -> `scripts/require-siblings.sh`
# is the first thing that happens in every desktop-core build, and it refuses
# to start when a repo the Nim/Cargo/cc resolvers reach by RELATIVE PATH is not
# checked out beside this one. That refusal is correct. What has no guard is the
# other side of it: a WORKFLOW that runs `just build-once` in a job whose
# `Setup dev env` clones a workspace the preflight will refuse.
#
# `launcher-recorder-e2e` was exactly that, from the day it was written. It
# provisions the three repos the GATE spans -- codetracer-launcher, one
# recorder, codetracer-trace-format-nim -- and then asks for a desktop core
# that needs eight more. Every run of it that ever reached the build step
# failed there, on all three matrix arms identically, 0.45 seconds in:
#
#     bash scripts/build-once.sh
#     Cannot start the CodeTracer build: 8 required sibling repo(s) are missing.
#       * isonim ... * nim-agents ... * nim-agent-harbor ... * nim-acp
#       * nim-everywhere ... * codetracer-trace-format
#       * codetracer-native-recorder ... * runquota
#     error: Recipe `build-once` failed on line 5 with exit code 1
#
# Nothing language-specific, nothing to do with the workspace lock, and no
# compiler ever started. It is a workspace-shape defect, and a workspace shape
# is a static property of the workflow file -- which is what makes it checkable
# here, in a bash-only lane, instead of on a self-hosted runner forty minutes
# into a queue.
#
# The gate's own "Check the workspace has the shape the driver expects" step
# looks like it would have caught this and does not: it probes the four repos
# the GATE spans, which is a different set from the eleven the BUILD needs. A
# check that validates the repos under test is not a check that the build can
# start.
#
# # What is asserted
#
#   1. The required-sibling table is still parseable out of
#      `scripts/require-siblings.sh` and is non-empty, so a rename cannot turn
#      this suite into a vacuous pass.
#   2. Every workflow job containing a step that runs `just build-once` or
#      `bash scripts/build-once.sh` provisions every name in that table --
#      through a `siblings:` block, through one of this repo's
#      `.github/actions/setup-*-siblings` composites, or through a `clone-repo`
#      step -- except for pairs recorded in KNOWN_GAPS below.
#      SCOPE, stated rather than implied: the scanner matches the literal
#      command in a non-comment line, so a job that reaches build-once through
#      a wrapper script is out of its reach. `visual-replay-regression-gate` is
#      the one such job today -- it names `just build-once` only in prose and
#      drives it from ci/, and it happens to provision all nine anyway. A
#      wrapper is therefore a way to escape this check; adding the wrapper's
#      name to the pattern is how to close that.
#   3. KNOWN_GAPS is shrink-only: a recorded gap that has been fixed must be
#      deleted from the list rather than left to rot, so the exception list
#      cannot quietly become the specification.
#   4. `scripts/require-siblings.sh` PRINTS its diagnosis when it refuses. The
#      script runs under `set -euo pipefail`, and a `grep -c` inside it exits 1
#      when its count is zero -- which killed the script at an assignment, with
#      no output at all, in precisely the environment CI provides (submodules
#      initialised, so the count IS zero). A refusal nobody can read is worse
#      than the late compiler error the whole file exists to pre-empt: the
#      launcher-recorder-e2e logs for d05e45f9 contain the recipe failure and
#      not one word of the report above.
#
# # No mocks
#
# Assertions 1-3 read `.github/workflows/*.yml` and `scripts/require-siblings.sh`
# as committed. Assertion 4 EXECUTES the real script against a throwaway git
# repository built to reproduce the CI condition exactly -- zero uninitialised
# submodules, no dev-shell markers -- rather than asserting anything about its
# text.
#
# Run: bash ci/test/build-once-workspace-test.sh
# Lane: a step of the `ci-verdict` job (stock ubuntu-latest, bash only -- no
#       Nix, no dev shell), alongside ci/test/sibling-provisioning-test.sh.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly WORKFLOW_DIR="$REPO_ROOT/.github/workflows"
readonly ACTIONS_DIR="$REPO_ROOT/.github/actions"
readonly PREFLIGHT="$REPO_ROOT/scripts/require-siblings.sh"

# -----------------------------------------------------------------------------
# The recorded exceptions: (workflow file | job id | sibling name).
#
# SHRINK-ONLY. Each line is a sibling a build-once job does not provision and
# cannot yet, with the reason. Assertion 3 fails if a line here is no longer a
# real gap, so closing one forces its deletion; adding one is a deliberate,
# reviewed act. There is no ceiling and no wildcard: an unlisted gap fails.
#
# THE TWO launcher-recorder-e2e GAPS THAT WERE HERE ARE CLOSED (defect #152).
# They were recorded as un-closable because the `codetracer` project in
# metacraft-labs/metacraft-manifests declares neither `isonim` nor `runquota`,
# so a BARE entry fails `Setup dev env` with "the workspace lock for
# codetracer@<sha> pins no revision for these sibling(s)" -- and both ways of
# spelling around it looked shut: the planner refuses a `<name>=<ref>` entry,
# and a branch-tip pin would breach the shrink-only ceiling in
# ci/test/sibling-provisioning-test.sh.
#
# Both of those are narrower than they read. The planner's `=<ref>` guard
# covers the THREE REPOS UNDER TEST it emits itself, not the literal block
# beside it; and the ceiling counts BRANCH TIPS, which a 40-hex commit SHA is
# not -- that suite's own classify_ref calls it `sha` and accepts it. So
# launcher-recorder-e2e.yml now pins both to the revisions this repo's
# flake.lock already pins them to, which is also the only value that keeps the
# tup driver (which reads ../isonim and ../runquota) and the nix driver (which
# reads flake.lock) on one tree. The remedy below is still the right end state
# and is still owed; the SHAs are a bridge, and deleting them once the manifest
# declares the two repos is a one-line change.
#
# REMEDY, and it is a change in another repository: declare `isonim` and
# `runquota` in codetracer's project manifest, publish a lock
# (`repro workspace lock --trigger-repo=codetracer`, in a workspace whose
# `.repro/manifests` is a real git checkout -- where it is a plain directory
# the lock is generated and then silently dropped), then drop the `=<sha>` from
# the two entries in launcher-recorder-e2e.yml's `siblings:` block.
#
# THE REMAINING FOUR ARE A DIFFERENT CASE and are recorded as FOUND, not as
# accepted. This suite's first run reported them, they are static facts about
# the workflow file, and no CI run has yet corroborated them because neither
# job has reached `build-once` recently -- `viewmodel-tests` died in `Setup dev
# env` on a branch with no lock and then on an unrelated nixpkgs fetch, and
# `windows-installer-build` is release-gated and reports `skipped`. They are
# listed rather than fixed because fixing them means editing jobs this change
# cannot exercise; each line says what is missing and what would close it.
KNOWN_GAPS=(
	# viewmodel-tests provisions the IsoNim family through
	# .github/actions/setup-isonim-siblings and adds codetracer-trace-format-nim,
	# codetracer-js-recorder and runquota as clone-repo steps -- but not
	# codetracer-trace-format (whose column in the required table is
	# deliberately override-free) nor codetracer-native-recorder. Both ARE in
	# the published lock, so both close with a bare entry.
	"codetracer.yml|viewmodel-tests|codetracer-trace-format"
	"codetracer.yml|viewmodel-tests|codetracer-native-recorder"

	# windows-installer-build runs `bash scripts/build-once.sh` directly with an
	# `env-flavor: windows-diy` setup-dev-env whose siblings: block carries only
	# the three db-backend repos. The preflight is driver-agnostic -- it runs
	# before the reprobuild/tup branch is even selected -- so the Windows leg
	# needs the same workspace as the Linux one. Four of these six close with a
	# bare entry; isonim and runquota need the manifest change above.
	"codetracer.yml|windows-installer-build|isonim"
	"codetracer.yml|windows-installer-build|nim-agents"
	"codetracer.yml|windows-installer-build|nim-agent-harbor"
	"codetracer.yml|windows-installer-build|nim-acp"
	"codetracer.yml|windows-installer-build|nim-everywhere"
	"codetracer.yml|windows-installer-build|runquota"
)

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	echo "  ok   $1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	echo "  FAIL $1"
	shift
	local line
	for line in "$@"; do
		echo "         $line"
	done
}

# -----------------------------------------------------------------------------
# 1. The required-sibling table.
#
# Parsed out of the shell array rather than duplicated here: a second copy of
# the list is a second thing to forget to update, and this suite's whole value
# is that the two cannot drift.
# -----------------------------------------------------------------------------
echo "the required-sibling table is readable from the preflight"

required_names=""
if [ -f "$PREFLIGHT" ]; then
	required_names="$(awk '
		/^required_siblings=\(/ { inblock = 1; next }
		inblock && /^\)/        { inblock = 0 }
		inblock {
			line = $0
			sub(/^[ \t]*/, "", line)
			if (line ~ /^#/ || line == "") next
			# Entries are quoted "name|probe|overrides|reason" rows; the name is
			# everything up to the first "|" with the opening quote removed.
			sub(/^["'\'']/, "", line)
			split(line, parts, "|")
			if (parts[1] != "") print parts[1]
		}
	' "$PREFLIGHT")"
fi

required_count="$(printf '%s\n' "$required_names" | grep -c '[^[:space:]]')"
if [ "$required_count" -ge 5 ]; then
	ok "read $required_count required siblings from scripts/require-siblings.sh ($(printf '%s' "$required_names" | tr '\n' ' '))"
else
	fail "read the required_siblings table from scripts/require-siblings.sh" \
		"got $required_count entries; the array was renamed or its row format changed," \
		"so every assertion below would pass over an empty list."
	echo
	echo "$failures of $assertions assertions failed"
	exit 1
fi

# -----------------------------------------------------------------------------
# 2. Which sibling names a composite action provisions.
#
# A job can reach its siblings through one of this repo's composites instead of
# an inline block, and a checker that only reads inline blocks would report
# every such job as broken. Read each composite's own `siblings:` block once.
# -----------------------------------------------------------------------------
sibling_names_in_block() { # <file> ; echoes one bare repo name per line
	awk '
		{
			line = $0
			stripped = line
			sub(/^[ \t]*/, "", stripped)
			indent = length(line) - length(stripped)
			if (inblock) {
				if (stripped == "" || indent <= key_indent) { inblock = 0 }
				else {
					sub(/#.*/, "", stripped)
					n = split(stripped, toks, /[ \t]+/)
					for (i = 1; i <= n; i++) {
						t = toks[i]
						if (t == "" || t ~ /\$\{\{/) continue
						sub(/=.*/, "", t)     # name=ref -> name
						sub(/!$/, "", t)      # name!    -> name
						sub(/^.*\//, "", t)   # owner/name -> name
						if (t != "") print t
					}
					next
				}
			}
			if (stripped ~ /^siblings:/) { inblock = 1; key_indent = indent }
		}
	' "$1"
}

declare -A COMPOSITE_PROVIDES=()
for _act in "$ACTIONS_DIR"/*/action.yml; do
	[ -f "$_act" ] || continue
	_dir="${_act%/action.yml}"
	COMPOSITE_PROVIDES["${_dir##*/}"]="$(sibling_names_in_block "$_act" | tr '\n' ' ')"
done
unset _act _dir

# `provision-repro-lock-siblings` has no `siblings:` block to read, and that is
# not an oversight in the action -- it is the point of it. It runs
#
#     repro develop --all --reset --into=<siblings root>
#
# which clones exactly the `deps` this repo's own `repro.lock` declares, at the
# revisions it pins. Its predecessor, `setup-isonim-siblings`, hand-wrote a
# NINE-repo list resolved against the workspace lock in metacraft-manifests --
# a repo set that reflected whatever the last pusher happened to have checked
# out, and which disagreed with `repro.lock` about isonim's revision.
#
# The names are therefore read from `repro.lock` rather than restated here.
# That keeps this check falsifiable in the direction that matters: if a repo
# stops being declared in the lock, the action stops cloning it, and this
# suite must report the jobs that need it as broken. A hard-coded list here
# would keep saying "provisioned" after the action had stopped providing it,
# which is precisely the class of gate this suite exists to be the opposite of.
#
# The self entry (`path = "."`) is skipped: the primary checkout is not one of
# its own siblings, and handing it to a clone step would `rm -rf` the work tree
# mid-run -- a defect the sibling wiring has already had once.
repro_lock_deps() { # echoes one bare repo name per line
	[ -f "$REPO_ROOT/repro.lock" ] || return 0
	awk '
		/^deps[ \t]*=/ {
			line = $0
			n = split(line, entries, /\}[ \t]*,[ \t]*\{/)
			for (i = 1; i <= n; i++) {
				e = entries[i]
				if (e !~ /path[ \t]*=[ \t]*"\.\"/) {
					if (match(e, /name[ \t]*=[ \t]*"[^"]+"/)) {
						nm = substr(e, RSTART, RLENGTH)
						sub(/^name[ \t]*=[ \t]*"/, "", nm)
						sub(/"$/, "", nm)
						print nm
					}
				}
			}
		}
	' "$REPO_ROOT/repro.lock"
}

_repro_provides="$(repro_lock_deps | tr '\n' ' ')"
if [ -d "$ACTIONS_DIR/provision-repro-lock-siblings" ]; then
	if [ -z "${_repro_provides// /}" ]; then
		fail "provision-repro-lock-siblings exists but repro.lock declares no deps" \
			"Every job relying on it provisions nothing, and this suite cannot" \
			"tell that apart from the action having been deleted."
		echo
		echo "$failures of $assertions assertions failed"
		exit 1
	fi
	COMPOSITE_PROVIDES["provision-repro-lock-siblings"]="$_repro_provides"
fi
unset _repro_provides

# -----------------------------------------------------------------------------
# 3. Every build-once job provisions the table.
#
# Jobs are the unit, not files: `codetracer.yml` holds dozens of jobs and only
# some of them build the core. A job is everything from its 2-space-indented id
# under `jobs:` up to the next one.
# -----------------------------------------------------------------------------
echo "every job that runs 'just build-once' provisions the required siblings"

gaps_seen=()
missing_reports=()
build_once_jobs=0

for wf in "$WORKFLOW_DIR"/*.yml; do
	[ -f "$wf" ] || continue
	wf_name="${wf##*/}"
	# Job ids, in file order.
	job_ids="$(awk '
		/^jobs:[ \t]*$/ { injobs = 1; next }
		injobs && /^[^ \t#]/ { injobs = 0 }
		injobs && /^  [A-Za-z0-9_-]+:[ \t]*$/ {
			id = $0; sub(/^  /, "", id); sub(/:.*/, "", id); print id
		}
	' "$wf")"
	[ -n "$job_ids" ] || continue

	while IFS= read -r job_id; do
		[ -n "$job_id" ] || continue
		job_body="$(awk -v want="  $job_id:" '
			$0 ~ "^" want "[ \t]*$" { injob = 1; print; next }
			injob && /^  [A-Za-z0-9_-]+:[ \t]*$/ { injob = 0 }
			injob { print }
		' "$wf")"

		# Match the COMMAND, never the prose. Both `#` YAML comments and `#`
		# shell comments inside a `run: |` block are dropped first: this suite's
		# own wiring step in codetracer.yml describes the defect in a comment
		# that says "just build-once", and a scanner that reads comments
		# promptly reported the `ci-verdict` job -- a bash-only lane that builds
		# nothing -- as an under-provisioned build job.
		# WHOLE comment lines only. Truncating each line at its first `#` looks
		# equivalent and is not: the real invocation is
		# `nix develop .#devShells.x86_64-linux.default --command just build-once`,
		# and cutting at the `#` of `.#devShells` deletes the very command being
		# looked for -- which silently dropped three of the six build-once jobs
		# from this scan.
		job_code="$(printf '%s\n' "$job_body" | grep -vE '^[[:space:]]*#')"
		# HERESTRING, NOT A PIPE, and the difference is not stylistic.
		#
		# This script runs under `set -uo pipefail`. `grep -q` exits on its
		# FIRST match, which closes the pipe; if `printf` has not finished
		# writing by then it dies of SIGPIPE, and `pipefail` makes the whole
		# pipeline report that failure. So `printf ... | grep -q ... || continue`
		# skips the job precisely WHEN THE PATTERN MATCHES -- the exact
		# inversion of what it is written to do.
		#
		# It has been surviving on a race it usually wins: a job body smaller
		# than the 64 KiB pipe buffer is written in full before `grep` can exit,
		# so `printf` never sees EPIPE. The jobs in this file are near that size
		# and growing, and the failure is silent when it comes -- a dropped job
		# is one this suite then never checks, while still reporting a pass over
		# the jobs it did reach. The same defect elsewhere in this repo
		# fabricated two of three failures in a gate that gates every build.
		#
		# A herestring feeds `grep` from a temporary file: no pipe, no writer,
		# no EPIPE, and the exit status is `grep`'s own in every case.
		grep -qE 'just build-once|scripts/build-once\.sh' <<<"$job_code" || continue
		build_once_jobs=$((build_once_jobs + 1))

		# What this job provisions: its own inline blocks, plus the blocks of
		# every composite it `uses:`, plus any `clone-repo` destinations.
		job_tmp="$(mktemp)"
		printf '%s\n' "$job_body" >"$job_tmp"
		provided=" $(sibling_names_in_block "$job_tmp" | tr '\n' ' ') "
		rm -f "$job_tmp"
		for comp in "${!COMPOSITE_PROVIDES[@]}"; do
			if printf '%s\n' "$job_body" | grep -q "actions/$comp"; then
				provided="${provided}${COMPOSITE_PROVIDES[$comp]} "
			fi
		done
		# `clone-repo`-style steps name the repo as `owner/name`; take the leaf.
		while IFS= read -r repo_line; do
			leaf="${repo_line##*/}"
			[ -n "$leaf" ] && provided="${provided}${leaf} "
		done < <(printf '%s\n' "$job_body" | sed -n 's/^[ \t]*repo:[ \t]*\([A-Za-z0-9_.-]*\/[A-Za-z0-9_.-]*\).*$/\1/p')

		while IFS= read -r name; do
			[ -n "$name" ] || continue
			case "$provided" in
			*" $name "*) continue ;;
			esac
			key="$wf_name|$job_id|$name"
			gaps_seen+=("$key")
			is_known=0
			for known in "${KNOWN_GAPS[@]}"; do
				[ "$known" = "$key" ] && is_known=1 && break
			done
			if [ "$is_known" -eq 0 ]; then
				missing_reports+=("$wf_name job '$job_id' runs build-once but never provisions '$name'")
			fi
		done <<<"$required_names"
	done <<<"$job_ids"
done

if [ "$build_once_jobs" -eq 0 ]; then
	fail "found at least one job that runs build-once" \
		"no workflow job matched 'just build-once' or 'scripts/build-once.sh';" \
		"the scanner regressed and every assertion here is vacuous."
elif [ "${#missing_reports[@]}" -eq 0 ]; then
	ok "all $build_once_jobs build-once job(s) provision every required sibling (${#KNOWN_GAPS[@]} recorded gap(s))"
else
	fail "every build-once job provisions every required sibling" \
		"${missing_reports[@]}" \
		"" \
		"scripts/build-once.sh runs scripts/require-siblings.sh first, so this job" \
		"cannot start a compile at all -- it fails in under a second with" \
		"'Cannot start the CodeTracer build: N required sibling repo(s) are missing.'" \
		"Add the name to the job's siblings: block (bare, so the workspace lock" \
		"pins it), or record it in KNOWN_GAPS here with the reason it cannot be."
fi

# -----------------------------------------------------------------------------
# 4. KNOWN_GAPS is shrink-only.
# -----------------------------------------------------------------------------
echo "the recorded gaps are all still real"

stale=()
for known in "${KNOWN_GAPS[@]}"; do
	found=0
	for seen in ${gaps_seen[@]+"${gaps_seen[@]}"}; do
		[ "$seen" = "$known" ] && found=1 && break
	done
	[ "$found" -eq 0 ] && stale+=("$known")
done

if [ "${#stale[@]}" -eq 0 ]; then
	ok "all ${#KNOWN_GAPS[@]} recorded gap(s) are still outstanding"
else
	fail "every recorded gap is still outstanding" \
		"${stale[@]}" \
		"" \
		"These are provisioned now, so the exception is spent. Delete the line(s)" \
		"from KNOWN_GAPS -- an exception list that outlives its exceptions stops" \
		"being a record of debt and becomes the specification."
fi

# -----------------------------------------------------------------------------
# 5. The preflight prints its refusal.
#
# The defect being pinned: `set -euo pipefail` plus `grep -c`, which EXITS 1
# when it counts zero. A CI checkout has its submodules initialised, so the
# count is zero, so the pipeline "fails", so `-e` killed the script at the
# assignment -- before a single line of the several-hundred-line report. Exit
# code 1 either way; the difference is entirely in whether anyone can read why.
#
# The fixture reproduces that environment rather than describing it: a real git
# repo, no submodules (hence a zero count), no dev-shell markers (hence a
# failing toolchain-pins delegate), and an empty parent so the sibling table is
# unsatisfied and the script has something to report.
# -----------------------------------------------------------------------------
echo "the preflight prints its refusal instead of dying silently"

if ! command -v git >/dev/null 2>&1; then
	fail "exercise the preflight" "git is unavailable, so this assertion cannot run"
else
	fixture="$(mktemp -d)"
	trap 'rm -rf "$fixture"' EXIT
	ws="$fixture/workspace"
	repo="$ws/codetracer"
	mkdir -p "$repo/scripts"
	cp "$PREFLIGHT" "$repo/scripts/require-siblings.sh"
	cp "$REPO_ROOT/scripts/toolchain-pins.sh" "$repo/scripts/toolchain-pins.sh" 2>/dev/null || true
	# `.envrc` is what makes the dev-shell delegate FAIL: `toolchain-pins.sh
	# --devshell-init` only looks for the generated `.pre-commit-config.yaml`
	# when a `.envrc` is present, and without a failing delegate the branch
	# holding the defect is never entered at all. Leaving this out made an
	# earlier version of this assertion a vacuous pass -- it reported success
	# against a mutant with the fix removed.
	printf 'use flake\n' >"$repo/.envrc"
	git -C "$repo" init -q 2>/dev/null
	git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

	# The condition that mattered: no submodules at all, so `grep -c '^-'`
	# counts zero and exits 1.
	uninit="$(git -C "$repo" submodule status 2>/dev/null | grep -c '^-')" || uninit=0
	delegate_rc=0
	bash "$repo/scripts/toolchain-pins.sh" --devshell-init >/dev/null 2>&1 || delegate_rc=$?
	out="$(cd "$repo" && bash scripts/require-siblings.sh 2>&1)"
	rc=$?

	if [ "${uninit:-0}" -ne 0 ]; then
		fail "the fixture reproduces the CI condition" \
			"the throwaway repo reports $uninit uninitialised submodule(s); it was built to" \
			"have none, which is the whole point -- the silent path needs a ZERO count."
	elif [ "$delegate_rc" -eq 0 ]; then
		fail "the fixture reproduces the CI condition" \
			"toolchain-pins.sh --devshell-init PASSED in the throwaway repo, so" \
			"require-siblings.sh never enters the branch that holds the defect and this" \
			"assertion proves nothing. The fixture must present a checkout the dev shell" \
			"has demonstrably not initialised."
	elif [ "$rc" -eq 0 ]; then
		fail "the preflight refuses an empty workspace" \
			"it exited 0 with no siblings present, so assertion 4 proves nothing about" \
			"a refusal that never happened."
	elif [ -z "${out//[[:space:]]/}" ]; then
		fail "the preflight prints its refusal" \
			"it exited $rc having printed NOTHING. This is the regression: a 'grep -c'" \
			"that counts zero exits 1, pipefail propagates it, and 'set -e' kills the" \
			"script at the assignment before any report is emitted. Capture the count" \
			"with a trailing '|| true' and default an empty capture to 0."
	elif printf '%s' "$out" | grep -q "required sibling repo(s) are missing"; then
		ok "the preflight exited $rc and named the missing repos ($(printf '%s' "$out" | wc -l | tr -d ' ') lines)"
	else
		fail "the preflight names the missing repos" \
			"it exited $rc and printed output, but nothing matching" \
			"'required sibling repo(s) are missing'. First line: $(printf '%s' "$out" | head -1)"
	fi
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "all $assertions assertions passed"
	exit 0
fi
echo "$failures of $assertions assertions failed"
exit 1
