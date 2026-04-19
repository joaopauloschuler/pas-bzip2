# pas-bzip2

A faithful port of [bzip2 / libbzip2 1.1.0](https://sourceware.org/bzip2/) (Julian Seward) from C to Free Pascal.

## Overview

bzip2 is a high-quality, block-sorting file compressor based on the Burrows–Wheeler transform (BWT), run-length encoding, and Huffman coding. This project ports the complete libbzip2 library to Free Pascal, targeting **bit-exact agreement with the C reference implementation** for both compression and decompression.

**Key properties:**
- Bit-exact compressed output matching the C libbzip2 reference
- Pure Pascal — no C code is compiled into the library itself
- Full public API: streaming, buffer-to-buffer, and stdio wrappers
- Exhaustively validated against the C reference across a wide range of inputs and block sizes
- x86_64 Linux target with FPC optimisation flags for tight inner loops

## API

All symbols mirror the `bzlib.h` interface exactly.

### Stream life-cycle

```pascal
function BZ2_bzCompressInit(strm: Pbz_stream;
    blockSize100k, verbosity, workFactor: Int32): Int32;
function BZ2_bzCompress(strm: Pbz_stream; action: Int32): Int32;
function BZ2_bzCompressEnd(strm: Pbz_stream): Int32;

function BZ2_bzDecompressInit(strm: Pbz_stream;
    verbosity, small: Int32): Int32;
function BZ2_bzDecompress(strm: Pbz_stream): Int32;
function BZ2_bzDecompressEnd(strm: Pbz_stream): Int32;
```

### Buffer-to-buffer convenience wrappers

```pascal
function BZ2_bzBuffToBuffCompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    blockSize100k, verbosity, workFactor: Int32): Int32;

function BZ2_bzBuffToBuffDecompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    small, verbosity: Int32): Int32;
```

### stdio wrappers

```pascal
function  BZ2_bzWriteOpen(bzerror: PInt32; f: THandle;
              blockSize100k, verbosity, workFactor: Int32): BZFILE;
procedure BZ2_bzWrite(bzerror: PInt32; b: BZFILE; buf: Pointer; len: Int32);
procedure BZ2_bzWriteClose(bzerror: PInt32; b: BZFILE; abandon: Int32;
              nbytes_in, nbytes_out: PUInt32);

function  BZ2_bzReadOpen(bzerror: PInt32; f: THandle;
              verbosity, small: Int32;
              unused: Pointer; nUnused: Int32): BZFILE;
function  BZ2_bzRead(bzerror: PInt32; b: BZFILE;
              buf: Pointer; len: Int32): Int32;
procedure BZ2_bzReadClose(bzerror: PInt32; b: BZFILE);
```

### zlib-compatible helpers

```pascal
function  BZ2_bzopen(path: PChar; mode: PChar): BZFILE;
function  BZ2_bzdopen(fd: Int32; mode: PChar): BZFILE;
function  BZ2_bzread(b: BZFILE; buf: Pointer; len: Int32): Int32;
function  BZ2_bzwrite(b: BZFILE; buf: Pointer; len: Int32): Int32;
function  BZ2_bzflush(b: BZFILE): Int32;
procedure BZ2_bzclose(b: BZFILE);
function  BZ2_bzerror(b: BZFILE; errnum: PInt32): PChar;
```

### Version query

```pascal
function BZ2_bzlibVersion: PChar;   // returns '1.1.0'
```

## Repository Layout

<pre>
/
├── <a href="src/">src/</a>
│   ├── <a href="src/pasbzip2.inc">pasbzip2.inc</a>               # Shared FPC compiler directives
│   ├── <a href="src/pasbzip2types.pas">pasbzip2types.pas</a>          # Primitive type aliases, bz_stream, error/action codes
│   ├── <a href="src/pasbzip2tables.pas">pasbzip2tables.pas</a>         # BZ2_crc32Table, BZ2_rNums (crctable.c / randtable.c)
│   ├── <a href="src/pasbzip2huffman.pas">pasbzip2huffman.pas</a>        # Huffman code-length assignment and decode-table builder
│   ├── <a href="src/pasbzip2blocksort.pas">pasbzip2blocksort.pas</a>      # BZ2_blockSort: fallbackSort + mainSort (blocksort.c)
│   ├── <a href="src/pasbzip2compress.pas">pasbzip2compress.pas</a>       # BZ2_compressBlock, bit-stream writer, MTF, sendMTFValues
│   ├── <a href="src/pasbzip2decompress.pas">pasbzip2decompress.pas</a>     # BZ2_decompress state machine, makeMaps_d, indexIntoF
│   ├── <a href="src/pasbzip2.pas">pasbzip2.pas</a>               # Public API: stream lifecycle, buffer wrappers, stdio
│   ├── <a href="src/cbzip2.pas">cbzip2.pas</a>                 # External cdecl declarations of C reference (cbz_* aliases)
│   └── <a href="src/tests/">tests/</a>
│       ├── <a href="src/tests/TestCRC.pas">TestCRC.pas</a>            # Validate BZ2_crc32Table against C libbz2
│       ├── <a href="src/tests/TestHuffman.pas">TestHuffman.pas</a>        # Unit tests for Huffman primitives
│       ├── <a href="src/tests/TestRoundTrip.pas">TestRoundTrip.pas</a>      # Compress → decompress, verify recovery
│       ├── <a href="src/tests/TestReferenceVectors.pas">TestReferenceVectors.pas</a>  # Decompress sample{1,2,3}.bz2 → byte-exact match
│       ├── <a href="src/tests/TestBitExactness.pas">TestBitExactness.pas</a>   # Pascal compress output == C libbz2 compress output
│       ├── <a href="src/tests/TestCrossCompat.pas">TestCrossCompat.pas</a>    # Pascal→C decompress and C→Pascal decompress
│       ├── <a href="src/tests/Benchmark.pas">Benchmark.pas</a>          # MB/s throughput: Pascal vs C for compress + decompress
│       └── <a href="src/tests/build.sh">build.sh</a>               # Build libbz2.so from ../bzip2/ + all Pascal test binaries
├── <a href="bin/">bin/</a>
├── <a href="install_dependencies.sh">install_dependencies.sh</a>        # Install FPC, GCC, and other dependencies
└── <a href="README.md">README.md</a>
</pre>

## Requirements

- **Free Pascal Compiler** (FPC) 3.2.2 or later
- **GCC** (to compile the C reference libbz2.so for testing/benchmarking only)
- **bzip2 C source** cloned alongside this repository at `../bzip2/`
- **x86_64 Linux**

## Building

```bash
cd src/tests
bash build.sh
```

This builds `libbz2.so` from `../bzip2/` (once, if not present) and compiles all Pascal test and benchmark binaries into `bin/`.

To enable AVX2 and tune for a modern Intel/AMD core:

```bash
bash build.sh -dAVX2 -CfAVX2 -CpCOREI -OpCOREI
```

## Running the Tests

```bash
SRC=$PWD/src
LD_LIBRARY_PATH=$SRC bin/TestCRC
LD_LIBRARY_PATH=$SRC bin/TestHuffman
LD_LIBRARY_PATH=$SRC bin/TestRoundTrip
LD_LIBRARY_PATH=$SRC bin/TestReferenceVectors
LD_LIBRARY_PATH=$SRC bin/TestBitExactness
LD_LIBRARY_PATH=$SRC bin/TestCrossCompat
```

| Test | What it checks |
|------|----------------|
| `TestCRC` | All 256 entries of `BZ2_crc32Table` match the C reference; `BZ_UPDATE_CRC` spot-checks pass |
| `TestHuffman` | Code-length assignment, code assignment, and decode-table construction for degenerate, small, and large symbol sets |
| `TestRoundTrip` | Compress then decompress recovers the original for random, uniform, pattern, and edge-case buffers across all block sizes (bs=1..9) |
| `TestReferenceVectors` | The three bzip2 sample files (`sample1.bz2`, `sample2.bz2`, `sample3.bz2`) decompress to their exact reference output |
| `TestBitExactness` | Pascal-compressed output is byte-identical to C libbz2 output for all block sizes, work factors, and corpus types |
| `TestCrossCompat` | Pascal compress → C decompress, and C compress → Pascal decompress, both yield the original data |

## Running the Benchmark

```bash
LD_LIBRARY_PATH=$PWD/src bin/Benchmark
```

Measures MB/s throughput for both compression and decompression across three corpora:

| Corpus | Description |
|--------|-------------|
| `text` | 1 MB cycling printable ASCII (high compressibility) |
| `binary` | 1 MB pseudo-random bytes (low compressibility) |
| `ac` | ~1 MB already-compressed data (resists further compression) |

Each combination of corpus × block size (1, 5, 9) × direction (compress, decompress) is run for 10 iterations. The benchmark reports MB/s and the Pascal/C speed ratio for every row, with a summary at the end.

## Correctness Guarantee

The test suite performs a multi-level validation:

1. **Table correctness** — CRC and randomisation tables match the C reference bit-for-bit.
2. **Algorithm correctness** — Huffman, block-sort, compress, and decompress units are individually unit-tested.
3. **Round-trip correctness** — Every compressed buffer decompresses to the original across all seeds, lengths, and block sizes.
4. **Bit-exact output** — The Pascal compressor produces the identical byte stream to C libbz2 for all tested inputs.
5. **Cross-compatibility** — Streams produced by each implementation are accepted by the other.

## References

- bzip2 home page and source: https://sourceware.org/bzip2/
- Julian Seward — *bzip2 and libbzip2, version 1.1.0* (original C implementation)
- Burrows, Wheeler — *A Block-sorting Lossless Data Compression Algorithm*, DEC SRC Technical Report 124, 1994
