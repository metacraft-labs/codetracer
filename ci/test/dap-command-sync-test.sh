#!/usr/bin/env bash
#
# dap-command-sync-test.sh — the contract suite for ci/test/dap-command-sync.py.
#
# WHY THIS EXISTS
# ---------------
# The same reason ci/test/test-lane-coverage-test.sh exists, and the same reason
# `test_mock_backend_validates_dap_commands.nim` exists one level down: a
# validator that has never rejected anything is indistinguishable from one that
# cannot. The sync guard's whole value is that it goes RED when a command the
# engine dispatches is missing from `VALID_DAP_COMMANDS`. Having watched it
# print OK proves nothing about that.
#
# It is also the guard most at risk of passing vacuously. Every one of its
# checks is a subset test, and a subset test against an EMPTY set passes — so if
# a refactor in `dap_server.rs` breaks the extraction regexes, a guard without
# this suite would go green at the exact moment it stopped working. Cases 5-7
# below are about that failure mode specifically.
#
# The checks driven here:
#
#   1. ENGINE   — a command in the engine's dispatch but not the allow-list
#                 must be named and must fail the run.
#   2. MAPPING  — a non-empty EVENT_KIND_TO_DAP_MAPPING value not in the
#                 allow-list must be named and must fail the run.
#   3. RESIDUE  — an allow-list entry that gains/loses its CtEventKind must
#                 fail, so the untranslatable set cannot grow silently.
#   4. the all-green case still reports green.
#   5. each of the FOUR engine dispatch constructs is actually extracted —
#      the `match` arms, the `_` fallthrough specials, the step-action match,
#      and the message-loop guards. `disconnect` lives only in the last of
#      these, and the nine-vs-ten miscount this guard corrected is exactly what
#      happens when one construct goes unread.
#   6. `#[cfg(test)]` content is NOT counted as engine dispatch.
#   7. the real tree's extraction floors hold (a broken regex is loud).
#
# Pure bash + python3, no Nim toolchain, seconds to run: it belongs in the lint
# stage next to the guard.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/dap-command-sync.py"

failures=0
checks=0

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# run_guard COMMANDS MAPPING ENGINE RESIDUE
run_guard() {
	python3 "${guard}" --commands-from "$1" --mapping-from "$2" \
		--engine-from "$3" --residue "$4" 2>&1
}

# expect NAME EXPECTED_STATUS ACTUAL_STATUS OUTPUT [MUST_CONTAIN...]
expect() {
	local name="$1" want_status="$2" got_status="$3" output="$4"
	shift 4
	checks=$((checks + 1))
	local ok=1
	if [ "${got_status}" != "${want_status}" ]; then
		ok=0
		echo "  [FAILED] ${name}: expected exit ${want_status}, got ${got_status}"
	fi
	local needle
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${output}"; then
			ok=0
			echo "  [FAILED] ${name}: output lacks '${needle}'"
		fi
	done
	if [ "${ok}" -eq 1 ]; then
		echo "  [OK] ${name}"
	else
		failures=$((failures + 1))
		printf '%s\n' "${output}" | sed 's/^/      | /'
	fi
}

echo "=== ci/test/dap-command-sync.py contract suite ==="

# ---------------------------------------------------------------------------
# Synthetic inputs, in the shape of the three real files.
# ---------------------------------------------------------------------------
mk_commands() { # mk_commands FILE cmd...
	local f="$1"
	shift
	{
		echo 'const VALID_DAP_COMMANDS_SEQ*: seq[string] = @['
		local c
		for c in "$@"; do printf '  "%s",\n' "${c}"; done
		echo ']'
	} >"${f}"
}

mk_mapping() { # mk_mapping FILE cmd...
	local f="$1"
	shift
	{
		echo 'const EVENT_KIND_TO_DAP_MAPPING*: array[CtEventKind, cstring] = ['
		local c i=0
		for c in "$@"; do
			i=$((i + 1))
			printf '  Kind%d: "%s",\n' "${i}" "${c}"
		done
		echo '  KindUnmapped: "",'
		echo ']'
	} >"${f}"
}

# A synthetic dap_server.rs exercising ALL FOUR dispatch constructs.
mk_engine() { # mk_engine FILE
	cat >"$1" <<'RUST'
fn dap_command_to_step_action(command: &str) -> Result<(Action, bool), CtDapError> {
    match command {
        "stepIn" => Ok((Action::StepIn, false)),
        "ct/reverseStepIn" => Ok((Action::StepIn, true)),
        _ => Err(CtDapError::new("nope")),
    }
}

fn handle_request(handler: &mut Handler, req: dap::Request) -> Result<(), Box<dyn Error>> {
    match req.command.as_str() {
        "scopes" => handler.scopes(req.clone())?,
        "ct/originMode" => handler.origin_mode(req.clone())?,
        _ => {
            if req.command == "next" {
                handler.next_dap(req)?;
                return Ok(());
            }
        }
    }
    Ok(())
}

fn message_loop(msg: DapMessage) {
    match msg {
        DapMessage::Request(req) if req.command == "disconnect" => shutdown(),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    fn t() {
        let cases = &[("only-in-tests", json!({}))];
        match req.command.as_str() {
            "also-only-in-tests" => unreachable!(),
        }
    }
}
RUST
}

C="${work}/commands.nim"
M="${work}/mapping.nim"
E="${work}/engine.rs"
mk_engine "${E}"

# The synthetic engine dispatches exactly these six.
# AN ARRAY, not a space-separated string. The string form needed an unquoted
# expansion at every use site, which is word splitting AND globbing: a DAP
# command name containing a glob character would have been silently replaced by
# whatever filenames happened to match in the cwd.
ENGINE_SET=(stepIn ct/reverseStepIn scopes ct/originMode next disconnect)

# ---------------------------------------------------------------------------
# 1. ENGINE — engine dispatches it, allow-list does not name it
# ---------------------------------------------------------------------------
mk_commands "${C}" stepIn ct/reverseStepIn ct/originMode next disconnect
mk_mapping "${M}" stepIn ct/reverseStepIn ct/originMode next disconnect
out="$(run_guard "${C}" "${M}" "${E}" "")"
status=$?
expect "a command the engine dispatches but the allow-list omits fails, by name" \
	1 "${status}" "${out}" \
	"scopes" \
	"the ENGINE dispatches are absent"

# ---------------------------------------------------------------------------
# 2. MAPPING — EVENT_KIND_TO_DAP_MAPPING names it, allow-list does not
# ---------------------------------------------------------------------------
mk_commands "${C}" "${ENGINE_SET[@]}"
mk_mapping "${M}" "${ENGINE_SET[@]}" ct/install-source-view
out="$(run_guard "${C}" "${M}" "${E}" "")"
status=$?
expect "a mapped event kind missing from the allow-list fails, by name" \
	1 "${status}" "${out}" \
	"ct/install-source-view" \
	"absent from VALID_DAP_COMMANDS"

# ---------------------------------------------------------------------------
# 3. RESIDUE — an allow-list entry with no CtEventKind, unexpectedly
# ---------------------------------------------------------------------------
mk_commands "${C}" "${ENGINE_SET[@]}" ct/emitted-event
mk_mapping "${M}" "${ENGINE_SET[@]}"
out="$(run_guard "${C}" "${M}" "${E}" "")"
status=$?
expect "an unexpected untranslatable command fails the residue pin, by name" \
	1 "${status}" "${out}" \
	"ct/emitted-event" \
	"no CtEventKind"

# ... and naming it in the pin makes it pass, so the pin is a real allow-list
# and not a blanket "any residue is fine".
out="$(run_guard "${C}" "${M}" "${E}" "ct/emitted-event")"
status=$?
expect "the residue pin accepts exactly the command it names" \
	0 "${status}" "${out}" \
	"OK: every engine-dispatched command"

# A residue entry that DISAPPEARS is also a failure — the pin is an equality,
# not a subset, so a command silently dropped from the allow-list is loud too.
mk_commands "${C}" "${ENGINE_SET[@]}"
out="$(run_guard "${C}" "${M}" "${E}" "ct/emitted-event")"
status=$?
expect "a residue entry that vanished fails the pin too" \
	1 "${status}" "${out}" \
	"ct/emitted-event"

# ---------------------------------------------------------------------------
# 4. the all-green case
# ---------------------------------------------------------------------------
mk_commands "${C}" "${ENGINE_SET[@]}"
mk_mapping "${M}" "${ENGINE_SET[@]}"
out="$(run_guard "${C}" "${M}" "${E}" "")"
status=$?
expect "a fully synchronised set of tables passes" \
	0 "${status}" "${out}" \
	"OK: every engine-dispatched command"

# ---------------------------------------------------------------------------
# 5. every one of the FOUR dispatch constructs is really extracted.
#
# Dropping each command in turn from the allow-list must redden the guard. If a
# construct were not parsed, its command would be absent from the extracted set
# and its arm here would pass green — which is precisely how the tenth command
# (`disconnect`, message-loop only) went unnoticed in the hand-written triage.
# ---------------------------------------------------------------------------
for probe in stepIn:step-action-match \
	ct/reverseStepIn:step-action-match \
	scopes:handle_request-match \
	ct/originMode:handle_request-match \
	next:fallthrough-special \
	disconnect:message-loop-guard; do
	cmd="${probe%%:*}"
	construct="${probe##*:}"
	kept=()
	for c in "${ENGINE_SET[@]}"; do
		[ "${c}" = "${cmd}" ] || kept+=("${c}")
	done
	mk_commands "${C}" "${kept[@]}"
	mk_mapping "${M}" "${kept[@]}"
	out="$(run_guard "${C}" "${M}" "${E}" "")"
	status=$?
	expect "extraction reaches the ${construct}: dropping '${cmd}' reddens the guard" \
		1 "${status}" "${out}" \
		"${cmd}" \
		"the ENGINE dispatches are absent"
done

# ---------------------------------------------------------------------------
# 6. #[cfg(test)] content is not engine dispatch
# ---------------------------------------------------------------------------
mk_commands "${C}" "${ENGINE_SET[@]}"
mk_mapping "${M}" "${ENGINE_SET[@]}"
out="$(run_guard "${C}" "${M}" "${E}" "")"
status=$?
expect "commands that appear only under #[cfg(test)] are not required" \
	0 "${status}" "${out}" \
	"OK: every engine-dispatched command"
checks=$((checks + 1))
if grep -qF "only-in-tests" <<<"${out}"; then
	failures=$((failures + 1))
	echo "  [FAILED] a #[cfg(test)] command leaked into the engine set"
else
	echo "  [OK] no #[cfg(test)] command leaked into the engine set"
fi

# ---------------------------------------------------------------------------
# 7. the REAL tree: the extraction floors hold, so a dead regex is loud
# ---------------------------------------------------------------------------
out="$(python3 "${guard}" 2>&1)"
status=$?
expect "the real tree is in sync" \
	0 "${status}" "${out}" \
	"OK: every engine-dispatched command"

checks=$((checks + 1))
engine_n="$(printf '%s' "${out}" | sed -n 's/^engine dispatches: *//p')"
if [ -n "${engine_n}" ] && [ "${engine_n}" -ge 40 ]; then
	echo "  [OK] real engine dispatch extraction returned ${engine_n} commands"
else
	failures=$((failures + 1))
	echo "  [FAILED] real engine extraction returned '${engine_n}', expected >= 40"
fi

echo ""
# The count itself is asserted: a suite that returned early, or a loop over a
# list that turned out empty, must not be able to report success.
expected_checks=16
if [ "${checks}" -ne "${expected_checks}" ]; then
	echo "dap-command-sync contract: ran ${checks} check(s), expected ${expected_checks}" >&2
	exit 1
fi
if [ "${failures}" -eq 0 ]; then
	echo "dap-command-sync contract: ${checks} check(s) passed"
	exit 0
fi
echo "dap-command-sync contract: ${failures} of ${checks} check(s) FAILED" >&2
exit 1
