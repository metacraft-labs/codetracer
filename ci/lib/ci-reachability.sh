#!/usr/bin/env bash
# shellcheck shell=bash
#
# ci-reachability.sh — "can a CI lane actually reach this?", answered once.
#
# WHY THIS EXISTS
# ---------------
# Two guards ask the same question about different subjects.
# `ci/test/shell-gate-coverage.sh` asks it about shell scripts under ci/ and
# scripts/; `ci/test/test-lane-job-coverage.sh` asks it about the test LANES
# declared in ci/lib/test-lane-files.sh. Both need the identical answer to
# "which `just` recipes, and which scripts, can a GitHub workflow actually get
# to?", and that answer is 600 lines of hard-won reference parsing: command
# position vs. a mere mention, variables that hold script paths, `just`
# dependency lists, script-to-script calls, and the equal-length-basename trap
# that credited `ci/test/rust.sh` for years because `ci/lint/rust.sh` is the
# same length.
#
# The second guard was written after the first. Re-deriving the walk for it
# would have produced two engines that agree today and drift by the first
# bugfix applied to only one -- which is precisely the failure mode
# `ci/lib/test-lane-files.sh` exists to have ended for lane FILE selection.
# This file ends it for lane REACHABILITY. Everything below was moved here
# VERBATIM from shell-gate-coverage.sh; that guard's 22-check contract suite
# (ci/test/shell-gate-coverage-test.sh) is what proves the move changed no
# behaviour, and it must keep passing.
#
# CONTRACT
#   The caller creates `tmp` (a mktemp -d it owns), sets `gates` to the
#   newline-separated universe of script paths to resolve references against,
#   and defines a `note` function for the one progress line `ci_reach_walk`
#   does not emit. Then:
#
#     source ci/lib/ci-reachability.sh
#     roots="$(ci_reach_roots)"
#     ci_reach_parse_justfile     # sets `recipe_count`; fills ${tmp}/bodies,deps
#     ci_reach_walk              # fills ${tmp}/reached, rreached, recipe-names
#
#   Outputs, all under ${tmp}:
#     reached          script paths a CI lane can reach
#     rreached         `just` recipe names a CI lane can reach
#     recipe-names     every recipe the justfile defines
#     missing-recipes  `just <name>` for a recipe the justfile does not define
#
#   `ci_reach_walk` reports nothing itself; the caller owns all output, because
#   the two guards word their findings differently and neither should have to
#   inherit the other's phrasing.

# `ci_reach_roots` — the files a CI lane can START from, and nothing else.
#
# ---------------------------------------------------------------------------
# THE WORKFLOWS, AND NOTHING ELSE. THIS IS THE OTHER HALF OF THE FIX.
#
# This list used to include the justfile and the `ci/lint/*.sh` dispatchers as
# roots in their own right, and the justfile is the one that made the number a
# fiction: EVERY gate any `just` recipe mentioned was seeded as reachable,
# whether or not any lane runs that recipe. `just` is a developer entry point.
# Most of its 200-odd recipes are things a person types; a handful are things CI
# types. Seeding from the file rather than from the recipes CI actually calls
# credited fourteen gates — the `noir-*` family, the `desktop-*` family,
# `cli-record-smoke.sh`, `python-recorder-smoke.sh` and the rest — as covered
# while they ran in no lane at all.
#
# The dispatchers do not need to be roots either, and making them roots hid the
# same class of error one level down. `ci/lint/nim.sh` IS reachable — four
# workflow steps name it — so the walk below reaches it the ordinary way, and if
# a day comes when no workflow names it, this guard should say so rather than
# assume it.
#
# NOT A ROOT, DELIBERATELY: `.gitlab-ci.yml`. It exists, it is 120 lines, and it
# names `just test` and `ci/test/ui-tests.sh`. Counting it would credit
# `ui-tests.sh` and everything under `just test` — and this repository's CI is
# GitHub Actions: the inventory beside this file has recorded `ui-tests.sh` as
# dark since 2026-09-01 with `ui-tests-db.sh is wired and this is not` as the
# reason, which is a statement about the GitHub lanes. Treating the GitLab file
# as a lane would silently retire that finding and five more. If somebody
# revives that pipeline, add it here and watch six entries evict themselves.
ci_reach_roots() {
	find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort
}

# `refs_in` — reads file paths on STDIN, prints one reference per line:
#
#     S <token>     a `*.sh` path or basename this file INVOKES
#     J <recipe>    a `just <recipe>` this file CALLS
#
# AN INVOCATION IS A POSITION, NOT A MENTION — AND THAT IS THE WHOLE RULE.
#
# This used to extract EVERY `*.sh`/`*.mjs`/`*.py` token on every non-comment
# line and call each one a reference. That reads a filename and calls it a wire,
# and it was wrong in three shapes that all look identical to a regex:
#
#     grep -q wasm_engine_assert_fresh "${WORKER_E2E}"   # a READ
#     cat "${WORKER_E2E}"                                # a READ
#     WORKER_E2E="${SUITE_ROOT}/ci/test/worker-...-e2e.sh"  # a NAME
#
# 295f36835 added exactly those three lines to `stale-artefact-guards-test.sh`.
# Nothing in that commit builds the WASM engine and nothing executes the gate —
# it is read as text, twice — and this guard nevertheless reported
# `ci/test/worker-backend-wasm-e2e.sh` RESURRECTED and demanded its line be
# deleted from the recorded-dark inventory. A truthfully recorded blocker, about
# to be retired because a meta-test `cat`ted the file.
#
# The old rule needed a BLACKLIST to stay standing — `shellcheck` and `shfmt`
# lines were dropped wholesale, because `ci/lint/bash.sh` shellchecks eleven
# scripts it never runs. That blacklist is the same shape as a sweep that names
# a symptom: it stops the readers somebody remembered, and `grep`, `cat`, `head`,
# `cp`, `echo`, `diff` and a Python docstring went on counting. Enumerating them
# is unbounded, and every miss is silent and green.
#
# So the test is now STRUCTURAL, and it is the one the shell itself applies. A
# path is INVOKED when it stands where a command goes:
#
#   * COMMAND POSITION — the first word of a command. Start of a line, or after
#     `|`, `||`, `&&`, `;`, `&`, `$(`, a backtick, a justfile `@`/`-` prefix, a
#     workflow `run:`, or a keyword that opens a command (`if`, `then`, `do`,
#     `exec`, `env`, `timeout 60`).
#   * INTERPRETER ARGUMENT — the first non-flag word after `bash`, `sh`,
#     `source`, `.`, `node`, `python3` and their relatives, WHEREVER that word
#     stands. This one clause is what makes the wrappers work without a list of
#     wrappers: `lint_step "name" bash ci/x.sh`, `nix develop -c ./ci/x.sh`,
#     `timeout 900 bash ci/x.sh` and `xargs bash ci/x.sh` are all just `bash`
#     followed by a path.
#
# Everything else is an argument, and an argument is a read. `shellcheck x.sh`
# needs no special case any more: `shellcheck` takes command position and `x.sh`
# is its argument. The blacklist is GONE, and eleven shellchecked-never-run
# scripts stay dark for a reason that is now stated once instead of enumerated.
#
# AND THE ONE THING A POSITION RULE ALONE GETS WRONG: `bash "${GUARD}"`.
#
# Twenty-nine contract suites in this tree are written
#
#     GUARD="$REPO_ROOT/ci/verdict/job-timeouts.py"
#     python3 "${GUARD}" --root "${TMP}"
#
# and the path never appears in command position at all. Dropping assignments
# outright would have invented dark gates by the dozen — the failure mode that
# gets a guard switched off. So the extractor makes TWO PASSES over the file: the
# first records what each variable was ASSIGNED, the second resolves a variable
# standing in an invoking position back to the paths it holds.
#
# That is also precisely what tells the two cases apart. `WASM_FRESHNESS_LIB` is
# `source`d, so `ci/lib/wasm-engine-freshness.sh` is reachable and stays
# reachable. `WORKER_E2E` is only ever `grep`ped and `cat`ted, so it confers
# nothing — which is the truth 295f36835 wrote into the file.
#
# LINE CONTINUATIONS ARE JOINED FIRST, and that is load-bearing for both rules:
# `ci/lint/bash.sh` writes every step as `lint_step "..." \` with the command on
# the next physical line, so reading them separately would put `bash` at the
# start of a line and make the interpreter clause fire on nothing.
#
# NOT DROPPED, DELIBERATELY: `source` and `.`. Sourcing EXECUTES the file in the
# current shell, so it is an invocation and this guard has always counted it —
# `ci/lib/published-asset.sh` and `visual-replay-gate-lib.sh` are reachable only
# that way, and the transitivity note above depends on it.
refs_in() {
	# Reads paths on STDIN, one per line, so the caller need not expand a list
	# into positional arguments — bash 3.2 has no array to expand.
	#
	# COMMENT LINES ARE DROPPED BEFORE NAMES ARE EXTRACTED, and this file is the
	# reason. Its own header lists the gates it found dark. Once it was wired
	# into `ci/lint/nim.sh` it became reachable, the transitive walk followed it,
	# and every gate NAMED IN ITS PROSE was credited as reachable — so the guard
	# reported 63 of 63 covered while four of them were referenced by nothing at
	# all. A scanner that reads its own documentation is satisfied by anything
	# that documentation says.
	#
	# Verification-Harness-Traps.md §4d, and the third instance found in this
	# session: `ci-coverage.sh` in the sibling repository read a step's doc
	# comment instead of the step, and its selftest's mutation arms rewrote a
	# comment about a trigger instead of the trigger. Each time a control caught
	# it; none of the three would have been visible in the transcript.
	local f
	while read -r f; do
		[ -n "${f}" ] || continue
		[ -f "${f}" ] || continue
		refs_of_text <"${f}"
	done | grep -v '^$' | sort -u || true
}

# The extractor itself, over one file's text on stdin. `awk`, because joining
# continuations and then walking command positions is a multi-state job and
# `grep` has one state.
#
# POSIX awk only: no `gensub`, no `asort`, no `[[:space:]]` outside brackets.
# AND NO APOSTROPHE ANYWHERE IN THIS PROGRAM, comments included: it is
# single-quoted from bash, and one apostrophe closes it — producing a bash
# syntax error a hundred lines further down, in code that is not wrong. Where
# the character itself is needed it is built with `sprintf("%c", 39)`.
#
# THE WHOLE FILE IS BUFFERED because the rule needs two passes: pass 1 records
# variable assignments, pass 2 resolves them in invoking positions. See the
# `bash "${GUARD}"` note in the header above for why that is not optional.
refs_of_text() {
	awk '
	BEGIN {
		SQ = sprintf("%c", 39)
		# Quotes and parens are noise around a token, never part of a path.
		STRIP = "[\"" SQ "()]"
		# Words after which the NEXT non-flag word is a file this runs.
		INTERP = " bash sh zsh dash ksh source . node nodejs python python2 python3 deno bun npx tsx ts-node ruby perl "
		# Words that KEEP command position rather than consuming it: shell
		# keywords, transparent prefixes, the justfile line prefixes, and the
		# workflow `run:` key whose value is a shell script.
		OPEN = " if while until then else elif do done fi ! exec command sudo nohup env eval builtin nice ionice stdbuf setsid time timeout xargs run: - @ @- -@ { } "
		# Flags whose VALUE is a command line: `nix develop -c ./ci/lint/bash.sh`.
		CMDARG = " -c --command --run --exec -exec "
		# Declaration keywords: what follows is an assignment, not a command.
		DECL = " local readonly export declare typeset "
		# The JavaScript module-execution positions. `new Worker(x)`, `import(x)`
		# and `require(x)` LOAD AND RUN x; they are the `.mjs` spelling of
		# `bash x.sh`, and `ci/test/noir-wasm-worker/compare.mjs` reaches
		# `worker.mjs` through nothing else.
		JSEXEC = "(^|[^A-Za-z0-9_$.])(new[ \t]+Worker|require|import)[ \t]*\\("
		nl = 0
	}
	{
		cur = cur $0
		if (cur ~ /\\$/) { sub(/\\$/, " ", cur); next }
		lines[++nl] = cur; cur = ""
	}
	END {
		if (cur != "") lines[++nl] = cur
		# PASS 1 RUNS TWICE, and the second time is not superstition. It learns
		# which parameter of each local function is EXECUTED rather than read
		# (see `runsarg`), and functions call each other: `expect_leak` hands its
		# `$1` to `leak_scan`, so whether `$1` is executed depends on what
		# `leak_scan` was found to do. One iteration answers that only when the
		# callee is defined first. Two covers a call to a helper defined later,
		# which is the whole of the nesting this tree actually has.
		for (pass = 1; pass <= 2; pass++) {
			curfn = ""
			for (k = 1; k <= nl; k++) scan(lines[k], 1)
		}
		curfn = ""
		for (k = 1; k <= nl; k++) scan(lines[k], 2)
	}

	# A line that carries no wire at all, whatever it names.
	function dropped(line) {
		# COMMENT MARKERS FOR ALL THREE LANGUAGES, not just `#`. Widening the
		# subject to `.mjs` and `.py` without widening this would re-create the
		# exact defect the comment rule exists for, in the new files: a probe
		# named in a `//` doc comment would be credited as wired.
		if (line ~ /^[ \t]*#/) return 1
		if (line ~ /^[ \t]*\/\//) return 1
		if (line ~ /^[ \t]*\*/) return 1
		# A `paths:` TRIGGER FILTER NAMES A FILE TO WATCH, NOT ONE TO RUN. It is
		# the read rule one more step along: `grep x.sh` at least opens the file,
		# while `- x.sh` under `on: push: paths:` only decides whether the
		# workflow starts. Measured: `beam-flow.yml` lists
		# `ci/test/elixir-flow-cross-repo.sh` in two `paths:` blocks and runs
		# `beam-flow-cross-repo.sh` instead, so the ONLY reference to that shim
		# in the entire repository was a trigger condition, and it counted as
		# coverage.
		#
		# The shape matched is a YAML sequence item whose whole content is one
		# unbroken token ending in `.sh`, optionally quoted. A real step is
		# `- run: bash x.sh` or `- uses: ...` and always carries a space before
		# the path, so it cannot match this.
		if (line ~ /^[ \t]*-[ \t]*[^ \t]*\.(sh|mjs|py)[^ \t]*[ \t]*$/) return 1
		return 0
	}

	function haspath(s) { return (s ~ /[A-Za-z0-9_-]\.(sh|mjs|py)/) }

	function putpaths(s,   rest) {
		rest = s
		while (match(rest, /[A-Za-z0-9_.\/-]*[A-Za-z0-9_-]\.(sh|mjs|py)/)) {
			print "S " substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
		}
	}

	# The first ${NAME} or $NAME in a token, so `"${GUARD}"` resolves.
	function varname(s) {
		if (match(s, /\$\{[A-Za-z_][A-Za-z0-9_]*/)) return substr(s, RSTART + 2, RLENGTH - 2)
		if (match(s, /\$[A-Za-z_][A-Za-z0-9_]*/)) return substr(s, RSTART + 1, RLENGTH - 1)
		return ""
	}

	# `$1`, `${2}`, `$@` — a POSITIONAL PARAMETER standing where a command goes.
	# Returns the index, or 0.
	function posref(s) {
		if (s ~ /^\$\{?[@*]\}?$/) return 1
		if (match(s, /^\$\{?[0-9]+/)) {
			if (match(s, /[0-9]+/)) return substr(s, RSTART, RLENGTH) + 0
		}
		return 0
	}

	# A token that stands where a command goes.
	#
	# Phase 2 prints the paths it holds — literally, or through the variable it
	# names. Phase 1 prints nothing and instead LEARNS: a positional parameter in
	# this position means the enclosing function EXECUTES that argument, which is
	# what makes `probe chords ci/test/chord_double_fire_probe.mjs` a wire and
	# `expect_leak leaky.sh REPO_ROOT` a read.
	function invoke(tok, phase,   v, p) {
		p = posref(tok)
		if (p > 0) {
			posmode = 1
			if (phase == 1 && curfn != "") runsarg[curfn, p] = 1
			return
		}
		v = varname(tok)
		if (phase == 1) {
			if (v != "" && curfn != "" && ((curfn, v) in frompos))
				runsarg[curfn, frompos[curfn, v]] = 1
			return
		}
		if (haspath(tok)) { putpaths(tok); return }
		if (v != "" && (v in assigned)) putpaths(assigned[v])
	}

	function record(tok,   name, val) {
		name = substr(tok, 1, index(tok, "=") - 1)
		val = substr(tok, index(tok, "=") + 1)
		# `local script="$2"` inside a function: remember the binding, so that a
		# later `node "${script}"` is understood as executing parameter 2.
		if (curfn != "" && match(val, /^\$\{?[0-9]+/)) {
			if (match(val, /[0-9]+/)) frompos[curfn, name] = substr(val, RSTART, RLENGTH) + 0
		}
		if (!haspath(val)) return
		# A variable assigned twice holds either value, so both are recorded —
		# but pass 1 itself runs twice, so an unconditional append would store
		# every value twice over.
		if (!(name in assigned)) assigned[name] = val
		else if (index(" " assigned[name] " ", " " val " ") == 0)
			assigned[name] = assigned[name] " " val
	}

	# `bash`, `/usr/bin/python3`, and the two indirect spellings this tree uses
	# for an interpreter it had to locate first:
	#
	#     cargo_lock_pin_guard_python="$(type -P python3)"
	#     "$cargo_lock_pin_guard_python" -I "$PREFLIGHT_DIR/cargo-lock-pin-guard.py"
	#     "$(visual_replay_gate_python)" -I "$VISUAL_REPLAY_GATE_REPORT_VALIDATOR"
	#
	# Both of those RUN a python guard, and a rule that only knows the literal
	# word `python3` calls both of those guards dark. The LAST word of the name
	# is the test — `..._python` and `${BASH:-bash}` are interpreters,
	# `${SUITE_ROOT}` and `${WORKER_E2E}` are not — and it is the last word
	# rather than any word for exactly that reason: `${SH_LIB}` would otherwise
	# read as `sh`.
	# A FILENAME IS NEVER THE INTERPRETER, and this guard is not decorative.
	# Without it `scripts/docs/deep-review-capture-lib.sh` splits to a last word
	# of `sh`, reads as an interpreter, and credits whatever `shellcheck` was
	# handed next on the same line — which put `capture-deep-review-screenshots.sh`
	# back on the reachable list while it declares NOT-A-CI-GATE in its own header.
	function isinterp(s,   b, nb, ba, q, last) {
		if (haspath(s)) return 0
		if (index(INTERP, " " s " ") > 0) return 1
		b = s
		sub(/.*\//, "", b)
		if (index(INTERP, " " b " ") > 0) return 1
		gsub(/[^A-Za-z0-9]/, " ", b)
		nb = split(b, ba, / +/)
		last = ""
		for (q = 1; q <= nb; q++) if (ba[q] != "") last = ba[q]
		if (last != "" && index(INTERP, " " tolower(last) " ") > 0) return 1
		return 0
	}

	function scan(line, phase,   work, n, arr, i, t, core, cmdpos, want, infn, argn) {
		if (dropped(line)) return
		if (phase == 2) justrefs(line)

		# FUNCTION BOUNDARIES, tracked so that `$1` can be attributed to the
		# function whose parameter it is. Closing brace at column 0 is how every
		# function in this tree ends, and a stricter parser buys nothing here.
		if (match(line, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_-]*[ \t]*\(\)/)) {
			curfn = line
			sub(/^[ \t]*/, "", curfn)
			sub(/^function[ \t]+/, "", curfn)
			sub(/[ \t]*\(\).*$/, "", curfn)
			isfn[curfn] = 1
		} else if (line ~ /^\}/) {
			curfn = ""
		}

		# The operators that END one command and start the next. Turned into
		# free-standing tokens so the walk below needs no separate lexer.
		# NOT SPLIT ON: `{`, because `${VAR}` would then put the rest of the
		# path in command position and credit every `X="${ROOT}/ci/y.sh"` line
		# this rule exists to stop.
		#
		# A BACKTICK IS NOT COMMAND SUBSTITUTION HERE, IT IS A QUOTATION MARK.
		# This did split on it, and that put a path in command position every
		# time a Python docstring or a `.mjs` block comment quoted one the way
		# this repository quotes everything:
		#
		#     suppresses everything, so `ci/test/known-failures-gate.sh` drives
		#     `ci/test/desktop-bundle-self-contained.sh` asks "does every path...
		#
		# Both read as an invocation, in files that only mention the name. The
		# invariant that makes dropping the split safe is enforced, not assumed:
		# `shellcheck` runs over all of ci/ and scripts/ in the `lint-bash` lane
		# and SC2006 flags legacy backtick substitution, of which this tree has
		# exactly zero. So the token rule below can treat a leading backtick as
		# prose outright.
		work = line
		gsub(/\$\(/, " @@CMD@@ ", work)
		gsub(/\|\|/, " @@CMD@@ ", work)
		gsub(/&&/, " @@CMD@@ ", work)
		gsub(/\|/, " @@CMD@@ ", work)
		gsub(/;/, " @@CMD@@ ", work)
		gsub(/&/, " @@CMD@@ ", work)

		posmode = 0
		n = split(work, arr, /[ \t]+/)
		cmdpos = 1
		want = 0
		infn = ""
		argn = 0
		for (i = 1; i <= n; i++) {
			t = arr[i]
			if (t == "") continue
			if (t == "@@CMD@@") { cmdpos = 1; want = 0; infn = ""; continue }
			# A backtick-quoted word is prose. See the note above the splitter.
			if (t ~ /^`/) { cmdpos = 0; want = 0; continue }
			core = t
			gsub(STRIP, "", core)
			if (core == "") continue

			# `VAR=value`. The path in it is a NAME. Command position survives,
			# because `FOO=1 bash x.sh` is an environment prefix.
			if (core ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
				if (phase == 1) record(core)
				cmdpos = 1; want = 0; continue
			}
			if (index(DECL, " " core " ") > 0) { cmdpos = 1; want = 0; continue }

			if (want) {
				if (core ~ /^-/) {
					# `bash -lc PROGRAM` / `python3 -c PROGRAM`: what follows is
					# not a path but a SCRIPT, so the walk restarts in command
					# position inside it rather than eating the next word.
					if (core ~ /^-[A-Za-z]*c$/ || index(CMDARG, " " core " ") > 0) {
						want = 0; cmdpos = 1
					}
					continue
				}
				invoke(core, phase)
				want = 0; cmdpos = 0; continue
			}
			if (cmdpos) {
				if (index(OPEN, " " core " ") > 0) continue
				# `timeout 900 bash x.sh`, `sleep 5` — a bare duration.
				if (core ~ /^[0-9]+[smhd]?$/) continue
				if (haspath(core)) { invoke(core, phase); cmdpos = 0; continue }
				if (isinterp(core)) { want = 1; cmdpos = 0; continue }
				# A LOCALLY DEFINED FUNCTION. Its arguments are invoking
				# positions exactly where its body executes the matching `$N`.
				if (core in isfn) { infn = core; argn = 0; cmdpos = 0; continue }
				cmdpos = 0; continue
			}
			# Argument position. An argument is a READ — with three exceptions,
			# each of which is still "something executes this".
			if (infn != "") {
				argn++
				if ((infn, argn) in runsarg) { invoke(core, phase); continue }
			}
			if (index(CMDARG, " " core " ") > 0) { cmdpos = 1; continue }
			if (isinterp(core)) { want = 1; continue }
		}

		# A POSITIONAL PARAMETER STOOD WHERE A COMMAND GOES, and the program it
		# stood in is a quoted string this walk cannot see inside:
		#
		#     bash -c "source \"$1\"; newest_executable \"$@\"" _ "${NEWEST_LIB}"
		#
		# `ci/lib/newest-build.sh` is reached by that line and by nothing else in
		# ci/ or scripts/. Rather than parse an embedded shell program, the line
		# that proves it runs one is credited whole. Deliberately the widening
		# direction: it over-credits a line that already declared it executes an
		# argument, and it fires on nothing that does not.
		if (posmode && phase == 2)
			for (i = 1; i <= n; i++) {
				core = arr[i]
				gsub(STRIP, "", core)
				if (core == "") continue
				if (core ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
				if (haspath(core)) { putpaths(core); continue }
				t = varname(core)
				if (t != "" && (t in assigned)) putpaths(assigned[t])
			}

		# THE JAVASCRIPT MODULE-EXECUTION POSITIONS, which have no command
		# position to stand in. See JSEXEC.
		if (phase == 2 && line ~ JSEXEC) putpaths(line)
	}

	# `just <recipe>`, unchanged: a recipe name is not a path and the position
	# rule above does not apply to it.
	function justrefs(line,   n, i, j, t, u, arr) {
		n = split(line, arr, /[ \t]+/)
		for (i = 1; i <= n; i++) {
			t = arr[i]
			gsub(/^[^A-Za-z0-9_.\/-]+/, "", t)
			gsub(/[^A-Za-z0-9_.\/-]+$/, "", t)
			if (t != "just") continue
			# Skip flags, and the VALUE of a flag that takes one — otherwise
			# `just --justfile X recipe` reports the recipe as `--justfile`.
			j = i + 1
			while (j <= n) {
				u = arr[j]
				gsub(/^[^A-Za-z0-9_.\/=-]+/, "", u)
				gsub(/[^A-Za-z0-9_.\/=-]+$/, "", u)
				if (u !~ /^-/) break
				if (u == "-f" || u == "--justfile" || u == "-d" ||
					u == "--working-directory" || u == "--set") j++
				j++
			}
			if (j > n) continue
			u = arr[j]
			gsub(/^[^A-Za-z0-9_-]+/, "", u)
			gsub(/[^A-Za-z0-9_-]+$/, "", u)
			if (u ~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/) print "J " u
		}
	}
	'
}

# `ci_reach_parse_justfile` — fill ${tmp}/bodies and ${tmp}/deps, set recipe_count.
# ---------------------------------------------------------------------------
# The justfile, read as a GRAPH rather than as a root.
# ---------------------------------------------------------------------------
# A recipe is reached when a workflow calls it, or when a reached recipe depends
# on it, or when a reached script calls it. Only THEN does what it invokes count.
#
# Emitted as two flat, tab-separated tables rather than shell variables, because
# bash 3.2 has no associative array and `just` has 208 recipes here.
#
#     ${tmp}/bodies   NAME <tab> one body line
#     ${tmp}/deps     NAME <tab> one dependency name
#
# The header grammar this reads: an unindented line whose first token is the
# recipe name, optional parameters, then `:` and optional dependencies. `:=` is
# an assignment, not a recipe, and dependencies may carry `(args)` or be joined
# by `&&` for post-dependencies — all stripped. The body is every following line
# that is indented or blank, up to the next unindented non-blank line.
ci_reach_parse_justfile() {
	: >"${tmp}/bodies"
	: >"${tmp}/deps"
	justfile=""
	[ -f justfile ] && justfile="justfile"
	[ -z "${justfile}" ] && [ -f Justfile ] && justfile="Justfile"
	recipe_count=0
	if [ -n "${justfile}" ]; then
		awk -v bodies="${tmp}/bodies" -v deps="${tmp}/deps" '
		/^[ \t]/  { if (name != "") print name "\t" $0 >> bodies; next }
		/^[ \t]*$/ { next }
		{
			name = ""
			if ($0 !~ /:=/ && $0 ~ /^@?[A-Za-z0-9_][A-Za-z0-9_-]*([ \t][^:]*)?:/) {
				hdr = $0
				sub(/^@/, "", hdr)
				split(hdr, h, ":")
				split(h[1], hn, /[ \t]/)
				name = hn[1]
				if (name == "set" || name == "alias" || name == "export" ||
					name == "import" || name == "mod") { name = ""; next }
				d = substr(hdr, index(hdr, ":") + 1)
				gsub(/\(/, " ", d); gsub(/\)/, " ", d); gsub(/&&/, " ", d)
				gsub(/{{[^}]*}}/, " ", d)
				nd = split(d, da, /[ \t]+/)
				for (i = 1; i <= nd; i++)
					if (da[i] ~ /^[A-Za-z0-9_][A-Za-z0-9_-]*$/)
						print name "\t" da[i] >> deps
				print name "\t" >> bodies
			}
		}
		' "${justfile}"
		recipe_count="$(cut -f1 "${tmp}/bodies" | sort -u | grep -c . || true)"
	fi
}

# `resolve` — reference tokens on stdin, universe paths on stdout.
#
# A token carrying a directory wins over a bare basename: `ci/lint/nix.sh`
# resolves to that file alone, while a bare `nix.sh` cannot tell `ci/build/nix.sh`
# from `ci/lint/nix.sh` and credits both. That is the false-POSITIVE direction
# for exactly two basenames in this tree, and it is the safe one — a guard that
# invents dark gates gets switched off.
resolve() {
	awk -F'\t' '
	NR == FNR { n[$1]++; p[$1, n[$1]] = $2; next }
	{
		tok = $0; sub(/^\.\//, "", tok)
		b = tok; sub(/.*\//, "", b)
		if (!(b in n)) next
		found = 0
		if (tok ~ /\//)
			for (i = 1; i <= n[b]; i++) {
				q = p[b, i]
				# `index()` RETURNS 0 FOR "NOT FOUND", AND 0 IS ALSO A LEGITIMATE
				# VALUE OF `length(q) - length(tok)` — WHENEVER THE TWO PATHS ARE
				# THE SAME LENGTH. Without the `> 0` guard the suffix test reads
				# `0 == 0` and every equal-length sibling of a basename is
				# credited by its twin. Measured on this tree: `ci/lint/rust.sh`
				# (15 chars) is invoked by `codetracer.yml`, and that invocation
				# silently credited `ci/test/rust.sh` (15 chars), which is
				# referenced by NOTHING in the repository — an orphan from the
				# initial open-source release, superseded by the `test-rust`
				# recipe and still naming `--bin db-backend`, a binary since
				# renamed. The guard reported it covered for as long as it existed.
				#
				# `ci/build/nix.sh` (15) and `ci/lint/nix.sh` (14) differ in
				# length, which is the only reason that pair never showed the bug.
				if (q == tok ||
					(index(q, "/" tok) > 0 &&
						index(q, "/" tok) == length(q) - length(tok))) {
					print q; found = 1
				}
			}
		if (!found) for (i = 1; i <= n[b]; i++) print p[b, i]
	}
	' "${tmp}/index" -
}

# `body_of RECIPE` / `deps_of RECIPE` — the two tables, read back.
body_of() { awk -F'\t' -v r="$1" '$1 == r { print substr($0, length(r) + 2) }' "${tmp}/bodies"; }
deps_of() { awk -F'\t' -v r="$1" '$1 == r { print $2 }' "${tmp}/deps"; }

# `absorb` — reference lines (`S tok` / `J recipe`) on stdin; enqueue what is new.
# One `resolve` per CALLER, not per token: resolving token-at-a-time made this a
# few thousand awk processes and thirty seconds.
absorb() {
	local r
	cat >"${tmp}/refs"
	grep '^S ' "${tmp}/refs" | cut -c3- | resolve | sort -u >"${tmp}/refs.s"
	grep '^J ' "${tmp}/refs" | cut -c3- | sort -u >"${tmp}/refs.j"
	while read -r r; do
		[ -n "${r}" ] || continue
		grep -Fxq -- "${r}" "${tmp}/reached" && continue
		printf '%s\n' "${r}" >>"${tmp}/reached"
		printf '%s\n' "${r}" >>"${tmp}/fq"
	done <"${tmp}/refs.s"
	while read -r r; do
		[ -n "${r}" ] || continue
		if grep -Fxq -- "${r}" "${tmp}/recipe-names"; then
			grep -Fxq -- "${r}" "${tmp}/rreached" && continue
			printf '%s\n' "${r}" >>"${tmp}/rreached"
			printf '%s\n' "${r}" >>"${tmp}/rq"
		else
			# `just <name>` for a recipe THIS justfile does not define. Recorded
			# but not reported: see step 4 for why it cannot be treated as rot.
			# What matters here is that it confers no reachability.
			printf '%s\n' "${r}" >>"${tmp}/missing-recipes"
		fi
	done <"${tmp}/refs.j"
}

# `ci_reach_walk` — seed from the roots, then alternate the two worklists.
ci_reach_walk() {
	printf '%s\n' "${gates}" >"${tmp}/universe"
	# basename <tab> path, so a reference can be resolved without an assoc array.
	awk -F/ '{ print $NF "\t" $0 }' "${tmp}/universe" >"${tmp}/index"

	# TWO WORKLISTS, because the graph has two kinds of node. Files and recipes are
	# not interchangeable: a recipe's outgoing edges come from its body AND its
	# dependency list, a file's only from its text.
	: >"${tmp}/reached"
	: >"${tmp}/rreached"
	: >"${tmp}/fq"
	: >"${tmp}/rq"

	: >"${tmp}/missing-recipes"
	cut -f1 "${tmp}/bodies" | sort -u >"${tmp}/recipe-names"

	printf '%s\n' "${roots}" | grep -v '^$' | refs_in | absorb

	# THE SEED COUNTS ARE SNAPSHOTTED HERE, BEFORE THE TRANSITIVE LOOP RUNS.
	#
	# When the seed and the loop lived in the caller, it read these two numbers
	# off `${tmp}/reached` between the two stages and got "what the workflows
	# name DIRECTLY". Folding both stages into this one function silently
	# changed that line's meaning to "everything reachable at all": the first
	# refactor of this file reported `197 script(s) and 66 recipe(s) directly`
	# where the truth is 62 and 41. The gate's verdict was unaffected -- the
	# same 238/197/30/1 came out either way -- which is exactly why it would
	# have shipped. A number that is only ever printed is the easiest kind to
	# corrupt without failing anything.
	grep -c . "${tmp}/reached" >"${tmp}/seeded-scripts" || true
	grep -c . "${tmp}/rreached" >"${tmp}/seeded-recipes" || true

	# Alternate between the two queues until both are empty.
	while [ -s "${tmp}/fq" ] || [ -s "${tmp}/rq" ]; do
		if [ -s "${tmp}/fq" ]; then
			cur="$(head -1 "${tmp}/fq")"
			tail -n +2 "${tmp}/fq" >"${tmp}/fq.next" && mv "${tmp}/fq.next" "${tmp}/fq"
			printf '%s\n' "${cur}" | refs_in | absorb
		else
			cur="$(head -1 "${tmp}/rq")"
			tail -n +2 "${tmp}/rq" >"${tmp}/rq.next" && mv "${tmp}/rq.next" "${tmp}/rq"
			{
				body_of "${cur}" | refs_of_text
				deps_of "${cur}" | sed 's/^/J /'
			} | absorb
		fi
	done
}
