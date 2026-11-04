#!/usr/bin/env bash
#
# mayhem/build.sh — build all 12 of Suricata's upstream fuzz targets (sanitized, DWARF 3) and the unit-test binary.
#
# Runs in the commit image as `mayhem` in /mayhem. Two in-tree builds, one after the other (Suricata's Rust
# half cannot build out-of-tree): the project's NORMAL-flags unit-test binary is stashed at build/suricata-ut
# for mayhem/test.sh, then the ASan+UBSan+SanCov fuzz targets are built.
# Every network dependency (apt, rust toolchain, cargo crates, libfuzzpcap) is in the image; this script
# only needs the in-image caches under /opt/toolchains/rust, so it re-runs offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

TARGETS="fuzz_applayerparserparse fuzz_applayerprotodetectgetproto fuzz_confyamlloadstring fuzz_dataset \
fuzz_decodebase64 fuzz_decodepcapfile fuzz_iprep fuzz_mimedecparseline fuzz_predefpcap_aware fuzz_siginit \
fuzz_sigpcap fuzz_sigpcap_aware"

# Rust: SanCov the Rust half too (stable rustc: -C passes/llvm-args), DWARF 3, explicit --target so the
# flags never reach build scripts / proc-macros (which would not link without a fuzzer runtime).
RUST_COV_FLAGS="-Cpasses=sancov-module -Cllvm-args=-sanitizer-coverage-level=4 \
-Cllvm-args=-sanitizer-coverage-trace-compares -Cllvm-args=-sanitizer-coverage-inline-8bit-counters \
-Cllvm-args=-sanitizer-coverage-pc-table -Clink-dead-code -Ccodegen-units=1 -Cdebug-assertions=yes"
RUST_DWARF_FLAGS="-Cdebuginfo=1 -Cforce-frame-pointers=yes -Cdwarf-version=3"
# rustc links Rust bins (suricatasc/suricatactl) itself; give them the SanCov callbacks from libFuzzer.
RUST_LINK_FLAGS="-Clinker=clang -Clink-arg=-fsanitize=fuzzer-no-link"

# Suricata's Rust half cannot be built out-of-tree, so both builds share the source tree, one after the
# other. Everything they generate (configure, Makefiles, objects, rust/target) is gitignored upstream.
if [ -f Makefile ]; then make distclean >/dev/null 2>&1 || true; fi
sh autogen.sh
mkdir -p build

# ---- 1) project test suite: NORMAL flags, stashed at build/suricata-ut for mayhem/test.sh --------------------
unset CARGO_BUILD_TARGET CFLAGS CXXFLAGS LDFLAGS RUSTFLAGS
./configure --disable-shared --enable-unittests --disable-gccmarch-native
make -j"$MAYHEM_JOBS"
install -m 0755 src/suricata build/suricata-ut
make distclean

# ---- 2) fuzz targets: sanitized, SanCov, DWARF 3 -------------------------------------------------------------
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/build/lsan_off.o"
# -fno-sanitize=alignment: Suricata casts unaligned packet bytes (Ethernet header is 14 bytes) to header structs
# throughout the decoders, benign on x86 and reported on every packet; the other UBSan checks stay halting.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fno-sanitize=alignment $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
export CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu
export RUSTFLAGS="$RUST_COV_FLAGS $RUST_DWARF_FLAGS $RUST_LINK_FLAGS"
CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_CFLAGS $SRC/build/lsan_off.o" \
  ./configure --disable-shared --enable-fuzztargets --disable-gccmarch-native --enable-debug-validation
make -j"$MAYHEM_JOBS"

for t in $TARGETS; do
  [ -x "src/$t" ] || { echo "build.sh: src/$t was not built" >&2; exit 1; }
  install -m 0755 "src/$t" "/mayhem/$t"
done

# fuzz_predefpcap_aware loads the rule set from fuzz.rules next to its binary
cat rules/*.rules > /mayhem/fuzz.rules

# ---- 3) standalone reproducers: relink the same objects with the run-once driver ---------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build/standalone_main.o"
(cd src && rm -f $TARGETS)
make -C src -j"$MAYHEM_JOBS" $TARGETS \
  LIB_FUZZING_ENGINE=-fsanitize=fuzzer-no-link \
  'LDADD_FUZZ=$(LDADD_GENERIC) '"$SRC/build/standalone_main.o"
for t in $TARGETS; do
  install -m 0755 "src/$t" "/mayhem/$t-standalone"
done
