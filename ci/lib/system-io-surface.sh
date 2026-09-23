# ci/lib/system-io-surface.sh — the surface `system` puts in EVERY nim module,
# DERIVED from the compiler in use rather than from a list somebody typed.
#
# WHY THIS FILE EXISTS
# --------------------
# PLAT-8's source-admission pass closed the import surface with an allow-list
# (`PluginAllowedStdlibModules`) and the FFI surface with a denylist
# (`PluginDeniedFfiPragmas`). It left one residual, and wrote it down as ten
# names:
#
#     `system` … carries `readFile`, `writeFile`, `readLine`, `readLines`,
#     `readChar`, `open`, `close`, `staticExec`, `gorge` and `gorgeEx`.
#
# That sentence is false, and the way it is false is the point. `system.nim`
# ends with
#
#     when not defined(nimPreviewSlimSystem):
#       import std/syncio
#       export syncio
#
# so the residual is not ten names — it is the WHOLE EXPORTED SURFACE of
# `std/syncio`, thirty-six entries on the pinned compiler, plus `system`'s own
# compile-time family in `system/compilation.nim`. Nine of the thirty-six were
# denied. `open` was NAMED in the paragraph and denied nowhere, and the buffer
# family around it was not named at all, so a plugin whose entire import list is
# `import codetracer_plugin` had a complete, unmediated file I/O API:
#
#     SYSIO-READ[gpu-server-001]      <- /etc/hostname, no fs:read grant
#     SYSIO-WRITE-OK                  <- a file created, no fs:write grant
#
# measured 2026-09-09; `src/frontend/viewmodel/tests/unit/plugin_probes/`
# `sysio_raw_plugin.nim.probe` is that program, committed.
#
# TWO PASSES HAD ALREADY EXTENDED THE LIST BY HAND, and each found names the
# previous enumeration missed. A third hand-extension would have missed more:
# measured, again on 2026-09-09, `reopen(stdin, "/etc/hostname", fmRead)` reads
# any file with NO `open` at all — so denying `open` alone would have left the
# hole exactly where it was — and `for l in lines("/etc/hostname")` reads any
# file with ONE identifier. Neither was on anybody's list.
#
# So the enumeration is DERIVED HERE, off the compiler's own source, on every
# gate run. A name nim adds in a future release turns up in this sweep and has
# to be accounted for; it does not wait for somebody to be attacked by it.
#
# WHAT "ACCOUNTED FOR" MEANS
# -------------------------
# `ci/test/plugin-reactive-boundary.sh`'s `system-surface-enumerated` check
# requires every name this file derives to be on ONE of two tables in
# `src/frontend/viewmodel/plugin_host/plugin_io.nim`:
#
#   `PluginDeniedSyncIo`            refused in a plugin's source, by name;
#   `PluginSystemSurfaceExempt`     deliberately NOT refused, with the reason.
#
# A name on neither reddens the gate. That is the whole mechanism: the SET is
# derived, the VERDICT on each member is reviewed, and a compiler bump that
# widens the set cannot widen it silently.
#
# THE SWEEP READS EVERY `when` BRANCH, ON PURPOSE
# -----------------------------------------------
# `nim jsondoc` reports the surface of ONE build configuration. This sweep reads
# the source, so it reports a name that exists under ANY of them — e.g. `nimrtl`,
# which lives in `system/inclrtl.nim` behind `when defined(useNimRtl)` and which
# jsondoc does not list. That is the safe direction for a security sweep and it
# is the reason this is a source sweep rather than a `jsondoc` call: an
# over-report costs one exempt row with a reason, an under-report costs a hole.
#
# VALIDATED AGAINST THE COMPILER'S OWN VIEW. On nim 2.2.8, `system_surface_names`
# over `std/syncio.nim` returns exactly `nim jsondoc`'s 36 entries plus `nimrtl`,
# and over `system/compilation.nim` a subset of jsondoc's view of `system`. Re-run
# that comparison at the next compiler bump:
#
#     nim jsondoc --outdir:/tmp/jd "$(system_surface_lib)/std/syncio.nim"
#
# shellcheck shell=bash

# SYSTEM_SURFACE_ROOTS_REL — the sweep's roots, RELATIVE to a library directory.
#
# ONE list, read from the two places that need it: `system_surface_roots`, which
# turns it into the files to sweep, and `system_surface_lib_has_roots`, which
# uses it to decide whether a candidate library directory is a Nim stdlib at
# all. Written twice — once to validate and once to emit — they would be two
# things that can disagree while each goes on agreeing with itself
# (Verification-Harness-Traps §14), and the disagreement would be silent in the
# worst direction: a validator that accepted a directory the sweep then could
# not read is a sweep of NOTHING, which is a clean bill of health.
#
# WHY THESE TWO, and what they deliberately leave out, is in
# `system_surface_roots` below.
SYSTEM_SURFACE_ROOTS_REL="std/syncio.nim
system/compilation.nim"

# system_surface_lib_has_roots DIR — is DIR a Nim stdlib this sweep can read?
#
# The validation the executable-relative fallback below owes, and the reason
# that fallback is allowed to exist at all. It is the same shape as
# `src/db-backend/build.rs`'s `nim_lib_dir_is_valid`, which accepts a derived
# directory only when `nimbase.h` is actually in it: a derived path is a guess
# until something in it has been looked at.
system_surface_lib_has_roots() {
	local dir="$1" r
	[ -n "${dir}" ] || return 1
	while IFS= read -r r; do
		[ -n "${r}" ] || continue
		[ -f "${dir}/${r}" ] || return 1
	done <<<"${SYSTEM_SURFACE_ROOTS_REL}"
	return 0
}

# system_surface_nim_exec_target <path> — the executable a nim wrapper runs.
#
# Follows `makeWrapper`-style shell scripts (nixpkgs wraps nim this way: a
# `#!` script whose LAST `exec` hands off to the real compiler by absolute
# path, optionally through `-a "$0"`) until it reaches something that is not
# such a script, and prints that. A path that is not a `#!` script — the ELF
# compiler itself, the source layout's `bin/nim` — is printed unchanged, so this
# is a no-op on every layout that worked before it existed. The target is taken
# ONLY when it is an absolute path to an executable file; anything else (a
# script that computes its target, a relative path) stops the walk at the
# script, and the caller's validation then decides, as it always did. Bounded,
# so a wrapper cycle cannot hang the gate.
#
# Read, never run: executing the wrapper is exactly what this fallback exists
# to avoid (see `system_surface_lib_from_exe`).
system_surface_nim_exec_target() {
	local exe="$1" hops=0 line target first
	while [ "${hops}" -lt 8 ]; do
		[ -f "${exe}" ] || break
		IFS= read -r -n 2 first <"${exe}" || true
		[ "${first}" = "#!" ] || break
		target=""
		while IFS= read -r line; do
			if [[ ${line} =~ ^[[:space:]]*exec[[:space:]]+(-a[[:space:]]+\"[^\"]*\"[[:space:]]+)?\"(/[^\"]+)\" ]]; then
				target="${BASH_REMATCH[2]}"
			fi
		done <"${exe}"
		[ -n "${target}" ] && [ -f "${target}" ] && [ -x "${target}" ] || break
		exe="${target}"
		hops=$((hops + 1))
	done
	printf '%s\n' "${exe}"
}

# system_surface_lib_from_exe — the library directory of the nim on PATH,
# derived from WHERE THAT EXECUTABLE SITS rather than from what it prints.
#
# THE SAME NIM, A SECOND WAY OF ASKING WHERE ITS LIBRARY IS — and the
# distinction is the whole licence for this function. `command -v nim` is the
# lookup `nim dump` itself used; there is still exactly one way of finding nim
# from the shell, which is the property the header of `system_surface_lib`
# insists on. What is doubled is the DERIVATION of the library directory from
# that one executable, which is precisely what `src/db-backend/build.rs` already
# does for the same compiler (`nim dump`, then `nim_lib_from_executable`) and
# for a reason that applies here verbatim: a `dump` that cannot be read is not
# evidence that the stdlib is missing.
#
# IT EXISTS BECAUSE THE COMPILER CAN FAIL TO RUN WHILE BEING PERFECTLY PRESENT.
# Measured 2026-09-11: a host driven to load ~1200 with two gigabytes of memory
# left — 1250 orphaned processes from an unrelated runaway — turns `nim dump`
# into a process that is killed before it prints, and check 23 then reports the
# sweep as empty. That verdict is correct as far as check 23 can see and it is
# still the wrong finding: the stdlib had not moved, nothing was unaccounted
# for, and the transcript sent a reader looking for a defect in this repository.
# Nothing in this sweep needs nim to EXECUTE — it reads the stdlib's source off
# disk — so when the compiler cannot be run, the honest repair is to find its
# library without running it.
#
# BOTH LAYOUTS, AND VALIDATED IN BOTH. The nix layout puts the library at
# `<prefix>/nim/lib` and the source layout at `<prefix>/lib`; on the pinned
# 2.2.8 the first is the real directory and the second is a symlink to it, and
# `pwd -P` resolves them to the same answer, which is what lets the agreement
# control in `plugin-reactive-boundary-test.sh` be a plain string comparison
# against `nim dump`'s own line. A candidate that carries no `std/syncio.nim` is
# NOT returned — an unvalidated guess is how a wrong path becomes an empty
# sweep, which is the failure this whole file is written around.
#
# A WRAPPER IS FOLLOWED TO THE COMPILER IT RUNS. nixpkgs' `nim` (the one the
# lint devShell carries) is a `makeWrapper` shell script in a prefix holding only
# `bin/` and `etc/`; its last line is `exec "<store>/nim-unwrapped-X/nim/bin/nim"
# "$@"`, and THAT binary's prefix is the one `nim dump` names. Walking up from
# the script found no library at all, so the fallback came back empty on the
# very layout CI runs. See `system_surface_nim_exec_target`.
system_surface_lib_from_exe() {
	local exe dir root cand
	exe="$(command -v nim 2>/dev/null || true)"
	[ -n "${exe}" ] || return 1
	exe="$(system_surface_nim_exec_target "${exe}")" || return 1
	dir="$(dirname -- "${exe}")"
	root="$(cd -- "${dir}/.." 2>/dev/null && pwd -P)" || return 1
	[ -n "${root}" ] || return 1
	for cand in "${root}/lib" "${root}/nim/lib"; do
		if system_surface_lib_has_roots "${cand}"; then
			(cd -- "${cand}" && pwd -P)
			return 0
		fi
	done
	return 1
}

# system_surface_lib — the `lib/` directory of the nim on PATH.
#
# ONE COMPILER, ASKED ABOUT ITSELF, WITH A VALIDATED FALLBACK.
#
# Taken from `nim dump`'s own search paths rather than guessed off `command -v
# nim`, because the nix layout puts the library at `<prefix>/nim/lib` and the
# source layout at `<prefix>/lib`, and a guess that is wrong resolves to a
# missing file — which this sweep would report as an EMPTY surface, i.e. as a
# clean bill of health. The empty case is refused by the caller for exactly that
# reason. When `dump` cannot be read at all, `system_surface_lib_from_exe`
# derives the directory from where that same executable sits and returns it ONLY
# once it has been looked at; see its header for why a guess is admissible there
# and not here. (`src/db-backend/build.rs` wants the same directory for a
# different question — the `nimbase.h` every generated C file includes — and
# asks the same way, `nim dump` first with an executable-relative derivation
# only as a validated fallback.)
#
# THE THREE `--skip*Cfg` FLAGS ARE THE 2026-09-10 REPAIR, AND THEY ARE
# LOAD-BEARING. Without them `nim dump` evaluates the PROJECT configuration of
# whatever directory the gate is standing in — and the gate stands wherever
# `--root` points, which for `test_plugin_source_admission.nim` is a synthetic
# tree inside this repository, so `codetracer/config.nims` runs in full: a
# NimScript program that walks `~/.nimble/pkgs2`, parses `NIX_CFLAGS_COMPILE`
# and may `include repro.paths`. None of that has anything to do with where THIS
# COMPILER keeps its standard library, and every line of it is one more way for
# the lookup to be slow, to be starved, or to fail. Measured from a synthetic
# tree under `build/`, on the host this was found on:
#
#     nim dump                                       6.8 s wall, 53 MB peak RSS
#     nim --skipUserCfg --skipParentCfg --skipProjCfg dump
#                                                    1.1 s wall, 16 MB peak RSS
#
# and worse under load: 29 s against 3 s, inside a gate the suite bounds at 180.
#
# The two resolve to the SAME directory, and THAT is the property that makes the
# flags safe rather than merely cheap — a project that redirected `--lib` would
# be swept differently by the two spellings, and this repository does not (there
# is no `--lib` in `config.nims`). It is asserted as a case in
# `plugin-reactive-boundary-test.sh` rather than claimed in this comment, so the
# day a config gains one, that case goes red instead of the sweep going quietly
# wrong (Verification-Harness-Traps §15: the repair normalises how the question
# is asked, so it owes the case where the un-normalised form must still agree).
#
# IT STILL FAILS CLOSED, AND IT NOW SAYS WHY. Every failure used to arrive at
# check 23 as one sentence — "found nothing" — followed by three guesses (nim is
# not on PATH / the stdlib moved / the parser stopped parsing), with nim's exit
# code and its stderr discarded by the caller's `2>/dev/null`. Those are three
# different facts and only one of them is a finding about this repository;
# telling them apart by hand cost this campaign two verification passes. The
# reason goes to stderr and check 23 prints it verbatim.
system_surface_lib() {
	local out rc pure fallback
	# CAPTURED WHOLE, NOT PIPED. Callers run under `set -o pipefail`, and any
	# reader that closes the pipe early kills `nim` with SIGPIPE, which makes the
	# pipeline report failure and this function return nothing — i.e. an EMPTY
	# SURFACE, which is a clean bill of health. That is the same trap
	# `plugin-reactive-boundary.sh`'s own `sync-io-scan-discriminates` control
	# carries a comment about. Reading the output into a variable first removes
	# the pipe and the whole class with it, and it is also the only way to keep
	# nim's OWN exit code, which a pipeline would have replaced with grep's.
	out="$(nim --skipUserCfg --skipParentCfg --skipProjCfg dump 2>&1)"
	rc=$?
	pure="$(printf '%s\n' "${out}" | grep -E '/lib/pure$' || true)"
	# The first line, taken with parameter expansion rather than `head -1`, for
	# the SIGPIPE reason above.
	pure="${pure%%$'\n'*}"
	if [ -n "${pure}" ]; then
		printf '%s\n' "${pure%/pure}"
		return 0
	fi

	# THE COMPILER DID NOT ANSWER. Before this is a refusal, ask where it SITS
	# — see `system_surface_lib_from_exe`. A directory comes back only if it
	# carries the sweep's roots, so the sweep that follows is the same sweep,
	# over the same files, and not a narrower one.
	fallback="$(system_surface_lib_from_exe || true)"
	if [ -n "${fallback}" ]; then
		# THE FALLBACK SAYS SO, EVERY TIME IT ANSWERS, and check 23 puts these
		# lines in the transcript under its OK as well as under its VIOLATION.
		# A fallback nobody is told about is a fallback nobody can audit, and
		# "this compiler could not be executed" is exactly the environment fact
		# whose absence from the transcript cost this campaign two verification
		# passes when the failing spelling of it arrived.
		{
			echo "system-io-surface: NOTE — \`nim --skipUserCfg --skipParentCfg --skipProjCfg dump\` exited ${rc}"
			echo "system-io-surface: and named no search path ending in /lib/pure, so the library"
			echo "system-io-surface: directory was derived from where the nim on PATH SITS instead:"
			echo "system-io-surface:   ${fallback}"
			echo "system-io-surface: It carries the sweep's roots, so the surface below is complete."
			echo "system-io-surface: What could not be run is the compiler, which is a fact about this"
			echo "system-io-surface: machine and not a finding about this repository. What dump printed:"
			# `tail` LAST, so nothing closes the pipe on `printf` early.
			printf '%s\n' "${out}" | sed 's/^/system-io-surface:   /' | tail -20
		} >&2
		printf '%s\n' "${fallback}"
		return 0
	fi

	{
		echo "system-io-surface: \`nim --skipUserCfg --skipParentCfg --skipProjCfg dump\` exited ${rc}"
		echo "system-io-surface: and named no search path ending in /lib/pure, and the nim on PATH"
		echo "system-io-surface: does not sit beside a library carrying this sweep's roots either."
		echo "system-io-surface: What it printed:"
		# `tail` LAST, so nothing closes the pipe on `printf` early.
		printf '%s\n' "${out}" | sed 's/^/system-io-surface:   /' | tail -20
	} >&2
	return 1
}

# system_surface_roots — the module files whose exports land in every plugin.
#
# TWO, and the list is short because the claim is narrow. `std/syncio` is what
# `system` re-exports wholesale, and `system/compilation.nim` is where the
# compile-time `staticExec` / `gorge` / `slurp` / `staticRead` family lives.
# `system.nim` in FULL is 575 names, almost all of them arithmetic and memory
# management that mediate nothing; sweeping it would produce five hundred exempt
# rows and a table nobody reads. The bound this file claims is therefore
# EXPLICITLY over these two roots and their `include` closures, and the residual
# that leaves is written down in `plugin_model/source_admission.nim` rather than
# glossed.
#
# THE ROOTS ARE VERIFIED TO EXIST, BY NAME, and that is a repair rather than a
# formality. `system_surface_names` skips a queued file it cannot read, which is
# right for an `include` candidate and wrong for a ROOT: a lib directory that
# resolved to somewhere plausible but wrong produced a sweep of NOTHING with no
# statement anywhere that a file had been missed — Verification-Harness-Traps §4
# arriving through the INPUT of the scan rather than through its pattern. A root
# that is not there is the sweep's own named refusal now, and the contract suite
# drives it with a `nim` that answers with a library directory that has no
# `std/syncio.nim` under it.
system_surface_roots() {
	local lib roots r missing=""
	lib="$(system_surface_lib)" || return 1
	# ONE list, validated and then printed. Written twice — once to test and
	# once to emit — it would be two things that can disagree while each goes on
	# agreeing with itself (Verification-Harness-Traps §14). That list is
	# `SYSTEM_SURFACE_ROOTS_REL`, which `system_surface_lib_has_roots` reads too,
	# so the directory a fallback lookup ACCEPTS and the files this sweep READS
	# cannot come apart.
	roots=""
	while IFS= read -r r; do
		[ -n "${r}" ] || continue
		roots="${roots}${roots:+$'\n'}${lib}/${r}"
	done <<<"${SYSTEM_SURFACE_ROOTS_REL}"
	while IFS= read -r r; do
		[ -f "${r}" ] || missing="${missing}${r} "
	done <<<"${roots}"
	if [ -n "${missing}" ]; then
		{
			echo "system-io-surface: nim reports its library at '${lib}', but the sweep's"
			echo "system-io-surface: root(s) are not there: ${missing}"
		} >&2
		return 1
	fi
	printf '%s\n' "${roots}"
}

# system_surface_exports FILE — every EXPORTED name defined in FILE.
#
# An export in nim is an identifier carrying `*` AT A DEFINITION SITE, in one of
# three shapes: after a routine keyword (`proc open*`), inside a `type`/`var`/
# `let`/`const` section (`FileHandle* = int`, `stdin*: File`), or backquoted
# (`` `&=`* ``). The `*` must be ADJACENT to the name — `a * b` is
# multiplication, and requiring adjacency is what tells them apart.
system_surface_exports() {
	awk '
	BEGIN { in_doc = 0; ex_indent = -1 }
	{
		line = $0

		# 1. A `runnableExamples:` body is DOCUMENTATION that happens to be
		#    nim. `system/compilation.nim` defines `proc timesTwo*` inside one
		#    and the compiler exports no such thing; a sweep that reported it
		#    would be crying wolf, and a sweep that cries wolf gets switched
		#    off. Bounded by INDENTATION, which is what delimits the body.
		if (ex_indent >= 0) {
			if (line ~ /^[[:space:]]*$/) next
			match(line, /^[[:space:]]*/)
			if (RLENGTH > ex_indent) next
			ex_indent = -1
		}
		if (line ~ /^[[:space:]]*runnableExamples([[:space:]]|:|$)/) {
			match(line, /^[[:space:]]*/)
			ex_indent = RLENGTH
			next
		}

		# 2. Triple-quoted bodies. Prose inside one can look like anything,
		#    including a definition.
		n = gsub(/"""/, "&", line)
		if (n % 2 == 1) { in_doc = 1 - in_doc; next }
		if (in_doc) next

		# 3. Comments, whole-line and trailing.
		if (line ~ /^[[:space:]]*#/) next
		sub(/#.*$/, "", line)

		# 4. The definition site.
		if (!match(line, /^[[:space:]]*(proc|func|template|macro|iterator|converter|method|type|var|let|const)?[[:space:]]*(`[^`]+`|[A-Za-z_][A-Za-z0-9_]*)\*/))
			next
		hit = substr(line, RSTART, RLENGTH)
		# `**` is an operator and `*=` is an assignment; neither is an export.
		rest = substr(line, RSTART + RLENGTH, 1)
		if (rest == "*" || rest == "=") next
		sub(/\*$/, "", hit)
		sub(/^[[:space:]]*(proc|func|template|macro|iterator|converter|method|type|var|let|const)?[[:space:]]*/, "", hit)
		gsub(/`/, "", hit)
		if (hit == "" || (hit in seen)) next
		seen[hit] = 1
		print hit
	}
	' "$1"
}

# system_surface_includes FILE — the files FILE splices in with `include`.
#
# `system.nim` is thirty `include`s in a trenchcoat and `std/syncio.nim` opens
# with `include system/inclrtl`. An `include` splices the file in, so its
# exports ARE the including module's exports; a sweep that stopped at the named
# file would be a sweep of one of the module's files rather than of the module.
system_surface_includes() {
	local dir
	dir="$(dirname "$1")"
	sed -e 's/#.*$//' "$1" |
		grep -oE '^[[:space:]]*include[[:space:]]+"?[A-Za-z0-9_/.]+"?[[:space:]]*$' |
		sed -e 's/^[[:space:]]*include[[:space:]]*//' -e 's/"//g' -e 's/[[:space:]]*$//' |
		while IFS= read -r spec; do
			[ -n "${spec}" ] || continue
			case "${spec}" in *.nim) ;; *) spec="${spec}.nim" ;; esac
			for cand in "${dir}/${spec}" "${dir}/../${spec}"; do
				if [ -f "${cand}" ]; then
					printf '%s\n' "${cand}"
					break
				fi
			done
		done
}

# system_surface_names — every name the two roots and their include closures
# export, sorted and unique. THIS IS THE DERIVED SET the gate ranges over.
system_surface_names() {
	local roots queue seen_files=" " f
	roots="$(system_surface_roots)" || return 1
	queue="${roots}"
	{
		while [ -n "${queue}" ]; do
			# Parameter expansion rather than `head`/`tail`, for the SIGPIPE
			# reason in `system_surface_lib` above — and because a queue popped
			# with `tail -n +2` never empties when its last element carries no
			# trailing newline.
			f="${queue%%$'\n'*}"
			if [ "${queue}" = "${f}" ]; then
				queue=""
			else
				queue="${queue#*$'\n'}"
			fi
			[ -n "${f}" ] || continue
			case "${seen_files}" in *" ${f} "*) continue ;; esac
			seen_files="${seen_files}${f} "
			[ -f "${f}" ] || continue
			system_surface_exports "${f}"
			queue="${queue}
$(system_surface_includes "${f}")"
		done
	} | grep -v '^$' | LC_ALL=C sort -u
}
