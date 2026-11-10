#!/usr/bin/env bash
#
# mayhem/build.sh — build GnuCash's library stack twice (sanitized for the fuzz harnesses, normal for the
# unit tests) plus the three libFuzzer harnesses and their -standalone reproducers.
# Runs in the commit image as `mayhem` in /mayhem, offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ=.build-fuzz
TEST=.build-test

# The compiler comes from the exported CC/CXX (found by name); a -DCMAKE_C_COMPILER=clang would differ from
# the cached /usr/bin/clang on a re-run and make cmake wipe the cache.
# Options shared by both trees: library only (no GTK front end, no aqbanking/ofx/python), SQL backend on.
COMMON_OPTS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DWITH_GNUCASH=OFF -DWITH_AQBANKING=OFF -DWITH_OFX=OFF
             -DWITH_PYTHON=OFF -DWITH_SQL=ON)

# 1) The test suite with the project's NORMAL flags (clean, independent tree). `all` yields the guile
#    modules/.go files the scheme tests load, `testbuild` the test executables; mayhem/test.sh only runs ctest.
cmake -S . -B "$TEST" "${COMMON_OPTS[@]}" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST" -j"$MAYHEM_JOBS" --target all testbuild

# 2) The sanitized, SanCov-instrumented libraries the harnesses link against. Only the shared libs are built here: generating
#    the guile .go files would load them, which cannot work under ASan.
cmake -S . -B "$FUZZ" "${COMMON_OPTS[@]}" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$SANITIZER_FLAGS"
cmake --build "$FUZZ" -j"$MAYHEM_JOBS" \
      --target gnc-engine gnc-core-utils gnc-app-utils gnc-backend-xml-utils gnc-expressions

# 3) Harnesses: fuzzer binary and -standalone reproducer. The XML backend is normally a dlopen'd module,
#    so fuzz_xml_book compiles gnc-backend-xml.cpp in and registers it with gnc_module_init_backend_xml().
INC=(-I"$SRC/libgnucash/backend/xml" -I"$SRC/libgnucash/engine" -I"$SRC/libgnucash/app-utils"
     -I"$SRC/libgnucash/app-utils/calculation" -I"$SRC/$FUZZ/common" -I"$SRC/common"
     -I"$SRC/borrowed/libc" -I"$SRC/$FUZZ/libgnucash/core-utils" -I"$SRC/libgnucash/core-utils"
     -I"$SRC/borrowed/ctre" $(pkg-config --cflags glib-2.0 libxml-2.0))
DEFS=(-DHAVE_CONFIG_H -D_GNU_SOURCE -DU_SHOW_CPLUSPLUS_API=0 '-DG_LOG_DOMAIN="fuzz"'
      -DGLIB_VERSION_MAX_ALLOWED=GLIB_VERSION_2_68 -DGLIB_VERSION_MIN_REQUIRED=GLIB_VERSION_2_68)
LIBS=(-L"$SRC/$FUZZ/lib" -L"$SRC/$FUZZ/lib/gnucash"
      -Wl,-rpath,"$SRC/$FUZZ/lib" -Wl,-rpath,"$SRC/$FUZZ/lib/gnucash"
      -lgnc-app-utils -lgnc-backend-xml-utils -lgnc-engine -lgnc-core-utils -lgnc-expressions
      $(pkg-config --libs glib-2.0 libxml-2.0) -lm)

OBJ="$SRC/$FUZZ/mayhem-obj"
mkdir -p "$OBJ"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"

for h in fuzz_xml_book fuzz_text_parsers fuzz_timezone; do
  extra=()
  [ "$h" = fuzz_xml_book ] && extra=("$SRC/libgnucash/backend/xml/gnc-backend-xml.cpp")
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS "${DEFS[@]}" "${INC[@]}" $LIB_FUZZING_ENGINE \
       "$SRC/mayhem/harnesses/$h.cpp" "${extra[@]}" "${LIBS[@]}" "$OBJ/lsan_off.o" -o "/mayhem/$h"
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS "${DEFS[@]}" "${INC[@]}" \
       "$SRC/mayhem/harnesses/$h.cpp" "${extra[@]}" "$OBJ/standalone_main.o" "${LIBS[@]}" \
       "$OBJ/lsan_off.o" -o "/mayhem/$h-standalone"
done
