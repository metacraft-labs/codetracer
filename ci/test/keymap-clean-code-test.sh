#!/usr/bin/env bash
# shellcheck disable=SC2016  # the expected texts quote backticks literally
#
# keymap-clean-code-test.sh — the contract suite over
# ci/test/keymap-clean-code.sh (Base-Keymaps-And-Layer-Stack.md §8, KL-10).
#
# A guard that has only ever been watched printing OK is not evidence
# (Verification-Harness-Traps §4). Each case below copies the modules the gate
# reads into a synthetic tree — the REAL files, so the baseline is the tree's
# own state — plants exactly one violation, and requires the gate to redden
# on it BY CHECK NAME; the clean copy must pass. The planted second resolver,
# the second decoder and the out-of-order modifier spelling are the controls
# §8 asks for ("a source gate with a planted second resolver").
#
# No mocks: the gate is run as shipped, over copies of the shipped modules.
#
# Usage: ci/test/keymap-clean-code-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${repo_root}/ci/test/keymap-clean-code.sh"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "  ok   $1"
}
bad() {
	fail=$((fail + 1))
	echo "  FAIL $1"
	shift
	while [ $# -gt 0 ]; do
		echo "         $1"
		shift
	done
}

work="$(mktemp -d)"
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

FILES=(
	src/common/key_names.nim
	src/common/key_event_names.nim
	src/frontend/gpui/app/gpui_keys.nim
	src/frontend/gpui/main.nim
	src/frontend/ui/key_router.nim
	src/frontend/tui/app/runtime.nim
)

make_tree() {
	local t="${work}/$1" f
	mkdir -p "${t}/src/frontend/viewmodel/keymap"
	for f in "${FILES[@]}"; do
		mkdir -p "${t}/$(dirname "${f}")"
		cp "${repo_root}/${f}" "${t}/${f}"
	done
	cp "${repo_root}"/src/frontend/viewmodel/keymap/*.nim "${t}/src/frontend/viewmodel/keymap/"
	echo "${t}"
}

# expect_red NAME CHECK TEXT — the gate over tree NAME fails, on check CHECK,
# with a line containing TEXT.
expect_red() {
	local name="$1" check="$2" text="$3" out rc
	out="$(bash "${gate}" "${work}/${name}" 2>&1)"
	rc=$?
	if [ "${rc}" -eq 0 ]; then
		bad "${name}: the gate passed a planted violation" "${out##*$'\n'}"
	elif grep -qF -- "${text}" <<<"$(grep -F -- "FAIL  [${check}]" <<<"${out}")"; then
		ok "${name}: reddens on check ${check}"
	else
		bad "${name}: red, but not on check ${check} with '${text}'" \
			"$(grep 'FAIL' <<<"${out}" | head -3)"
	fi
}

# The clean copy passes.
t="$(make_tree clean)"
if out="$(bash "${gate}" "${t}" 2>&1)"; then
	ok "clean: the shipped modules pass"
else
	bad "clean: the shipped modules fail" "$(grep FAIL <<<"${out}" | head -3)"
fi

# --- check 1: one resolver ------------------------------------------------
t="$(make_tree second-trie-resolver)"
mkdir -p "${t}/src/frontend/tui/app/input"
cat >"${t}/src/frontend/tui/app/input/fast_keys.nim" <<'EOF'
## A planted second resolver: walks the trie itself.
import ../../../viewmodel/keymap/editing_keymap
proc fastResolve*(t: EditingTrie; key: string): int =
  var cur = 0
  if not t.nodes[cur].children.hasKey(key): return -1
  cur = t.nodes[cur].children[key]
  t.nodes[cur].binding
EOF
expect_red second-trie-resolver 1 'fast_keys.nim: `fastResolve`'

t="$(make_tree second-linear-resolver)"
cat >"${t}/src/frontend/ui/quick_keys.nim" <<'EOF'
## A planted second resolver: a linear match over the bindings.
proc quickResolve*(km: EditingKeymap; key: string): EditingResolution =
  for b in km.bindings:
    if b.chords == @[key]:
      return EditingResolution(kind: erOperation, operation: b.operation)
EOF
expect_red second-linear-resolver 1 'quick_keys.nim: `quickResolve`'

t="$(make_tree retired-resolver)"
cat >>"${t}/src/frontend/gpui/main.nim" <<'EOF'
proc actionForChord(chord: string): string = ""
EOF
expect_red retired-resolver 1 "actionForChord"

t="$(make_tree resolver-gone)"
sed -i 's/proc resolveLayers\*/proc resolveLayersRenamed*/' \
	"${t}/src/frontend/viewmodel/keymap/editing_keymap.nim"
expect_red resolver-gone 1 "positive control"

t="$(make_tree comment-is-not-a-resolver)"
cat >"${t}/src/frontend/ui/notes.nim" <<'EOF'
## proc actionForChord was the desktop's; this comment names it, nothing more.
# for b in km.bindings: if b.chords == @[key]: nodeAfter(t, key)
const Notes* = 1
EOF
if bash "${gate}" "${t}" >/dev/null 2>&1; then
	ok "comment-is-not-a-resolver: a comment naming the retired resolver passes"
else
	bad "comment-is-not-a-resolver: the gate read a comment as code"
fi

# --- check 2: one decoder per device -------------------------------------
t="$(make_tree second-speller)"
cat >"${t}/src/frontend/ui/my_names.nim" <<'EOF'
## A planted second decoder: spells names itself.
import ../../common/key_names
proc nameOf*(ctrl: bool; key: string): string =
  chordName((if ctrl: {kmodCtrl} else: {}), key)
EOF
expect_red second-speller 2a "my_names.nim spells key names itself"

t="$(make_tree declared-decoder-stale)"
sed -i 's/chordName(/chordNameX(/g' "${t}/src/common/key_event_names.nim"
expect_red declared-decoder-stale 2a "key_event_names.nim (the desktop's KeyboardEvent decoder) no longer calls"

t="$(make_tree entry-bypasses-decoder)"
sed -i 's/canonicalKeyOfDom(/myOwnKeyOf(/g' "${t}/src/frontend/ui/key_router.nim"
expect_red entry-bypasses-decoder 2b "the desktop's key entry"

t="$(make_tree key-bytes-in-a-view)"
mkdir -p "${t}/src/frontend/tui/app/views"
cat >"${t}/src/frontend/tui/app/views/prompt.nim" <<'EOF'
## A planted byte match: a view reads the terminal's bytes itself.
proc onKey*(token: string): int =
  case token
  of "Up", "\x1b[A": 1
  of "\x1bOH": 2
  else: 0
EOF
expect_red key-bytes-in-a-view 2c 'prompt.nim:4: "\x1b[A"'

t="$(make_tree key-bytes-in-a-test)"
mkdir -p "${t}/src/frontend/tui/tests"
cat >"${t}/src/frontend/tui/tests/test_keys.nim" <<'EOF'
const Up = "\x1b[A"
EOF
mkdir -p "${t}/src/frontend/tui/host"
cat >"${t}/src/frontend/tui/host/probe.nim" <<'EOF'
const Query = "\x1b[?u"   # a query the terminal answers, never a key
EOF
if bash "${gate}" "${t}" >/dev/null 2>&1; then
	ok "key-bytes-in-a-test: a test's bytes and a CSI ? query pass"
else
	bad "key-bytes-in-a-test: the gate read a test or a query as a decoder"
fi

# --- check 3: one modifier order -----------------------------------------
t="$(make_tree modifier-order)"
cat >"${t}/src/frontend/ui/labels.nim" <<'EOF'
const Hint* = "Shift+Ctrl+K"
EOF
expect_red modifier-order 3 '"Shift+Ctrl+K" spells modifiers out of the order'

t="$(make_tree modifier-prefix)"
cat >"${t}/src/frontend/ui/labels.nim" <<'EOF'
proc label*(k: string): string = "Ctrl+Alt+" & k
EOF
expect_red modifier-prefix 3 'builds a multi-modifier prefix'

t="$(make_tree modifier-array)"
cat >"${t}/src/frontend/ui/labels.nim" <<'EOF'
const Order* = ["Shift", "Ctrl", "Alt"]
EOF
expect_red modifier-array 3 "listed out of the order"

t="$(make_tree written-chords-are-input)"
cat >>"${t}/src/frontend/viewmodel/keymap/binding_sets.nim" <<'EOF'
const PlantedWritten = "Alt+Shift+F12"
EOF
if bash "${gate}" "${t}" >/dev/null 2>&1; then
	ok "written-chords-are-input: a written chord in a base's data passes (normalizeChord orders it)"
else
	bad "written-chords-are-input: a written chord was read as a spelled name"
fi

# --- check 4: bases are data ---------------------------------------------
t="$(make_tree procedure-in-a-base)"
cat >>"${t}/src/frontend/viewmodel/keymap/cua_keymap.nim" <<'EOF'
proc extraRows(): seq[string] = @["F13"]
EOF
expect_red procedure-in-a-base 4 "cua_keymap.nim"

t="$(make_tree case-in-a-base)"
cat >>"${t}/src/frontend/viewmodel/keymap/emacs_keymap.nim" <<'EOF'
let planted = (case 1
  of 1: "a"
  else: "b")
EOF
expect_red case-in-a-base 4 "emacs_keymap.nim"

t="$(make_tree base-gone)"
rm "${t}/src/frontend/viewmodel/keymap/navigation_keymap.nim"
expect_red base-gone 4 "navigation_keymap.nim is gone"

# --- check 5: no behaviour in a binding ----------------------------------
t="$(make_tree closure-in-a-row)"
python3 -I - "${t}/src/frontend/viewmodel/keymap/base_rows.nim" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  BaseRow* = object\n", "  BaseRow* = object\n    action*: proc (x: int) {.closure.}\n", 1)
open(p, "w").write(s)
PY
expect_red closure-in-a-row 5 "BaseRow.action"

# --- check 6: one owner per module ---------------------------------------
t="$(make_tree no-refusal)"
sed -i 's/Refuses to own:/Does not take:/' "${t}/src/frontend/viewmodel/keymap/when_expr.nim"
expect_red no-refusal 6 'when_expr.nim: its header has no `Refuses to own:` line'

t="$(make_tree no-header)"
printf 'const X* = 1\n' >"${t}/src/frontend/viewmodel/keymap/new_layer.nim"
expect_red no-header 6 "new_layer.nim: its header does not open"

echo
echo "keymap-clean-code-test: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
