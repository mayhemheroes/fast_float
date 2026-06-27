// fast_float behavioral checker — parses known float strings with fast_float::from_chars,
// prints the parsed values to stdout, and exits non-zero on any mismatch.
//
// The print-then-check design is deliberate: test.sh greps the printed values, so a
// sabotaged binary that exits(0) without printing causes the grep to fail (CTRF failed>0).
// This makes the oracle resistant to reward-hacking via no-op patches.
#include "fast_float/fast_float.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <system_error>

static int FAILURES = 0;

// Parse a double from the string and print it; return the parsed value.
static double check_double(const char *input, double expected, const char *label) {
  double result = 0.0;
  auto answer = fast_float::from_chars(input, input + strlen(input), result);
  // Print BEFORE checking so the output exists even if we exit early.
  printf("PARSED_DOUBLE %s = %.17g\n", label, result);
  fflush(stdout);
  if (answer.ec != std::errc()) {
    printf("FAIL %s: parse error\n", label);
    FAILURES++;
    return result;
  }
  // Use bit-exact comparison (both IEEE 754 doubles, round-to-even).
  if (result != expected && !(std::isnan(result) && std::isnan(expected))) {
    printf("FAIL %s: expected %.17g got %.17g\n", label, expected, result);
    FAILURES++;
  } else {
    printf("OK %s\n", label);
  }
  fflush(stdout);
  return result;
}

// Parse a float from the string and print it.
static float check_float(const char *input, float expected, const char *label) {
  float result = 0.0f;
  auto answer = fast_float::from_chars(input, input + strlen(input), result);
  printf("PARSED_FLOAT %s = %.9g\n", label, (double)result);
  fflush(stdout);
  if (answer.ec != std::errc()) {
    printf("FAIL %s: parse error\n", label);
    FAILURES++;
    return result;
  }
  if (result != expected && !(std::isnan(result) && std::isnan(expected))) {
    printf("FAIL %s: expected %.9g got %.9g\n", label, (double)expected, (double)result);
    FAILURES++;
  } else {
    printf("OK %s\n", label);
  }
  fflush(stdout);
  return result;
}

int main() {
  printf("fast_float checker begin\n");
  fflush(stdout);

  // Double precision cases — canonical values the IEEE round-to-even spec mandates.
  check_double("3.14159265358979",    3.14159265358979,    "pi");
  check_double("1e10",                1e10,                "1e10");
  check_double("-0.5",               -0.5,                 "neg_half");
  check_double("2.2250738585072014e-308", 2.2250738585072014e-308, "dbl_min_normal");
  check_double("1.7976931348623157e+308", 1.7976931348623157e+308, "dbl_max");
  check_double("0.1",                0.1,                  "one_tenth");
  check_double("1e-100",             1e-100,               "tiny");
  check_double("-1.23456789",       -1.23456789,           "neg_frac");

  // Float precision cases.
  check_float("3.14159274",  3.14159274f, "pi_f");
  check_float("-0.5",       -0.5f,        "neg_half_f");
  check_float("1e10",        1e10f,       "1e10_f");

  // Pointer advancement: after parsing "3.1416 xyz", ptr must point at ' '.
  {
    const char *input = "3.1416 xyz";
    double result = 0.0;
    auto ans = fast_float::from_chars(input, input + strlen(input), result);
    printf("PARSED_DOUBLE ptr_adv = %.17g\n", result);
    fflush(stdout);
    if (ans.ec != std::errc() || result != 3.1416 || ans.ptr == nullptr || *ans.ptr != ' ') {
      printf("FAIL ptr_adv: ptr did not stop at space after 3.1416\n");
      FAILURES++;
    } else {
      printf("OK ptr_adv\n");
    }
    fflush(stdout);
  }

  // Out-of-range: 3e-1000 must parse to 0.0 with result_out_of_range.
  {
    const char *input = "3e-1000";
    double result = -1.0;
    auto ans = fast_float::from_chars(input, input + strlen(input), result);
    printf("PARSED_DOUBLE underflow = %.17g\n", result);
    fflush(stdout);
    if (ans.ec != std::errc::result_out_of_range || result != 0.0) {
      printf("FAIL underflow: expected result_out_of_range and 0.0\n");
      FAILURES++;
    } else {
      printf("OK underflow\n");
    }
    fflush(stdout);
  }

  printf("fast_float checker end failures=%d\n", FAILURES);
  fflush(stdout);
  return FAILURES == 0 ? 0 : 1;
}
