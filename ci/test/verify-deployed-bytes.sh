#!/usr/bin/env bash
#
# verify-deployed-bytes.sh — is every host serving what the origin serves?
#
# WHAT THIS IS FOR
# ----------------
# After a Cloudflare cache purge. The deploy workflow's own verification
# compares the live hosts against the `site/` tree it just built, which a human
# running a purge does not have and should not need to rebuild for. This asks
# the same question without a build:
#
#     does each product host serve, byte for byte, what the ORIGIN serves?
#
# `web-codetracer.pages.dev` is the origin here — the Pages alias, which is
# fed directly by the deployment and was observed CORRECT throughout the
# 2026-09-01 incident while both custom domains served a stale object. So a
# disagreement between a custom domain and the alias is a stale zone cache,
# which is exactly the condition a purge is meant to clear.
#
# Running it after a purge takes about a minute and answers the only question
# that matters: did the purge work, on EVERY zone.
#
# WHY IT CHECKS EVERY DECLARED HOST AND COUNTS THEM
# -------------------------------------------------
# The deploy step it complements used to name two hosts and `noirstudio.dev`
# was not one of them. On 2026-09-01 `ide.codetracer.com` and `noirstudio.dev`
# held INDEPENDENTLY poisoned copies of `assets/wasm-worker.js` on separate
# zone caches with different ages (~138537s and ~47520s). Purging one zone
# would have turned that gate green while the other host stayed stale.
#
# So the host list is derived from the deployment descriptor the origin serves
# — `origin` plus every `languageOrigins[].origin` — and the number of hosts
# checked is asserted against the number declared. A host that drops out of
# the list has to fail, not pass.
#
# WHY EVERY COUNT IS ASSERTED
# ---------------------------
# A universal quantification over an empty set passes. While testing the
# workflow version of this on macOS, `find -printf` turned out to be an
# unknown primary there; the manifest came out empty and the step reported
# "ok: 0/0 published files match" for all four hosts and exited 0. Nothing was
# wrong with the deployment and nothing was checked. Every loop below
# therefore reports a verdict per subject and asserts the number of verdicts.
#
# USAGE
#   ci/test/verify-deployed-bytes.sh                    # against the live origin
#   ci/test/verify-deployed-bytes.sh https://other.origin
#
# Exit 0 only if every host agrees with the origin on every checked path and
# no stable-named asset is served `immutable`.

set -uo pipefail

# TOOLS RESOLVED ONCE, BY ABSOLUTE PATH, AND CHECKED.
#
# Not defensiveness for its own sake: on 2026-09-01 `curl` and `wc`
# intermittently vanished from `PATH` inside `$(...)` on the workstation these
# checks run on, and manufactured five route failures that looked exactly like
# a broken deployment (`000` status, zero bytes). A tool that is missing must
# say so once, up front, rather than be re-discovered as a fake result per
# call site.
CURL="$(command -v curl || true)"
WC="$(command -v wc || true)"
PY="$(command -v python3 || true)"
SHA="$(command -v shasum || true)"
SHA_ARGS=(-a 256)
if [ -z "$SHA" ]; then
	SHA="$(command -v sha256sum || true)"
	SHA_ARGS=()
fi
for tool in CURL WC PY SHA; do
	if [ -z "${!tool}" ]; then
		echo "verify-deployed-bytes.sh: ${tool} not found on PATH" >&2
		exit 2
	fi
done

origin="${1:-https://web-codetracer.pages.dev}"
fail=0

# ---------------------------------------------------------------------------
# The hosts, from the descriptor rather than from a list kept here.
# ---------------------------------------------------------------------------
descriptor_html="$("$CURL" -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
	"$origin/noir" || true)"
if [ -z "$descriptor_html" ]; then
	echo "could not fetch the entry document from $origin" >&2
	exit 2
fi

hosts_declared="$(printf '%s' "$descriptor_html" | "$PY" -c '
import json, re, sys
html = sys.stdin.read()
m = re.search(r"id=\"codetracer-deployment\"[^>]*>(.*?)</script>", html, re.S)
if not m:
    sys.exit("the served page carries no deployment descriptor")
d = json.loads(m.group(1))
out, seen = [], set()
for o in [d.get("origin", "")] + [x.get("origin", "") for x in d.get("languageOrigins", [])]:
    if o and o not in seen:
        seen.add(o)
        out.append(o)
print("\n".join(out))
')" || { echo "could not read the descriptor" >&2; exit 2; }

# The paths to compare. EVERY `/assets/` path comes from the descriptor, so a
# deployment that adds one is covered without editing this file; the rest are
# the fixed skeleton every deployment has.
#
# `/assets/wasm-worker.js` USED TO BE IN THE LITERAL LIST and had to come out,
# and the way it would have failed is the reason this whole file counts things.
# Every published `/assets/` file now carries a content digest in its name, so
# that literal is served by nobody — and Cloudflare Pages answers a path it has
# no file for with the SPA ENTRY DOCUMENT AT 200 `text/html`. `curl -fsSL`
# succeeds, a body is written, the digest is computed, and every host agrees
# with the origin on it, because they are all serving the same fallback page.
# The check would have gone green while checking an address that does not exist.
#
# So the paths come from the document, and the ids that MUST be there are
# asserted by name below — a list derived from a descriptor is only as
# non-vacuous as the descriptor, and an empty `assets` array would otherwise
# reduce this to the fixed skeleton without a word.
paths="$(printf '%s' "$descriptor_html" | "$PY" -c '
import json, re, sys
html = sys.stdin.read()
m = re.search(r"id=\"codetracer-deployment\"[^>]*>(.*?)</script>", html, re.S)
d = json.loads(m.group(1))
paths = ["/", "/noir", "/ui.js",
         "/worker.js", "/pkg/db_backend_bg.wasm",
         "/public/dist/frontend_bundle.js"]
for row in list(d.get("modules", [])) + list(d.get("assets", [])):
    u = row.get("url", "")
    if u and u not in paths:
        paths.append(u)
print("\n".join(paths))
')"

# THE IDS THIS DEPLOYMENT MUST DECLARE, BY NAME.
#
# `wasm-worker` is a REQUIRED asset: a deployment without it cannot start the
# Noir worker at all. Before digests its URL was a constant and this file
# spelled it; now the deployment supplies it, and what is checked instead is
# that the deployment supplies it. Named rather than counted, because "the
# descriptor listed four things" is satisfied by four of the wrong things.
declared_ids="$(printf '%s' "$descriptor_html" | "$PY" -c '
import json, re, sys
html = sys.stdin.read()
m = re.search(r"id=\"codetracer-deployment\"[^>]*>(.*?)</script>", html, re.S)
d = json.loads(m.group(1))
for row in list(d.get("modules", [])) + list(d.get("assets", [])):
    if row.get("id"):
        print(row["id"])
')"
required_ids=(wasm-worker)
for required_id in "${required_ids[@]}"; do
	if grep -qx "$required_id" <<<"$declared_ids"; then
		echo "ok: the descriptor declares \`$required_id\`"
	else
		echo "the served descriptor declares no \`$required_id\` — every /assets/ check below would be checking the fixed skeleton only" >&2
		fail=1
	fi
done

host_count=0
while IFS= read -r h; do [ -n "$h" ] && host_count=$((host_count + 1)); done <<<"$hosts_declared"
path_count=0
while IFS= read -r p; do [ -n "$p" ] && path_count=$((path_count + 1)); done <<<"$paths"

if [ "$host_count" -lt 1 ] || [ "$path_count" -lt 1 ]; then
	echo "nothing to check: $host_count hosts, $path_count paths — every result below would pass vacuously" >&2
	exit 2
fi

echo "origin : $origin"
echo "hosts  : $host_count declared"
while IFS= read -r h; do [ -n "$h" ] && printf '         %s\n' "$h"; done <<<"$hosts_declared"
echo "paths  : $path_count per host"
echo

# ---------------------------------------------------------------------------
# The origin's own bytes, once, as the thing everything is compared to.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== the origin's digests =="
origin_verdicts=0
while IFS= read -r path; do
	[ -n "$path" ] || continue
	body="$tmp/origin$(printf '%s' "$path" | tr '/' '_')"
	"$CURL" -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
		-o "$body" "$origin$path" 2>/dev/null
	if [ ! -f "$body" ]; then
		echo "  the ORIGIN did not serve $path — cannot compare hosts against it" >&2
		fail=1
		continue
	fi
	size="$("$WC" -c <"$body" | tr -d ' ')"
	digest="$("$SHA" "${SHA_ARGS[@]}" "$body" | cut -d' ' -f1)"
	printf '%s\t%s\t%s\n' "$path" "$size" "$digest" >>"$tmp/origin.tsv"
	printf '  %-34s %10s bytes  %s\n' "$path" "$size" "${digest:0:16}"
	origin_verdicts=$((origin_verdicts + 1))
done <<<"$paths"

if [ "$origin_verdicts" -ne "$path_count" ]; then
	echo "  the origin answered $origin_verdicts of $path_count paths" >&2
	fail=1
fi
echo

# ---------------------------------------------------------------------------
# Every declared host, against those digests.
# ---------------------------------------------------------------------------
hosts_checked=0
while IFS= read -r host; do
	[ -n "$host" ] || continue
	echo "== $host =="
	verdicts=0
	bad=0
	while IFS=$'\t' read -r path expect_size expect_digest; do
		[ -n "$path" ] || continue
		body="$tmp/host$(printf '%s' "$path" | tr '/' '_')"
		rm -f "$body"
		"$CURL" -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
			-o "$body" "$host$path" 2>/dev/null
		verdicts=$((verdicts + 1))
		if [ ! -f "$body" ]; then
			echo "  UNSERVED $path" >&2
			bad=$((bad + 1))
			continue
		fi
		got_size="$("$WC" -c <"$body" | tr -d ' ')"
		got_digest="$("$SHA" "${SHA_ARGS[@]}" "$body" | cut -d' ' -f1)"
		if [ "$got_digest" = "$expect_digest" ]; then
			continue
		fi
		# Size is printed beside the digest because a stale cache is usually a
		# DIFFERENT SIZE, and that is the number a human recognises from the
		# incident; a same-size different-digest is a rarer and worse thing.
		echo "  STALE    $path served $got_size bytes ($(printf '%s' "$got_digest" | cut -c1-16)), origin has $expect_size ($(printf '%s' "$expect_digest" | cut -c1-16))" >&2
		bad=$((bad + 1))
	done <"$tmp/origin.tsv"

	if [ "$verdicts" -ne "$origin_verdicts" ]; then
		echo "  $verdicts verdicts for $origin_verdicts paths — the instrument did not run over every path" >&2
		fail=1
	fi
	if [ "$bad" -eq 0 ]; then
		echo "  ok: $verdicts/$verdicts paths identical to the origin"
	else
		echo "  $bad of $verdicts paths differ from the origin — this zone's cache is stale" >&2
		fail=1
	fi
	hosts_checked=$((hosts_checked + 1))
done <<<"$hosts_declared"

if [ "$hosts_checked" -ne "$host_count" ]; then
	echo "checked $hosts_checked hosts but $host_count were declared — a host was not verified" >&2
	fail=1
fi
echo

# ---------------------------------------------------------------------------
# The cause, not just the symptom.
# ---------------------------------------------------------------------------
# A purge clears what is cached; it does not stop it being re-poisoned. If a
# stable-named asset is still being served `immutable`, the next deploy puts
# the deployment straight back into the state the purge just cleared.
# THE CHECK IS TWO-SIDED, and it did not used to be.
#
# It used to `continue` past every name that carried a digest and grade only the
# stable ones. That was right while nothing was hashed and is a check that
# asserts NOTHING now that everything is: six `continue`s, zero verdicts, and
# the `-lt 1` guard below firing on a perfectly correct deployment. Worse, if
# the guard were then deleted to make it pass — which is what happens to a check
# that fails on a correct state — the arm that catches a stable name served
# `immutable` would be gone with it.
#
# So a digest in the name is not a reason to skip; it is the PREMISE, and the
# conclusion is the opposite header in each case:
#
#   name carries a digest      MUST be `immutable`, or the deploy is paying for
#                              content addressing and getting nothing for it
#   name carries none          MUST NOT be, or a deploy cannot dislodge it
#
# Mirrors `assetIsContentAddressed` in web_deployment.nim. Deliberately NOT a
# dotfile-style blanket rule: `app.9f2b1c.js` earns it, `app.v2.js` and
# `noir_wasm.wasm` do not.
echo "== the immutable header follows the digest, in both directions =="
header_verdicts=0
asset_paths_seen=0
hashed_seen=0
while IFS=$'\t' read -r path _ _; do
	case "$path" in /assets/*) ;; *) continue ;; esac
	asset_paths_seen=$((asset_paths_seen + 1))
	name="${path##*/}"
	if grep -qE '\.[0-9a-fA-F]{6,}\.' <<<"$name"; then
		hashed=1
		hashed_seen=$((hashed_seen + 1))
	else
		hashed=0
	fi
	while IFS= read -r host; do
		[ -n "$host" ] || continue
		headers="$("$CURL" -fsSI --retry 3 --retry-delay 2 --retry-all-errors \
			"$host$path" 2>/dev/null | tr -d '\r' || true)"
		cc="$(printf '%s' "$headers" | grep -i '^cache-control:' | cut -d' ' -f2- || true)"
		ctype="$(printf '%s' "$headers" | grep -i '^content-type:' | cut -d' ' -f2- || true)"
		header_verdicts=$((header_verdicts + 1))

		# IS IT THE ASSET, OR IS IT THE ENTRY DOCUMENT WEARING ITS ADDRESS?
		# Cloudflare Pages answers a path it has no file for with the SPA
		# fallback at 200 `text/html`, so "the header is right" can be a true
		# statement about a page that is not the asset. Measured on an absent
		# `.wasm`. Nothing under `/assets/` is HTML.
		case "$ctype" in
		*text/html*)
			echo "  $host$path answered '$ctype' — that is the entry document, not the asset; the file was never published at this address" >&2
			fail=1
			continue
			;;
		esac

		# ONE `max-age`, NOT MERELY THE WORD `immutable`. Cloudflare Pages
		# applies EVERY matching `_headers` rule and CONCATENATES the values,
		# which was measured on this deployment producing
		#
		#   cache-control: public, max-age=60, must-revalidate,
		#                  public, max-age=31536000, immutable
		#
		# on a 16 MB wasm module — the short TTL first, silently undoing the
		# year. A substring test for `immutable` says that header is fine. The
		# count of `max-age=` is what says it is one rule's answer.
		age_count="$(printf '%s' "$cc" | grep -o 'max-age=' | wc -l | tr -d ' ')"
		if [ "${age_count:-0}" -gt 1 ]; then
			echo "  $host$path is served '$cc' — two rules were concatenated, and the first max-age is the one a cache obeys" >&2
			fail=1
			continue
		fi

		# AND THE `max-age` IS ACTUALLY LONG, not merely accompanied by the word
		# `immutable`.
		#
		# Measured on 2026-09-02, and it is why this is not pedantry: the custom
		# domains do not serve what `_headers` says. The pages.dev ORIGIN gives
		# `.js` and `.wasm` under `/assets/` the same header; every custom domain
		# edge-caches the `.js` (`cf-cache-status: REVALIDATED`) and REWRITES its
		# browser TTL to 14400, while the `.wasm` is not edge-cached
		# (`DYNAMIC`) and passes through untouched. That asymmetry is also the
		# explanation for the incident's: the `.js` worker was edge-cached and
		# poisoned, the wasm modules never were.
		#
		# So a zone can hand back `max-age=14400, immutable`, where the digest
		# bought four hours instead of a year, and a check that greps for the
		# word would call that a success.
		max_age="$(printf '%s' "$cc" | sed -n 's/.*max-age=\([0-9][0-9]*\).*/\1/p')"
		if [ "$hashed" -eq 1 ] && [ -n "$max_age" ] && [ "$max_age" -lt 86400 ]; then
			echo "  $host$path carries a digest and is served '$cc' — max-age=$max_age is under a day, so the content-addressed name is buying revalidation, not caching" >&2
			fail=1
			continue
		fi

		if grep -qi 'immutable' <<<"$cc"; then
			if [ "$hashed" -eq 1 ]; then
				printf '  ok: %-52s %s\n' "$host$path" "${cc:-<none>}"
			else
				echo "  $host$path is served '$cc' but its name carries no digest — a deploy cannot dislodge it" >&2
				fail=1
			fi
		else
			if [ "$hashed" -eq 1 ]; then
				echo "  $host$path carries a digest and is served '${cc:-<none>}' — the rename bought nothing and every load re-revalidates it" >&2
				fail=1
			else
				printf '  ok: %-52s %s\n' "$host$path" "${cc:-<none>}"
			fi
		fi
	done <<<"$hosts_declared"
done <"$tmp/origin.tsv"

# EVERY COUNT ASSERTED, including the one that says the interesting case
# occurred. `header_verdicts -lt 1` alone would pass a deployment that published
# a single stable-named file and nothing else; `hashed_seen -lt 1` is what says
# the content-addressing this file is checking for is actually in use.
if [ "$header_verdicts" -lt 1 ]; then
	echo "  no asset headers were checked — the origin manifest carried no /assets/ path" >&2
	fail=1
fi
if [ "$hashed_seen" -lt 1 ]; then
	echo "  none of the $asset_paths_seen /assets/ path(s) carries a digest — this deployment publishes stable names and cannot serve them immutable" >&2
	fail=1
else
	echo "  $hashed_seen of $asset_paths_seen /assets/ path(s) are content-addressed, over $header_verdicts host-path verdict(s)"
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "every declared host serves the origin's bytes, and every immutable name carries a digest."
else
	echo "the deployment is not consistent across its hosts." >&2
fi
exit "$fail"
