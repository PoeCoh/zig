#!/bin/sh

# Requires cmake ninja-build

set -x
set -e

ARCH="$(uname -m)"
MODE="${1:-$MODE}"
BUILD="${2:-$BUILD}"
TARGET="$ARCH-linux-musl"
MCPU="baseline"
CACHE_BASENAME="zig+llvm+lld+clang-$TARGET-$BUILD"
PREFIX="$HOME/deps/$CACHE_BASENAME"
ZIG="$PREFIX/bin/zig"

# Make the `zig version` number consistent.
# This will affect the cmake command below.
git fetch --unshallow || true
git fetch --tags

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of zig, and ultimately would just
# fill up space on the hard drive for no reason.
export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/zig-local-cache"

export CC="$ZIG cc -target $TARGET -mcpu=$MCPU"
export CXX="$ZIG c++ -target $TARGET -mcpu=$MCPU"

if ["$ARCH" = "aarch64"]; then
  MAXRSS=24696061952
  export PATH="$HOME/deps/wasmtime-v10.0.2-$ARCH-linux:$PATH"
else
  MAXRSS=21000000000
  export PATH="$HOME/deps/wasmtime-v10.0.2-$ARCH-linux:$HOME/deps/qemu-linux-x86_64-8.2.1/bin:$PATH"

  # Test building from source without LLVM.
  git clean -fd
  rm -rf zig-out
  cc -o bootstrap bootstrap.c
  ./bootstrap
  ./zig2 build -Dno-lib
  ./zig-out/bin/zig test test/behavior.zig
fi

rm -rf build-$MODE
mkdir build-$MODE
cd build-$MODE

# capitolize the first letter of the mode
$CAP_MODE=$(echo $MODE | awk '{print toupper(substr($0, 1, 1))substr($0, 2)}')

cmake .. \
    -DCMAKE_INSTALL_PREFIX="stage3-$MODE" \
    -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_BUILD_TYPE=$CAP_MODE \
    -DZIG_TARGET_TRIPLE="$TARGET" \
    -DZIG_TARGET_MCPU="$MCPU" \
    -DZIG_STATIC=ON \
    -DZIG_NO_LIB=ON \
    -GNinja

# Now cmake will use zig as the C/C++ compiler. We reset the environment variables
# so that installation and testing do not get affected by them.
unset CC
unset CXX

ninja install

# TODO: move this to a build.zig step (check-fmt)
echo "Looking for non-conforming code formatting..."
FLAGS="--exclude ../test/cases/ --exclude ../doc/ --exclude ../build-$MODE"
# is this one actually necessary? i dont think this will exist.
if ["$MODE" = "release" && "$ARCH" != "aarch64"]; then
  FLAGS="$FLAGS --exclude ../build-debug"
fi
stage3-$MODE/bin/zig fmt --check .. $FLAGS

# simultaneously test building self-hosted without LLVM and with 32-bit arm
stage3-$MODE/bin/zig build \
  -Dtarget=arm-linux-musleabihf \
  -Dno-lib

FLAGS="--maxrss $MAXRSS -fwasmtime -Dstatic-llvm -Dtarget=native-native-musl --search-prefix $PREFIX --zig-lib-dir $PWD/../lib"
if ["$ARCH" != "aarch64"]; then
  FLAGS="$FLAGS -fqemu"
fi
stage3-$MODE/bin/zig build test docs $FLAGS

# Look for HTML errors.
# TODO: move this to a build.zig flag (-Denable-tidy)
tidy --drop-empty-elements no -qe "../zig-out/doc/langref.html"

if ["$MODE" = "release" && "$ARCH" != "aarch64"]; then
  # Ensure that stage3 and stage4 are byte-for-byte identical.
  stage3-release/bin/zig build \
    --prefix stage4-release \
    -Denable-llvm \
    -Dno-lib \
    -Doptimize=ReleaseFast \
    -Dstrip \
    -Dtarget=$TARGET \
    -Duse-zig-libcxx \
    -Dversion-string="$(stage3-release/bin/zig version)"

  # diff returns an error code if the files differ.
  echo "If the following command fails, it means nondeterminism has been"
  echo "introduced, making stage3 and stage4 no longer byte-for-byte identical."
  diff stage3-release/bin/zig stage4-release/bin/zig
fi

# Ensure that updating the wasm binary from this commit will result in a viable build.
stage3-$MODE/bin/zig build update-zig1

rm -rf ../build-new
mkdir ../build-new
cd ../build-new

export ZIG_GLOBAL_CACHE_DIR="$PWD/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="$PWD/zig-local-cache"
export CC="$ZIG cc -target $TARGET -mcpu=$MCPU"
export CXX="$ZIG c++ -target $TARGET -mcpu=$MCPU"

cmake .. \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_BUILD_TYPE=$MODE \
  -DZIG_TARGET_TRIPLE="$TARGET" \
  -DZIG_TARGET_MCPU="$MCPU" \
  -DZIG_STATIC=ON \
  -DZIG_NO_LIB=ON \
  -GNinja

unset CC
unset CXX

ninja install

stage3/bin/zig test ../test/behavior.zig
stage3/bin/zig build -p stage4 \
  -Dstatic-llvm \
  -Dtarget=native-native-musl \
  -Dno-lib \
  --search-prefix "$PREFIX" \
  --zig-lib-dir "$PWD/../lib"
stage4/bin/zig test ../test/behavior.zig
