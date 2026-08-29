#!/usr/bin/env bash
#
# hostfree-build.sh — the platform facade's compile-time gate.
#
# WHY THIS EXISTS
# ---------------
# NS1 in codetracer-specs/Planned-Work/Noir-Studio.milestones.org:
#
#   "**The enforcement is the point.** [The time-facade] document records its
#    own weakness: a caller who reaches for `std/asyncdispatch` directly
#    silently defeats fake-time, and compile-time enforcement is impossible
#    while the primitives keep their own clock. This facade has no such
#    excuse — a build that does not link `os` or `osproc` turns every direct
#    call into a build failure on a developer's machine rather than a defect
#    in a user's tab."
#
# The verification test it names is
# `test_direct_host_access_fails_to_compile`: "A deliberate readFile and a
# deliberate startProcess in front-end code each fail the host-free build, at
# compile time; the facade cannot be bypassed by discipline alone."
#
# Scenarios 2 and 3 below ARE that test, planted into a real front-end module
# rather than into a synthetic file, and scenario 4 is the counter-check
# without which neither would mean anything.
#
# HOW THE HOST-FREE BUILD WORKS
# -----------------------------
# Each module of the surface is compiled through a two-line probe:
#
#     import stubs/no_host_access
#     include viewmodels/state_vm
#
# `include` splices the module's source into the probe's scope, so the poisoned
# declarations in no_host_access.nim are visible to THAT module's body and to no
# dependency's. That scoping is the whole design, and it is not decoration: the
# two mechanisms that do not scope — `--import:` and `patchFile` — were both
# tried first and both failed most of the tree on legitimate host calls inside
# nim-everywhere and isonim. ci/hostfree/config.nims records the measurements.
#
# `-d:asyncBackend=none` selects nim-everywhere's sync-stub future backend, so
# the compile does not drag in `std/asyncdispatch` (and through it `std/posix`
# and `std/nativesockets`). The facade's futures still typecheck; there is
# simply no event loop, which is correct for a compile-only gate.
#
# MOCKING POLICY
#   (metacraft-dev-guidelines/policies/documentation-conventions.md)
#   This test mocks nothing. It compiles the real front-end modules with the
#   real compiler, and every mutation scenario edits a byte-copy of a real
#   module and restores it. There is no fixture standing in for anything's
#   behaviour.
#
# NO SKIPS
#   Every prerequisite is a hard failure with a remedy. An empty surface is a
#   failure, not a vacuous pass — a glob that silently matches nothing is the
#   invisible-coverage defect this repository has found repeatedly.
#
# WHAT THIS DOES NOT CATCH
# ------------------------
# A review pass planted ten evasions into the same victim module the scenarios
# below use. Eight got through. Recorded here rather than in a report, because
# the milestone's headline is "a compile error, not discipline" and for these
# shapes it is still discipline:
#
#   1. An ALIASED import. `import std/os as hostos` then `hostos.fileExists(p)`
#      defeats the ambiguity and defeats scenario 6, whose HOST_MODULES list
#      cannot know the alias. (`from std/os import nil` then `os.fileExists(p)`
#      defeats the compiler but IS caught by scenario 6.)
#      CHEAP TO CLOSE: reject `import std/(os|osproc|posix|...) as` outright in
#      the surface, in the same source pass as scenario 6.
#   2. `when defined(js):`. This is a `nim c` compile, so no JS branch in the
#      surface is ever type-checked — and JS is the backend the renderer ships.
#      53 of the 121 surface modules contain such a block.
#      CHEAP TO CLOSE: a second pass with `nim js`, which needs a JS-side poison
#      list (node's `require('fs')`, not `std/os`).
#   3. A host call inside a GENERIC PROC or a TEMPLATE declared in the surface
#      module. Nim semchecks those bodies at instantiation, and nothing here
#      instantiates them. This is an `include`-scoping false pass, not a hole in
#      the poison list, and closing it would mean forcing instantiation.
#   4. A host call reached through a PROC or TEMPLATE in any module outside the
#      four surface directories, since dependencies compile in their own
#      unpoisoned scope. That is the same property that makes this mechanism
#      usable at all (see the header above), so it is a limit rather than a bug.
#   5. `staticRead` / `staticExec` — the host at compile time, in neither the
#      poison list nor scenario 6's proc list.
#   6. `{.emit.}` raw C, and an own `{.importc.}` binding to a libc symbol. The
#      second is documented in no_host_access.nim as an unclosable residual; the
#      first has the same character.
#
# What DOES hold: a bare `readFile`, a bare or qualified `startProcess`, a bare
# `p.fileExists()` in method-call syntax, `import std/osproc as anything`, a
# raw `std/posix` `fork()`, and a qualified `os.fileExists(p)`. Those are the
# shapes a developer reaches for without meaning to bypass anything, which is
# the population this gate exists to police.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

HOSTFREE_DIR="ci/hostfree"
PROBE="${HOSTFREE_DIR}/hostfree_probe.nim"
CACHE="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/hostfree"
NIM_FLAGS=(-d:asyncBackend=none --hints:off --warnings:off
	--path:src/frontend/viewmodel --nimcache:"${CACHE}")

mkdir -p "${CACHE}"

failures=0
scenario=0

note() { printf '    %s\n' "$*"; }
ok() { printf '  [OK]     %s\n' "$*"; }
bad() {
	printf '  [FAILED] %s\n' "$*"
	failures=$((failures + 1))
}

# ---------------------------------------------------------------------------
# The surface: which modules must be host-free
# ---------------------------------------------------------------------------
#
# DISCOVERED, not listed. ci/lib/test-lane-files.sh's header explains why at
# length and this file obeys the same rule: a new ViewModel is covered on the
# next CI run without anyone editing anything. A hand-written list omits
# silently, and the omitted module is exactly the one that acquires a `readFile`.
#
# The four directories are the layer the tree already treats as pure.
# src/frontend/viewmodel/host/project_action_runner.nim states the rule in its
# own header: "a module in here may touch the platform, and a module in
# `viewmodels/` may not". This makes that sentence enforceable.
hostfree_surface() {
	find src/frontend/viewmodel/viewmodels \
		src/frontend/viewmodel/views \
		src/frontend/viewmodel/store \
		src/frontend/viewmodel/platform \
		-name '*.nim' -type f 2>/dev/null | sort
}

# Modules that are IN the surface's directories but cannot yet be host-free.
# Every entry must name the blocker. A stale entry — one that would now compile
# host-free — fails the run too (scenario 1b), because an exception nobody
# removes is how a gate quietly stops covering the tree.
#
# Format: <module path>|<reason>
KNOWN_VIOLATIONS=(
	# This module's OWN host calls are gone — NS1 replaced its `fileExists` +
	# `readFile` with `platform().fs.readText` and dropped its `std/os` import.
	# What remains is transitive and not ours: `agent_service` imports
	# `nim_agents`, which links `std/osproc` to spawn agent processes. Routing
	# that through the process facade is a change to a dependency in another
	# repository, and is deliberately out of NS1's first pass. The entry stays
	# so the surface stays enumerated; scenario 1b removes it automatically the
	# day the dependency stops linking osproc.
	"src/frontend/viewmodel/viewmodels/agentic_session_vm.nim|transitively imports nim_agents (via agent_service), which links std/osproc to spawn agent processes. Its own direct host calls were migrated to the facade."
)

is_known_violation() {
	local path="$1" entry
	for entry in "${KNOWN_VIOLATIONS[@]}"; do
		[ "${entry%%|*}" = "${path}" ] && return 0
	done
	return 1
}

# compile_hostfree <module-path> -> prints the first Error line, empty if clean
compile_hostfree() {
	local path="$1"
	local base sub
	base="$(basename "${path}" .nim)"
	sub="$(basename "$(dirname "${path}")")"
	printf 'import stubs/no_host_access\ninclude %s/%s\n' "${sub}" "${base}" >"${PROBE}"
	timeout "${CT_HOSTFREE_TIMEOUT:-600}" nim c "${NIM_FLAGS[@]}" \
		-o:"${CACHE}/probe" "${PROBE}" 2>&1 |
		grep -E '\.nim\([0-9]+, [0-9]+\) Error:' | head -1
	rm -f "${PROBE}"
}

# compile_normal <module-path> -> prints the first Error line, empty if clean
#
# The same module, WITHOUT the poison import — and critically, from a project
# directory that ci/hostfree/config.nims does NOT govern. Nim reads config.nims
# from the project directory and every parent, so a probe left in ci/hostfree/
# would still get the osproc patch and this counter-check would restate
# scenario 3 instead of contradicting it. The probe therefore lives under
# src/frontend/viewmodel/, which sees the repo's normal configuration and
# nothing else.
NORMAL_PROBE="src/frontend/viewmodel/ns1_hostfree_normal_probe.nim"

compile_normal() {
	local path="$1"
	local base sub
	base="$(basename "${path}" .nim)"
	sub="$(basename "$(dirname "${path}")")"
	printf 'include %s/%s\n' "${sub}" "${base}" >"${NORMAL_PROBE}"
	timeout "${CT_HOSTFREE_TIMEOUT:-600}" nim c --hints:off --warnings:off \
		--path:src/frontend/viewmodel --nimcache:"${CACHE}-normal" \
		-o:"${CACHE}/probe-normal" "${NORMAL_PROBE}" 2>&1 |
		grep -E '\.nim\([0-9]+, [0-9]+\) Error:' | head -1
	rm -f "${NORMAL_PROBE}"
}

command -v nim >/dev/null 2>&1 || {
	echo "hostfree-build.sh: no 'nim' on PATH." >&2
	echo "  remedy: run inside the dev shell (direnv exec ${repo_root} ...)" >&2
	exit 2
}

echo "=== host-free build gate (NS1: the platform facade) ==="

# ---------------------------------------------------------------------------
scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: every module of the host-free surface compiles with no host access"

mapfile -t SURFACE < <(hostfree_surface)
surface_count="${#SURFACE[@]}"

if [ "${surface_count}" -lt 50 ]; then
	bad "the host-free surface has ${surface_count} modules, which is implausibly few"
	note "A glob that matches nothing is not a pass. Check hostfree_surface()"
	note "against the directories it names."
	echo
	echo "RESULT: FAILED (${failures} scenario(s))"
	exit 1
fi
note "surface: ${surface_count} modules under viewmodels/, views/, store/, platform/"

clean=0
violating=0
for module in "${SURFACE[@]}"; do
	err="$(compile_hostfree "${module}")"
	if [ -z "${err}" ]; then
		clean=$((clean + 1))
		if is_known_violation "${module}"; then
			bad "STALE EXCEPTION: ${module} now compiles host-free"
			note "Remove it from KNOWN_VIOLATIONS in $0."
		fi
	else
		if is_known_violation "${module}"; then
			violating=$((violating + 1))
		else
			bad "${module} reaches the host"
			note "${err}"
			note "Route it through src/frontend/viewmodel/platform, or add it to"
			note "KNOWN_VIOLATIONS in $0 with the blocker named."
			violating=$((violating + 1))
		fi
	fi
done
note "clean: ${clean}/${surface_count}; declared exceptions: ${violating}"
[ "${clean}" -gt 0 ] || bad "no module compiled cleanly — the probe itself is broken"
if [ "${failures}" -eq 0 ]; then
	ok "the surface holds"
fi

# ---------------------------------------------------------------------------
# The mutation scenarios. These are NS1's test_direct_host_access_fails_to_compile.
#
# Each plants a violation into a byte-copy of a REAL front-end module, requires
# the host-free build to reject it by name, and restores the original. Planting
# into a real module rather than a synthetic file matters: a synthetic file
# proves the poison compiles, not that it reaches the code the rule is about.
# ---------------------------------------------------------------------------

VICTIM="src/frontend/viewmodel/viewmodels/state_vm.nim"
VICTIM_BACKUP="${CACHE}/victim.bak"

plant() {
	# plant <snippet>  — append to the victim, keeping a restorable copy
	cp "${VICTIM}" "${VICTIM_BACKUP}" || return 1
	printf '\n%s\n' "$1" >>"${VICTIM}"
}

unplant() {
	cp "${VICTIM_BACKUP}" "${VICTIM}"
	rm -f "${VICTIM_BACKUP}"
}

[ -f "${VICTIM}" ] || {
	echo "hostfree-build.sh: victim module ${VICTIM} is missing." >&2
	echo "  remedy: point VICTIM at another module in the host-free surface." >&2
	exit 2
}

READFILE_PLANT='proc ns1DeliberateReadFile*(path: string): string =
  ## Planted by ci/test/hostfree-build.sh and removed again. If you are reading
  ## this in a committed file, the script was interrupted — delete this proc.
  readFile(path)'

STARTPROCESS_PLANT='import std/osproc

proc ns1DeliberateStartProcess*(): int =
  ## Planted by ci/test/hostfree-build.sh and removed again.
  let child = startProcess("/bin/echo", args = @["hi"], options = {poUsePath})
  result = child.waitForExit()'

POSIX_PLANT='import std/posix

proc ns1DeliberateFork*(): cint =
  ## Planted by ci/test/hostfree-build.sh and removed again. Covers the back
  ## door ci/hostfree/config.nims leaves open by NOT patching std/posix.
  fork()'

run_mutation() {
	# run_mutation <label> <snippet> <expected-substring-in-error>
	local label="$1" snippet="$2" expect="$3"
	plant "${snippet}" || {
		bad "${label}: could not write the plant"
		return
	}
	local err
	err="$(compile_hostfree "${VICTIM}")"
	unplant
	if [ -z "${err}" ]; then
		bad "${label}: the host-free build ACCEPTED it"
		note "The gate does not hold. This is the milestone's core claim."
		return
	fi
	case "${err}" in
	*"${expect}"*)
		ok "${label}: rejected at compile time"
		note "${err}"
		;;
	*)
		bad "${label}: rejected, but not for the expected reason"
		note "expected the error to mention: ${expect}"
		note "got: ${err}"
		;;
	esac
}

scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: a deliberate readFile in front-end code fails the host-free build"
run_mutation "readFile in ${VICTIM##*/}" "${READFILE_PLANT}" "readFile"

scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: a deliberate startProcess in front-end code fails the host-free build"
run_mutation "startProcess in ${VICTIM##*/}" "${STARTPROCESS_PLANT}" "osproc"

scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: the same two plants COMPILE under the normal build"
note "Without this, scenarios 2 and 3 prove nothing: a plant that fails"
note "everywhere would score green while the gate did no work at all."
for pair in "readFile:${READFILE_PLANT}" "startProcess:${STARTPROCESS_PLANT}"; do
	label="${pair%%:*}"
	snippet="${pair#*:}"
	plant "${snippet}" || {
		bad "counter-check ${label}: could not write the plant"
		continue
	}
	err="$(compile_normal "${VICTIM}")"
	unplant
	if [ -z "${err}" ]; then
		ok "counter-check ${label}: the normal build accepts it, as it must"
	else
		bad "counter-check ${label}: the normal build ALSO rejected it"
		note "${err}"
		note "The host-free gate is then not what rejected it, and scenario"
		note "$((scenario - 2)) / $((scenario - 1)) is a check that cannot fail."
	fi
done

scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: the raw-POSIX back door is closed at the call site"
note "config.nims deliberately does not patch std/posix (std/times needs it),"
note "so the syscalls are poisoned by name instead. This checks that decision."
run_mutation "fork() via std/posix" "${POSIX_PLANT}" "fork"

# ---------------------------------------------------------------------------
scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: no module in the surface reaches the host by QUALIFIED call"
note "no_host_access.nim works by making a call ambiguous. A caller who writes"
note "os.fileExists(p) disambiguates and gets through — the one residual the"
note "compile-time mechanism cannot close. This closes it by source inspection."

# The qualifier alone is not enough to match on. `files.len` on a local named
# `files` and the word `osproc.Process` inside a doc comment are both hits for a
# bare `(os|files)\.` pattern, and a check that cries wolf gets deleted. So the
# pattern requires a host MODULE followed by a host PROC — the same names
# no_host_access.nim poisons — and comment lines are stripped first.
HOST_MODULES='os|osproc|posix|dirs|files|envvars|appdirs|tempfiles|syncio|cmdline|symlinks'
HOST_PROCS='readFile|writeFile|readLines|readAll|fileExists|dirExists|symlinkExists|removeFile|removeDir|moveFile|moveDir|copyFile|copyDir|createDir|existsOrCreateDir|createSymlink|expandSymlink|getFileSize|sameFile|expandFilename|absolutePath|walkDir|walkDirRec|walkFiles|walkDirs|walkPattern|getCurrentDir|setCurrentDir|getHomeDir|getConfigDir|getCacheDir|getDataDir|getTempDir|getAppDir|getAppFilename|createTempDir|genTempPath|getEnv|putEnv|existsEnv|delEnv|envPairs|paramStr|paramCount|commandLineParams|findExe|startProcess|execProcess|execCmd|execCmdEx|execShellCmd|quoteShell|quoteShellCommand|fork|execv|execvp|execve|popen|chdir|unlink|rmdir'
QUALIFIED_RE="(^|[^A-Za-z0-9_.])(${HOST_MODULES})\.(${HOST_PROCS})[^A-Za-z0-9_]"

# strip_comments — drop whole-line `#` comments, keeping line numbers intact by
# blanking rather than deleting. A qualified call mentioned in prose is not a
# call.
strip_comments() {
	sed -E 's/^[[:space:]]*#.*$//' "$1"
}

qualified_hits=0
while read -r module; do
	[ -n "${module}" ] || continue
	hits="$(strip_comments "${module}" | grep -nE "${QUALIFIED_RE}" || true)"
	if [ -n "${hits}" ]; then
		bad "${module} reaches the host by qualified call"
		printf '%s\n' "${hits}" | head -3 | sed 's/^/      /'
		qualified_hits=$((qualified_hits + 1))
	fi
done < <(hostfree_surface)
[ "${qualified_hits}" -eq 0 ] && ok "no qualified host calls in the surface"

scenario=$((scenario + 1))
echo
echo "Scenario ${scenario}: the qualified-call check can actually fail"
note "This repository has found a lint that could not detect the literal it was"
note "written to catch. So the check above is run against a planted violation."
plant 'proc ns1QualifiedViolation*(p: string): bool =
  ## Planted by ci/test/hostfree-build.sh and removed again.
  os.fileExists(p)'
if strip_comments "${VICTIM}" | grep -qE "${QUALIFIED_RE}"; then
	ok "the qualified-call check detects a planted os.fileExists"
else
	bad "the qualified-call check did NOT detect a planted os.fileExists"
	note "The regex does not match what it was written to match."
fi
unplant

# ...and that it does NOT fire on the two shapes that made an earlier, looser
# regex unusable: a local named `files` and a module name inside a comment. A
# check that cannot distinguish those is one that gets switched off.
plant 'proc ns1QualifiedFalsePositiveBait*(): int =
  ## Planted by ci/test/hostfree-build.sh. Mentions osproc.startProcess in
  ## prose, which is not a call.
  var files = @["a", "b"]
  files.len'
if strip_comments "${VICTIM}" | grep -qE "${QUALIFIED_RE}"; then
	bad "the qualified-call check fires on a local named 'files' or on prose"
	note "That is a false positive, and a noisy check is a deleted check."
else
	ok "the qualified-call check ignores a local named 'files' and a comment"
fi
unplant

# ---------------------------------------------------------------------------
echo
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the host-free build gate holds (${scenario} scenarios)"
	exit 0
fi
echo "RESULT: FAILED — ${failures} scenario(s) failed"
exit 1
