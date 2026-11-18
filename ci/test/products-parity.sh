#!/usr/bin/env bash
#
# products-parity.sh -- products_parity: a clean `repro build`
# of CodeTracer produces every product the last tup build produced.
#
# The list of tup's products is ci/build/linux-products-baseline.txt, recorded
# from the build rules immediately before they were removed (its header says how).
# This script checks an output tree against it, and it can say whether a tree is
# CLEAN, which is what makes "a clean build" something it can assert rather than
# something it is told.
#
# USAGE
#   products-parity.sh [--out-root DIR] [--require-clean-stamp] [--self-test]
#
#   --out-root DIR   the build output tree to check (default: $CODETRACER_BUILD_DIR,
#                    else <checkout>/src/build-<$CODETRACER_CONFIG|debug>-repro)
#   --self-test      run only the instrument checks (below), over scratch trees
#
# A product is a line `file <path>` (a regular file, or a symlink that resolves to
# one) or `tree <path>` (a directory, or a symlink that resolves to one), relative
# to the output tree; `omitted <path> -- <reason>` lines are not required. Every
# required product must exist, and a `file` must not be empty unless the baseline
# line says nothing about size (none does: tup's outputs are non-empty, with the
# one omitted exception).
#
# THE INSTRUMENT IS CHECKED FIRST, over scratch trees built from the baseline
# itself: a tree with every product passes, and a tree missing one product fails
# naming exactly that product, for a file, a tree and a symlinked tree. Without
# that, a parser that silently read an empty baseline would pass everything.
#
# FALSIFYING MUTATION (recorded in the milestone, repeatable by hand): remove one
# product's action from repro.nim (for example the `frontend-index-html` target)
# and run this script against a clean build of the mutated tree: it fails naming
# `index.html`. The `--self-test` controls above are the cheap form of the same
# thing, and need no build.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
baseline="${repo_root}/ci/build/linux-products-baseline.txt"

out_root=""
self_test_only=0
while [ $# -gt 0 ]; do
	case "$1" in
	--out-root)
		out_root="${2:?--out-root needs a directory}"
		shift 2
		;;
	--self-test)
		self_test_only=1
		shift
		;;
	-h | --help)
		sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "products-parity: unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [ -z "$out_root" ]; then
	if [ -n "${CODETRACER_BUILD_DIR:-}" ]; then
		out_root="$CODETRACER_BUILD_DIR"
	else
		out_root="${repo_root}/src/build-${CODETRACER_CONFIG:-debug}-repro"
	fi
fi

passes=0
failures=0
t_pass() {
	passes=$((passes + 1))
	echo "  ok   $1"
}
t_fail() {
	failures=$((failures + 1))
	echo "  FAIL $1" >&2
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/         /' >&2
	fi
}

# parse_baseline <file>: print `<kind>\t<path>` for every required product, in
# file order. `omitted` lines and comments are skipped.
parse_baseline() {
	awk '
		/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
		$1 == "file" || $1 == "tree" { print $1 "\t" $2 }
	' "$1"
}

# check_tree <baseline> <root>: print `<kind> <path>: <why>` for every required
# product the tree at <root> lacks; return 1 if any.
check_tree() {
	local base="$1" root="$2" kind path missing=0
	while IFS=$'\t' read -r kind path; do
		case "$kind" in
		file)
			if [ ! -e "$root/$path" ]; then
				echo "file $path: missing"
				missing=1
			elif [ ! -f "$root/$path" ]; then
				echo "file $path: not a regular file"
				missing=1
			elif [ ! -s "$root/$path" ]; then
				echo "file $path: empty"
				missing=1
			fi
			;;
		tree)
			if [ ! -e "$root/$path" ]; then
				echo "tree $path: missing"
				missing=1
			elif [ ! -d "$root/$path" ]; then
				echo "tree $path: not a directory"
				missing=1
			fi
			;;
		esac
	done < <(parse_baseline "$base")
	return "$missing"
}

work="$(mktemp -d "${TMPDIR:-/tmp}/parity.XXXXXX")"
trap 'rm -rf "${work:?}"' EXIT

echo "products_parity:"

# --- instrument: the baseline parses to something, and the check discriminates.
total="$(parse_baseline "$baseline" | wc -l | tr -d ' ')"
if [ "$total" -ge 100 ]; then
	t_pass "the baseline lists ${total} required products"
else
	t_fail "the baseline lists at least 100 required products" "parsed ${total} from ${baseline}"
fi
# Captured first: `grep -q` closes the pipe on its first match and, under
# pipefail, the producer's SIGPIPE would read as a failed match.
parsed_baseline="$(parse_baseline "$baseline" | tr '\t' ' ')"
for need in "file bin/ct" "file bin/replay-server" "file bin/session-manager" "file bin/db-backend-record" \
	"file bin/ct-test" "file ui.js" "file index.js" "file subwindow.js" "file server_index.js" \
	"file index.html" "file config/default_config.yaml" "tree public/dist"; do
	if grep -qxF "$need" <<<"$parsed_baseline"; then
		t_pass "the baseline requires '${need}'"
	else
		t_fail "the baseline requires '${need}'" "it is not in ${baseline}"
	fi
done

# A scratch tree holding every required product: real files for `file`, real
# directories for `tree`, and one `tree` spelt as a symlink (the shape tup gave the
# third-party directories).
full="$work/full"
mkdir -p "$full"
symlink_done=0
while IFS=$'\t' read -r kind path; do
	case "$kind" in
	file)
		mkdir -p "$full/$(dirname "$path")"
		printf 'x\n' >"$full/$path"
		;;
	tree)
		if [ "$symlink_done" -eq 0 ] && [[ $path == public/third_party/* ]]; then
			mkdir -p "$full/$(dirname "$path")" "$work/linked-target"
			ln -s "$work/linked-target" "$full/$path"
			symlink_done=1
		else
			mkdir -p "$full/$path"
		fi
		;;
	esac
done < <(parse_baseline "$baseline")
if out="$(check_tree "$baseline" "$full")"; then
	t_pass "control: a tree holding every required product passes"
else
	t_fail "control: a tree holding every required product passes" "$out"
fi
if [ "$symlink_done" -eq 1 ]; then
	t_pass "control: a symlinked tree product counts as present"
else
	t_fail "control: a symlinked tree product counts as present" "the baseline has no public/third_party tree to link"
fi

# Remove one product of each kind in turn: the check must fail and name it.
drop_one() {
	local label="$1" kind_want="$2" pattern="$3" kind path victim=""
	while IFS=$'\t' read -r kind path; do
		# $pattern is a glob on purpose.
		# shellcheck disable=SC2053
		if [ "$kind" = "$kind_want" ] && [[ $path == $pattern ]]; then
			victim="$path"
			break
		fi
	done < <(parse_baseline "$baseline")
	if [ -z "$victim" ]; then
		t_fail "$label" "no ${kind_want} product matching ${pattern} in the baseline"
		return
	fi
	local copy="$work/drop-$$-$RANDOM"
	cp -a "$full" "$copy"
	rm -rf "${copy:?}/${victim:?}"
	local out
	if out="$(check_tree "$baseline" "$copy")"; then
		t_fail "$label" "the check passed a tree missing ${victim}"
	elif [ "$out" = "${kind_want} ${victim}: missing" ]; then
		t_pass "$label"
	else
		t_fail "$label" "expected exactly '${kind_want} ${victim}: missing', got: ${out}"
	fi
	rm -rf "${copy:?}"
}
drop_one "mutation: a missing binary fails and is named" file "bin/replay-server"
drop_one "mutation: a missing generated file fails and is named" file "index.html"
drop_one "mutation: a missing copied resource fails and is named" file "public/resources/*"
drop_one "mutation: a missing tree fails and is named" tree "public/dist"

# An empty file is not a product.
copy="$work/empty-one"
cp -a "$full" "$copy"
: >"$copy/bin/ct"
if out="$(check_tree "$baseline" "$copy")" || [ "$out" != "file bin/ct: empty" ]; then
	t_fail "mutation: an empty bin/ct fails and is named" "got: ${out:-<passed>}"
else
	t_pass "mutation: an empty bin/ct fails and is named"
fi

if [ "$self_test_only" -eq 1 ]; then
	echo
	echo "products_parity (self-test only): ${passes} passed, ${failures} failed"
	[ "$failures" -eq 0 ]
	exit
fi

# --- the build.
echo
echo "the output tree ${out_root}:"
if [ ! -d "$out_root" ]; then
	t_fail "the output tree exists" "${out_root} is not a directory; run 'just build-once' first"
elif out="$(check_tree "$baseline" "$out_root")"; then
	t_pass "every one of the ${total} products tup built is in the output tree"
else
	t_fail "every product tup built is in the output tree" "$out"
fi

echo
echo "products_parity: ${passes} passed, ${failures} failed"
[ "$failures" -eq 0 ]
