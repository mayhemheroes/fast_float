#!/usr/bin/env bash
#
# fast_float/mayhem/test.sh — RUN fast_float's behavioral oracle (built by mayhem/build.sh)
# and emit a CTRF summary. exit 0 iff no test failed.
#
# Oracle design (reward-hack-resistant, §6.3):
#   The dedicated checker (mayhem/checker.cpp, built to $BUILDDIR/checker) parses known float
#   strings with fast_float::from_chars and PRINTS the parsed values to stdout before checking
#   them.  test.sh captures the output and verifies specific expected strings appear in the
#   PARSED_* lines.  A sabotaged binary that exits(0) without printing produces no output →
#   the checks fail → FAILED count goes up → CTRF reports failed>0 → the oracle is detected
#   as behavioral, not reward-hackable.
#
# This script only RUNS the pre-built binaries; it NEVER compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "fast_float-tests" 0 1 0; exit 2
fi

PASSED=0; FAILED=0

# grep_in <string> <pattern> — grep for pattern in string without treating pattern as an option.
# Uses printf '%s' to avoid echo/heredoc surprises; grep -F -- to avoid option-flag confusion.
grep_in() {
  printf '%s\n' "$1" | grep -qF -- "$2"
}

# check_label <output> <type> <label> <expected_substr>
# Verifies that the PARSED_<type> line for <label> contains <expected_substr> AND "OK <label>" appears.
# A sabotaged binary exits(0) without printing → both conditions fail → FAILED increments.
check_label() {
  local output="$1" type="$2" label="$3" val="$4"
  local parsed_line ok_line

  parsed_line="$(printf '%s\n' "$output" | grep -F -- "PARSED_${type} ${label} = " || true)"
  ok_line="$(printf '%s\n' "$output" | grep -xF -- "OK ${label}" || true)"

  if [ -n "$parsed_line" ] && [ -n "$ok_line" ] && grep_in "$parsed_line" "$val"; then
    echo "PASS checker:${label}"; PASSED=$((PASSED+1))
  else
    echo "FAIL checker:${label} (expected '${val}' in '${parsed_line}' with ok='${ok_line}')"
    FAILED=$((FAILED+1))
  fi
}

# ── 1) Behavioral checker: parse known float strings, verify printed output ─────────────────────
CHECKER="$BUILDDIR/checker"
if [ ! -x "$CHECKER" ]; then
  echo "MISSING checker (not built)" >&2
  FAILED=$((FAILED+1))
else
  CHECKER_OUT="$("$CHECKER" 2>&1 || true)"
  printf '%s\n' "$CHECKER_OUT"

  # Expected PARSED_DOUBLE lines: label → required substring in the printed value.
  # Values are printed with %.17g format.
  # pi:     3.14159265358979    → "3.14159265358979"  (%.17g of pi)
  # 1e10:   10000000000         → "10000000000"
  # neg_half: -0.5              → "0.5"   (avoid leading dash being a grep option; presence checked via ok_line)
  # dbl_min_normal: 2.2250738585072014e-308 → "2.2250738585072014e"
  # dbl_max: 1.7976931348623157e+308        → "1.7976931348623157e"
  # one_tenth: 0.10000000000000001          → "0.10000000000000001"
  # tiny:   1e-100              → "1e-100"
  # neg_frac: -1.2345678899999999           → "1.23456788"  (avoid leading dash)
  # ptr_adv: 3.1416 → %.17g = "3.1415999999999999"          → "3.141599999"
  # underflow: 0.0              → "= 0"  (the line ends with " = 0")
  check_label "$CHECKER_OUT" "DOUBLE" "pi"              "3.14159265358979"
  check_label "$CHECKER_OUT" "DOUBLE" "1e10"            "10000000000"
  check_label "$CHECKER_OUT" "DOUBLE" "neg_half"        "0.5"
  check_label "$CHECKER_OUT" "DOUBLE" "dbl_min_normal"  "2.2250738585072014e"
  check_label "$CHECKER_OUT" "DOUBLE" "dbl_max"         "1.7976931348623157e"
  check_label "$CHECKER_OUT" "DOUBLE" "one_tenth"       "0.1000000000000000"
  check_label "$CHECKER_OUT" "DOUBLE" "tiny"            "1e-100"
  check_label "$CHECKER_OUT" "DOUBLE" "neg_frac"        "1.23456788"
  check_label "$CHECKER_OUT" "DOUBLE" "ptr_adv"         "3.14159999"
  check_label "$CHECKER_OUT" "DOUBLE" "underflow"       "= 0"

  # Float precision cases (%.9g format).
  # pi_f: 3.14159274f → "3.14159274"
  # neg_half_f: -0.5f → "0.5"
  # 1e10_f: 1e10f → printed as "1e+10"
  check_label "$CHECKER_OUT" "FLOAT" "pi_f"       "3.14159274"
  check_label "$CHECKER_OUT" "FLOAT" "neg_half_f" "0.5"
  check_label "$CHECKER_OUT" "FLOAT" "1e10_f"     "1e"
fi

# ── 2) Run the upstream test suite programs (exit-code-based secondary checks) ──────────────────
TESTS=(
  example_test
  example_comma_test
  example_integer_times_pow10
  supported_chars_test
  wide_char_test
  p2497
  fast_int
  json_fmt
  fortran
)

for t in "${TESTS[@]}"; do
  bin="$BUILDDIR/$t"
  if [ ! -x "$bin" ]; then
    echo "MISSING $t" >&2; FAILED=$((FAILED+1)); continue
  fi
  if "$bin" > "/tmp/$t.log" 2>&1; then
    echo "PASS $t"; PASSED=$((PASSED+1))
  else
    rc=$?
    echo "FAIL $t (exit $rc)"; sed 's/^/    /' "/tmp/$t.log" | tail -20
    FAILED=$((FAILED+1))
  fi
done

emit_ctrf "fast_float-tests" "$PASSED" "$FAILED" 0
