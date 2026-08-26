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

EXPECTED_ASSERTIONS=89

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
# 11. Manifest LAYERS — public + org/team-private + personal
#
# `reprobuild-specs/Workspace-And-Develop-Mode.md` §"Workspace Composition and
# Manifest Layers" specifies that a workspace's repo set is assembled from
# several manifest repos by visibility, that private layers are REQUIRED once
# private repos participate, and that a repo declared in more than one layer is
# deduplicated "with the more specific (private) layer taking precedence".
#
# `--manifest-dir` is repeatable and its order IS the precedence order. These
# contracts pin what composition may and may not do — in particular that a
# broken private layer can never be silently skipped in favour of the public
# one, which is the failure mode that would quietly reintroduce a wrong pin.
# =========================================================================

# One [[repo]] block, arbitrary name — private layers pin repos the public
# layer has never heard of, which the two-repo fixture above cannot express.
mk_toml_lock1() {
	local file="$1" name="$2" rev="$3"
	mkparent "$file"
	{
		printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
		printf '%s\n' ''
		printf '%s\n' '[lock]'
		printf '%s\n' 'project = "codetracer"'
		printf '%s\n' ''
		printf '%s\n' '[[repo]]'
		printf '%s\n' "name = \"$name\""
		printf '%s\n' "path = \"$name\""
		printf '%s\n' 'remote = "metacraft-labs"'
		printf '%s\n' "revision = \"$rev\""
	} >"$file"
}

REV_PRIVATE="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
REV_PRIVATE2="ffffffffffffffffffffffffffffffffffffffff"

# (a) A private layer that pins only its own repo leaves the public answer
# alone. This is the ordinary shape of an org-private manifest.
LPUB="$TMPROOT/layers/public"
LPRIV="$TMPROOT/layers/private"
mk_toml_lock "$LPUB/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$LPRIV/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-internal-dashboards" "$REV_PRIVATE"
expect_rev "layers: a private layer that does not name the sibling leaves the public pin" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LPRIV" --sha "$SHA_SELF" --no-walk

# (b) A repo only the private layer knows about resolves. Without the private
# layer this same query is the exit-4 "not present in lock" case, so the
# assertion is not vacuous.
expect_rev "layers: a private-only repo resolves from the private layer" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-internal-dashboards \
	--manifest-dir "$LPUB" --manifest-dir "$LPRIV" --sha "$SHA_SELF" --no-walk
expect_fail "layers: that same repo is exit 4 without the private layer" 4 "not present in lock" -- \
	--repo codetracer --sibling codetracer-internal-dashboards \
	--manifest-dir "$LPUB" --sha "$SHA_SELF" --no-walk

# (c) Both layers pin the sibling: the MORE SPECIFIC (last) layer wins, and
# says so on stderr. This is the spec's override rule.
LPRIV_OVR="$TMPROOT/layers/private-override"
mk_toml_lock1 "$LPRIV_OVR/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_rev "layers: the more specific layer overrides the public pin" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LPRIV_OVR" --sha "$SHA_SELF" --no-walk
run_resolver --repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LPRIV_OVR" --sha "$SHA_SELF" --no-walk
if [[ $_err == *"overridden by a more specific manifest layer"* &&
	$_err == *"$REV_NB_TOML"* && $_err == *"$REV_PRIVATE"* ]]; then
	ok "layers: the override is announced on stderr, naming both pins"
else
	bad "layers: the override is announced on stderr, naming both pins" "stderr: $_err"
fi

# (d) Precedence is the CALLER'S order, not any property of the directories.
# Swapping the two `--manifest-dir` arguments flips the winner.
expect_rev "layers: swapping the layer order flips which pin wins" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPRIV_OVR" --manifest-dir "$LPUB" --sha "$SHA_SELF" --no-walk

# (e) A MALFORMED private layer fails the whole resolve. Skipping it and
# answering from the healthy public layer would hand CI a pin while a layer
# that claims authority over it could not be read — the exact silent-wrong-pin
# outcome the exit-5 contract exists to prevent.
LBAD="$TMPROOT/layers/private-malformed"
mkdir -p "$LBAD/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' 'revision = "main"'
} >"$LBAD/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "layers: a private layer pinning a branch name is refused, not skipped" 5 "SHA" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LBAD" --sha "$SHA_SELF" --no-walk

LBAD2="$TMPROOT/layers/private-noschema"
mkdir -p "$LBAD2/locks/codetracer/codetracer"
{
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_PRIVATE\""
} >"$LBAD2/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "layers: a schema-less private layer is refused, not skipped" 5 "schema" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LBAD2" --sha "$SHA_SELF" --no-walk

# (f) A layer that contradicts ITSELF (xml vs toml for one commit) is still an
# unresolvable conflict. Layer precedence orders LAYERS; it never arbitrates
# inside one.
LSELF="$TMPROOT/layers/private-self-conflict"
mk_xml_lock "$LSELF/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$LSELF/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_PRIVATE" "$REV_NIM_TOML"
expect_fail "layers: a layer that contradicts itself is still exit 6" 6 "conflicting" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LSELF" --sha "$SHA_SELF" --no-walk

# (g) A private layer with no lock for this commit contributes nothing and is
# not an error — private manifests are locked on their own cadence.
LEMPTY="$TMPROOT/layers/private-otherlock"
mk_toml_lock1 "$LEMPTY/locks/codetracer/codetracer/$SHA_OTHER.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_rev "layers: a private layer with no lock for this commit is not an error" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LEMPTY" --sha "$SHA_SELF" --no-walk

# (h) The COMMIT is chosen once, for ALL layers. The layers describe one
# workspace state; reading each at whichever candidate it happens to have a
# lock for would compose two different workspaces into one answer.
#
# Here the public layer locks $SHA_SELF and the private layer locks only the
# unrelated $SHA_OTHER, with both offered as candidates in that order. The
# chosen commit is $SHA_SELF, at which the private layer has nothing to say —
# so the public pin stands. A resolver that let each layer pick its own commit
# would fall the private layer through to $SHA_OTHER and let a lock for a
# DIFFERENT commit override the one under test.
LONLY_PUB="$TMPROOT/layers/other-commit-public"
LONLY_PRIV="$TMPROOT/layers/other-commit-private"
mk_toml_lock "$LONLY_PUB/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$LONLY_PRIV/locks/codetracer/codetracer/$SHA_OTHER.toml" \
	"codetracer-native-backend" "$REV_PRIVATE2"
expect_rev "layers: one commit is chosen for every layer, never a mix" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LONLY_PUB" --manifest-dir "$LONLY_PRIV" \
	--sha "$SHA_SELF" --sha "$SHA_OTHER" --no-walk

# The mirror image: when the chosen commit is the one the PRIVATE layer locks,
# its pin is the one that must be used — so (h) is not passing merely because
# the private layer is being ignored.
LONLY_PUB2="$TMPROOT/layers/other-commit-public2"
LONLY_PRIV2="$TMPROOT/layers/other-commit-private2"
mk_toml_lock "$LONLY_PUB2/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$LONLY_PRIV2/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE2"
expect_rev "layers: at the chosen commit the private pin is used" "$REV_PRIVATE2" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LONLY_PUB2" --manifest-dir "$LONLY_PRIV2" \
	--sha "$SHA_SELF" --sha "$SHA_OTHER" --no-walk

# (i) A named layer with no locks/ subtree is skipped, not fatal — an org
# manifest may carry only projects/ fragments.
LNOLOCKS="$TMPROOT/layers/no-locks"
mkdir -p "$LNOLOCKS/projects"
expect_rev "layers: a layer with no locks/ subtree is skipped, not fatal" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --manifest-dir "$LNOLOCKS" --sha "$SHA_SELF" --no-walk

# ...but when NO named layer has one, that is still the exit-3 no-manifest case,
# and the diagnostic names every layer it looked at.
expect_fail "layers: no layer with a locks/ subtree is exit 3" 3 "cannot locate the manifest repo" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LNOLOCKS" --manifest-dir "$TMPROOT/nope" --sha "$SHA_SELF" --no-walk
run_resolver --repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LNOLOCKS" --manifest-dir "$TMPROOT/nope" --sha "$SHA_SELF" --no-walk
if [[ $_err == *"$LNOLOCKS"* && $_err == *"$TMPROOT/nope"* ]]; then
	ok "layers: the exit-3 diagnostic names every layer it looked at"
else
	bad "layers: the exit-3 diagnostic names every layer it looked at" "stderr: $_err"
fi

# (j) Auto-discovery finds the workspace's private companion checkout
# (`.repro/manifests-private`, the RA-11 `[manifest] private_url` layer) on top
# of the public `.repro/manifests`, with private taking precedence — the same
# composition CI gets by passing both dirs explicitly, for a developer running
# the resolver from inside their workspace.
WP="$TMPROOT/ws-private"
mkdir -p "$WP/codetracer"
mk_toml_lock "$WP/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$WP/.repro/manifests-private/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_rev "auto-discovery: .repro/manifests-private overrides the public layer" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WP/codetracer" --sha "$SHA_SELF" --no-walk
expect_rev "auto-discovery: the public layer still answers repos the private one omits" "$REV_NIM_TOML" -- \
	--repo codetracer --sibling nim \
	--repo-dir "$WP/codetracer" --sha "$SHA_SELF" --no-walk

# (k) A URL-backed `[[manifest]]` layer materialised at
# `.repro/manifests-<n>-<slug>` participates too, and is itself shadowed by the
# private companion — the public -> org -> personal ordering of the spec.
WL="$TMPROOT/ws-layers"
mkdir -p "$WL/codetracer"
mk_toml_lock "$WL/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$WL/.repro/manifests-0-github-com-org-internal/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_rev "auto-discovery: a .repro/manifests-<n>-<slug> layer overrides the public one" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WL/codetracer" --sha "$SHA_SELF" --no-walk
mk_toml_lock1 "$WL/.repro/manifests-private/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE2"
expect_rev "auto-discovery: the private companion is the most specific layer of all" "$REV_PRIVATE2" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WL/codetracer" --sha "$SHA_SELF" --no-walk

# (k2) The `<n>` in `manifests-<n>-<slug>` is the layer's index in the
# workspace's `[[manifest]]` array, and THAT is the precedence order — not the
# alphabet. Shell glob order sorts `manifests-10-x` ahead of `manifests-2-x`, so
# a resolver that simply iterated the glob would let layer 2 override layer 10
# once a workspace has ten or more URL-backed layers: a silently inverted
# precedence, in the one mechanism whose entire purpose is to say which pin wins.
WN="$TMPROOT/ws-numeric"
mkdir -p "$WN/codetracer"
mk_toml_lock "$WN/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$WN/.repro/manifests-2-two/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
mk_toml_lock1 "$WN/.repro/manifests-10-ten/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE2"
expect_rev "auto-discovery: numbered layers are ordered by <n>, not lexicographically" "$REV_PRIVATE2" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WN/codetracer" --sha "$SHA_SELF" --no-walk

# (k3) A `.repro/manifests-<name>` layer whose name encodes no index carries no
# precedence information at all — its position lives only in the workspace
# config. Alphabetical order would put `manifests-team` ahead of
# `manifests-personal`, which is backwards; skipping it would silently answer
# from a LESS specific layer. Refuse, and say how to order them explicitly.
WA="$TMPROOT/ws-ambiguous"
mkdir -p "$WA/codetracer"
mk_toml_lock "$WA/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$WA/.repro/manifests-team/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_fail "auto-discovery: an unorderable manifests-<name> layer is refused, not guessed" 3 "cannot order the auto-discovered manifest layers" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WA/codetracer" --sha "$SHA_SELF" --no-walk
run_resolver --repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WA/codetracer" --sha "$SHA_SELF" --no-walk
if [[ $_err == *"manifests-team"* && $_err == *"--manifest-dir"* ]]; then
	ok "auto-discovery: the refusal names the layer and how to order it explicitly"
else
	bad "auto-discovery: the refusal names the layer and how to order it explicitly" "stderr: $_err"
fi

# (k4) A workspace midway through the migration can carry a lock-bearing legacy
# `.repo/manifests` beside a `.repro/manifests-private`. The private layer must
# still apply: dropping it because the BASE happens to be the legacy one is the
# silent downgrade to public-only that the CI path treats as fatal.
WM="$TMPROOT/ws-mixed"
mkdir -p "$WM/codetracer" "$WM/.repro/manifests/projects"
mk_toml_lock "$WM/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock1 "$WM/.repro/manifests-private/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer-native-backend" "$REV_PRIVATE"
expect_rev "auto-discovery: a legacy .repo base does not drop .repro/manifests-private" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WM/codetracer" --sha "$SHA_SELF" --no-walk

# (l) The env-var spelling of the same composition, for callers that address
# the manifest checkouts through the environment (`ci/setup-rr-backend.sh`,
# `scripts/run-cross-repo-tests.sh`).
export CT_MANIFEST_DIR="$LPUB"
export CT_PRIVATE_MANIFEST_DIR="$LPRIV_OVR"
expect_rev "CT_PRIVATE_MANIFEST_DIR layers on top of CT_MANIFEST_DIR" "$REV_PRIVATE" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--sha "$SHA_SELF" --no-walk
# An explicit --manifest-dir still wins outright over both env vars, so a
# caller that names its layers is never silently given another one.
expect_rev "an explicit --manifest-dir ignores CT_PRIVATE_MANIFEST_DIR" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$LPUB" --sha "$SHA_SELF" --no-walk
unset CT_MANIFEST_DIR
unset CT_PRIVATE_MANIFEST_DIR

# =========================================================================
# 12. Routed per-repo participation records are NOT locks
# =========================================================================
#
# `repro locking adopt-manifest` puts a workspace in ROUTED locking mode. In
# that mode reprobuild's HL-2 tier isolation deliberately skips the monolithic
# workspace-lock document and `recordRoutedParticipation` writes one minimal
# per-repo record — via the git-checkout backend, into the SAME
# `locks/<project>/<repo>/<sha>.toml` namespace the lock documents use.
#
# Such a record pins only the repo whose directory it sits in, so it cannot
# answer this resolver's question at all. Read as a lock it produced
# "malformed lock ... no top-level 'schema' key" and EXIT 5 — the code that
# means "a lock exists but cannot be trusted", which callers escalate to a job
# abort. 98 of these records (96 repos) are published in
# metacraft-labs/metacraft-manifests@latest and 71 of them reproduced that
# exit 5, so a commit that merely lacked a lock became a commit that killed the
# job.
#
# The contract below is that they degrade EXACTLY like a missing lock: exit 3,
# candidate fall-through intact, ancestry walk intact — while every genuinely
# untrustworthy document stays loud at exit 5.

# A routed participation record, byte-for-byte the shape reprobuild's
# `routedParticipationBody` emits.
mk_participation_record() {
	local file="$1" name="$2" path="$3" sha="$4"
	mkparent "$file"
	{
		printf '%s\n' '[[repo]]'
		printf '%s\n' "name = \"$name\""
		printf '%s\n' "path = \"$path\""
		printf '%s\n' "revision = \"$sha\""
	} >"$file"
}

P="$TMPROOT/participation"

# (a) A routed record ALONE is a missing lock, not a broken one. This is the
# whole point: exit 5 aborts the job, exit 3 is the graceful "not locked".
mk_participation_record "$P/a/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
expect_fail "participation: a routed record alone is exit 3, not exit 5" 3 \
	"no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/a" --sha "$SHA_SELF" --no-walk

# (b) ...and the diagnostic must say WHY, naming the file. A silent exit 3 for
# a commit that visibly has a file on disk is its own debugging trap.
expect_fail "participation: the exit-3 diagnostic names the ignored record" 3 \
	"locks/codetracer/codetracer/$SHA_SELF.toml" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/a" --sha "$SHA_SELF" --no-walk

# (c) A routed record must not poison a REAL lock written for the same commit.
# Before this was recognised, the record was collected alongside the lock and
# failed the whole resolve at exit 5 even though the answer was right there.
mk_xml_lock "$P/c/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_participation_record "$P/c/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
expect_rev "participation: a routed record does not poison a real xml lock" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/c" --sha "$SHA_SELF" --no-walk

# (d) The same in the flat legacy spelling, so the recognition is not attached
# to one layout.
mk_xml_lock "$P/d/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_participation_record "$P/d/locks/codetracer/codetracer-$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
expect_rev "participation: recognised in the flat layout too" "$REV_NB_XML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/d" --sha "$SHA_SELF" --no-walk

# (e) Candidate FALL-THROUGH. This is what parsing the record into an exit 4
# would NOT have bought: a caller probing HEAD then its parent must move past
# the routed record to the parent's real lock, exactly as it moves past a
# commit with no file at all.
mk_participation_record "$P/e/locks/codetracer/codetracer/$SHA_OTHER.toml" \
	"codetracer" "codetracer" "$SHA_OTHER"
mk_toml_lock "$P/e/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "participation: a routed leading candidate falls through to a locked one" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/e" --sha "$SHA_OTHER" --sha "$SHA_SELF" --no-walk

# (f) The ancestry walk must survive it too: a routed record at the tip must
# not stop the walk reaching the locked parent.
GP="$TMPROOT/walkp"
mkdir -p "$GP/codetracer"
(
	cd "$GP/codetracer" || exit 1
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
PBASE="$(git -C "$GP/codetracer" rev-parse HEAD~1)"
PTIP="$(git -C "$GP/codetracer" rev-parse HEAD)"
mk_toml_lock "$GP/.repro/manifests/locks/codetracer/codetracer/$PBASE.toml" \
	"$REV_NB_TOML" "$REV_NIM_TOML"
mk_participation_record "$GP/.repro/manifests/locks/codetracer/codetracer/$PTIP.toml" \
	"codetracer" "codetracer" "$PTIP"
expect_rev "participation: a routed record at the tip does not stop the walk" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$GP/codetracer" --sha "$PTIP"

# (g) Extra keys must not un-recognise it. Recognition is semantic — "declares
# no schema, only [[repo]] tables, names nobody but itself" — precisely so that
# reprobuild adding `remote` / `branch` to the record does not silently restore
# the exit-5 abort.
mkdir -p "$P/g/locks/codetracer/codetracer"
{
	printf '%s\n' '# written by repro'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer"'
	printf '%s\n' 'path = "codetracer"'
	printf '%s\n' 'remote = "metacraft-labs"'
	printf '%s\n' 'branch = "dev"'
	printf '%s\n' "revision = \"$SHA_SELF\""
} >"$P/g/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "participation: extra keys still degrade to exit 3" 3 \
	"no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/g" --sha "$SHA_SELF" --no-walk

# (h) OVER-BREADTH GUARD. A schema-less document that names some OTHER repo is
# not a participation record — it is a lock document that failed to declare
# itself, and it claims to know a sibling's revision. Trusting it silently, or
# skipping it silently, would both be wrong: it stays exit 5.
mkdir -p "$P/h/locks/codetracer/codetracer"
{
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer"'
	printf '%s\n' 'path = "codetracer"'
	printf '%s\n' "revision = \"$SHA_SELF\""
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' 'path = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$P/h/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "participation: a schema-less doc naming a sibling is still exit 5" 5 \
	"schema" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/h" --sha "$SHA_SELF" --no-walk

# (i) OVER-BREADTH GUARD. A schema-less document carrying a non-[[repo]] table
# is a truncated or corrupt LOCK, not a participation record: reprobuild's
# record has no `[lock]` header. Still exit 5.
mkdir -p "$P/i/locks/codetracer/codetracer"
{
	printf '%s\n' '[lock]'
	printf '%s\n' 'project = "codetracer"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer"'
	printf '%s\n' 'path = "codetracer"'
	printf '%s\n' "revision = \"$SHA_SELF\""
} >"$P/i/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "participation: a schema-less doc with a [lock] table is still exit 5" 5 \
	"schema" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/i" --sha "$SHA_SELF" --no-walk

# (j) A document that DOES declare the schema is a lock even when it pins only
# one repo — a one-repo workspace is legitimate, and its "sibling absent"
# answer is the honest exit 4, not exit 3.
mkdir -p "$P/j/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer"'
	printf '%s\n' 'path = "codetracer"'
	printf '%s\n' "revision = \"$SHA_SELF\""
} >"$P/j/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_fail "participation: a schema'd self-only lock is exit 4, not exit 3" 4 \
	"not present in lock" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/j" --sha "$SHA_SELF" --no-walk

# (k..m) THE REMEDY MUST BE TRUE.
#
# The exit-3 diagnostic is the only thing an operator sees when a commit has
# nothing but routed records, so its "here is how to fix it" half is load
# bearing. It used to assert that routed mode "by design does not write the
# monolithic workspace lock document" and to send the reader off to publish one
# "for the public tier" -- and both were wrong.
#
# Routed mode DOES publish a `reprobuild.workspace.lock.v1` document. HL-2
# Decision 1 gives each routed PARTITION one, written into that partition's own
# durable backend at the same `locks/<project>/<repo>/<sha>.toml` key, and
# reserves the minimal per-repo record for repos no partition covers
# (reprobuild's `prepareWorkspaceParticipation` skips a repo whose store is the
# partition root, because the two writers would otherwise collide on the
# trigger repo's key and the loser's push is REFUSED). So the workspace this
# resolver serves publishes its lock into the routed TEAM backend, not "for the
# public tier", and an operator told to add a public-tier document was being
# sent to fix something that is not broken.
#
# `expect_stderr_lacks` asserts an ANCHOR present before asserting the wrong
# wording absent: a "does not say X" check against a diagnostic that was never
# emitted -- wrong exit code, renamed message, empty stream -- passes for the
# wrong reason, which is exactly the vacuous green this suite exists to avoid.

# expect_stderr_lacks DESC EXPECTED_EXIT ANCHOR FORBIDDEN -- <resolver args...>
expect_stderr_lacks() {
	local desc="$1" want_rc="$2" anchor="$3" forbidden="$4"
	shift 5
	run_resolver "$@"
	if [[ $_rc -ne $want_rc ]]; then
		bad "$desc" "exit $_rc (expected $want_rc); stderr: $_err"
		return
	fi
	if [[ $_err != *"$anchor"* ]]; then
		bad "$desc" "anchor '$anchor' absent from stderr — this check is not looking at the diagnostic it means to; got: $_err"
		return
	fi
	if [[ $_err == *"$forbidden"* ]]; then
		bad "$desc" "stderr still carries '$forbidden'"
		return
	fi
	ok "$desc"
}

expect_stderr_lacks "remedy: does not claim routed mode omits the lock document" 3 \
	"Ignored 1 routed per-repo participation record(s)" \
	"does not write the monolithic workspace" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/a" --sha "$SHA_SELF" --no-walk

# NOTE the forbidden string is "public tier", not "for the public tier": the
# message is emitted one `echo` per output line and the phrase straddled the
# wrap ("...document (...) for the" / "public tier alongside..."). The longer
# spelling matched nothing and passed while the wrong remedy was still being
# printed — a vacuous green found while writing this very contract. Forbidden
# strings must not span a line break in the text they police.
expect_stderr_lacks "remedy: does not misdirect the fix to the public tier" 3 \
	"Ignored 1 routed per-repo participation record(s)" \
	"public tier" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/a" --sha "$SHA_SELF" --no-walk

expect_fail "remedy: says where routed mode DOES publish the lock document" 3 \
	"one per routed partition" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/a" --sha "$SHA_SELF" --no-walk

# =========================================================================

printf '\n%s\n' "assertions: $ASSERTIONS  pass: $PASS  fail: $FAIL"
if [[ $ASSERTIONS -ne $EXPECTED_ASSERTIONS ]]; then
	printf '%s\n' "resolve-sibling-rev-test: expected $EXPECTED_ASSERTIONS assertions, ran $ASSERTIONS." >&2
	printf '%s\n' "  A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
[[ $FAIL -eq 0 ]] || exit 1
printf '%s\n' "resolve-sibling-rev: all contracts hold."
