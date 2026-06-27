#!/usr/bin/env bash
#
# fast_float/mayhem/build.sh — build fastfloat/fast_float's OSS-Fuzz harness (fuzz/from_chars.cc)
# as a sanitized libFuzzer target (+ a standalone reproducer), AND a curated, self-contained
# subset of fast_float's own test programs (normal flags) for mayhem/test.sh to RUN.
#
# fast_float is a HEADER-ONLY C++ library (include/fast_float/*.h). The fuzzed surface is the
# string->number parser: the harness feeds attacker-controlled bytes through a FuzzedDataProvider
# and calls fast_float::from_chars three times — parsing a double, a float, and an int from
# fuzz-derived strings (with a fuzz-chosen chars_format). Because the library is header-only, the
# parser code is compiled INTO the harness with $SANITIZER_FLAGS, so the fuzzed code is instrumented.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). FuzzedDataProvider.h ships on clang's default include path in the base.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
INC="-I$SRC/include"
STD="-std=c++17"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# ── 1) libFuzzer target -> /mayhem/from_chars (parser compiled in with sanitizers) ────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
    "$HARNESS_DIR/from_chars.cc" $LIB_FUZZING_ENGINE \
    -o "/mayhem/from_chars"

# ── 2) standalone reproducer -> /mayhem/from_chars-standalone (no libFuzzer runtime, one input) ────
# The driver is C (extern "C" LLVMFuzzerTestOneInput); compile it as a C object first so clang++
# doesn't mangle its symbol reference, then link with the C++ harness.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $STD $INC \
    "$HARNESS_DIR/from_chars.cc" "$BUILD/standalone_main.o" \
    -o "/mayhem/from_chars-standalone"

echo "built from_chars (+ standalone)"

# ── 3) Dedicated behavioral checker -> $TESTDIR/checker (normal flags; prints parsed values to
#       stdout so test.sh can grep for them — a sabotaged binary that exits(0) without printing
#       will cause the grep to fail, making the oracle reward-hack-resistant). ───────────────────
TESTDIR="$SRC/mayhem-tests"
mkdir -p "$TESTDIR"
TEST_CXXFLAGS="$STD $INC -O2"

env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  $CXX $TEST_CXXFLAGS "$SRC/mayhem/checker.cpp" -o "$TESTDIR/checker"
echo "built checker"

# ── 4) Build fast_float's OWN self-contained test programs with NORMAL flags (no sanitizers, no
#       FetchContent/network) so test.sh only RUNS them. These are real known-answer tests: each
#       parses fixed strings, asserts the exact resulting value/pointer, and returns EXIT_FAILURE on
#       mismatch — so a no-op / exit(0) patch (or any parser regression) FAILS them. We deliberately
#       skip basictest (it pulls doctest + supplemental_test_files over the network via CMake
#       FetchContent, which is unavailable in the hermetic build) and the EXHAUSTIVE sweeps (minutes
#       to hours). The curated set below covers floats, integers, wide chars, locale/comma, Fortran
#       and JSON number formats, supported-character edge cases, and integer*pow10. ──────────────────
# (TESTDIR and TEST_CXXFLAGS already set above)

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
  env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
    $CXX $TEST_CXXFLAGS "$SRC/tests/$t.cpp" -lpthread -o "$TESTDIR/$t"
  echo "built test $t"
done

echo "build.sh complete:"
ls -la /mayhem/from_chars /mayhem/from_chars-standalone 2>&1 || true
ls -la "$TESTDIR" 2>&1 || true
