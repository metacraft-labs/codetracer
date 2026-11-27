#!/usr/bin/env bash
# =============================================================================
# Pinned repro vs. sibling recipes — the `repro` this repo's `reprobuild`
# flake pin builds must be able to compile the `repro.nim` of every sibling
# that codetracer's own build enters through `repro exec`.
#
# ## Why
#
# codetracer's reprobuild pin is a FLOOR for more than this repo's recipe.
# `src/db-backend/build.rs` (`regenerate_c`) runs
#
#     repro exec <codetracer-native-recorder> -- bash ct_emulator/build_native_api.sh
#
# with the `repro` the dev shell ships, so that `repro` compiles the native
# recorder's `repro.nim`. When the sibling adopts a DSL feature the pinned
# reprobuild does not have yet, the db-backend build dies inside cargo:
#
#     codetracer-native-recorder/repro.nim(169, 3) Error: undeclared identifier: 'pinned'
#     thread 'main' panicked at build.rs:1130:17:
#
# That is what happened when codetracer-native-recorder 993c42c6 adopted
# `pinned:` (reprobuild c1e518185, first released in v0.2.36) while this repo
# pinned reprobuild 2f7cb5db52 (0.2.31) (codetracer-pm issue
# 2026-11-27-native-recorder-repro-nim-uses-pinned-which-codetracers-dev-shell-
# reprobuild-cannot-parse.md). Nothing on a codetracer pull request compiles
# the sibling recipe before `cargo` does, minutes into a lane, and the panic
# names build.rs rather than the pin.
#
# ## What it runs
#
# The PINNED repro, never an ambient or sibling one. It resolves the flake's
# `reprobuild` input through `builtins.getFlake` on this checkout, so the
# binary is the very store path `nix develop '.?submodules=1'` puts on PATH
# (the input's `follows` overrides included), built by `nix build` when it is
# not in the store yet. `repro` on PATH is NOT used: in a workspace checkout
# `.envrc` sets `NIX_FLAKE_OVERRIDE_AUTO=1`, so the shell's `repro` is the
# `../reprobuild` sibling's HEAD and says nothing about the pin. For the same
# reason `REPROBUILD_SOURCE_ROOT` and `REPROBUILD_PACKAGES_ROOT` are set to the
# pinned inputs, exactly as nix/shells/ci-base.nix exports them, because the
# recipe is compiled against those trees, not against the binary alone, and
# `IO_MON_SRC` falls back to the pinned `io-mon` as nix/shells/main.nix does.
#
# A RunQuota daemon that refuses the client (`runquotad at ... refused this
# client`) is reported apart too: nothing was compiled, so it says nothing about
# the pin, and it still fails, as the db-backend build would.
#
# A refusal that names `no acceptable source for <VAR>` is reported apart: the
# pinned repro refuses a workspace checkout that is behind the revision it
# pins, which says the workspace lags the pin, not that the pin lacks a DSL
# feature. It still fails, because the dev shell's build would fail the same
# way.
#
# Each sibling is then entered with `repro exec <sibling> -- true`, the same
# activation build.rs performs, minus the build.
#
# ## Siblings
#
# By default the one build.rs drives, found the way build.rs finds it:
# `$CT_CODETRACER_NATIVE_RECORDER_SIBLING`, else `<workspace>/codetracer-native-recorder`
# (this checkout's parent). Arguments replace that list with the given sibling
# directories.
#
# ## Skips are loud, never silent
#
# A missing sibling, or no `nix` on PATH, prints a SKIP naming what is missing
# and exits 0 having verified nothing about it. CT_PINNED_REPRO_SIBLING_RECIPES_STRICT=1
# turns every skip into a failure. Failing to LOCATE or BUILD the pinned repro
# is never a skip: the pin exists, and not being able to read it is a failure
# that names itself.
#
# Run: bash scripts/test-pinned-repro-sibling-recipes.sh [<sibling-dir>...]
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRICT="${CT_PINNED_REPRO_SIBLING_RECIPES_STRICT:-0}"
SKIPPED=0

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

skip() {
	if [ "$STRICT" = "1" ]; then
		echo "FAIL (CT_PINNED_REPRO_SIBLING_RECIPES_STRICT=1): $*" >&2
		exit 1
	fi
	echo "SKIP: $*" >&2
	SKIPPED=$((SKIPPED + 1))
}

command -v nix >/dev/null 2>&1 || {
	skip "nix is not on PATH, so the pinned reprobuild cannot be located; run inside the dev shell (\`nix develop '.?submodules=1' --command just test-pinned-repro-sibling-recipes\`)."
	echo "SKIP: pinned repro vs. sibling recipes was NOT verified by this run." >&2
	exit 0
}

# --- the siblings ------------------------------------------------------------
siblings=()
if [ "$#" -gt 0 ]; then
	siblings=("$@")
else
	native="${CT_CODETRACER_NATIVE_RECORDER_SIBLING:-$REPO_ROOT/../codetracer-native-recorder}"
	siblings=("$native")
fi

present=()
for s in "${siblings[@]}"; do
	if [ -f "$s/repro.nim" ]; then
		present+=("$(cd "$s" && pwd)")
	else
		skip "no repro.nim at $s; clone the sibling (\`repro ws enable codetracer\` from the workspace root) or point CT_CODETRACER_NATIVE_RECORDER_SIBLING at it."
	fi
done
if [ "${#present[@]}" -eq 0 ]; then
	echo "SKIP: pinned repro vs. sibling recipes was NOT verified by this run (no sibling present)." >&2
	exit 0
fi

# --- the pinned reprobuild ---------------------------------------------------
# One evaluation answers all five facts, from the same lock the dev shell
# reads. `getFlake` writes no lock file.
system="$(nix eval --raw --impure --expr builtins.currentSystem)" ||
	fail "nix could not report builtins.currentSystem"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
# Newline-separated, one fact per line; no store path or revision holds one.
pin_facts="$(nix eval --raw --impure --expr "
  let f = builtins.getFlake \"$REPO_ROOT\"; r = f.inputs.reprobuild; in
  builtins.concatStringsSep \"\\n\" [
    (r.rev or \"(unlocked)\")
    r.outPath
    f.inputs.\"reprobuild-packages\".outPath
    f.inputs.\"io-mon\".outPath
    r.packages.\"$system\".reprobuild.drvPath
  ]" 2>"$err")" ||
	fail "could not evaluate the flake's \`reprobuild\` input. This is a failure to READ the pin, not a verdict about any sibling. nix stderr:
$(cat "$err")"
{
	read -r pin_rev
	read -r pin_src
	read -r pin_catalog
	read -r pin_io_mon
	read -r pin_drv
} <<<"$pin_facts"
[ -n "${pin_drv:-}" ] || fail "nix answered an incomplete description of the \`reprobuild\` input: $pin_facts"

pin_out="$(nix build --no-link --print-out-paths "$pin_drv^out" 2>"$err")" ||
	fail "could not build the pinned reprobuild $pin_rev ($pin_drv). Not a verdict about any sibling. nix stderr:
$(tail -n 30 "$err")"
repro="$pin_out/bin/repro"
[ -x "$repro" ] || fail "the pinned reprobuild $pin_rev built to $pin_out, which has no bin/repro"
echo "pinned reprobuild: $pin_rev ($pin_out)"

# --- the check ---------------------------------------------------------------
failures=0
for s in "${present[@]}"; do
	srev="$(git -C "$s" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"
	log="$(mktemp)"
	# IO_MON_SRC only when the caller has none, as nix/shells/main.nix does.
	if env REPROBUILD_SOURCE_ROOT="$pin_src" REPROBUILD_PACKAGES_ROOT="$pin_catalog" \
		IO_MON_SRC="${IO_MON_SRC:-$pin_io_mon/src}" \
		"$repro" exec "$s" -- true >"$log" 2>&1; then
		echo "PASS: pinned repro ($pin_rev) activates $s (at $srev)"
	else
		failures=$((failures + 1))
		recipe_err="$(grep -m1 -E 'repro\.nim\([0-9]+, [0-9]+\) Error:' "$log" || true)"
		drift="$(grep -c 'no acceptable source for' "$log" || true)"
		rq_refused="$(grep -c 'runquotad at .* refused this client' "$log" || true)"
		if [ -n "$recipe_err" ]; then
			echo "FAIL: the reprobuild codetracer pins ($pin_rev, flake.lock input \`reprobuild\`) cannot compile the recipe of sibling $s (at $srev):" >&2
			echo "        $recipe_err" >&2
			echo "      codetracer's build enters this sibling with \`repro exec\` (src/db-backend/build.rs), so its" >&2
			echo "      repro.nim may use only DSL the pinned reprobuild carries. Move codetracer's pin to an" >&2
			echo "      'agents' revision that has the feature (re-lock flake.lock, then" >&2
			echo "      'repro lock update reprobuild --to <rev>'), or back the feature out of the sibling." >&2
		elif [ "$drift" -gt 0 ]; then
			echo "FAIL: the pinned reprobuild ($pin_rev) compiled nothing for $s (at $srev): $drift workspace" >&2
			echo "      checkout(s) it would compile against are behind the revisions it pins. That is the" >&2
			echo "      workspace lagging the pin, not a DSL the pin lacks: sync those siblings ('repro sync')," >&2
			echo "      or point their *_SRC variable at a tree of the pin, as the refusal below says." >&2
		elif [ "$rq_refused" -gt 0 ]; then
			echo "FAIL: the pinned reprobuild ($pin_rev) compiled nothing for $s (at $srev): the RunQuota" >&2
			echo "      daemon refused this client before activation. That is this host's RunQuota setup, not" >&2
			echo "      a DSL the pin lacks; the refusal below names the daemon. Point RUNQUOTA_SOCKET at a" >&2
			echo "      runquotad that serves this namespace and run again." >&2
		else
			echo "FAIL: \`repro exec $s -- true\` with the pinned reprobuild ($pin_rev) failed (sibling at $srev); last lines:" >&2
		fi
		tail -n 25 "$log" | sed 's/^/        /' >&2
	fi
	rm -f "$log"
done

if [ "$failures" -gt 0 ]; then
	echo "FAIL: $failures sibling(s) could not be entered with the pinned reprobuild $pin_rev (see above for which reason)" >&2
	exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
	echo "SKIP: $SKIPPED sibling(s) were NOT verified by this run." >&2
fi
