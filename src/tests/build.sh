#!/usr/bin/env bash
# build.sh — build libbz2.so from ../bzip2/ and compile all Pascal test binaries.
# Run from any directory; paths are derived from the script location.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/.."          # pas-bzip2/src/
ROOT_DIR="$SRC_DIR/.."            # pas-bzip2/
BIN_DIR="$ROOT_DIR/bin"
BZIP2_C_DIR="$ROOT_DIR/../bzip2"

mkdir -p "$BIN_DIR"

# ---- Step 1: Build libbz2.so if not present ----
SOFILE="$SRC_DIR/libbz2.so"
if [ ! -f "$SOFILE" ]; then
  echo "Building libbz2.so from $BZIP2_C_DIR ..."

  C_SOURCES=(
    blocksort.c
    bzlib.c
    compress.c
    crctable.c
    decompress.c
    huffman.c
    randtable.c
  )

  OBJS=()
  for src in "${C_SOURCES[@]}"; do
    name="$(basename "$src" .c)"
    out="/tmp/bz2_${name}.o"
    echo -n "  Compiling $src ... "
    gcc -O2 -fPIC -c "$BZIP2_C_DIR/$src" -o "$out"
    echo "OK"
    OBJS+=("$out")
  done

  echo "  Linking ${#OBJS[@]} objects -> $SOFILE"
  gcc -shared -O2 -o "$SOFILE" "${OBJS[@]}"
  echo "  libbz2.so built OK"
else
  echo "libbz2.so already present, skipping C build."
fi

FPC_FLAGS="-O3 -dAVX2 -CfAVX2 -CpCOREI -OpCOREI -Fu$SRC_DIR -Fi$SRC_DIR -FE$BIN_DIR -Fl$SRC_DIR $@"

compile_test() {
  local name="$1"
  local src="$SCRIPT_DIR/$name.pas"
  if [ ! -f "$src" ]; then
    echo "  SKIP $name.pas (not yet implemented)"
    return
  fi
  echo
  echo "Compiling $name.pas ..."
  fpc $FPC_FLAGS "$src"
  echo "$name compiled -> $BIN_DIR/$name"
}

compile_test TestCRC
compile_test TestHuffman
compile_test TestRoundTrip
compile_test TestReferenceVectors
compile_test TestBitExactness
compile_test TestCrossCompat
compile_test Benchmark

echo
echo "Compiling bzip2.pas ..."
fpc $FPC_FLAGS $SRC_DIR/bzip2.pas
echo "bzip2 compiled -> $BIN_DIR/bzip2"

# ---- Clean compiled Pascal artifacts ----
find "$SRC_DIR"    -maxdepth 2 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete
find "$BIN_DIR"    -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete
find "$SCRIPT_DIR" -maxdepth 1 \( -name '*.ppu' -o -name '*.o' -o -name '*.compiled' -o -name '*.s' \) -delete

echo
echo "Build complete."
echo
echo "Run tests with:"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestCRC"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestHuffman"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestRoundTrip"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestReferenceVectors"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestBitExactness"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/TestCrossCompat"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/Benchmark"
echo
echo "Run bzip2 with:"
echo "  LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/bzip2 --help"
echo "  echo 'hello' | LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/bzip2 -c | LD_LIBRARY_PATH=$SRC_DIR $BIN_DIR/bzip2 -d"
