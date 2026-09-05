#!/usr/bin/env bash
#
# check-test-assertions.sh — Flag Rust test functions with zero assert statements.
#
# Part of the M0 CI lint deliverable. Scans .rs files for #[test] functions
# whose bodies contain no assertion or expectation calls.
#
# Usage:
#   ./tools/check-test-assertions.sh [OPTIONS] [DIR ...]
#
# Options:
#   --help         Show this help message and exit.
#   --strict       Also flag tests whose only "assertion" is .unwrap().
#                  (unwrap alone is a weak assertion — it checks for Some/Ok
#                  but doesn't verify the value.)
#   --allow-empty  Treat "nothing to scan" as success instead of an error.
#
# Directories default to  src/  and  tests/  when none are given.
#
# WHAT COUNTS AS AN ASSERTION
#   1. An assertion macro: assert!, assert_eq!, assert_ne!, assert_matches!,
#      debug_assert*.
#   2. A loud-failure macro: panic!, unreachable!, todo!, unimplemented!.
#      A test that reaches one of these cannot report success, which is the
#      property this lint exists to enforce — so a stub armed with one is
#      correct code, not a violation. Flagging those buries real findings
#      under good code, which is how a lint gets ignored and then disabled.
#   3. .expect(...).
#   4. A call to a DIVERGING function declared in the same file (`-> !`).
#      Same argument as (2): the callee cannot return, so the caller cannot
#      self-pass. This is how a repository factors "unimplemented end-to-end
#      body" out of twenty test stubs without copying panic! into each.
#   5. A call to a function declared in the same file that is itself
#      assertive, resolved TRANSITIVELY. A table-driven test whose assertions
#      live in a shared `run_x_dap_test(...)` driver is not assertion-less.
#      Only rules 1, 2, 4 and 6 propagate this way — NOT `.expect(...)`. A
#      setup helper that writes `env::var(..).expect(..)` is doing plumbing,
#      and treating that as an assertion made every test that merely located
#      its fixture look assertive, hiding real stubs behind their own setup.
#   6. A call to a function whose NAME begins with `assert_` — the Rust
#      convention for a panicking checker, and the only rule here that reaches
#      a helper defined in another file (e.g. `assert_hop_count`).
#
# WHAT IT DELIBERATELY CANNOT SEE (documented residue, not oversight)
#   - A diverging or assertive helper defined in ANOTHER file and not named
#     `assert_*`. Resolving that needs the module graph and type information;
#     a shell lint should not pretend to have either. Rule 6 is the cheap
#     convention-based substitute.
#   - Assertive METHODS (`runner.verify(...)`), trait/generic dispatch, and
#     assertions produced by a macro defined elsewhere. Method calls are
#     deliberately NOT resolved: `x.run(...)` and a local `fn run(...)` are
#     different functions and treating them as one would let a vacuous test
#     through.
#   Every residue above is in the SAFE direction for a stub-hunter: it makes
#   the lint flag honest code, never let a vacuous test pass.
#
# COMMENTS AND STRING LITERALS ARE NOT CODE. Line comments, nested block
# comments, ordinary/raw/byte strings and char literals are stripped before
# anything is matched. Without that stripping this lint had a silent-pass
# hole in the direction that matters: `// assert_eq!(a, b);` SATISFIED it, so
# commenting an assertion out kept the test green. It also scanned `#[test]`
# found inside a raw string or a block comment as if it were a real test, and
# counted braces inside literals when finding function bodies.
#
# The verdict names the quantities it measured — directories, .rs files and
# #[test] functions — so a run that scanned nothing is visibly different from
# a run that scanned and found no violations. Scanning zero files is an ERROR
# (exit 3) unless --allow-empty is given: a lint that read no code has not
# cleared any code.
#
# Exit codes:
#   0  All test functions contain at least one assertion.
#   1  One or more test functions lack assertions.
#   2  Usage / argument error.
#   3  Nothing was scanned (no existing directories, or no .rs files in them).
#
# WHERE THIS RUNS. This repo is the canonical home, and `just
# test-check-test-assertions` proves the lint still works here. It has no
# subject here, though — the code it judges lives in the product repos, and
# those repos do not have this one on disk: `codetracer`'s lint job checks out
# `codetracer` alone, so for its first years this lint shipped to nobody and
# `codetracer` accumulated assertion-less tests inside a required gate.
#
# Delivery is therefore a BYTE-IDENTICAL VENDORED COPY at
# `codetracer/tools/check-test-assertions.sh`, guarded by a sha256 comparison
# in `codetracer/ci/test/test-assertion-baseline.sh` that fires whenever both
# repos are on disk. Edit this file, then re-copy; do not edit the copy.
#
# Pre-commit integration (prek / .pre-commit-config.yaml):
#   - repo: local
#     hooks:
#       - id: check-test-assertions
#         name: Rust test assertion lint
#         entry: ./tools/check-test-assertions.sh
#         language: script
#         types: [rust]
#         pass_filenames: false
#

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  # `\?` is a GNU extension; BSD sed treats it literally, so the substitution
  # never matched and `--help` printed nothing at all on macOS. `\{0,1\}` is
  # POSIX BRE and works in both.
  sed -n '3,/^$/{s/^# \{0,1\}//;p;}' "$0"
  exit "${1:-0}"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# ── Argument parsing ────────────────────────────────────────────────────────

STRICT=0
ALLOW_EMPTY=0
DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)      usage 0 ;;
    --strict)       STRICT=1; shift ;;
    --allow-empty)  ALLOW_EMPTY=1; shift ;;
    -*)             die "unknown option: $1" ;;
    *)              DIRS+=("$1"); shift ;;
  esac
done

if [[ ${#DIRS[@]} -eq 0 ]]; then
  DIRS=(src tests)
fi

# Filter to directories that actually exist.
EXISTING_DIRS=()
MISSING_DIRS=()
for d in "${DIRS[@]}"; do
  if [[ -d "$d" ]]; then
    EXISTING_DIRS+=("$d")
  else
    MISSING_DIRS+=("$d")
  fi
done

report_empty() {
  # "Nothing to scan" is not a pass. Name what was empty.
  local reason="$1"
  if [[ "$ALLOW_EMPTY" -eq 1 ]]; then
    echo "test assertion lint: nothing to scan ($reason) — accepted via --allow-empty"
    exit 0
  fi
  echo "test assertion lint DID NOT RUN: $reason" >&2
  echo "  requested directories: ${DIRS[*]}" >&2
  if [[ ${#MISSING_DIRS[@]} -gt 0 ]]; then
    echo "  missing directories:   ${MISSING_DIRS[*]}" >&2
  fi
  echo "  (pass --allow-empty if an empty scan is genuinely acceptable here)" >&2
  exit 3
}

if [[ ${#EXISTING_DIRS[@]} -eq 0 ]]; then
  report_empty "none of the requested directories exist under $PWD"
fi

# ── Main logic ──────────────────────────────────────────────────────────────
#
# Strategy: two awk passes over each .rs file.
#
#   Pass 1 records, for every function DEFINED in the file: whether its
#   signature diverges (`-> !`), whether its body contains a direct assertion,
#   and which same-file functions it calls. A fixpoint over that call graph
#   then marks every transitively assertive helper.
#
#   Pass 2 walks the #[test] functions and asks whether each body contains a
#   direct assertion or a call to a helper pass 1 marked assertive.
#
# Both passes read only SANITIZED lines — comments and literals removed — so
# brace counting finds real function bodies and no commented-out assertion is
# mistaken for a live one.

VIOLATIONS=0
FILES_SCANNED=0
FILES_WITH_TESTS=0
TESTS_EXAMINED=0
VIOLATION_COUNT=0

# A test attribute is an attribute whose path ENDS in `test`: #[test],
# #[tokio::test], #[tokio::test(flavor = "...")], #[async_std::test].
#
# It is NOT `#[cfg(test)]`, and the difference is not cosmetic: matching
# `#[.*test` made every `#[cfg(test)]` helper function in a file that also
# had real tests count as a test function AND get reported as assertion-less.
# It is also not `#[ignore = "... run via: just test-x-flow"]`, which the old
# pattern matched through the string literal.
#
# The same expression is the file pre-filter. As `#\[test` it skipped any file
# whose tests are ALL `#[tokio::test]` — those files were never scanned at all.
TEST_ATTR_RE='#\[[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*::[[:space:]]*)*test[[:space:]]*[](]'

check_file() {
  local file="$1"
  local strict="$2"

  # Fast pre-filter: skip files with no test attribute at all.
  if ! grep -qE "$TEST_ATTR_RE" "$file" 2>/dev/null; then
    return 0
  fi

  awk -v file="$file" -v strict="$strict" '
    function reset_scanner() {
      in_block = 0; block_depth = 0; in_raw = 0; raw_hashes = 0; in_str = 0
    }

    function hashes(k,   s, i) { s = ""; for (i = 0; i < k; i++) s = s "#"; return s }

    # Remove comment and literal CONTENT from a line, carrying multi-line
    # block-comment / raw-string state across calls. What is returned is the
    # code, and only the code.
    function sanitize(line,   out, i, n, c, c2, j, k, prev) {
      # Fast path: nothing that can open or close a comment or a literal.
      if (!in_block && !in_raw && !in_str && line !~ /["\047\/]/) return line
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        c  = substr(line, i, 1)
        c2 = substr(line, i, 2)
        if (in_block) {
          if (c2 == "*/") { block_depth--; if (block_depth <= 0) in_block = 0; i += 2; continue }
          if (c2 == "/*") { block_depth++; i += 2; continue }
          i++; continue
        }
        if (in_raw) {
          if (c == "\"" && (raw_hashes == 0 || substr(line, i + 1, raw_hashes) == hashes(raw_hashes))) {
            in_raw = 0; i += 1 + raw_hashes; continue
          }
          i++; continue
        }
        if (in_str) {
          if (c == "\\") { i += 2; continue }
          if (c == "\"") { in_str = 0; i++; continue }
          i++; continue
        }
        if (c2 == "//") break
        if (c2 == "/*") { in_block = 1; block_depth = 1; i += 2; continue }
        # Raw / byte-raw string opener:  r"  r#"  r##"  br"  br#"
        if (c == "r" || c == "b") {
          prev = (i == 1) ? "" : substr(line, i - 1, 1)
          if (prev !~ /[A-Za-z0-9_]/) {
            j = i
            if (substr(line, j, 1) == "b") j++
            if (substr(line, j, 1) == "r") {
              j++; k = 0
              while (substr(line, j, 1) == "#") { k++; j++ }
              if (substr(line, j, 1) == "\"") { in_raw = 1; raw_hashes = k; i = j + 1; continue }
            }
          }
        }
        if (c == "\"") { in_str = 1; i++; continue }
        if (c == "\047") {                                  # char literal or lifetime
          if (substr(line, i + 1, 1) == "\\") {             # escaped: \n \047 \\
            j = i + 2
            while (j <= n && substr(line, j, 1) != "\047") j++
            i = j + 1; continue
          }
          if (substr(line, i + 2, 1) == "\047") { i += 3; continue }   # plain: a
          # else a lifetime such as &\047a — emit it
        }
        out = out c
        i++
      }
      return out
    }

    # A STRONG assertion: the line states a property of the thing under test
    # and fails the run when it does not hold. Rules 1, 2 and 6.
    #
    # Only these propagate through the helper call graph. `.expect(...)` is
    # deliberately excluded here, and that exclusion is the whole reason this
    # predicate is separate from the next one: a setup helper that writes
    # `env::var("CARGO_MANIFEST_DIR").expect(...)` is doing PLUMBING, not
    # asserting anything about the code under test. Propagating that made
    # every test that merely located its fixture count as assertive, which
    # would have hidden real stubs behind their setup code.
    function has_strong_assert(s) {
      if (s ~ /(^|[^A-Za-z0-9_])(assert|assert_eq|assert_ne|assert_matches|debug_assert|debug_assert_eq|debug_assert_ne)[[:space:]]*!/) return 1
      if (s ~ /(^|[^A-Za-z0-9_])(panic|unreachable|todo|unimplemented)[[:space:]]*!/) return 1
      if (s ~ /(^|[^A-Za-z0-9_])assert_[A-Za-z0-9_]*[[:space:]]*\(/) return 1
      return 0
    }

    # What satisfies the lint when written directly in a TEST body: the strong
    # forms above plus `.expect(...)`, which the original lint accepted and
    # which is a deliberate failure point when the test author writes it.
    function has_direct_assert(s) {
      if (has_strong_assert(s)) return 1
      if (s ~ /\.expect[[:space:]]*\(/) return 1
      if (s ~ /(^|[^A-Za-z0-9_])expect[[:space:]]*\(/) return 1
      return 0
    }

    # Record every same-file function `owner` calls. Method calls (`x.f()`)
    # are skipped: a method and a free function of the same name are different
    # functions, and conflating them would let a vacuous test through.
    function collect_calls(s, owner,   t, nm, prevc, off) {
      if (owner == "") return
      t = s; off = 0
      while (match(t, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        prevc = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ((off == 0) ? "" : "x")
        nm = substr(t, RSTART, RLENGTH); sub(/[[:space:]]*\($/, "", nm)
        t = substr(t, RSTART + RLENGTH); off = 1
        if (prevc == ".") continue
        if (nm ~ /^(if|while|for|match|fn|return|let|Some|Ok|Err|None|as|in)$/) continue
        if ((owner SUBSEP nm) in seen_call) continue
        seen_call[owner SUBSEP nm] = 1
        calls[owner] = calls[owner] " " nm
      }
    }

    function resolve_fixpoint(   changed, rounds, nm, arr, cnt, i) {
      rounds = 0
      do {
        changed = 0; rounds++
        for (nm in calls) {
          if (assertive[nm]) continue
          cnt = split(calls[nm], arr, " ")
          for (i = 1; i <= cnt; i++) {
            if (arr[i] != "" && assertive[arr[i]]) { assertive[nm] = 1; changed = 1; break }
          }
        }
      } while (changed && rounds < 50)
    }

    # Rules 4 and 5 — needs the pass-1 call graph.
    function line_is_assertive(s,   t, nm, prevc, off) {
      if (has_direct_assert(s)) return 1
      t = s; off = 0
      while (match(t, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
        prevc = (RSTART > 1) ? substr(t, RSTART - 1, 1) : ((off == 0) ? "" : "x")
        nm = substr(t, RSTART, RLENGTH); sub(/[[:space:]]*\($/, "", nm)
        t = substr(t, RSTART + RLENGTH); off = 1
        if (prevc == ".") continue
        if (assertive[nm]) return 1
      }
      return 0
    }

    BEGIN { reset_scanner(); depth = 0; stack_n = 0 }

    # ── Pass 1: what does every function in this file do? ────────────────────
    FNR == NR {
      if (FNR == 1) { reset_scanner(); depth = 0; stack_n = 0; collecting_sig = 0 }
      s = sanitize($0)

      if (collecting_sig) {
        sig_text = sig_text " " s
        if (index(s, "{") > 0) collecting_sig = 0
      } else if (s ~ /(^|[^A-Za-z0-9_])fn[[:space:]]+[A-Za-z_]/) {
        tmp = s
        sub(/.*fn[[:space:]]+/, "", tmp)
        sub(/[^A-Za-z0-9_].*/, "", tmp)
        sig_fn = tmp
        sig_text = s
        pending_fn = sig_fn
        if (index(s, "{") == 0) collecting_sig = 1
        if (sig_text ~ /->[[:space:]]*!/) { diverges[sig_fn] = 1; assertive[sig_fn] = 1 }
      }

      opened_here = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "{") {
          depth++
          if (pending_fn != "") {
            stack_n++; stack_name[stack_n] = pending_fn; stack_depth[stack_n] = depth
            opened_here = pending_fn; pending_fn = ""
          }
        } else if (c == "}") {
          if (stack_n > 0 && stack_depth[stack_n] == depth) stack_n--
          depth--
        }
      }

      # Attribute the line to the function whose body it is in. `owner_before`
      # keeps a closing `}` line (which may still carry an assertion) with the
      # function it closes; `opened_here` catches a one-line body.
      owner = (owner_before != "") ? owner_before : opened_here
      if (owner != "") {
        if (has_strong_assert(s)) { direct[owner] = 1; assertive[owner] = 1 }
        collect_calls(s, owner)
      }
      if (sig_text ~ /->[[:space:]]*!/ && sig_fn != "") { diverges[sig_fn] = 1; assertive[sig_fn] = 1 }
      owner_before = (stack_n > 0) ? stack_name[stack_n] : ""
      next
    }

    # ── Pass 2: do the #[test] functions assert? ─────────────────────────────
    !fixpoint_done {
      resolve_fixpoint(); fixpoint_done = 1
      reset_scanner(); brace_depth = 0
      in_test_attr = 0; in_test_fn = 0
    }

    {
      s = sanitize($0)

      if (s ~ /^[[:space:]]*#\[[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]*::[[:space:]]*)*test[[:space:]]*[](]/) {
        in_test_attr = 1
        has_should_panic = 0
      }

      # Only an ATTRIBUTE line can carry #[should_panic]. Without the `#[`
      # guard, a test merely NAMED `..._should_panic` matched here -- the fn
      # line is still seen while in_test_attr is set -- and was exempted from
      # the lint entirely on the strength of its own name.
      if (in_test_attr && s ~ /^[[:space:]]*#\[/ && s ~ /should_panic/) has_should_panic = 1

      if (in_test_attr && s ~ /^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn[[:space:]]+/) {
        in_test_fn   = 1
        in_test_attr = 0
        brace_depth  = 0
        body_started = 0
        has_assert   = 0
        has_unwrap   = 0
        tests++

        tmp = s
        sub(/.*fn[[:space:]]+/, "", tmp)
        sub(/[^A-Za-z0-9_].*/, "", tmp)
        fn_name = tmp
        fn_line = FNR

        # should_panic IS the assertion: the test fails if it does not panic.
        if (has_should_panic) has_assert = 1
      } else if (in_test_attr && s !~ /^[[:space:]]*#\[/ && s !~ /^[[:space:]]*$/) {
        in_test_attr = 0
      }

      if (in_test_fn) {
        n = length(s)
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1)
          if (c == "{") { brace_depth++; body_started = 1 }
          else if (c == "}") brace_depth--
        }

        if (line_is_assertive(s)) has_assert = 1
        if (s ~ /\.unwrap[[:space:]]*\(/) has_unwrap = 1
        if (s ~ /\?[[:space:]]*;/ || s ~ /\?[[:space:]]*$/) has_unwrap = 1

        # End of function body. The opening brace must have been seen first:
        # the original guard was `brace_depth <= 0 && brace_depth != 0 - 0`,
        # i.e. `brace_depth < 0`, which balanced code never reaches -- so this
        # block never ran and the lint could not report a violation at all.
        if (body_started && brace_depth <= 0) {
          pass = 0
          if (has_assert) pass = 1
          else if (has_unwrap && strict != "1") pass = 1

          if (!pass) {
            if (strict == "1" && has_unwrap && !has_assert) {
              printf "%s:%d: test `%s` has only .unwrap() — no real assertion\n", file, fn_line, fn_name
            } else {
              printf "%s:%d: test `%s` has zero assert statements\n", file, fn_line, fn_name
            }
            violations++
          }

          in_test_fn = 0
          brace_depth = 0
        }
      }
    }

    END {
      # Machine-readable tally consumed by the caller, so the verdict can name
      # how many test functions were actually examined.
      printf "@@TALLY %d %d\n", tests, violations
      exit (violations > 0) ? 1 : 0
    }
  ' "$file" "$file"
}

# Find all .rs files in the target directories.
while IFS= read -r -d '' rsfile; do
  FILES_SCANNED=$((FILES_SCANNED + 1))
  output=""
  if ! output="$(check_file "$rsfile" "$STRICT")"; then
    VIOLATIONS=1
  fi
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "$line" == @@TALLY\ * ]]; then
      # shellcheck disable=SC2086
      set -- $line
      FILES_WITH_TESTS=$((FILES_WITH_TESTS + 1))
      TESTS_EXAMINED=$((TESTS_EXAMINED + $2))
      VIOLATION_COUNT=$((VIOLATION_COUNT + $3))
    else
      echo "$line"
    fi
  done <<< "$output"
done < <(find "${EXISTING_DIRS[@]}" -type f -name '*.rs' -print0)

if [[ "$FILES_SCANNED" -eq 0 ]]; then
  report_empty "no .rs files found under: ${EXISTING_DIRS[*]}"
fi

MEASUREMENT="${#EXISTING_DIRS[@]} directory/ies (${EXISTING_DIRS[*]}), \
$FILES_SCANNED .rs file(s), $FILES_WITH_TESTS with #[test], \
$TESTS_EXAMINED test function(s) examined"

if [[ "$VIOLATIONS" -ne 0 ]]; then
  echo ""
  echo "test assertion lint FAILED: $VIOLATION_COUNT test function(s) with no assertions; scanned $MEASUREMENT"
  echo "Add assert!, assert_eq!, etc."
  if [[ "$STRICT" -eq 0 ]]; then
    echo "(Run with --strict to also flag tests that rely only on .unwrap())"
  fi
  exit 1
fi

echo "test assertion lint passed: scanned $MEASUREMENT; 0 without assertions"
exit 0
