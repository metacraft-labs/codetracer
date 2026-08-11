#!/usr/bin/env bash
#
# resolve-sibling-rev-test.sh — contract suite for resolve-sibling-rev.sh.
#
# `metacraft-github-actions` is a SHARED action repo: several Metacraft
# projects consume `clone-siblings`, and they are not all on the same
# workspace tooling.  The resolver therefore has to serve two lock layouts
# at once during the repo-workspaces -> reprobuild migration, and neither
# may regress the other.  This suite pins both.
#
# It is pure bash + git — no bats, no jq, no coreutils beyond `git` and
# `mkdir`/`rm` — because it must be runnable in the same minimal shells the
# action itself runs in.  Run it directly:
#
#     bash clone-siblings/resolve-sibling-rev-test.sh
#
# Every fixture is a REAL on-disk lock tree (and, for the ancestry-walk
# contracts, a real git repository).  Nothing is mocked: the resolver is
# executed as a subprocess exactly as the action executes it, and its exit
# status, stdout and stderr are asserted.  The assertion COUNT is asserted
# too, so a contract that is deleted or short-circuited cannot leave the
# suite reporting success on fewer checks than it claims.
set -uo pipefail

HERE="${BASH_SOURCE[0]%/*}"
[[ $HERE == "${BASH_SOURCE[0]}" ]] && HERE="."
HERE="$(cd "$HERE" && pwd)"
RESOLVER="$HERE/resolve-sibling-rev.sh"

if [[ ! -x $RESOLVER && ! -f $RESOLVER ]]; then
	echo "resolve-sibling-rev-test: cannot find $RESOLVER" >&2
	exit 3
fi

EXPECTED_ASSERTIONS=51

PASS=0
FAIL=0
ASSERTIONS=0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/resolve-sibling-rev-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# --- fixture builders -----------------------------------------------------

# Revisions used throughout.  `SHA_SELF` is the commit under test.
SHA_SELF="1111111111111111111111111111111111111111"
SHA_OTHER="2222222222222222222222222222222222222222"
REV_NB_XML="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REV_NIM_XML="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REV_NB_TOML="cccccccccccccccccccccccccccccccccccccccc"
REV_NIM_TOML="dddddddddddddddddddddddddddddddddddddddd"

mkparent() {
	local d="${1%/*}"
	mkdir -p "$d"
}

# A `repo manifest -r` snapshot, as the repo-workspaces `workspace lock`
# hook writes it.  Note `nim` is at path `codetracer-nim`: the sibling's
# identity is its NAME, not its path, in both formats.
mk_xml_lock() {
	local file="$1" nb="$2" nim="$3"
	mkparent "$file"
	{
		printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
		printf '%s\n' '<manifest>'
		printf '%s\n' '  <remote name="metacraft-labs" fetch="https://github.com/metacraft-labs" />'
		printf '%s\n' '  <default remote="metacraft-labs" revision="main" sync-j="4" />'
		printf '%s\n' "  <project name=\"codetracer-native-backend\" remote=\"metacraft-labs\" revision=\"$nb\" upstream=\"dev\" dest-branch=\"dev\" />"
		printf '%s\n' "  <project name=\"nim\" path=\"codetracer-nim\" remote=\"metacraft-github\" revision=\"$nim\" upstream=\"codetracer\" />"
		printf '%s\n' '</manifest>'
	} >"$file"
}

# A reprobuild `reprobuild.workspace.lock.v1` lock, as
# `repro workspace lock` / the post-commit hook writes it.
mk_toml_lock() {
	local file="$1" nb="$2" nim="$3" schema="${4-reprobuild.workspace.lock.v1}"
	mkparent "$file"
	{
		printf '%s\n' "schema = \"$schema\""
		printf '%s\n' ''
		printf '%s\n' '[lock]'
		printf '%s\n' 'project = "codetracer"'
		printf '%s\n' 'created_at = "2026-08-10T11:55:29Z"'
		printf '%s\n' 'created_by = "repro workspace lock"'
		printf '%s\n' ''
		printf '%s\n' '[[repo]]'
		printf '%s\n' 'name = "codetracer-native-backend"'
		printf '%s\n' 'path = "codetracer-native-backend"'
		printf '%s\n' 'remote = "metacraft-labs"'
		printf '%s\n' "revision = \"$nb\""
		printf '%s\n' 'branch = "dev"'
		printf '%s\n' ''
		printf '%s\n' '[[repo]]'
		printf '%s\n' 'name = "nim"'
		printf '%s\n' 'path = "codetracer-nim"'
		printf '%s\n' 'remote = "metacraft-github"'
		printf '%s\n' "revision = \"$nim\""
		printf '%s\n' 'branch = "codetracer"'
	} >"$file"
}

# --- assertions -----------------------------------------------------------

_out=""
_err=""
_rc=0

run_resolver() {
	local errfile="$TMPROOT/.stderr"
	_out="$("$RESOLVER" "$@" 2>"$errfile")"
	_rc=$?
	_err="$(<"$errfile")"
}

ok() {
	ASSERTIONS=$((ASSERTIONS + 1))
	PASS=$((PASS + 1))
	printf 'ok   %s\n' "$1"
}

bad() {
	ASSERTIONS=$((ASSERTIONS + 1))
	FAIL=$((FAIL + 1))
	printf 'FAIL %s\n' "$1"
	printf '       %s\n' "$2"
}

# expect_rev DESC EXPECTED_REV -- <resolver args...>
expect_rev() {
	local desc="$1" want="$2"
	shift 3
	run_resolver "$@"
	if [[ $_rc -ne 0 ]]; then
		bad "$desc" "exit $_rc (expected 0); stderr: $_err"
		return
	fi
	if [[ $_out != "$want" ]]; then
		bad "$desc" "got '$_out', want '$want'"
		return
	fi
	ok "$desc"
}

# expect_fail DESC EXPECTED_EXIT SUBSTRING -- <resolver args...>
expect_fail() {
	local desc="$1" want_rc="$2" want_sub="$3"
	shift 4
	run_resolver "$@"
	if [[ $_rc -eq 0 ]]; then
		bad "$desc" "exited 0 and printed '$_out' (expected failure $want_rc)"
		return
	fi
	if [[ $want_rc != "any" && $_rc -ne $want_rc ]]; then
		bad "$desc" "exit $_rc (expected $want_rc); stderr: $_err"
		return
	fi
	if [[ -n $want_sub && $_err != *"$want_sub"* ]]; then
		bad "$desc" "stderr missing '$want_sub'; got: $_err"
		return
	fi
	# A failing resolve must never emit a plausible-looking revision on
	# stdout: the caller substitutes stdout into a `git fetch`.
	if [[ -n $_out ]]; then
		bad "$desc" "printed '$_out' on stdout while failing"
		return
	fi
	ok "$desc"
}

# =========================================================================
# 1. repo-workspaces XML layout — MUST NOT REGRESS
# =========================================================================

X="$TMPROOT/xml/manifests"
mk_xml_lock "$X/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"

expect_rev "xml/nested: resolves sibling by name" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk

expect_rev "xml/nested: name differs from path (nim -> codetracer-nim)" "$REV_NIM_XML" -- \
	--repo codetracer --sibling nim \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk

XF="$TMPROOT/xmlflat/manifests"
mk_xml_lock "$XF/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "xml/flat: locks/<project>/<repo>-<sha>.xml still resolves" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XF" --sha "$SHA_SELF" --no-walk

expect_fail "xml: sibling absent from the lock fails loudly" 4 "not present in lock" -- \
	--repo codetracer --sibling codetracer-rr \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 2. reprobuild TOML layout
# =========================================================================

T="$TMPROOT/toml/manifests"
mk_toml_lock "$T/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"

expect_rev "toml/nested: resolves sibling by name" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$T" --sha "$SHA_SELF" --no-walk

expect_rev "toml/nested: name differs from path (nim -> codetracer-nim)" "$REV_NIM_TOML" -- \
	--repo codetracer --sibling nim \
	--manifest-dir "$T" --sha "$SHA_SELF" --no-walk

TF="$TMPROOT/tomlflat/manifests"
mk_toml_lock "$TF/locks/codetracer/codetracer-$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "toml/flat: locks/<project>/<repo>-<sha>.toml resolves" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$TF" --sha "$SHA_SELF" --no-walk

expect_fail "toml: sibling absent from the lock fails loudly" 4 "not present in lock" -- \
	--repo codetracer --sibling codetracer-rr \
	--manifest-dir "$T" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 3. No lock / wrong sha
# =========================================================================

E="$TMPROOT/empty/manifests"
mkdir -p "$E/locks"
expect_fail "no lock at all: exit 3" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$E" --sha "$SHA_SELF" --no-walk
run_resolver --repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$E" --sha "$SHA_SELF" --no-walk
if [[ $_err == *".xml"* && $_err == *".toml"* ]]; then
	ok "no lock: diagnostic names BOTH layouts it searched"
else
	bad "no lock: diagnostic names BOTH layouts it searched" "stderr: $_err"
fi

expect_fail "lock exists only for an unrelated sha (xml): exit 3" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$X" --sha "$SHA_OTHER" --no-walk

expect_fail "lock exists only for an unrelated sha (toml): exit 3" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$T" --sha "$SHA_OTHER" --no-walk

expect_fail "missing manifest dir: exit 3" 3 "cannot locate the manifest repo" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$TMPROOT/nope" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 4. Malformed locks — must fail, never guess
# =========================================================================

M="$TMPROOT/malformed/manifests"

# (a) TOML with an unrecognised schema.
mk_toml_lock "$M/a/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"$REV_NB_TOML" "$REV_NIM_TOML" "reprobuild.workspace.lock.v99"
expect_fail "toml: unsupported schema is rejected, not guessed" 5 "schema" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/a" --sha "$SHA_SELF" --no-walk

# (b) TOML with no schema key at all.
mkdir -p "$M/b/locks/codetracer/codetracer"
{
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$M/b/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "toml: missing schema key is rejected" 5 "schema" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/b" --sha "$SHA_SELF" --no-walk

# (c) TOML truncated to the header — no [[repo]] entries.
mkdir -p "$M/c/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[lock]'
	printf '%s\n' 'project = "codetracer"'
} >"$M/c/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "toml: no [[repo]] entries is rejected" 5 "no [[repo]]" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/c" --sha "$SHA_SELF" --no-walk

# (d) zero-byte TOML lock.
mkdir -p "$M/d/locks/codetracer/codetracer"
: >"$M/d/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "toml: zero-byte lock is rejected" 5 "" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/d" --sha "$SHA_SELF" --no-walk

# (e) TOML repo block with a name but no revision.
mkdir -p "$M/e/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' 'path = "codetracer-native-backend"'
} >"$M/e/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "toml: repo entry with no revision is rejected" 5 "revision" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/e" --sha "$SHA_SELF" --no-walk

# (f) XML project line with no revision attribute.  This one used to emit a
# fragment of the XML line as if it were a SHA.
mkdir -p "$M/f/locks/codetracer/codetracer"
{
	printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
	printf '%s\n' '<manifest>'
	printf '%s\n' '  <project name="codetracer-native-backend" remote="metacraft-labs" />'
	printf '%s\n' '</manifest>'
} >"$M/f/locks/codetracer/codetracer/$SHA_SELF.xml"
expect_fail "xml: project with no revision attribute is rejected" 5 "revision" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/f" --sha "$SHA_SELF" --no-walk

# (g) A revision that is not a full commit SHA. The resolved value is
# substituted straight into `git fetch <remote> <rev>`, so anything that is not
# a 40-hex SHA must be refused rather than handed on:
#
#   "main"                  -> git would fetch the branch TIP, which is exactly
#                              the silent unpinned fallback the lock model
#                              exists to prevent, arriving as a clean exit 0.
#   "--upload-pack=<cmd>"   -> git parses options after the remote, so this
#                              executes <cmd> on the runner.
#   '"<sha>" # comment'     -> quoting/syntax the scanners do not model, leaking
#   '["<sha>"]'                out as plausible-looking garbage.
#
# Checked on both sides, because both feed the same `git fetch`.
_bad_rev_toml() {
	local dir="$1" rev="$2"
	mkdir -p "$dir/locks/codetracer/codetracer"
	{
		printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
		printf '%s\n' '[[repo]]'
		printf '%s\n' 'name = "codetracer-native-backend"'
		printf '%s\n' "revision = $rev"
	} >"$dir/locks/codetracer/codetracer/$SHA_SELF.toml"
}
_bad_rev_xml() {
	local dir="$1" rev="$2"
	mkdir -p "$dir/locks/codetracer/codetracer"
	{
		printf '%s\n' '<manifest>'
		printf '%s\n' "  <project name=\"codetracer-native-backend\" revision=\"$rev\" />"
		printf '%s\n' '</manifest>'
	} >"$dir/locks/codetracer/codetracer/$SHA_SELF.xml"
}

_bad_rev_toml "$M/g1" '"main"'
expect_fail "toml: a branch name is not a revision (no silent tip fallback)" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g1" --sha "$SHA_SELF" --no-walk

_bad_rev_toml "$M/g2" '"--upload-pack=touch /tmp/resolve-sibling-rev-pwned"'
expect_fail "toml: an option-shaped revision is rejected (git argv injection)" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g2" --sha "$SHA_SELF" --no-walk

_bad_rev_toml "$M/g3" "\"$REV_NB_TOML\" # pinned by hand"
expect_fail "toml: a trailing comment does not leak into the revision" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g3" --sha "$SHA_SELF" --no-walk

_bad_rev_toml "$M/g4" "[\"$REV_NB_TOML\", \"$REV_NIM_TOML\"]"
expect_fail "toml: an array revision is rejected, not half-parsed" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g4" --sha "$SHA_SELF" --no-walk

_bad_rev_toml "$M/g5" '"0123456"'
expect_fail "toml: an abbreviated SHA is rejected" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g5" --sha "$SHA_SELF" --no-walk

# Exactly 40 characters, and hex apart from a leading `-`. The length alone must
# not be taken as proof of shape: this is the shortest step from a real SHA to a
# value `git fetch` reads as an option rather than a refspec.
_bad_rev_toml "$M/g5b" '"-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
expect_fail "toml: 40 chars is not enough — a leading '-' is not hex" 5 "hexadecimal" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g5b" --sha "$SHA_SELF" --no-walk

_bad_rev_xml "$M/g6" 'main'
expect_fail "xml: a branch name is not a revision (no silent tip fallback)" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g6" --sha "$SHA_SELF" --no-walk

_bad_rev_xml "$M/g7" '--upload-pack=touch /tmp/resolve-sibling-rev-pwned'
expect_fail "xml: an option-shaped revision is rejected (git argv injection)" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/g7" --sha "$SHA_SELF" --no-walk

# (h) Two [[repo]] entries pinning the same name. One repo cannot have two
# revisions in one workspace; answering with whichever came first would be a
# coin toss presented as a resolve.
mkdir -p "$M/h/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NIM_TOML\""
} >"$M/h/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "toml: duplicate [[repo]] for one name is rejected" 5 "more than one" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/h" --sha "$SHA_SELF" --no-walk

# (i) A sibling name that is a strict prefix of another entry's name must not
# match it. Substring matching here would pin a DIFFERENT repo's revision and
# still exit 0 — the worst available failure.
mkdir -p "$M/i/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend-extra"'
	printf '%s\n' "revision = \"$REV_NIM_TOML\""
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$M/i/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_rev "toml: sibling names match exactly, never as a substring" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$M/i" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 5. Both layouts present for the same commit
# =========================================================================

B="$TMPROOT/both-agree/manifests"
mk_xml_lock "$B/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$B/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "both layouts agree: resolves" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$B" --sha "$SHA_SELF" --no-walk

C="$TMPROOT/both-conflict/manifests"
mk_xml_lock "$C/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$C/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_fail "both layouts disagree: refuses to pick one" 6 "conflicting" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$C" --sha "$SHA_SELF" --no-walk
run_resolver --repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$C" --sha "$SHA_SELF" --no-walk
if [[ $_err == *".xml"* && $_err == *".toml"* && $_err == *"$REV_NB_XML"* && $_err == *"$REV_NB_TOML"* ]]; then
	ok "conflict diagnostic names both files and both revisions"
else
	bad "conflict diagnostic names both files and both revisions" "stderr: $_err"
fi

# A sibling that only ONE of the two locks knows about is also a conflict:
# the two locks describe the same commit and must not disagree on membership.
C2="$TMPROOT/both-partial/manifests"
mk_xml_lock "$C2/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mkdir -p "$C2/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "nim"'
	printf '%s\n' "revision = \"$REV_NIM_XML\""
} >"$C2/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "one layout omits the sibling entirely: refuses" 6 "conflicting" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$C2" --sha "$SHA_SELF" --no-walk

# ...but a nested and a flat lock of the SAME extension are NOT a conflict, even
# when they disagree. The flat spelling is the historical one, and the manifest
# repo genuinely carries such pairs with the flat member stale by dozens of
# revisions; the nested file has always won and must keep winning. Treating this
# as unresolvable would turn commits that resolve correctly today into hard CI
# failures for every repo still on the XML layout.
N="$TMPROOT/nested-beats-flat/manifests"
mk_xml_lock "$N/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_xml_lock "$N/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "xml: nested wins over a stale flat lock for the same commit" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$N" --sha "$SHA_SELF" --no-walk

# The same precedence in the TOML layout.
N2="$TMPROOT/nested-beats-flat-toml/manifests"
mk_toml_lock "$N2/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock "$N2/locks/codetracer/codetracer-$SHA_SELF.toml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "toml: nested wins over a stale flat lock for the same commit" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$N2" --sha "$SHA_SELF" --no-walk

# A flat lock is still cross-checked against a flat lock of the OTHER extension:
# layout precedence resolves nested-vs-flat, never xml-vs-toml.
N3="$TMPROOT/flat-both-ext/manifests"
mk_xml_lock "$N3/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$N3/locks/codetracer/codetracer-$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_fail "flat layout: xml and toml still cross-check" 6 "conflicting" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$N3" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 6. Project preference across workspaces
# =========================================================================

P="$TMPROOT/prefer/manifests"
mk_toml_lock "$P/locks/aaa-other/codetracer/$SHA_SELF.toml" "$REV_NIM_TOML" "$REV_NIM_TOML"
mk_toml_lock "$P/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "toml: canonical project wins over another workspace" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P" --sha "$SHA_SELF" --no-walk

PX="$TMPROOT/preferx/manifests"
mk_xml_lock "$PX/locks/aaa-other/codetracer/$SHA_SELF.xml" "$REV_NIM_XML" "$REV_NIM_XML"
mk_xml_lock "$PX/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "xml: canonical project wins over another workspace" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$PX" --sha "$SHA_SELF" --no-walk

expect_rev "--prefer-project overrides the default preference" "$REV_NIM_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$PX" --sha "$SHA_SELF" --no-walk --prefer-project aaa-other

# A lock in another workspace, with none in the canonical one, is still used.
O="$TMPROOT/otheronly/manifests"
mk_toml_lock "$O/locks/mcr/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "toml: lock from a non-canonical workspace is used when it is the only one" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$O" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 7. Manifest-dir auto-discovery: .repro/ (reprobuild) and .repo/ (legacy)
# =========================================================================

WR="$TMPROOT/ws-repro"
mkdir -p "$WR/codetracer"
mk_toml_lock "$WR/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "auto-discovery finds .repro/manifests walking up from the repo" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WR/codetracer" --sha "$SHA_SELF" --no-walk

WO="$TMPROOT/ws-repo"
mkdir -p "$WO/codetracer"
mk_xml_lock "$WO/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "auto-discovery still finds legacy .repo/manifests" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WO/codetracer" --sha "$SHA_SELF" --no-walk

# Both present in one workspace: .repro is the migrated layer and wins.
WB="$TMPROOT/ws-both"
mkdir -p "$WB/codetracer"
mk_toml_lock "$WB/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_xml_lock "$WB/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "auto-discovery prefers .repro over a stale .repo layer" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WB/codetracer" --sha "$SHA_SELF" --no-walk

# CT_MANIFEST_DIR keeps working, and beats auto-discovery.  `--repo-dir`
# points at a workspace that has its OWN .repro layer, so a pass here means
# the env var really won rather than auto-discovery happening to agree.
export CT_MANIFEST_DIR="$O"
expect_rev "CT_MANIFEST_DIR overrides auto-discovery" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WB/codetracer" --sha "$SHA_SELF" --no-walk --prefer-project mcr
unset CT_MANIFEST_DIR

# =========================================================================
# 8. Ancestry walk (local, non-shallow) — format agnostic
# =========================================================================

GW="$TMPROOT/walk"
mkdir -p "$GW/codetracer"
(
	cd "$GW/codetracer" || exit 1
	git init -q .
	git config user.email t@t.invalid
	git config user.name t
	git config commit.gpgsign false
	: >a
	git add a
	git commit -qm one
	: >b
	git add b
	git commit -qm two
) >/dev/null 2>&1
BASE_SHA="$(git -C "$GW/codetracer" rev-parse HEAD~1)"
TIP_SHA="$(git -C "$GW/codetracer" rev-parse HEAD)"
mk_toml_lock "$GW/.repro/manifests/locks/codetracer/codetracer/$BASE_SHA.toml" "$REV_NB_TOML" "$REV_NIM_TOML"

expect_rev "walk: nearest locked first-parent ancestor is used (toml)" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$GW/codetracer" --sha "$TIP_SHA"

expect_fail "--no-walk: an ancestor-only lock is NOT accepted (toml)" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$GW/codetracer" --sha "$TIP_SHA" --no-walk

GX="$TMPROOT/walkx"
mkdir -p "$GX/codetracer"
(
	cd "$GX/codetracer" || exit 1
	git init -q .
	git config user.email t@t.invalid
	git config user.name t
	git config commit.gpgsign false
	: >a
	git add a
	git commit -qm one
	: >b
	git add b
	git commit -qm two
) >/dev/null 2>&1
XBASE="$(git -C "$GX/codetracer" rev-parse HEAD~1)"
XTIP="$(git -C "$GX/codetracer" rev-parse HEAD)"
mk_xml_lock "$GX/.repo/manifests/locks/codetracer/codetracer/$XBASE.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "walk: nearest locked first-parent ancestor is used (xml)" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$GX/codetracer" --sha "$XTIP"

# =========================================================================
# 9. Candidate ordering
# =========================================================================

expect_rev "first locked --sha candidate wins over later ones" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$T" --sha "$SHA_SELF" --sha "$SHA_OTHER" --no-walk

expect_rev "an unlocked leading candidate falls through to a locked one" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$T" --sha "$SHA_OTHER" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 10. Usage errors
# =========================================================================

expect_fail "missing --sibling is a usage error" 2 "missing required value" -- \
	--repo codetracer --manifest-dir "$T" --sha "$SHA_SELF" --no-walk

expect_fail "unknown argument is a usage error" 2 "unknown argument" -- \
	--repo codetracer --sibling codetracer-native-backend --bogus \
	--manifest-dir "$T" --sha "$SHA_SELF" --no-walk

# =========================================================================

printf '\n%s\n' "assertions: $ASSERTIONS  pass: $PASS  fail: $FAIL"
if [[ $ASSERTIONS -ne $EXPECTED_ASSERTIONS ]]; then
	printf '%s\n' "resolve-sibling-rev-test: expected $EXPECTED_ASSERTIONS assertions, ran $ASSERTIONS." >&2
	printf '%s\n' "  A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
[[ $FAIL -eq 0 ]] || exit 1
printf '%s\n' "resolve-sibling-rev: all contracts hold."
