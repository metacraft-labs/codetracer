#!/usr/bin/env bash
#
# Verification for `ci/deploy/docs-preview-comment.sh`.
#
# The one property that matters is that a pull request ends up with EXACTLY ONE
# preview comment however many times it is pushed to. Everything else about the
# script serves that: the hidden marker it searches by, the pagination of the
# search, and the choice between POST and PATCH.
#
# Driven against a fake GitHub REST API rather than mocked at the shell level.
# The script's real behaviour is which HTTP requests it makes, so the test
# records exactly that -- a stub of `curl` would only assert that the script
# calls the function the test told it to call.
#
# The fake implements the three endpoints the script uses (list issue comments
# with pagination, create, update) plus a failure-injection switch, and keeps a
# real comment store so "post once, edit thereafter" is observable rather than
# inferred.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/ci/deploy/docs-preview-comment.sh"
TEST_ROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

FAILURES=0
CASE=""
begin() {
	CASE="$1"
	echo
	echo "== $CASE"
}
pass() { echo "   ok -- $*"; }

fail() {
	echo "   FAIL [$CASE] -- $*" >&2
	FAILURES=$((FAILURES + 1))
}

# `A && pass || fail` reads as if-then-else but is not, so every check goes
# through here instead.
assert_eq() {
	# $1 actual, $2 expected, $3 label
	if [ "$1" = "$2" ]; then
		pass "$3"
	else
		fail "$3 -- got '$1', want '$2'"
	fi
}

assert_contains() {
	# $1 haystack, $2 needle, $3 label
	case "$1" in
	*"$2"*) pass "$3" ;;
	*) fail "$3 -- '$2' is absent" ;;
	esac
}

command -v jq >/dev/null || {
	echo "jq is required" >&2
	exit 1
}

STATE="$TEST_ROOT/state.json"
echo '{"comments": [], "requests": [], "next_id": 1000, "fail_status": 0}' >"$STATE"

cat >"$TEST_ROOT/fake_github.py" <<'PY'
"""Minimal stand-in for the GitHub issue-comments API.

Only the three routes docs-preview-comment.sh uses, plus a `fail_status` knob
so the caller can assert that an API failure is not swallowed. State lives in a
JSON file so the shell test can seed and inspect it between invocations.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE = sys.argv[1]
PORT_FILE = sys.argv[2]


def load():
    with open(STATE) as f:
        return json.load(f)


def save(state):
    with open(STATE, "w") as f:
        json.dump(state, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the test output readable
        pass

    def _send(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, method):
        state = load()
        state["requests"].append({"method": method, "path": self.path})
        save(state)
        return state

    def do_GET(self):
        state = self._record("GET")
        if state["fail_status"]:
            return self._send(state["fail_status"], {"message": "injected failure"})
        m = re.match(r"/repos/[^/]+/[^/]+/issues/(\d+)/comments", self.path)
        if not m:
            return self._send(404, {"message": "no route"})
        page = 1
        pm = re.search(r"[?&]page=(\d+)", self.path)
        if pm:
            page = int(pm.group(1))
        # Page size is fixed at 100 to match what the script asks for; the
        # store is padded by the test when a pagination case is wanted.
        chunk = state["comments"][(page - 1) * 100: page * 100]
        self._send(200, chunk)

    def do_POST(self):
        state = self._record("POST")
        if state["fail_status"]:
            return self._send(state["fail_status"], {"message": "injected failure"})
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        comment = {"id": state["next_id"], "body": body.get("body", "")}
        state["next_id"] += 1
        state["comments"].append(comment)
        save(state)
        self._send(201, comment)

    def do_PATCH(self):
        state = self._record("PATCH")
        if state["fail_status"]:
            return self._send(state["fail_status"], {"message": "injected failure"})
        m = re.match(r"/repos/[^/]+/[^/]+/issues/comments/(\d+)", self.path)
        if not m:
            return self._send(404, {"message": "no route"})
        cid = int(m.group(1))
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        for c in state["comments"]:
            if c["id"] == cid:
                c["body"] = body.get("body", "")
                save(state)
                return self._send(200, c)
        self._send(404, {"message": "no such comment"})


# Bind an ephemeral port and publish it: a fixed port would make this test
# collide with anything else already listening on a shared runner.
server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY

PORT_FILE="$TEST_ROOT/port"
python3 "$TEST_ROOT/fake_github.py" "$STATE" "$PORT_FILE" &
SERVER_PID=$!

# Wait for the fake to publish its port and accept a connection, rather than
# sleeping a guess.
API=""
for _ in $(seq 1 200); do
	if [ -s "$PORT_FILE" ]; then
		API="http://127.0.0.1:$(cat "$PORT_FILE")"
		if curl -s -o /dev/null "${API}/repos/x/y/issues/1/comments"; then break; fi
	fi
	sleep 0.1
done
[ -n "$API" ] || {
	echo "the fake GitHub API never started" >&2
	exit 1
}

export GITHUB_TOKEN=fake-token
export GITHUB_REPOSITORY=metacraft-labs/codetracer
export GITHUB_API_URL="$API"

reset_state() {
	echo '{"comments": [], "requests": [], "next_id": 1000, "fail_status": 0}' >"$STATE"
}

requests_of() { jq -r --arg m "$1" '[.requests[] | select(.method == $m)] | length' "$STATE"; }
comment_count() { jq '.comments | length' "$STATE"; }
comment_body() { jq -r '.comments[0].body' "$STATE"; }

run_script() {
	local rc=0
	"$SCRIPT" "$@" >"$TEST_ROOT/out.log" 2>&1 || rc=$?
	return "$rc"
}

# --- 1. first push: the comment is created ----------------------------------

begin "the first push posts one comment naming the URL and the commit"
reset_state
if run_script published 42 "https://docs.codetracer.com/pr/42/" "0123456789abcdef"; then
	pass "the script succeeded"
else
	fail "the script failed: $(cat "$TEST_ROOT/out.log")"
fi
assert_eq "$(comment_count)" 1 "exactly one comment exists"
assert_eq "$(requests_of POST)" 1 "one POST"
assert_eq "$(requests_of PATCH)" 0 "no PATCH"
body="$(comment_body)"
for want in "<!-- codetracer-docs-preview -->" "https://docs.codetracer.com/pr/42/" "0123456"; do
	assert_contains "$body" "$want" "the body carries '$want'"
done
# The full sha would be noise; the point is that SOME identification of the
# built commit is present and it is the head sha, not the merge commit.
case "$body" in
*"0123456789abcdef"*) fail "the body carries the full sha rather than a short one" ;;
*) pass "the commit is abbreviated" ;;
esac

# --- 2. subsequent pushes edit the same comment -----------------------------

begin "later pushes edit that comment instead of adding more"
first_id="$(jq -r '.comments[0].id' "$STATE")"
for sha in 1111111111111111 2222222222222222 3333333333333333; do
	run_script published 42 "https://docs.codetracer.com/pr/42/" "$sha" ||
		fail "push with sha $sha failed: $(cat "$TEST_ROOT/out.log")"
done
if [ "$(comment_count)" = "1" ]; then
	pass "still exactly one comment after three more pushes"
else
	fail "$(comment_count) comments after three more pushes"
fi
assert_eq "$(requests_of POST)" 1 "still only the original POST"
assert_eq "$(requests_of PATCH)" 3 "three PATCHes, one per push"
assert_eq "$(jq -r '.comments[0].id' "$STATE")" "$first_id" "the same comment id was edited"
assert_contains "$(comment_body)" "3333333" "the body now names the newest commit"

# --- 3. closing the pull request corrects the comment -----------------------

begin "closing the pull request rewrites the comment rather than posting"
run_script removed 42 || fail "removed mode failed: $(cat "$TEST_ROOT/out.log")"
assert_eq "$(comment_count)" 1 "still one comment"
assert_eq "$(requests_of POST)" 1 "no new POST"
assert_contains "$(comment_body)" "has been removed" "the body says the preview is gone"

begin "reopening the pull request reuses the same comment rather than adding one"
# A closed pull request can be reopened and pushed to, which publishes the
# preview again. The `removed` body must therefore stay FINDABLE -- it has to
# keep carrying the hidden marker. A "removed" notice written without it would
# look perfectly fine, and the next push would quietly post a second preview
# comment, which is the one outcome this script exists to prevent.
run_script published 42 "https://docs.codetracer.com/pr/42/" "4444444444444444" ||
	fail "the republish after reopening failed: $(cat "$TEST_ROOT/out.log")"
assert_eq "$(comment_count)" 1 "still exactly one comment after close-and-reopen"
assert_eq "$(requests_of POST)" 1 "no second POST"
assert_eq "$(jq -r '.comments[0].id' "$STATE")" "$first_id" "the original comment was reused"
assert_contains "$(comment_body)" "4444444" "it names the commit pushed after reopening"

begin "closing a pull request that never had a preview posts nothing"
reset_state
run_script removed 77 || fail "removed mode failed: $(cat "$TEST_ROOT/out.log")"
assert_eq "$(comment_count)" 0 "no comment was created"
assert_eq "$(requests_of POST)" 0 "no POST"
assert_eq "$(requests_of PATCH)" 0 "no PATCH"

# --- 4. the marker is found beyond the first page ---------------------------

begin "the existing comment is found even past the first page of comments"
# A long-lived pull request easily passes 100 comments. A search that stopped
# at the first page would silently start posting a second preview comment.
reset_state
python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
state["comments"] = [{"id": i, "body": "ordinary review comment %d" % i} for i in range(1, 151)]
state["comments"][140]["body"] = "<!-- codetracer-docs-preview -->\nold preview comment"
state["next_id"] = 9000
json.dump(state, open(path, "w"))
PY
marked_id="$(jq -r '.comments[140].id' "$STATE")"
run_script published 42 "https://docs.codetracer.com/pr/42/" "abcdef1234567890" ||
	fail "the script failed: $(cat "$TEST_ROOT/out.log")"
assert_eq "$(comment_count)" 150 "no comment was added"
assert_eq "$(requests_of POST)" 0 "no POST"
assert_eq "$(requests_of PATCH)" 1 "one PATCH"
if jq -e --argjson id "$marked_id" '.comments[] | select(.id == $id) | .body | contains("/pr/42/")' \
	"$STATE" >/dev/null; then
	pass "the marked comment on page 2 is the one that was edited"
else
	fail "a different comment was edited"
fi

# --- 5. failures are not swallowed ------------------------------------------

begin "an API failure fails the step"
reset_state
jq '.fail_status = 403' "$STATE" >"$TEST_ROOT/s" && mv "$TEST_ROOT/s" "$STATE"
if run_script published 42 "https://docs.codetracer.com/pr/42/" "abcdef1234567890"; then
	fail "a 403 from the API produced a green step"
else
	pass "exited non-zero"
	if grep -q "403" "$TEST_ROOT/out.log"; then
		pass "the status is in the log"
	else
		fail "the log does not name the status"
	fi
fi
reset_state

begin "unusable arguments are refused"
# `٤٢` is Arabic-Indic for 42, which a locale-collated `[0-9]` range accepts.
for args in "published" "published 0 url sha" "published abc url sha" "published 42" "bogus 42" "published ٤٢ url sha"; do
	# shellcheck disable=SC2086  # deliberate word splitting of the argument fixture
	if run_script $args; then
		fail "'$args' was accepted"
	else
		pass "'$args' was refused"
	fi
done
assert_eq "$(requests_of POST)" 0 "nothing was posted while refusing"

echo
if [ "$FAILURES" -gt 0 ]; then
	echo "docs preview comment tests: $FAILURES failure(s)." >&2
	exit 1
fi
echo "docs preview comment tests passed."
