#!/usr/bin/env bash
# ci/test/tree-sitter-nim-parser-test.sh -- the dev shell's prebuilt
# tree-sitter-nim parser is what `tree-sitter generate` writes for the pinned
# grammar, and the shell copies it only for that grammar.
#
# Every fresh checkout used to run `tree-sitter generate` for
# libs/tree-sitter-nim/src/parser.c (about 6 minutes at a 7.6 GB peak on each
# garm shard of run 44269676398). The tree-sitter-nim-parser package now
# generates it once and the dev shells copy it
# (non-nix-build/ensure_tree_sitter_nim_parser.sh). This holds:
#   * the package was generated from the checkout's grammar.js (its recorded
#     sha256), with the tree-sitter CLI the dev shells carry;
#   * its parser.c and node-types.json are byte-identical to a fresh
#     `tree-sitter generate` of the checkout's grammar with that CLI;
#   * the gate copies them when the grammar matches, and generates when it does
#     not (a fake CLI records whether it ran), leaving a newer grammar.js
#     regenerated rather than shadowed by a stale copy.
# Run by ci/lint/nix.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

system="$(nix eval --impure --raw --expr builtins.currentSystem)"
pkg="$(nix build --no-link --print-out-paths ".?submodules=1#packages.${system}.tree-sitter-nim-parser")"
# The CLI the package was built with, read from its derivation, so the
# comparison below cannot use a different tree-sitter than the package did.
cli="$(nix eval --raw ".?submodules=1#packages.${system}.tree-sitter-nim-parser" \
	--apply 'p: builtins.toString (builtins.head p.nativeBuildInputs)')/bin/tree-sitter"
# And its node, which `tree-sitter generate` runs to evaluate grammar.js.
node_bin="$(nix eval --raw ".?submodules=1#packages.${system}.tree-sitter-nim-parser" \
	--apply 'p: let n = builtins.elemAt p.nativeBuildInputs 1; in builtins.toString (n.out or n)')/bin"
nix build --no-link "$(dirname "$(dirname "$cli")")" "$(dirname "$node_bin")" >/dev/null 2>&1 || true
[ -x "$node_bin/node" ] || fail "no node at ${node_bin}: the comparison below cannot run"

grammar=libs/tree-sitter-nim/grammar.js
check "the package was generated from the checkout's grammar.js" \
	"the package's grammar.js.sha256 is not the checkout's" \
	test "$(<"$pkg/grammar.js.sha256")" = "$(sha256sum "$grammar" | cut -d' ' -f1)"
# shellcheck disable=SC2016 # a Nix expression, not shell
same_cli="$(nix eval --impure --raw --expr "
  let
    f = builtins.getFlake \"git+file://${root}?submodules=1\";
    ts = builtins.head f.packages.${system}.tree-sitter-nim-parser.nativeBuildInputs;
    inputsOf = s: map toString ((s.nativeBuildInputs or [ ]) ++ (s.buildInputs or [ ]));
  in if builtins.all (s: builtins.elem (toString ts) (inputsOf f.devShells.${system}.\${s})) [ \"ci\" \"default\" ]
     then \"yes\" else \"no\"")"
check "with the tree-sitter both dev shells carry ($(<"$pkg/tree-sitter.version"))" \
	"the package's tree-sitter is not the one devShells.ci and .default carry" \
	test "$same_cli" = yes

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$grammar" libs/tree-sitter-nim/tree-sitter.json libs/tree-sitter-nim/package.json "$work/"
(cd "$work" && PATH="$node_bin:$PATH" "$cli" generate >/dev/null 2>"$work/generate.err") ||
	fail "a fresh \`tree-sitter generate\` of the grammar failed: $(tail -3 "$work/generate.err")"
for f in parser.c node-types.json; do
	check "src/${f} equals a fresh \`tree-sitter generate\` of the grammar" \
		"src/${f} differs from a fresh generate" cmp -s "$pkg/src/$f" "$work/src/$f"
done

# The gate, against a scratch copy of the submodule and a fake CLI that records
# whether it was asked to generate.
gate_root="$work/gate"
mkdir -p "$gate_root/libs/tree-sitter-nim/src" "$work/bin"
cp "$grammar" libs/tree-sitter-nim/package.json "$gate_root/libs/tree-sitter-nim/"
cat >"$work/bin/tree-sitter" <<FAKE
#!/usr/bin/env bash
echo "\$*" >>"$work/cli.log"
[ "\$1" = generate ] && echo generated >src/parser.c && echo '[]' >src/node-types.json
exit 0
FAKE
chmod +x "$work/bin/tree-sitter"
gate() {
	rm -f "$work/cli.log"
	PATH="$work/bin:$PATH" ROOT_DIR="$gate_root" CT_TREE_SITTER_NIM_PARSER="$pkg" \
		bash "$root/non-nix-build/ensure_tree_sitter_nim_parser.sh" >"$work/gate.log" 2>&1
}
gate
check "matching grammar: the prebuilt parser is copied" "the gate did not copy it: $(cat "$work/gate.log")" \
	cmp -s "$pkg/src/parser.c" "$gate_root/libs/tree-sitter-nim/src/parser.c"
check "and nothing is generated" "the gate ran tree-sitter: $(cat "$work/cli.log" 2>/dev/null)" \
	test ! -e "$work/cli.log"
sleep 1
echo "// edited" >>"$gate_root/libs/tree-sitter-nim/grammar.js"
gate
check "edited grammar: the gate generates instead of copying" \
	"an edited grammar.js was not regenerated: $(cat "$work/gate.log")" \
	grep -q '^generate' "$work/cli.log"
check "and the stale prebuilt parser is not what is left" "the prebuilt parser shadows the edited grammar" \
	test "$(cat "$gate_root/libs/tree-sitter-nim/src/parser.c")" = generated

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
