#!/usr/bin/env bash
#
# resolve-sibling-rev-test.sh — contract suite for resolve-sibling-rev.sh.
#
# `metacraft-github-actions` is a SHARED action repo: several Metacraft
# projects consume `clone-siblings`.  The resolver reads ONE lock format,
# reprobuild's `<sha>.toml`.  The legacy repo-workspaces `<sha>.xml` records
# were dropped on 2026-09-29 (and erased from metacraft-manifests), and
# section 1 pins what that means: an .xml is never a lock, alone or beside a
# .toml.
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

EXPECTED_ASSERTIONS=98

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

# A `repo manifest -r` snapshot, as the retired repo-workspaces
# `workspace lock` hook wrote it.  It is a fixture for what the resolver must
# IGNORE, and it carries valid, distinct revisions so that a resolver still
# reading it would print one of them and fail the assertion.
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
# 1. Legacy repo-workspaces XML records are NOT locks (removed 2026-09-29)
# =========================================================================
#
# The resolver used to read `locks/<project>/<repo>/<sha>.xml` beside the TOML
# records. That support is gone, with no fallback, and every arm below asserts
# a consequence of it. The XML fixtures carry VALID, distinct revisions
# (`REV_*_XML`), so a resolver that still read them would print one and fail
# the arm, rather than failing for some unrelated parse reason.

# (a) An XML-only commit is UNLOCKED: exit 3 with the usual loud "no workspace
#     lock" diagnostic, and nothing on stdout.
X="$TMPROOT/xml/manifests"
mk_xml_lock "$X/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_fail "xml-only (nested): the commit has NO lock, exit 3" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk

# (b) ...and the diagnostic names the ignored file and says why, so that a
#     reader who can see a file for this commit is not left guessing.
expect_fail "xml-only: the diagnostic names the ignored .xml file" 3 \
	"locks/codetracer/codetracer/$SHA_SELF.xml" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk
expect_fail "xml-only: the diagnostic says XML records are not supported" 3 \
	"XML lock records are not supported" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$X" --sha "$SHA_SELF" --no-walk

XF="$TMPROOT/xmlflat/manifests"
mk_xml_lock "$XF/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_fail "xml-only (flat): locks/<project>/<repo>-<sha>.xml is not a lock either" 3 \
	"no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XF" --sha "$SHA_SELF" --no-walk

# (c) An XML record beside a TOML record for the same commit, in the same
#     project, is ignored: the TOML answers, even though the XML disagrees.
#     This used to be an exit-6 "conflicting locks".
XT="$TMPROOT/xml-beside-toml/manifests"
mk_xml_lock "$XT/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$XT/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "xml beside toml (same project): the toml answers, the xml is ignored" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XT" --sha "$SHA_SELF" --no-walk
expect_rev "xml beside toml (same project): name differs from path still resolves" "$REV_NIM_TOML" -- \
	--repo codetracer --sibling nim \
	--manifest-dir "$XT" --sha "$SHA_SELF" --no-walk

# (d) THE FIELD FAILURE. codetracer-python-recorder@377e03bb and
#     codetracer-ruby-recorder@8bacef81 carried a stale `locks/dev/` XML record,
#     and the fresh `locks/codetracer/` TOML record beside it was not read: the
#     glob listed every .xml before any .toml, and for a repo whose canonical
#     project is not a directory in the store, the first project the glob met
#     became the only one searched. Here SELF's own name is not a project, the
#     XML sits under `dev` and the TOML under `codetracer`, exactly as in the
#     manifest repo.
XS="$TMPROOT/xml-shadow/manifests"
mk_xml_lock "$XS/locks/dev/codetracer-python-recorder/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$XS/locks/codetracer/codetracer-python-recorder/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "xml under another project does not shadow the toml record" "$REV_NB_TOML" -- \
	--repo codetracer-python-recorder --sibling codetracer-native-backend \
	--manifest-dir "$XS" --sha "$SHA_SELF" --no-walk
expect_rev "...and the created-at reported is the toml record's" "2026-08-10T11:55:29Z" -- \
	--repo codetracer-python-recorder --print-created-at \
	--manifest-dir "$XS" --sha "$SHA_SELF" --no-walk

# (e) An XML record's CONTENT is never read: one that would have been a
#     malformed lock (exit 5) or an injection attempt is simply not a lock.
XM="$TMPROOT/xml-malformed/manifests"
mkdir -p "$XM/locks/codetracer/codetracer"
{
	printf '%s\n' '<manifest>'
	printf '%s\n' '  <project name="codetracer-native-backend" revision="--upload-pack=touch /tmp/resolve-sibling-rev-pwned" />'
	printf '%s\n' '</manifest>'
} >"$XM/locks/codetracer/codetracer/$SHA_SELF.xml"
expect_fail "xml-only, malformed: exit 3 (not a lock), never exit 5 (a broken lock)" 3 \
	"no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XM" --sha "$SHA_SELF" --no-walk
mk_toml_lock "$XM/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "a malformed xml beside a good toml does not fail the resolve" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XM" --sha "$SHA_SELF" --no-walk

# (f) Candidate fall-through: an XML-only candidate is passed over like any
#     unlocked commit, and the next candidate's TOML answers.
XC="$TMPROOT/xml-candidate/manifests"
mk_xml_lock "$XC/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$XC/locks/codetracer/codetracer/$SHA_OTHER.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "an xml-only leading candidate falls through to the next locked one" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$XC" --sha "$SHA_SELF" --sha "$SHA_OTHER" --no-walk

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
if [[ $_err == *"<sha>.toml"* && $_err != *"<sha>.xml"* && $_err != *"legacy repo-workspaces XML"* ]]; then
	ok "no lock: diagnostic names the .toml paths it searched, and no .xml path"
else
	bad "no lock: diagnostic names the .toml paths it searched, and no .xml path" "stderr: $_err"
fi

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
# 5. Nested and flat spellings for the same commit
# =========================================================================

# A nested and a flat lock for the SAME commit are NOT a conflict, even when
# they disagree. The flat spelling is the historical one, and where the tooling
# wrote both the nested file is the later, canonical one; the nested file has
# always won and must keep winning.
N2="$TMPROOT/nested-beats-flat-toml/manifests"
mk_toml_lock "$N2/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock "$N2/locks/codetracer/codetracer-$SHA_SELF.toml" "$REV_NB_XML" "$REV_NIM_XML"
expect_rev "toml: nested wins over a stale flat lock for the same commit" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$N2" --sha "$SHA_SELF" --no-walk

# A flat .xml beside a flat .toml is not cross-checked any more: the .xml is
# not a lock, so the .toml answers. (It used to be an exit-6 conflict.)
N3="$TMPROOT/flat-both-ext/manifests"
mk_xml_lock "$N3/locks/codetracer/codetracer-$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$N3/locks/codetracer/codetracer-$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "flat layout: an xml beside the toml is ignored, the toml answers" "$REV_NB_TOML" -- \
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

expect_rev "--prefer-project overrides the default preference" "$REV_NIM_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P" --sha "$SHA_SELF" --no-walk --prefer-project aaa-other

# A lock in another workspace, with none in the canonical one, is still used.
O="$TMPROOT/otheronly/manifests"
mk_toml_lock "$O/locks/mcr/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "toml: lock from a non-canonical workspace is used when it is the only one" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$O" --sha "$SHA_SELF" --no-walk

# An .xml under the CANONICAL project does not outrank a .toml under another
# one: the .xml is not a lock, so the preference never sees it.
PX="$TMPROOT/preferx/manifests"
mk_xml_lock "$PX/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$PX/locks/mcr/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "an xml in the canonical project does not outrank a toml elsewhere" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$PX" --sha "$SHA_SELF" --no-walk

# =========================================================================
# 7. Manifest-dir auto-discovery: .repro/manifests and the older .repo/manifests
# =========================================================================

WR="$TMPROOT/ws-repro"
mkdir -p "$WR/codetracer"
mk_toml_lock "$WR/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "auto-discovery finds .repro/manifests walking up from the repo" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WR/codetracer" --sha "$SHA_SELF" --no-walk

WO="$TMPROOT/ws-repo"
mkdir -p "$WO/codetracer"
mk_toml_lock "$WO/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "auto-discovery still finds .repo/manifests (it holds .toml records)" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WO/codetracer" --sha "$SHA_SELF" --no-walk

# A .repo/manifests layer holding only legacy .xml records is discovered, and
# has no lock in it.
WOX="$TMPROOT/ws-repo-xml"
mkdir -p "$WOX/codetracer"
mk_xml_lock "$WOX/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_fail "auto-discovery: a .repo/manifests with only .xml records has no lock" 3 "no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--repo-dir "$WOX/codetracer" --sha "$SHA_SELF" --no-walk

# Both present in one workspace: .repro is the migrated layer and wins.
WB="$TMPROOT/ws-both"
mkdir -p "$WB/codetracer"
mk_toml_lock "$WB/.repro/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mk_toml_lock "$WB/.repo/manifests/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_XML" "$REV_NIM_XML"
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
# 8. Ancestry walk (local, non-shallow)
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
# The walk passes over an XML-only commit exactly as over an unlocked one: the
# tip carries only an .xml, so the answer comes from the parent's .toml.
mk_xml_lock "$GX/.repo/manifests/locks/codetracer/codetracer/$XTIP.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$GX/.repo/manifests/locks/codetracer/codetracer/$XBASE.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "walk: an xml-only commit is walked past to the nearest toml lock" "$REV_NB_TOML" -- \
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

# (f) An .xml inside a layer does not make that layer contradict itself (this
# used to be exit 6): the .xml is not a lock, so the layer's .toml is its only
# answer, and as the more specific layer it overrides the public one.
LSELF="$TMPROOT/layers/private-with-xml"
mk_xml_lock "$LSELF/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
mk_toml_lock "$LSELF/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_PRIVATE" "$REV_NIM_TOML"
expect_rev "layers: an .xml inside a layer is ignored; the layer's .toml overrides" "$REV_PRIVATE" -- \
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
# The record sits in the canonical project, so it would also have outranked
# the real lock under another project had it been taken for one.
mk_participation_record "$P/c/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
mk_toml_lock "$P/c/locks/mcr/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "participation: a routed record does not poison a real lock" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/c" --sha "$SHA_SELF" --no-walk

# (d) The same in the flat legacy spelling, so the recognition is not attached
# to one layout.
mk_participation_record "$P/d/locks/codetracer/codetracer-$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
mk_toml_lock "$P/d/locks/mcr/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_rev "participation: recognised in the flat layout too" "$REV_NB_TOML" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/d" --sha "$SHA_SELF" --no-walk

# (d2) A routed record beside a legacy .xml: neither is a lock, so the commit
# is unlocked (exit 3) rather than resolved from the .xml.
mk_participation_record "$P/d2/locks/codetracer/codetracer/$SHA_SELF.toml" \
	"codetracer" "codetracer" "$SHA_SELF"
mk_xml_lock "$P/d2/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_fail "participation: a routed record beside an .xml is still exit 3" 3 \
	"no workspace lock found" -- \
	--repo codetracer --sibling codetracer-native-backend \
	--manifest-dir "$P/d2" --sha "$SHA_SELF" --no-walk

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
# N. --print-created-at — WHEN the pins were generated
#
# The consumer of a lock sees revisions and nothing else, so a set of pins
# generated months ago is indistinguishable, in a log, from one generated this
# morning. `[lock] created_at` is the field that says which, and it was already
# in the file this resolver has open.
#
# What is contracted here is that the resolver REPORTS the recorded value and
# never a derived one. Every arm below that expects `unknown` is an arm where a
# date could have been invented from something nearby — a `[[repo]]` table, a
# missing field, a format that has no such field at all — and inventing one
# would be worse than the silence this replaces, because a reader acts on it.
# =========================================================================

# expect_created_at DESC EXPECTED -- <resolver args...>
expect_created_at() {
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

CA="$TMPROOT/createdat"

# 1. The ordinary case: a reprobuild lock, read verbatim. `mk_toml_lock` writes
#    created_at = "2026-08-10T11:55:29Z".
mk_toml_lock "$CA/one/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
expect_created_at "created-at: reports the lock's recorded generation time" \
	"2026-08-10T11:55:29Z" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/one" --sha "$SHA_SELF" --no-walk

# 2. It is a question about the LOCK, not about a sibling, so no --sibling is
#    required. Asking for one that the lock does not pin must not change the
#    answer either: the record's age does not depend on who is asking.
expect_created_at "created-at: needs no --sibling" \
	"2026-08-10T11:55:29Z" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/one" --sha "$SHA_SELF" --no-walk
expect_created_at "created-at: a sibling absent from the lock does not change it" \
	"2026-08-10T11:55:29Z" -- \
	--repo codetracer --sibling not-in-this-lock --print-created-at \
	--manifest-dir "$CA/one" --sha "$SHA_SELF" --no-walk

# 3. Without the flag, --sibling stays REQUIRED. The new mode must not have
#    loosened the old one.
expect_fail "created-at: --sibling is still required for a revision query" 2 \
	"missing required value for SIBLING" -- \
	--repo codetracer \
	--manifest-dir "$CA/one" --sha "$SHA_SELF" --no-walk

# 4. An XML-only commit has no lock at all, so there is no generation time to
#    report: exit 3, like any unlocked commit — not `unknown`, which would say
#    a lock was found.
mk_xml_lock "$CA/xmlonly/locks/codetracer/codetracer/$SHA_SELF.xml" "$REV_NB_XML" "$REV_NIM_XML"
expect_fail "created-at: an xml-only commit is unlocked, exit 3" 3 \
	"no workspace lock found" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/xmlonly" --sha "$SHA_SELF" --no-walk

# 5. A reprobuild lock whose [lock] table simply has no created_at.
mkdir -p "$CA/nofield/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[lock]'
	printf '%s\n' 'project = "codetracer"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$CA/nofield/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_created_at "created-at: a lock with no created_at answers unknown" \
	"unknown" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/nofield" --sha "$SHA_SELF" --no-walk

# 6. THE ONE THAT MAKES THE PARSER'S TABLE SCOPING LOAD-BEARING. A created_at
#    inside a [[repo]] table is that repo's, not the lock's. Reading it as the
#    lock's would print a real-looking date for a record that never recorded
#    one — the exact shape of invented provenance this field exists to prevent.
mkdir -p "$CA/repofield/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[lock]'
	printf '%s\n' 'project = "codetracer"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' 'created_at = "1999-01-01T00:00:00Z"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$CA/repofield/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_created_at "created-at: a [[repo]] created_at is not the lock's" \
	"unknown" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/repofield" --sha "$SHA_SELF" --no-walk

# 7. Layer precedence is the same as for revisions: least specific first, and
#    the most specific layer that carries one wins.
mk_toml_lock "$CA/layers/pub/locks/codetracer/codetracer/$SHA_SELF.toml" "$REV_NB_TOML" "$REV_NIM_TOML"
mkdir -p "$CA/layers/priv/locks/codetracer/codetracer"
{
	printf '%s\n' 'schema = "reprobuild.workspace.lock.v1"'
	printf '%s\n' '[lock]'
	printf '%s\n' 'project = "codetracer"'
	printf '%s\n' 'created_at = "2026-09-09T12:55:52Z"'
	printf '%s\n' '[[repo]]'
	printf '%s\n' 'name = "codetracer-native-backend"'
	printf '%s\n' "revision = \"$REV_NB_TOML\""
} >"$CA/layers/priv/locks/codetracer/codetracer/$SHA_SELF.toml"
expect_created_at "created-at: the most specific layer's value wins" \
	"2026-09-09T12:55:52Z" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/layers/pub" --manifest-dir "$CA/layers/priv" \
	--sha "$SHA_SELF" --no-walk

# 8. No lock at all is still exit 3 — the resolver's one "this commit is not
#    locked" answer — and prints nothing on stdout. A caller must never be able
#    to mistake a missing lock for a lock of unknown age.
mkdir -p "$CA/empty/locks"
expect_fail "created-at: an unlocked commit is exit 3, not 'unknown'" 3 \
	"no workspace lock found" -- \
	--repo codetracer --print-created-at \
	--manifest-dir "$CA/empty" --sha "$SHA_SELF" --no-walk

# =========================================================================

printf '\n%s\n' "assertions: $ASSERTIONS  pass: $PASS  fail: $FAIL"
if [[ $ASSERTIONS -ne $EXPECTED_ASSERTIONS ]]; then
	printf '%s\n' "resolve-sibling-rev-test: expected $EXPECTED_ASSERTIONS assertions, ran $ASSERTIONS." >&2
	printf '%s\n' "  A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
[[ $FAIL -eq 0 ]] || exit 1
printf '%s\n' "resolve-sibling-rev: all contracts hold."
