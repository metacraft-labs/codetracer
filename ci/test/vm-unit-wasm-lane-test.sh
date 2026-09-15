#!/usr/bin/env bash
#
# vm-unit-wasm-lane-test.sh — contract suite for the `test-vm-unit-wasm` and
# `test-vm-unit-wasm-parity` recipes (PLAT-17).
#
# WHY THIS EXISTS
# ---------------
# `ci/test/vm-js-lane-test.sh` exists because the JS ViewModel lane reported
# test results it could not observe: `nim` auto-defines `nodejs` only for
# `nim js -r`, the lane compiled and ran as separate steps, so
# `std/exitprocs.setProgramResult` was undeclared, `std/unittest` substituted a
# no-op, and a FAILING suite exited 0. The lane looked green for as long as
# nobody read the console.
#
# A WASM lane has the same class of defect available to it and a different
# spelling. Emscripten's `main` returns into a JS loader, and whether that
# status ever reaches `process.exitCode` depends on `-sEXIT_RUNTIME`. Get it
# wrong and the lane is green over a failing suite, exactly as the JS lane was
# — with the additional problem that the toolchain is big and absent from stock
# runners, so "it was skipped" is a comfortable and wrong explanation for a
# lane that measured nothing.
#
# So the contracts below come in two halves, and the second is the one that
# matters:
#
#   * STATIC contracts read the recipes and the runner. Pure bash over the
#     justfile and ci/lib, no Nim, no emscripten — the same rule the other CI
#     gates follow, so `ci-verdict` can run them on a stock runner.
#   * DYNAMIC contracts PROVE the two load-bearing claims against the real
#     toolchain rather than grepping for them: that a failing suite exits
#     non-zero under this lane's flags, and that the 64 KB default stack is
#     genuinely what `-sSTACK_SIZE` is there to fix. Each compiles a tiny
#     purpose-built program both ways and compares.
#
# WHERE THIS RUNS, AND WHY BOTH CALL SITES MATTER
# -----------------------------------------------
# Same two-call-site design as vm-js-lane-test.sh, and the same warning: a
# contract suite whose decisive half never executes is the defect it exists to
# catch. On a runner without emscripten the dynamic contracts skip and the
# summary says how many — a count without a denominator cannot tell you what it
# failed to mention, so `ran + skipped` is reconciled against TOTAL_CONTRACTS
# and a disagreement is fatal.
#
# Run directly:  bash ci/test/vm-unit-wasm-lane-test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JUSTFILE="${REPO_ROOT}/justfile"
LANE_LIB="${REPO_ROOT}/ci/lib/test-lane-files.sh"
RUNNER="${REPO_ROOT}/ci/lib/run-nim-test-lane.sh"

# Every contract below, counted once, whether or not this environment can run
# it. Bump deliberately when adding one — the reconciliation at the end fails
# loudly if this disagrees with what actually ran.
TOTAL_CONTRACTS=12

pass_count=0
skip_count=0

fail() {
	echo "vm-unit-wasm-lane-test: FAIL: $1" >&2
	shift
	for line in "$@"; do echo "    ${line}" >&2; done
	exit 1
}

ok() {
	pass_count=$((pass_count + 1))
	echo "  ok — $1"
}

skip() {
	skip_count=$((skip_count + 1))
	echo "  -- skipped: $1"
}

[ -f "${JUSTFILE}" ] || fail "justfile not found at ${JUSTFILE}"
[ -f "${LANE_LIB}" ] || fail "ci/lib/test-lane-files.sh not found at ${LANE_LIB}"
[ -f "${RUNNER}" ] || fail "ci/lib/run-nim-test-lane.sh not found at ${RUNNER}"

# THE COMMENT STRIPPER, AND WHY IT IS NOT OPTIONAL.
#
# vm-js-lane-test.sh learned this the hard way and the lesson transfers
# verbatim: the recipe and the runner both carry long comments that QUOTE the
# very tokens under test (`-sEXIT_RUNTIME`, `--mm:orc`, `--cpu:wasm32`). A grep
# over the raw text matches the explanation and passes with the actual flag
# deleted. Strip comments, then fold backslash continuations, because this
# lane's `nim c` invocation is spread over ten lines and a line-oriented grep
# can only ever see the first fragment.
strip_and_join() {
	# shellcheck disable=SC2001 # parameter expansion cannot express this trim
	sed 's/[[:space:]]*#.*$//' |
		sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}'
}

runner_joined="$(strip_and_join <"${RUNNER}")"

# THE WASM ARM, ISOLATED — and isolating it is the point, not tidiness.
#
# The runner has a `js` arm, a `js-browser` arm, a `wasm` arm and a `c` arm,
# and several of the flags below appear in more than one of them. A grep over
# the whole file would answer "yes, --mm:orc is in run-nim-test-lane.sh"
# without saying WHICH lane gets it, which is trap 4 (a scan whose subject is
# wider than its claim) in the place it does the most damage here.
#
# The arm is also a MULTI-LINE ARRAY LITERAL rather than a backslash-continued
# command, so `strip_and_join`'s continuation fold does not reach it: measured,
# with `--mm:orc` present, a `nim c .*--mm:orc` grep over the folded runner
# matched nothing and contract 4 failed against a correct tree. Flatten the
# whole arm to one line instead.
wasm_arm="$(awk '
	/elif \[ "\$\{backend\}" = "wasm" \]; then/ { inarm = 1; next }
	inarm && /^\telse$/ { exit }
	inarm { print }
' "${RUNNER}" | strip_and_join | tr '\n' ' ')"
[ -n "${wasm_arm}" ] || fail "the runner has an arm for the wasm backend" \
	"could not extract 'elif [ \${backend} = wasm ]' from ci/lib/run-nim-test-lane.sh." \
	"Either the arm was removed or this extractor no longer matches it, and" \
	"every flag contract below would be checking an empty string."

recipe="$(awk '
	/^test-vm-unit-wasm:/ { inrec = 1; next }
	inrec && /^[^[:space:]#]/ { exit }
	inrec { print }
' "${JUSTFILE}")"
[ -n "${recipe}" ] || fail "could not extract the test-vm-unit-wasm recipe" \
	"either the recipe was renamed or this extractor no longer matches it," \
	"and every contract below would be vacuous"
recipe_joined="$(strip_and_join <<<"${recipe}")"

# Guard against the transforms emptying the haystack, which would make every
# shape contract pass over an empty string.
grep -q 'cpu:wasm32' <<<"${wasm_arm}" ||
	fail "the comment stripper preserved the runner's wasm invocation" \
		"After stripping comments there is no '--cpu:wasm32' left in the" \
		"runner's wasm arm, so the flag contracts below would be checking a" \
		"string from which the subject has already been removed."

echo "test-vm-unit-wasm lane contracts"

# --- static: the lane is wired to the wasm backend at all -----------------

# 1. The recipe delegates to the shared runner with the lane id this suite is
#    about. Everything below reads the runner's wasm arm, and that proves
#    nothing about THIS lane unless this lane is the one that takes it.
lane_id="$(grep -oE 'run-nim-test-lane\.sh[[:space:]]+[a-z0-9-]+' <<<"${recipe_joined}" |
	awk '{print $2}' | head -n1)"
if [ "${lane_id}" = "vm-unit-wasm" ]; then
	ok "test-vm-unit-wasm delegates to the shared runner as lane 'vm-unit-wasm'"
else
	fail "test-vm-unit-wasm delegates to the shared runner as lane 'vm-unit-wasm'" \
		"got lane id '${lane_id}'. Every contract below inspects the runner's" \
		"wasm arm; if this recipe does not route through it they are vacuous."
fi

# 2. The lane library routes that id to the wasm backend. This is the single
#    source of truth for the choice, so ask it rather than inferring it.
if [ "$(bash -c "source '${LANE_LIB}' && test_lane_backend vm-unit-wasm")" = "wasm" ]; then
	ok "the lane library routes vm-unit-wasm through the runner's wasm backend"
else
	fail "the lane library routes vm-unit-wasm through the runner's wasm backend" \
		"test_lane_backend vm-unit-wasm did not answer 'wasm', so this lane" \
		"would compile natively and the whole milestone's third backend would" \
		"be a second copy of its first."
fi

# 3. The lane is NOT empty, and is not the whole of vm-unit either. Both
#    directions matter: an empty lane is the vacuous pass, and a lane equal to
#    vm-unit would mean the six documented exclusions silently stopped being
#    applied.
wasm_files="$(bash -c "cd '${REPO_ROOT}' && source '${LANE_LIB}' && test_lane_files vm-unit-wasm" | grep -c . || true)"
native_files="$(bash -c "cd '${REPO_ROOT}' && source '${LANE_LIB}' && test_lane_files vm-unit" | grep -c . || true)"
if [ "${wasm_files}" -gt 0 ] && [ "${wasm_files}" -lt "${native_files}" ]; then
	ok "vm-unit-wasm runs ${wasm_files} of vm-unit's ${native_files} files"
else
	fail "vm-unit-wasm runs a non-empty proper subset of vm-unit" \
		"got ${wasm_files} wasm file(s) against ${native_files} native." \
		"Zero is the vacuous pass; equal means the six documented exclusions" \
		"are no longer being applied."
fi

# --- static: the flags whose absence is silent ----------------------------

# 4. `--mm:orc` is PLAT-17's own deliverable and must be explicit. Nim 2.x
#    defaults to orc, which is exactly why this is asserted: a measurement
#    that inherits a default cannot name the memory manager it was taken
#    under, and Verification-Harness-Traps.md §12b is about precisely that.
if grep -qE 'nim c .*--mm:orc' <<<"${wasm_arm}"; then
	ok "the wasm compile passes --mm:orc explicitly"
else
	fail "the wasm compile passes --mm:orc explicitly" \
		"PLAT-17's second deliverable is '--mm:orc under a linear-memory" \
		"target'. Relying on Nim's default makes the lane's memory manager a" \
		"property of the compiler version rather than of this repository."
fi

# 5. `-sEXIT_RUNTIME=1`. This is the `-d:nodejs` of a wasm lane: without it a
#    failing suite's status need not reach node's exit code, and the lane is
#    green over a red suite. Contract 10 proves it works; this one pins that
#    it is passed.
if grep -qE 'passL:-sEXIT_RUNTIME=1' <<<"${wasm_arm}"; then
	ok "the wasm compile passes -sEXIT_RUNTIME=1"
else
	fail "the wasm compile passes -sEXIT_RUNTIME=1" \
		"Without it emscripten need not propagate main's status, and a" \
		"failing suite can exit 0 — the JS lane's original defect in a" \
		"different spelling."
fi

# 6. `-sSTACK_SIZE`. Emscripten's default stack is 64 KB against a native
#    thread's 8 MiB, and two suites in this lane sit between the two.
#    Contract 11 proves that; this one pins the flag.
if grep -qE 'passL:-sSTACK_SIZE=' <<<"${wasm_arm}"; then
	ok "the wasm compile raises the stack above emscripten's 64 KB default"
else
	fail "the wasm compile raises the stack above emscripten's 64 KB default" \
		"Without it a deeply recursive suite dies with 'memory access out of" \
		"bounds' and no Nim frame in the trace, which reads as a miscompile" \
		"rather than as a stack overflow."
fi

# 7. `-sNODERAWFS=1`. This is the flag that decides the FILE SET: without it
#    emscripten's in-memory MEMFS replaces node's filesystem and every suite
#    that reads a fixture or writes a temporary directory would have to be
#    excluded — for a reason about the harness rather than about the platform,
#    which is the shape §2.1.4 forbids.
if grep -qE 'passL:-sNODERAWFS=1' <<<"${wasm_arm}"; then
	ok "the wasm compile uses node's real filesystem (-sNODERAWFS=1)"
else
	fail "the wasm compile uses node's real filesystem (-sNODERAWFS=1)" \
		"Without it the lane's file set shrinks by every suite that touches" \
		"a file, and a quietly smaller file set is what this milestone" \
		"exists to not reproduce."
fi

# 8. A missing toolchain must FAIL, never skip. The whole milestone rests on
#    the lane actually running; a lane that answers 'nothing to do, exit 0'
#    when emcc stops resolving satisfies every aggregate above it while
#    measuring nothing.
if grep -qE 'command -v emcc' <<<"${runner_joined}" &&
	grep -qE "ERROR: lane .*'emcc' is not on PATH" <<<"${runner_joined}"; then
	ok "a missing emcc fails the lane by name rather than skipping it"
else
	fail "a missing emcc fails the lane by name rather than skipping it" \
		"The runner must refuse to run a wasm lane without the toolchain." \
		"A skippable lane is indistinguishable from a passing one in every" \
		"aggregate that contains it."
fi

# 9. The parity gate exists and is reachable. `test-vm-unit-wasm` on its own
#    only says the lane is green, and green is the weaker claim — §2.1.4 asks
#    for equal counts against native.
if grep -qE '^test-vm-unit-wasm-parity:' "${JUSTFILE}" &&
	[ -f "${REPO_ROOT}/ci/test/vm-unit-wasm-parity.sh" ]; then
	ok "the count-equality gate exists as its own recipe and script"
else
	fail "the count-equality gate exists as its own recipe and script" \
		"Uniform-WASM-Core.md §2.1.4 asks for the same case count and the" \
		"same assertion count as native, not merely green. Without" \
		"test-vm-unit-wasm-parity nothing in this tree checks that."
fi

# --- dynamic: prove the two load-bearing flags against the real toolchain --

if ! command -v nim >/dev/null 2>&1 ||
	! command -v emcc >/dev/null 2>&1 ||
	! command -v node >/dev/null 2>&1; then
	# One skip per contract in the else arm. There are THREE.
	skip "nim/emcc/node not all on PATH; cannot verify -sEXIT_RUNTIME"
	skip "nim/emcc/node not all on PATH; cannot verify the stack-size claim"
	skip "nim/emcc/node not all on PATH; cannot verify that a passing suite exits 0"
else
	tmp_dir="$(mktemp -d)"
	trap 'rm -rf "${tmp_dir}"' EXIT

	wasm_build() { # wasm_build SRC OUT EXTRA...
		local src="$1" out="$2"
		shift 2
		nim c --hints:off --warnings:off \
			--cpu:wasm32 --os:linux -d:emscripten \
			--cc:clang --clang.exe:emcc --clang.linkerexe:emcc \
			--mm:orc --threads:off \
			--passL:-sNODERAWFS=1 \
			--passL:-sALLOW_MEMORY_GROWTH=1 \
			"$@" \
			--nimcache:"${tmp_dir}/cache-$(basename "${out}" .js)" \
			-o:"${out}" "${src}" >"${out}.build.log" 2>&1
	}

	# 10. A failing suite must exit non-zero under this lane's flags.
	cat >"${tmp_dir}/failing.nim" <<'EOF'
import std/unittest
suite "deliberately failing":
  test "this check must fail":
    check 1 == 2
EOF
	set +e
	wasm_build "${tmp_dir}/failing.nim" "${tmp_dir}/failing.js" \
		--passL:-sEXIT_RUNTIME=1 --passL:-sSTACK_SIZE=8388608
	failing_build_rc=$?
	node "${tmp_dir}/failing.js" >/dev/null 2>&1
	failing_rc=$?
	set -e
	if [ "${failing_build_rc}" -ne 0 ]; then
		fail "a failing suite exits non-zero under this lane's flags" \
			"the probe did not build; see ${tmp_dir}/failing.js.build.log"
	elif [ "${failing_rc}" -ne 0 ]; then
		ok "a failing suite exits non-zero under this lane's flags (got ${failing_rc})"
	else
		fail "a failing suite exits non-zero under this lane's flags" \
			"node exited 0 for a suite whose only test fails. The lane cannot" \
			"detect a failure at all, which is the JS lane's original defect."
	fi

	# 11. The stack size is load-bearing, proved by the pair.
	#
	#     This is the contract that stops -sSTACK_SIZE from becoming cargo
	#     cult, and its shape had to be MEASURED rather than guessed. The
	#     probe must sit between two bounds and under a third:
	#
	#       * above emscripten's 64 KB default, or the small build passes and
	#         the flag has no evidence;
	#       * below the 8 MiB this lane asks for, or BOTH builds die and the
	#         pair proves nothing — the first draft used 20,000 frames and did
	#         exactly that, which the third arm below caught;
	#       * under Nim's own call-depth limit, which is 2,000 in a debug
	#         build and is a DIFFERENT failure with a Nim traceback rather
	#         than a wasm trap. A probe deep enough to hit it is measuring
	#         Nim's guard and not emscripten's stack.
	#
	#     1,000 frames carrying a 256-element int array is about 2 MiB: thirty
	#     times the default, a quarter of the flag, and half the call limit.
	#     If emscripten ever changes its default, the first half of this
	#     contract fails and says so, rather than leaving a flag nobody can
	#     justify.
	cat >"${tmp_dir}/deep.nim" <<'EOF'
proc descend(n: int): int =
  # A local array per frame, so the frame is big enough for the depth below to
  # be a stack question rather than a tail-call question.
  var pad: array[256, int]
  pad[0] = n
  if n <= 0: return pad[0]
  descend(n - 1) + pad[0] - pad[0]
echo "depth-ok ", descend(1_000)
EOF
	set +e
	wasm_build "${tmp_dir}/deep.nim" "${tmp_dir}/deep-small.js" \
		--passL:-sEXIT_RUNTIME=1
	small_build_rc=$?
	node "${tmp_dir}/deep-small.js" >/dev/null 2>&1
	small_rc=$?
	wasm_build "${tmp_dir}/deep.nim" "${tmp_dir}/deep-big.js" \
		--passL:-sEXIT_RUNTIME=1 --passL:-sSTACK_SIZE=8388608
	big_build_rc=$?
	node "${tmp_dir}/deep-big.js" >/dev/null 2>&1
	big_rc=$?
	set -e
	if [ "${small_build_rc}" -ne 0 ] || [ "${big_build_rc}" -ne 0 ]; then
		fail "the stack-size flag is load-bearing" \
			"one of the two probes did not build; see ${tmp_dir}/*.build.log"
	elif [ "${small_rc}" -ne 0 ] && [ "${big_rc}" -eq 0 ]; then
		ok "the stack-size flag is load-bearing (default dies ${small_rc}, 8 MiB passes)"
	elif [ "${small_rc}" -eq 0 ]; then
		fail "the stack-size flag is load-bearing" \
			"a 1,000-frame recursion survived emscripten's DEFAULT stack, so" \
			"-sSTACK_SIZE is no longer justified by this evidence. Either the" \
			"default grew or the probe stopped recursing; do not keep a flag" \
			"whose reason has evaporated."
	else
		fail "the stack-size flag is load-bearing" \
			"the 8 MiB build ALSO died (${big_rc}). The flag is being passed" \
			"and is not having the effect it is passed for."
	fi

	# 12. THE NEGATIVE CONTROL FOR CONTRACT 10, and it is not decoration.
	#
	#     Contract 10 is satisfied by anything that makes node exit non-zero
	#     — a link error, a missing file, a runtime trap on startup. Without
	#     this, a build in which EVERY suite died on load would score contract
	#     10 green and the lane would be certified by its own breakage. So:
	#     the same flags, a suite that PASSES, must exit 0.
	cat >"${tmp_dir}/passing.nim" <<'EOF'
import std/unittest
suite "deliberately passing":
  test "this check must pass":
    check 1 == 1
EOF
	set +e
	wasm_build "${tmp_dir}/passing.nim" "${tmp_dir}/passing.js" \
		--passL:-sEXIT_RUNTIME=1 --passL:-sSTACK_SIZE=8388608
	passing_build_rc=$?
	passing_out="$(node "${tmp_dir}/passing.js" 2>&1)"
	passing_rc=$?
	set -e
	if [ "${passing_build_rc}" -ne 0 ]; then
		fail "a passing suite exits 0 and reports its case" \
			"the probe did not build; see ${tmp_dir}/passing.js.build.log"
	elif [ "${passing_rc}" -eq 0 ] && grep -q '\[OK\]' <<<"${passing_out}"; then
		ok "a passing suite exits 0 and prints its [OK] line"
	else
		fail "a passing suite exits 0 and reports its case" \
			"exit ${passing_rc}, output: ${passing_out}" \
			"Contract 10's non-zero exit would then be proving only that" \
			"something is broken, not that failures are detected."
	fi
fi

echo

# Reconcile against the declared total before reporting anything — a contract
# that neither ran nor announced itself skipped is invisible, and a count
# without a denominator cannot say what it failed to mention.
accounted=$((pass_count + skip_count))
if [ "${accounted}" -ne "${TOTAL_CONTRACTS}" ]; then
	fail "every contract is accounted for as run or skipped" \
		"declared TOTAL_CONTRACTS=${TOTAL_CONTRACTS} but ${pass_count} ran and" \
		"${skip_count} were skipped, which accounts for ${accounted}."
fi

if [ "${skip_count}" -eq 0 ]; then
	echo "contracts: ${pass_count} of ${TOTAL_CONTRACTS} ran, 0 skipped"
	echo "test-vm-unit-wasm lane: all contracts hold."
else
	echo "contracts: ${pass_count} of ${TOTAL_CONTRACTS} ran, ${skip_count} skipped" \
		"(no nim/emcc/node in this environment)"
	echo "test-vm-unit-wasm lane: the ${pass_count} contracts this environment can check hold."
	echo "  NOTE: the ${skip_count} skipped contract(s) are the ones that PROVE the flags are"
	echo "  load-bearing. They run inside the dev shell, where emscripten is."
fi
