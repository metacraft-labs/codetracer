#!/usr/bin/env bash
#
# portable-pre-commit-test.sh -- contract suite for the non-Nix hook layer:
# ci/dev/portable-pre-commit.py, ci/dev/portable-pre-commit.sh and
# ci/dev/install-portable-git-hooks.sh.
#
# WHAT IS BEING PINNED. That layer exists so a host without Nix -- native
# Windows -- runs the checks nix/pre-commit.nix declares instead of running
# nothing. Its failure mode is therefore never a crash; it is a check that
# quietly stops happening. Every case below is aimed at one way that could
# occur:
#
#   1. a hook nix/pre-commit.nix enables is absent from what the layer runs
#      (compared against an independent textual reading of the file, so an
#      evaluator bug cannot vouch for itself);
#   2. a hook runs without the tool guard in front of it;
#   3. the tool guard lets a missing tool through, or swallows a failure;
#   4. the evaluator guesses at a construct it does not understand, or drops a
#      built-in it has no definition for;
#   5. `compare`, the lockstep check against git-hooks.nix's own output, cannot
#      see a difference;
#   6. end to end, through a real `git commit` in a scratch repository, a
#      failing check does not block, a missing tool does not block, or a
#      missing pre-commit framework does not block -- or a linked worktree
#      runs no hook at all under git-hooks.nix's relative core.hooksPath.
#
# One stand-in, no mocks: case 3's WSL-launcher check puts EMPTY files named
# bash.exe where the WSL launcher lives, because running the real launcher is
# the very hazard the guard prevents; see the comment at that check.
#
# Case 5 runs against the REAL git-hooks.nix output when this checkout has one
# (the Nix dev shell links it at .pre-commit-config.yaml), and says so either
# way. Case 6 needs the pre-commit framework for its "checks run" half; without
# it, the half that runs is the one asserting the commit is REFUSED for want of
# the framework -- which is the behaviour a host without it must get.
#
# Pure bash + git + python3; no Nix, no network. Real repositories, real git
# hooks, real `git commit`: the property is about what git does with the
# installed hook, and a mock of git would encode the belief under test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNNER="$REPO_ROOT/ci/dev/portable-pre-commit.py"
INSTALLER="$REPO_ROOT/ci/dev/install-portable-git-hooks.sh"

PY=
for candidate in "${PYTHON:-}" python3 python; do
	if [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1 &&
		"$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then
		PY=$candidate
		break
	fi
done
if [ -z "$PY" ]; then
	echo "FAIL: no Python >= 3.9; this suite cannot run" >&2
	exit 1
fi

assertions=0
failures=0
ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "1. every hook nix/pre-commit.nix enables is rendered"

# The independent reading: attribute names directly under `hooks = {`, minus
# any whose own block says `enable = false`. Crude on purpose -- it shares no
# code with the evaluator it is checking.
textual_ids() {
	awk '
		/^  hooks = \{/ { inside = 1; next }
		inside && /^  \};/ { inside = 0 }
		!inside { next }
		match($0, /^    [A-Za-z0-9_-]+/) {
			name = substr($0, 5, RLENGTH - 4)
			current = name
			seen[name] = 1
			if ($0 ~ /\.enable = false/) off[name] = 1
			next
		}
		/^      enable = false;/ { off[current] = 1 }
		END { for (n in seen) if (!(n in off)) print n }
	' "$1" | sort
}

expected=$(textual_ids "$REPO_ROOT/nix/pre-commit.nix")
if ! generated_json=$("$PY" "$RUNNER" generate 2>"$tmp_root/gen.err"); then
	fail "nix/pre-commit.nix renders" "$(cat "$tmp_root/gen.err")"
	generated_json='{"repos":[{"hooks":[]}]}'
fi
# `tr -d '\r'`: a Windows Python ends its lines with CRLF.
rendered=$(printf '%s' "$generated_json" | "$PY" -c 'import json,sys; [print(h["id"]) for h in json.load(sys.stdin)["repos"][0]["hooks"]]' | tr -d '\r' | sort)
count=$(printf '%s\n' "$expected" | grep -c . || true)
if [ "$expected" = "$rendered" ] && [ "$count" -gt 0 ]; then
	ok "all $count enabled hooks are rendered, and nothing else"
else
	fail "the rendered hook set matches nix/pre-commit.nix" \
		"only in nix/pre-commit.nix: $(comm -23 <(echo "$expected") <(echo "$rendered") | tr '\n' ' ')" \
		"only in the rendered config: $(comm -13 <(echo "$expected") <(echo "$rendered") | tr '\n' ' ')"
fi

# The two built-ins git-hooks.nix@3bbec39 gives their OWN `stages`
# (modules/hooks.nix). They are why the Nix path installs a pre-push hook at
# all, and dropping them silently turns the pre-push checks into nothing. The
# first transcription of BUILTINS missed trim-trailing-whitespace's; this pins
# the upstream fact so it cannot regress while no Nix-generated config exists
# to `compare` against.
for id in trim-trailing-whitespace check-added-large-files; do
	stages=$(printf '%s' "$generated_json" | "$PY" -c '
import json, sys
hooks = {h["id"]: h for h in json.load(sys.stdin)["repos"][0]["hooks"]}
print(",".join(hooks[sys.argv[1]]["stages"]) if sys.argv[1] in hooks else "<absent>")
' "$id" | tr -d '\r')
	if [ "$stages" = "pre-commit,pre-push,manual" ]; then
		ok "$id keeps git-hooks.nix's own stages (pre-commit, pre-push, manual)"
	else
		fail "$id keeps git-hooks.nix's own stages" "rendered: $stages"
	fi
done

# ---------------------------------------------------------------------------
echo "2. no hook runs without the tool guard"

unguarded=$("$PY" "$RUNNER" generate --runtime | "$PY" -c '
import json, shlex, sys
for h in json.load(sys.stdin)["repos"][0]["hooks"]:
    argv = shlex.split(h["entry"])
    if argv[2:5] != ["exec", h["id"], "--"]:
        print(h["id"])
' | tr -d '\r')
if [ -z "$unguarded" ]; then
	ok "every runtime entry is 'exec <its own id> --'"
else
	fail "every runtime entry goes through exec" "unguarded: $unguarded"
fi

# ---------------------------------------------------------------------------
echo "3. the tool guard"

set +e
out=$("$PY" "$RUNNER" exec demo-hook -- codetracer-no-such-tool-xyz --flag 2>&1)
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'CANNOT RUN' <<<"$out" && grep -q 'remedy:' <<<"$out"; then
	ok "a missing tool fails the hook, by name, with a remedy"
else
	fail "a missing tool fails loudly" "rc=$rc" "$out"
fi

set +e
"$PY" "$RUNNER" exec demo-hook -- git --version >/dev/null 2>&1
rc_ok=$?
"$PY" "$RUNNER" exec demo-hook -- git definitely-not-a-git-command >/dev/null 2>&1
rc_bad=$?
set -e
if [ "$rc_ok" -eq 0 ] && [ "$rc_bad" -ne 0 ]; then
	ok "a present tool's exit status passes through, success and failure alike"
else
	fail "exit status passes through" "success gave $rc_ok, failure gave $rc_bad"
fi

# `bash` resolving to the WSL launcher must fail the hook, not run it inside a
# Linux distribution. Windows only: the guard is a no-op elsewhere, by design.
#
# The launchers here are EMPTY FILES named bash.exe, under a stand-in
# %SystemRoot%\system32 and a stand-in WindowsApps directory (where a Store
# install of WSL puts it) placed first on PATH. Not a mock of the tool: the
# guard is exercised end to end through `exec`'s real PATH lookup. It is a
# stand-in because the real launcher is the hazard itself -- if the guard were
# broken, the real one would start WSL -- while an empty file cannot run at all,
# so a broken guard shows up as the missing refusal, never as a side effect.
if [ "${OS:-}" = "Windows_NT" ]; then
	for where in system32 WindowsApps; do
		fake_root="$tmp_root/fake-windir-$where"
		mkdir -p "$fake_root/$where"
		: >"$fake_root/$where/bash.exe"
		native_root=$(cd "$fake_root" && pwd -W)
		set +e
		out=$(FAKE_ROOT="$native_root" FAKE_DIR="$native_root/$where" "$PY" -c '
import importlib.util, os, sys
os.environ["SystemRoot"] = os.environ["FAKE_ROOT"]
os.environ["PATH"] = os.environ["FAKE_DIR"] + os.pathsep + os.environ["PATH"]
spec = importlib.util.spec_from_file_location("ppc", sys.argv[1])
ppc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ppc)
sys.exit(ppc.main(["exec", "demo-hook", "--", "bash", "-c", "exit 0"]))
' "$RUNNER" 2>&1)
		rc=$?
		set -e
		if [ "$rc" -ne 0 ] && grep -q 'the WSL launcher' <<<"$out" && grep -q 'CANNOT RUN' <<<"$out"; then
			ok "bash resolving to the WSL launcher ($where\\bash.exe) fails the hook, by name"
		else
			fail "bash resolving to the WSL launcher ($where) fails loudly" "rc=$rc" "$out"
		fi
	done
else
	echo "  --   WSL-launcher guard NOT RUN: not Windows (the guard only applies there)"
fi

# ---------------------------------------------------------------------------
echo "4. the evaluator refuses rather than guesses"

refuses() {
	local label="$1" needle="$2" body="$3"
	printf '%s\n' "$body" >"$tmp_root/fixture.nix"
	set +e
	out=$(CODETRACER_PRE_COMMIT_NIX="$tmp_root/fixture.nix" "$PY" "$RUNNER" generate 2>&1)
	rc=$?
	set -e
	if [ "$rc" -ne 0 ] && grep -q -- "$needle" <<<"$out"; then
		ok "$label"
	else
		fail "$label" "rc=$rc; expected an error mentioning '$needle'" "$out"
	fi
}

# shellcheck disable=SC2016 # the ${...} is Nix under test, not shell
refuses "string interpolation is an error, not a literal" "interpolation" \
	'{ pkgs }: { hooks = { x = { enable = true; entry = "${pkgs.foo}/bin/foo"; }; }; }'
refuses "function application is an error" "function application" \
	'{ pkgs }: { hooks = { x = { enable = true; entry = pkgs.lib.getExe "x"; }; }; }'
refuses "a built-in with no definition here is an error naming it, not a skip" "hooks.ruff" \
	'{ pkgs }: { hooks = { ruff.enable = true; }; }'
refuses "a hook field this layer does not render is an error" "priority" \
	'{ pkgs }: { hooks = { x = { enable = true; entry = "true"; priority = 5; }; }; }'

# shellcheck disable=SC2016 # Nix and shell text under test, not expansions
printf '%s\n' '{ pkgs, rustPkgs ? null, ... }:
let
  marker = "\\.ct/";
in
{
  excludes = [ "^vendor/" marker ];
  hooks = {
    on = {
      enable = true;
      entry = '"''"'
        bash -c '"'"'echo "$1"'"'"' --
      '"''"';
      extraPackages = [ pkgs.nodePackages.cspell ];
      excludes = [ marker ];
    };
    off = { enable = false; entry = "false"; };
    trim-trailing-whitespace.enable = true;
  };
}' >"$tmp_root/fixture.nix"
fixture_out=$(CODETRACER_PRE_COMMIT_NIX="$tmp_root/fixture.nix" "$PY" "$RUNNER" generate)
# shellcheck disable=SC2016 # the "$1" is the expected Nix string, not an expansion
if printf '%s' "$fixture_out" | "$PY" -c '
import json, sys
c = json.load(sys.stdin)
h = {x["id"]: x for x in c["repos"][0]["hooks"]}
assert set(h) == {"on", "trim-trailing-whitespace"}, set(h)
assert c["exclude"] == "(^vendor/|\\.ct/)", c["exclude"]
assert h["on"]["entry"] == "bash -c '"'"'echo \"$1\"'"'"' --\n", repr(h["on"]["entry"])
assert h["on"]["exclude"] == "(\\.ct/)", h["on"]["exclude"]
assert h["trim-trailing-whitespace"]["types"] == ["text"]
assert h["trim-trailing-whitespace"]["entry"] == "trailing-whitespace-fixer"
'; then
	ok "the supported subset evaluates as Nix would (let, lambda, '' strings, dotted paths, excludes)"
else
	fail "the supported subset evaluates as Nix would" "$fixture_out"
fi

# ---------------------------------------------------------------------------
echo "5. compare sees every difference from git-hooks.nix's output"

# A synthetic git-hooks.nix output: the canonical render with /nix/store
# prefixes put back, which is exactly what compare must see through.
"$PY" "$RUNNER" generate | "$PY" -c '
import json, sys
c = json.load(sys.stdin)
for h in c["repos"][0]["hooks"]:
    if not h["entry"].startswith("bash "):
        h["entry"] = "/nix/store/" + "a" * 32 + "-tool-1.0/bin/" + h["entry"]
json.dump(c, open(sys.argv[1], "w"))
' "$tmp_root/nix-config.json"
if "$PY" "$RUNNER" compare "$tmp_root/nix-config.json" >/dev/null 2>&1; then
	ok "an identical config compares equal through /nix/store prefixes"
else
	fail "an identical config compares equal" "$("$PY" "$RUNNER" compare "$tmp_root/nix-config.json" 2>&1)"
fi
for mutation in drop-hook change-files change-exclude add-hook; do
	"$PY" -c '
import json, sys
c = json.load(open(sys.argv[1])); m = sys.argv[2]; hooks = c["repos"][0]["hooks"]
if m == "drop-hook": hooks.pop()
if m == "change-files": hooks[0]["files"] = "\\.nothing$"
if m == "change-exclude": c["exclude"] = "(^other/)"
if m == "add-hook": hooks.append(dict(hooks[0], id="extra"))
json.dump(c, open(sys.argv[3], "w"))
' "$tmp_root/nix-config.json" "$mutation" "$tmp_root/mutated.json"
	if "$PY" "$RUNNER" compare "$tmp_root/mutated.json" >/dev/null 2>&1; then
		fail "compare notices: $mutation" "it reported the configs identical"
	else
		ok "compare notices: $mutation"
	fi
done

real_config="$REPO_ROOT/.pre-commit-config.yaml"
if [ -e "$real_config" ]; then
	if out=$("$PY" "$RUNNER" compare "$real_config" 2>&1); then
		ok "LOCKSTEP against this checkout's git-hooks.nix output: $(printf '%s' "$out" | tail -n 1)"
	else
		fail "the portable render matches this checkout's git-hooks.nix output" "$out"
	fi
else
	echo "  --   lockstep against real git-hooks.nix output NOT RUN: no .pre-commit-config.yaml"
	echo "       here (the Nix dev shell links one). Run this suite from the dev shell to check it."
fi

# ---------------------------------------------------------------------------
echo "6. end to end, through real git commits"

e2e="$tmp_root/e2e"
git init -q --initial-branch=main "$e2e"
git -C "$e2e" config user.email t@example.com
git -C "$e2e" config user.name t
git -C "$e2e" config core.autocrlf false
mkdir -p "$e2e/ci/dev" "$e2e/nix"
cp "$REPO_ROOT/ci/dev/portable-pre-commit.py" "$REPO_ROOT/ci/dev/portable-pre-commit.sh" \
	"$REPO_ROOT/ci/dev/install-portable-git-hooks.sh" "$e2e/ci/dev/"
cat >"$e2e/nix/pre-commit.nix" <<'EOF'
{ pkgs, ... }:
{
  excludes = [ "^vendor/" ];
  hooks = {
    check-merge-conflict = {
      enable = true;
      name = "merge markers";
      entry = ''
        bash -c 'rc=0; for f in "$@"; do if grep -En "^(<{7}|={7}|>{7})( |$)" "$f" >/dev/null; then echo "Merge conflict markers in $f"; rc=1; fi; done; exit $rc' --
      '';
      language = "system";
      types = [ "text" ];
    };
    needs-missing-tool = {
      enable = true;
      entry = "codetracer-no-such-tool-xyz";
      language = "system";
      files = "\\.needs$";
    };
  };
}
EOF
git -C "$e2e" add -A
git -C "$e2e" commit -q -m "fixture: the hook layer itself" # no hook is installed yet

# What git-hooks.nix leaves behind from a main checkout: the RELATIVE
# core.hooksPath, under which a linked worktree runs no hook at all.
git -C "$e2e" config core.hooksPath .git/hooks
linked="$tmp_root/e2e-linked"
git -C "$e2e" worktree add -q "$linked" -b linked 2>/dev/null

# The installer's slot rules, against a reprobuild-style dispatcher.
hooks="$e2e/.git/hooks"
# shellcheck disable=SC2016 # a script body written to disk; it expands when it runs
printf '#!/bin/sh\n# reprobuild hook dispatcher protocol=2\nL="$(dirname "$0")/pre-commit.repro-local"\n[ -x "$L" ] && exec "$L" "$@"\nexit 0\n' >"$hooks/pre-commit"
chmod +x "$hooks/pre-commit"
printf '#!/nix/store/%s-bash/bin/bash\n# File generated by pre-commit: https://pre-commit.com\n' "$(printf 'b%.0s' $(seq 32))" >"$hooks/pre-commit.repro-local"
printf '#!/bin/sh\necho somebody else\n' >"$hooks/pre-push"
chmod +x "$hooks/pre-commit.repro-local" "$hooks/pre-push"
set +e
inst_out=$(cd "$e2e" && bash "$INSTALLER" 2>&1)
inst_rc=$?
set -e
if grep -q 'managed-by: ci/dev/install-portable-git-hooks.sh' "$hooks/pre-commit.repro-local" &&
	grep -q 'reprobuild hook dispatcher' "$hooks/pre-commit"; then
	ok "behind a reprobuild dispatcher it takes .repro-local, replacing the Nix pre-commit shim"
else
	fail "installs into .repro-local behind a dispatcher" "$inst_out"
fi
if [ "$inst_rc" -ne 0 ] && grep -q 'somebody else' "$hooks/pre-push"; then
	ok "a hook it did not write is left alone, and the installer says so and fails"
else
	fail "a foreign hook is left alone" "rc=$inst_rc" "$inst_out"
fi
(cd "$e2e" && bash "$INSTALLER" --force >/dev/null 2>&1)
if ! git -C "$e2e" config --local --get core.hooksPath >/dev/null &&
	[ -x "$(git -C "$linked" rev-parse --path-format=absolute --git-path hooks)/pre-commit" ]; then
	ok "the relative core.hooksPath is removed, so a linked worktree resolves the shared hooks"
else
	fail "the relative core.hooksPath is removed" "core.hooksPath=$(git -C "$e2e" config --local --get core.hooksPath || echo '<unset>')" "linked worktree hooks dir: $(git -C "$linked" rev-parse --git-path hooks)"
fi

commit() { # <expect: pass|refuse> <label> <needle-or-empty>
	local expect="$1" label="$2" needle="$3" out rc
	set +e
	out=$(git -C "$e2e" commit -m "$label" 2>&1)
	rc=$?
	set -e
	if [ "$expect" = pass ] && [ "$rc" -eq 0 ]; then
		ok "$label: committed"
	elif [ "$expect" = refuse ] && [ "$rc" -ne 0 ] && { [ -z "$needle" ] || grep -q -- "$needle" <<<"$out"; }; then
		ok "$label: refused${needle:+ ($needle)}"
		git -C "$e2e" reset -q --hard HEAD
	else
		fail "$label: expected $expect" "rc=$rc" "$out"
		git -C "$e2e" reset -q --hard HEAD
	fi
}

if (cd "$e2e" && "$PY" -c 'import pre_commit' 2>/dev/null); then
	echo "  (pre-commit $("$PY" -c 'import pre_commit.constants as c; print(c.VERSION)') is installed: running the checks)"
	echo clean >"$e2e/clean.txt" && git -C "$e2e" add clean.txt
	commit pass "a clean change" ""
	printf 'a\n<<<<<<< ours\nb\n' >"$e2e/conflict.txt" && git -C "$e2e" add conflict.txt
	commit refuse "a merge marker" "Merge conflict markers in conflict.txt"
	echo x >"$e2e/thing.needs" && git -C "$e2e" add thing.needs
	commit refuse "a file whose check's tool is missing" "CANNOT RUN"
	mkdir -p "$e2e/vendor" && printf '<<<<<<< ours\n' >"$e2e/vendor/v.txt" && git -C "$e2e" add vendor/v.txt
	commit pass "a merge marker under a globally excluded path" ""
	# The property the hooksPath repair exists for, observed through git itself.
	printf '<<<<<<< ours\n' >"$linked/linked-conflict.txt" && git -C "$linked" add linked-conflict.txt
	set +e
	linked_out=$(git -C "$linked" commit -m "a merge marker, in a linked worktree" 2>&1)
	linked_rc=$?
	set -e
	if [ "$linked_rc" -ne 0 ] && grep -q "Merge conflict markers in linked-conflict.txt" <<<"$linked_out"; then
		ok "a linked worktree's commit runs the hooks and is refused"
	else
		fail "a linked worktree's commit runs the hooks" "rc=$linked_rc" "$linked_out"
	fi
	git -C "$linked" reset -q --hard HEAD
else
	echo "  (the pre-commit framework is NOT installed for $PY: the checks cannot run here)"
fi

# Without the framework the commit must be REFUSED. Asserted on every host, not
# only on those that lack it: a package named `pre_commit` that cannot be
# imported, placed first on PYTHONPATH, shadows whatever is installed.
mkdir -p "$tmp_root/shadow/pre_commit"
echo 'raise ImportError("shadowed by portable-pre-commit-test.sh")' >"$tmp_root/shadow/pre_commit/__init__.py"
echo framework >"$e2e/framework.txt" && git -C "$e2e" add framework.txt
PYTHONPATH="$tmp_root/shadow" commit refuse "any change, without the pre-commit framework" "pip install --user pre-commit=="

# ---------------------------------------------------------------------------
echo
if [ "$failures" -ne 0 ]; then
	echo "portable-pre-commit-test: $failures of $assertions assertions FAILED"
	exit 1
fi
echo "portable-pre-commit-test: all $assertions assertions passed"
