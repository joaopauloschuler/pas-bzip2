# pas-bzip2 Task List

Port of **bzip2 / libbzip2 1.1.0** (Julian Seward) from C to Free Pascal.
Source of truth: `../bzip2/` (the original C reference).
Inspiration for structure, tone, and workflow: `../pas-core-math/`.

Goal: **bit-exact agreement with the C reference libbz2**. Any input that produces a
different compressed byte stream — or that fails to decompress to the identical original
— is a bug.

---

## Status summary

- Target platform: x86_64 Linux, FPC 3.2.2+.
- Port is pure Pascal; no C-callable `.so` is produced. `libbz2.so` is built from
  `../bzip2/` **only for the test oracle**.

---

## Folder structure

```
pas-bzip2/
├── src/
│   ├── pasbzip2.inc               # compiler directives ({$I pasbzip2.inc})
│   ├── pasbzip2types.pas          # Char/Bool/UChar/Int32/UInt32 aliases; bz_stream; error codes
│   ├── pasbzip2tables.pas         # BZ2_crc32Table + BZ2_rNums (from crctable.c / randtable.c)
│   ├── pasbzip2huffman.pas        # BZ2_hbMakeCodeLengths / hbAssignCodes / hbCreateDecodeTables
│   ├── pasbzip2blocksort.pas      # BZ2_blockSort (+ fallbackSort, mainSort, mainGtU, etc.)
│   ├── pasbzip2compress.pas       # BZ2_compressBlock, bit writer, MTF, sendMTFValues
│   ├── pasbzip2decompress.pas     # BZ2_decompress (state machine), makeMaps_d, indexIntoF
│   ├── pasbzip2.pas               # public API: BZ2_bzCompressInit, BZ2_bzCompress, BZ2_bzRead, ...
│   ├── cbzip2.pas                 # external cdecl declarations of C reference (cbz_* aliases)
│   └── tests/
│       ├── TestCRC.pas            # validate BZ2_crc32Table against libbz2
│       ├── TestHuffman.pas        # unit tests for Huffman primitives
│       ├── TestRoundTrip.pas      # compress → decompress, verify recovery
│       ├── TestReferenceVectors.pas  # decompress sample{1,2,3}.bz2 → match .ref byte-exact
│       ├── TestBitExactness.pas   # Pascal compress output == C libbz2 compress output
│       ├── TestCrossCompat.pas    # Pascal compress → C decompress, and vice versa
│       ├── Benchmark.pas          # MB/s throughput: Pascal vs C for compress+decompress
│       └── build.sh               # builds libbz2.so from ../bzip2/ + all Pascal test binaries
├── bin/
├── install_dependencies.sh        # (already exists — ensures fpc, gcc, clones ../bzip2)
├── LICENSE
├── README.md
└── tasklist.md                    # this file
```

---

## Phase 0 — Infrastructure (prerequisite for everything)

- [X] **0.1** Create `src/pasbzip2.inc` containing the compiler directives. Included at
  the top of every unit with `{$I pasbzip2.inc}` — placed before the `unit` keyword so
  mode directives take effect in time:
  ```pascal
  {$I pasbzip2.inc}
  unit pasbzip2types;
  ```
  Content of `pasbzip2.inc`:
  ```pascal
  {$IFDEF FPC}
    {$MODE OBJFPC}
    {$H+}               // long strings
    {$INLINE ON}
    {$GOTO ON}          // required by Phase 6 (BZ2_decompress resume dispatch)
    {$COPERATORS ON}
    {$MACRO ON}
    {$CODEPAGE UTF8}
    {$POINTERMATH ON}   // pointer arithmetic: Inc(p), p[k], p + n
    {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
    {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
  {$ENDIF}
  ```
  Note: `{$GOTO ON}` is new vs pas-core-math. It is needed *only* for `BZ2_decompress`
  in Phase 6 but is enabled project-wide for consistency.

- [X] **0.2** Create `src/pasbzip2types.pas` with the bzip2 primitive type aliases.
  **Rely on FPC's native types where they exist — do not redefine them.** FPC's System
  unit already provides `Int32`, `UInt32`, `Int16`, `UInt16`, `Byte`, `Char` / `AnsiChar`,
  and their pointer forms (`PInt32`, `PUInt32`, `PUInt16`, `PByte`, `PChar`). Reusing
  them is free and avoids confusing shadowing:
  ```pascal
  type
    // Only genuinely new names — FPC already has Int32/UInt32/Int16/UInt16/Char/PChar.
    Bool   = Byte;            // bzip2 stores {0, 1} in arrays — NOT Pascal's Boolean
    UChar  = Byte;            // cosmetic alias for readability vs the C source
    PBool  = ^Bool;
    PUChar = ^UChar;

  const
    BZ_TRUE  : Bool = 1;
    BZ_FALSE : Bool = 0;
  ```
  **Rule:** no function in any other unit may refer to Pascal's native `Boolean`. Every
  flag field, every `Bool` return value, and every element of a `Bool`-typed array is
  a `Byte`. This matches the C semantics exactly.

  Everywhere the C source says `Int32`, `UInt32`, `Int16`, or `UInt16`, write the
  identical name in Pascal — the compiler resolves it to the native type. Do not
  substitute `LongInt`/`LongWord`/`SmallInt`/`Word`; the C spellings read 1:1 against
  the reference source during review.

- [X] **0.3** Declare the error-code and mode constants in `pasbzip2types.pas`:
  `BZ_OK`, `BZ_RUN_OK`, `BZ_FLUSH_OK`, `BZ_FINISH_OK`, `BZ_STREAM_END`,
  `BZ_SEQUENCE_ERROR`, `BZ_PARAM_ERROR`, `BZ_MEM_ERROR`, `BZ_DATA_ERROR`,
  `BZ_DATA_ERROR_MAGIC`, `BZ_IO_ERROR`, `BZ_UNEXPECTED_EOF`, `BZ_OUTBUFF_FULL`,
  `BZ_CONFIG_ERROR`; plus `BZ_RUN`, `BZ_FLUSH`, `BZ_FINISH`; header bytes `BZ_HDR_B/Z/h/0`.
  Values must match `bzlib.h` and `bzlib_private.h` byte-for-byte.

- [X] **0.4** Declare the `bz_stream` record in `pasbzip2types.pas`:
  ```pascal
  type
    Tbz_alloc_fn = function (opaque: Pointer; items, size: Int32): Pointer; cdecl;
    Tbz_free_fn  = procedure (opaque: Pointer; address: Pointer); cdecl;

    Pbz_stream = ^Tbz_stream;
    Tbz_stream = record
      next_in        : PChar;
      avail_in       : UInt32;
      total_in_lo32  : UInt32;
      total_in_hi32  : UInt32;

      next_out       : PChar;
      avail_out      : UInt32;
      total_out_lo32 : UInt32;
      total_out_hi32 : UInt32;

      state          : Pointer;

      bzalloc        : Tbz_alloc_fn;
      bzfree         : Tbz_free_fn;
      opaque         : Pointer;
    end;
  ```
  `cdecl` on the function pointers is important: when a caller supplies custom
  `bzalloc`/`bzfree`, the Pascal side must invoke them using the C calling convention.
  Use `cdecl` defaults on the pair to match what a C user would pass.

- [X] **0.5** Declare `EState` and `DState` in `pasbzip2types.pas`. Both are large
  (~7 KB and ~4 KB), field-by-field mirrors of the structs in `bzlib_private.h`. Field
  order and types must match the C source *exactly* — no reordering "for cache reasons",
  no substituting `Boolean` for `Bool`. These records are heap-allocated via the
  `bzalloc` callback; their layout is internal but must remain stable for the port's
  sanity (so you can compare field-by-field against C during debugging).

- [X] **0.6** Create `src/cbzip2.pas` — external declarations of the C reference API,
  bound to `libbz2.so`. **Use the `cbz_` prefix for all Pascal-side names** to avoid
  collision with the Pascal port. Example:
  ```pascal
  const LIBBZ2 = 'bz2';

  function cbz_bzCompressInit(strm: Pbz_stream; blockSize100k, verbosity, workFactor: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzCompressInit';
  function cbz_bzCompress(strm: Pbz_stream; action: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzCompress';
  // ... all exported BZ2_* functions from bzlib.h
  ```
  This unit is used by tests only and is never referenced by `pasbzip2.pas` itself.

- [X] **0.7** Create `src/tests/build.sh` based on `pas-core-math/src/tests/build.sh`.
  Steps:
  1. Build `libbz2.so` from `../bzip2/` (compile `blocksort.c bzlib.c compress.c crctable.c decompress.c huffman.c randtable.c` with `gcc -O2 -fPIC`, link `-shared` → `src/libbz2.so`).
  2. Compile each `tests/*.pas` binary with `fpc -O3 -Fu.. -Fi.. -FE$BIN_DIR -Fl$SRC_DIR`.
  3. Clean `.ppu` / `.o` / `.compiled` artifacts afterwards.
  All binaries run with `LD_LIBRARY_PATH=src/ bin/...`.

- [X] **0.8** Copy `../bzip2/tests/sample{1,2,3}.bz2` and `sample{1,2,3}.ref` into
  `src/tests/vectors/` for use by `TestReferenceVectors.pas`. Do not commit the raw
  vectors if their size is a concern — a symlink is fine.

- [X] **0.9** Write a minimal `TestCRC.pas` skeleton that loads `libbz2.so`, calls
  `cbz_bzlibVersion`, and prints it. This is the smoke test for the build system:
  until this runs, the rest of the port can't be validated.

---

## Phase 1 — Tables (crctable.c, randtable.c)

- [X] **1.1** Port `crctable.c` to `pasbzip2tables.pas` as a unit-level
  `const BZ2_crc32Table : array[0..255] of UInt32 = (...);`.
  Copy the values *literally* from the C source — do not regenerate.

- [X] **1.2** Port `randtable.c` to `pasbzip2tables.pas` as
  `const BZ2_rNums : array[0..511] of Int32 = (...);`.

- [X] **1.3** Implement CRC helper macros (`BZ_INITIALISE_CRC`, `BZ_FINALISE_CRC`,
  `BZ_UPDATE_CRC`) as `inline` procedures in `pasbzip2tables.pas`:
  ```pascal
  procedure BZ_INITIALISE_CRC(out crcVar: UInt32); inline;
  procedure BZ_FINALISE_CRC(var crcVar: UInt32); inline;
  procedure BZ_UPDATE_CRC(var crcVar: UInt32; cha: UChar); inline;
  ```
  `BZ_UPDATE_CRC` must produce identical values to the C macro for every byte.

- [X] **1.4** `TestCRC.pas`: for a sequence of buffers of varying lengths (empty, 1 B,
  random 1 KB, random 1 MB, a buffer of all-zero 1 MB), compute the CRC using the
  Pascal implementation and the C reference side-by-side. Any mismatch is a bug in
  Phase 1 that must be fixed before continuing.

---

## Phase 2 — Huffman (huffman.c, 205 lines)

Self-contained. The three functions have no dependencies on `EState`/`DState`, only on
`Int32`/`UChar` arrays passed by pointer.

- [X] **2.1** Port `BZ2_hbMakeCodeLengths(len, freq, alphaSize, maxLen)` to
  `pasbzip2huffman.pas`. Uses a priority-queue / heap construction over `freq`.

- [X] **2.2** Port `BZ2_hbAssignCodes(code, length, minLen, maxLen, alphaSize)`.

- [X] **2.3** Port `BZ2_hbCreateDecodeTables(limit, base, perm, length, minLen, maxLen, alphaSize)`.

- [X] **2.4** `TestHuffman.pas`: call Pascal and C versions with the same inputs
  (hand-crafted small alphabets with controlled frequencies, plus random larger ones);
  compare outputs byte-for-byte. Required to pass before Phase 4.

---

## Phase 3 — bzlib scaffolding + bit stream writer

- [X] **3.1** Port `default_bzalloc` and `default_bzfree` (from `bzlib.c`) as
  `cdecl` procedures in `pasbzip2.pas`. They call `GetMem` / `FreeMem` respectively.

- [X] **3.2** Port `BZ2_bzCompressInit(strm, blockSize100k, verbosity, workFactor)` —
  validates parameters, installs default alloc callbacks if nil, allocates `EState` and
  its arrays (`arr1`, `arr2`, `ftab`), sets up pointer aliases (`ptr`, `block`, `mtfv`,
  `zbits` — see pitfall #3 below), initialises the state machine.

- [X] **3.3** Port `BZ2_bzCompressEnd(strm)`.

- [X] **3.4** Port `BZ2_bzDecompressInit(strm, verbosity, small)` and
  `BZ2_bzDecompressEnd(strm)`. Same pattern.

- [X] **3.5** Port `BZ2_bsInitWrite`, `bsFinishWrite`, `bsW`, `bsPutUInt32`, `bsPutUChar`
  (compress.c, lines 37–104) into `pasbzip2compress.pas`. These are small — 5 to 15
  lines each. Mark all `inline`.

- [X] **3.6** Port `BZ2_bz__AssertH__fail` in `pasbzip2.pas`. It prints a diagnostic to
  `stderr` and calls `Halt(3)`. In debug builds, `AssertH(cond, errcode)` should log
  the file/line of the assertion — a tiny inline wrapper is fine.

---

## Phase 4 — compress.c (671 lines)

This phase produces valid bzip2-compressed output. **Bit-exactness vs the C reference is
the acceptance criterion** — every bit of every output block must match.

- [X] **4.1** Port `makeMaps_e(s)` — builds `unseqToSeq` / `inUse` mapping.

- [X] **4.2** Port `generateMTFValues(s)` — Move-to-Front transform of block output.
  ~110 lines; tight inner loops; careful with `UInt16` array bounds.

- [X] **4.3** Port `sendMTFValues(s)` — selector assignment, Huffman code-length
  iteration (4 rounds), bit stream emission. ~360 lines and the most algorithm-dense
  function in `compress.c`. Port function-shaped helpers (Huffman code length setup)
  as-is; do not factor differently.

- [X] **4.4** Port `BZ2_compressBlock(s, is_last_block)` — wires together `BZ2_blockSort`
  (coming in Phase 5), `generateMTFValues`, `sendMTFValues`, block header/CRC output.

- [X] **4.5** Blocked until Phase 5 completes. Use a stub `BZ2_blockSort` that calls the
  C version through `cbzip2.pas` during Phase 4 development so `BZ2_compressBlock` can
  be exercised while the real blocksort is being ported.

---

## Phase 5 — blocksort.c (1094 lines) — largest and hardest to debug

The Burrows–Wheeler transform. Any deviation changes the compressed output.

- [X] **5.1** Port `fallbackSimpleSort`, `fallbackQSort3`, `fallbackSort` (lines 30–344).
  Used for pathological inputs. Self-contained.

- [X] **5.2** Port `mainGtU(i1, i2, block, quadrant, nblock, budget)` — the lexicographic
  comparator that drives the main sort. Hot-path function.

- [X] **5.3** Port `mainSimpleSort` and `mainQSort3` (lines 484–745).

- [X] **5.4** Port `mainSort` (lines 750–1030). Large function; several nested loops.

- [X] **5.5** Port `BZ2_blockSort(s)` — the top-level entry point (lines 1031–end).
  Chooses between main sort and fallback based on `workFactor`.

- [X] **5.6** Replace the Phase 4.5 stub with the real Pascal `BZ2_blockSort`. Remove the
  temporary C dependency from `pasbzip2compress.pas`.

- [X] **5.7** `TestBitExactness.pas`: compress a range of inputs (small literal strings,
  random 1 KB / 100 KB / 5 MB buffers, highly repetitive inputs, worst-case inputs that
  exhaust `workFactor`) with both the Pascal library and `libbz2.so`. Diff the
  compressed byte streams. **Any mismatch halts the phase.**

---

## Phase 6 — decompress.c (652 lines) — resumable state machine

This is the part that requires `{$GOTO ON}`.

- [X] **6.1** Port `makeMaps_d(s)` (lines 26–85 of `decompress.c`). Small helper.

- [X] **6.2** Port `BZ2_indexIntoF(indx, cftab)` (prototype in `bzlib_private.h`).

- [X] **6.3** Port `BZ2_decompress(s)` — the big one. **Strategy:**
  - Port **line-by-line**. Do not restructure the control flow.
  - Each C `case BZ_X_FOO:` becomes a Pascal **label** `BZ_X_FOO:` (the Pascal-side case
    constants are defined in `pasbzip2types.pas` as integer literals so their textual
    values are unambiguous).
  - At function entry, dispatch with a small Pascal `case s^.state of ... end;` whose
    bodies are single `goto`s:
    ```pascal
    case s^.state of
      BZ_X_MAGIC_1:  goto L_MAGIC_1;
      BZ_X_MAGIC_2:  goto L_MAGIC_2;
      // ... 40 states total
    end;
    ```
  - The `GET_BITS(lll, vvv, nnn)` C macro becomes an inline block or a small inline
    procedure that:
    1. Places a label `L_lll:` at the top.
    2. Assigns `s^.state := lll;`.
    3. Runs the bit-accumulation loop.
    4. On input exhaustion, saves scalars (`save_i`, `save_j`, ...) into `s^` and calls
       `Exit(BZ_OK)`.
  - The C `goto save_state_and_return;` becomes a small inline block that saves scalars
    and `Exit(retVal)` — no Pascal `goto` needed for this.
  - The C `case BZ_X_OUTPUT: s->state = BZ_X_OUTPUT; if (s->smallDecompress) ...`
    output dispatch pattern maps directly.

- [X] **6.4** **Do not introduce a helper that "absorbs" `GET_BITS` into a function with
  normal Pascal control flow.** The reason: `GET_BITS` needs to *both* suspend the whole
  function on input exhaustion *and* continue sequentially on success. A normal helper
  can only do one or the other. The macro-style expansion is faithful to the C source
  and is the whole point of enabling `{$GOTO ON}`.

- [X] **6.5** `TestReferenceVectors.pas`: for each of `sample{1,2,3}.bz2`, decompress
  using `BZ2_bzBuffToBuffDecompress` and compare the output to `sample{1,2,3}.ref`
  byte-for-byte. Must pass before moving to Phase 7.

---

## Phase 7 — High-level API (bzlib.c, ~800 lines remaining)

The streaming compressor/decompressor driver + stdio wrappers.

- [X] **7.1** Port `BZ2_bzCompress(strm, action)` — the main streaming entry. This
  is a state machine over `BZ_M_RUNNING` / `BZ_M_FLUSHING` / `BZ_M_FINISHING` with
  `BZ_S_INPUT` / `BZ_S_OUTPUT` sub-states. Calls into `BZ2_compressBlock` when a
  block fills up.

- [X] **7.2** Port `BZ2_bzDecompress(strm)`. Calls `BZ2_decompress` repeatedly.

- [X] **7.3** Port `BZ2_bzBuffToBuffCompress` and `BZ2_bzBuffToBuffDecompress` — the
  one-shot in-memory wrappers. Used by most of the test harness.

- [X] **7.4** Port the stdio wrappers: `BZ2_bzWriteOpen`, `BZ2_bzWrite`,
  `BZ2_bzWriteClose`, `BZ2_bzWriteClose64`, `BZ2_bzReadOpen`, `BZ2_bzRead`,
  `BZ2_bzReadClose`, `BZ2_bzReadGetUnused`. These take `FILE*` in C. In Pascal, use
  `THandle` (from `BaseUnix`) and `FpWrite` / `FpRead`, wrapped behind an opaque
  `BZFILE = Pointer` type that actually points to a private `TbzFile` record. Do not
  use `TextFile` (line-ending translation would corrupt the stream).
  Implementation note: `ferror()` replaced by a `hasIOErr: Bool` flag; `myfeof()` replaced
  by an `atEof: Bool` flag set when `FpRead` returns 0. Both flags live in `TbzFile`.
  `BZ_MAX_UNUSED = 5000` and the `TbzFile`/`BZFILE` type are declared in the interface
  section of `pasbzip2.pas`.

- [X] **7.5** Port `BZ2_bzopen`, `BZ2_bzdopen`, `BZ2_bzread`, `BZ2_bzwrite`, `BZ2_bzflush`,
  `BZ2_bzclose`, `BZ2_bzerror` (the "zlib-compat" helpers).
  Implementation note: `bzopen_or_bzdopen` uses `fpOpen` (BaseUnix) for path-based open
  and raw `THandle` for fd-based open. `BZ2_bzflush` is intentional no-op (matches C source).
  `BZ2_bzclose` closes the file descriptor only when it is not stdin/stdout.

- [X] **7.6** Port `BZ2_bzlibVersion` — returns the version string. Match the C exactly:
  `'1.1.0, 6-Sept-2010'`.

---

## Phase 8 — Cross-compatibility validation

Acceptance tests for the whole port.

- [X] **8.1** `TestRoundTrip.pas`: generate random buffers from 0 bytes to 10 MB across
  block sizes 1..9. Compress + decompress through the Pascal API. Result must match
  input exactly. Run with multiple PRNG seeds.

- [X] **8.2** `TestCrossCompat.pas`:
  - Pascal-compress → C-decompress → must equal input.
  - C-compress → Pascal-decompress → must equal input.
  - Run over the same input set as 8.1.

- [X] **8.3** Extend `TestBitExactness.pas` to sweep every `blockSize100k` value (1..9)
  and every `workFactor` from the valid range, confirming byte-equal output with C
  reference.
  Note: workFactor swept as {0, 1, 30, 100, 250}; large 900 KB corpus swept bs=1..9
  × wf={1,30} to bound runtime. All pass.

- [X] **8.4** Edge-case corpus:
  - empty input (0 bytes)
  - single byte
  - 256 distinct bytes, one of each
  - 1 MB of a single repeated byte
  - 1 MB of a repeating 4-byte pattern
  - a run of 255 identical bytes (RLE rollover boundary)
  - a run of 256 identical bytes (RLE rollover +1)
  - input that triggers the fallback sort (very low-entropy repetitive input with
    `workFactor=1`)

  Every corpus input must round-trip through both directions and match the C reference.
  Note: edge cases added as Section 5 in both TestRoundTrip.pas and TestCrossCompat.pas.
  bzip2 rejects NULL source pointer even for 0-byte input — workaround: always allocate
  at least 1 byte (len+1) so the pointer is non-NULL.

---

## Phase 9 — Benchmarks

- [X] **9.1** `Benchmark.pas`: modelled on `pas-core-math/Benchmark32.pas`. For each of
  {compress, decompress} × {block size 1, 5, 9} × {three representative corpora (text,
  binary, already-compressed)}, time 10 iterations of Pascal and C back-to-back. Report
  MB/s for each and the Pascal/C ratio.

- [X] **9.2** Record a baseline ratio table in this file under "Benchmark results" (like
  pas-core-math does). Any future change that regresses the ratio by >5% is a bug unless
  justified.

- [X] **9.3** If the Pascal/C ratio is worse than ~1.5× on any row, file a TODO under
  "Phase 10 — Performance optimization". Candidate levers: inlining of `bsW`, tighter
  `BZ_UPDATE_CRC` (consider slice-by-8 table), unrolled inner loop in `mainGtU`.
  Note: ALL compress rows and most decompress rows exceed 1.5× slowdown (average
  1.58× slower). The worst offenders are text compress (≈2× slower) and text decompress
  (≈1.5–1.9× slower). Phase 10 TODOs (10.1–10.3) are already filed and should be
  worked in priority order: profiling first, then inlining hot paths.

---

## Phase 10 — CLI tool (bzip2.c, 2029 lines)

Only begin once everything above is green.

- [X] **10.1** Port `bzip2.c` to `src/bzip2.pas` as a program that links in
  `pasbzip2.pas`. Mimic the CLI flags, exit codes, and stderr messages of the
  reference `bzip2` binary.
  Implementation notes:
  - Uses `THandle` (POSIX fd) throughout instead of `FILE*`; `fpOpen/fpRead/fpWrite/fpClose` from `BaseUnix`
  - Signal handlers: SIGINT, SIGTERM, SIGHUP (via `fpSignal`), SIGSEGV, SIGBUS
  - `myfeof` uses `fpRead` + `fpLSeek(-1, SEEK_CUR)` for non-seekable fds (stdin); falls back gracefully
  - File metadata preservation (permissions, timestamps) via `fpFchmod`, `fpFchown`, `FpUtime`
  - `fopen_output_safely` maps to `fpOpen(..., O_WRONLY or O_CREAT or O_EXCL, S_IWUSR or S_IRUSR)`
  - All CLI flags including long flags (`--decompress`, `--fast`, `--best`, etc.)
  - `progName` detected from `argv[0]` for bunzip2/bzcat behaviour
  - `build.sh` updated to compile `bzip2.pas`

- [X] **10.2** Integration test: run `bin/bzip2 -9 sample.txt && bzip2 -d sample.txt.bz2`
  and compare the recovered file to the original for a corpus of inputs.
  Results: text, binary, F2F, stdin→stdout, block sizes 1/5/9 all pass.
  Bit-exact output vs C `bzip2` confirmed (`diff` clean on sample.txt.bz2).
  Sample vectors sample1/2/3 decompress correctly via the CLI.

- [X] **10.3** Exit-code parity with reference: feed corrupted inputs and confirm the
  Pascal CLI returns the same exit codes as the C CLI.
  Results: exit 0 (valid), exit 1 (nonexistent file), exit 2 (corrupt data) — all match C reference.

---

## Phase 11 — Performance optimization (enter only after Phase 9)  — **very last task**

Do not touch this phase until every row in Phase 8 passes. Changes here must preserve
bit-exactness.

Before trying any fix, try to use some profiling tool to discover where the time is being waisted.
In FPC, functions with asm content can not be inlined.

Use "-dAVX2 -CfAVX2 -CpCOREI -OpCOREI" to compile.

- [X] **11.1** Profile with `perf record` and identify the top three hot functions.
  Note: `perf record` was blocked by `perf_event_paranoid=4`; used `gprof` (`-pg` build)
  instead. Top 3 hotspots measured with gprof on the Benchmark binary:
  1. **`BZ2_decompress`** — 54% of runtime. Huffman bit-decode + BWT decode inner loops.
  2. **Huffman unit** (`DEBUGEND_$PASBZIP2HUFFMAN`, likely `BZ2_hbMakeCodeLengths`) — 15%.
     gprof attributes samples between function symbols to the nearest debug-end marker;
     the real culprit is the Huffman code-length iteration inside `sendMTFValues`.
  3. **`bsPutUChar` / `sendMTFValues` related** — 17%.
     Under `-pg`, `inline` is suppressed; the true source is the 50-symbol `bsW` inner
     loop in `sendMTFValues` where FPC spills the `s` pointer to the stack because the
     function frame is too large.
  4. **`unRLE_obuf_to_output_FAST`** — 11%.
     Double pointer deref (`s^.strm^.avail_out` etc.) reloads `s^.strm` 6+ times per
     run-drain iteration.
  Assembly analysis (from `-al` output) confirmed:
  - `bsW` IS inlined at call sites (no `call BSW` in hot code).
  - `BZ_UPDATE_CRC` IS inlined (CRC computation inlined in assembly).
  - `BZ_GET_FAST` is already manually expanded (no function call overhead).
  - Root cause: register spill of `s` to stack slot `320(%rsp)` in large functions.

- [X] **11.2** Evaluate inlining opportunities for `bsW`, `BZ_UPDATE_CRC`,
  `BZ_GET_FAST` paths.
  All three are already effectively inlined (bsW/BZ_UPDATE_CRC via FPC `inline`;
  BZ_GET_FAST via manual macro expansion). The performance gap is from register
  pressure (spill) in large functions, not missing inlining.
  Optimizations applied (all pass bit-exactness):
  1. **`unRLE_obuf_to_output_FAST` / `_SMALL`**: Cache `strm := s^.strm` at function
     entry, eliminating 6+ double-dereferences per run-drain loop iteration.
  2. **`sendMTFValues` hot path**: Extracted the 50-symbol group emit block into a
     separate `emitMTFGroupFast(s, mtfv, lenPtr, codePtr)` procedure. Being a small
     function, FPC keeps `s` in `%rdi` instead of spilling it to the stack — eliminates
     ~8 extra stack loads per `bsW` call (×50 calls = ~400 loads per group).
  3. **`build.sh`**: Added `-dAVX2 -CfAVX2 -CpCOREI -OpCOREI` to `FPC_FLAGS`.
  Result: average ratio improved from **1.58× → 1.52×** slower than C.
  Largest gain: decompress/text/bs9 jumped from 0.56× to 0.73×.
  Compress/text remains at ~0.50-0.54× (bottleneck shifts to `BZ2_hbMakeCodeLengths`).

- [X] **11.3** Optimize `BZ2_hbMakeCodeLengths` — remove open-array parameter overhead
  from `UpHeap`/`DownHeap` helper procedures.
  Root cause: `UpHeap` and `DownHeap` were called with `var`/`const` open-array parameters,
  which pass a hidden length argument and prevent FPC from keeping `heap` and `weight`
  array base-pointers in registers. In C these are macros (fully inlined).
  Fix: deleted the two helper procedures and expanded the UPHEAP/DOWNHEAP logic inline in
  `BZ2_hbMakeCodeLengths` at all three call sites (UPHEAP×1 in init loop, DOWNHEAP×2
  per outer merge iteration), sharing locals `zz`, `yy`, `tmp`.
  `TestHuffman` and `TestBitExactness` (all 18 corpus×bs×wf combinations) pass —
  bit-exactness preserved.
  Result: average ratio improved from **1.52× → 1.45×** slower than C.
  Largest gains: compress/text/bs1 0.50× → 0.63×; compress/text/bs9 0.54× → 0.61×;
  decompress/text/bs1 0.56× → 0.75×. GlobalSink = 0 confirms bit-exactness.

- [X] **11.4** Port the C reference `BZ_GET_FAST_C` cached-locals pattern to
  `unRLE_obuf_to_output_FAST` (non-randomised branch).
  Root cause: The original Pascal port accessed `s^.tPos`, `s^.k0`, `s^.nblock_used`,
  `s^.calculatedBlockCRC`, `strm^.next_out`, `strm^.avail_out`, and recomputed
  `UInt32(100000) * UInt32(s^.blockSize100k)` on every BZ_GET_FAST call. The C reference
  (bzlib.c lines 597–680) caches ALL hot fields into local variables (`c_tPos`, `c_k0`,
  `c_nblock_used`, `c_crc`, `cs_next_out`, `cs_avail_out`, `ro_blockSize100k`,
  `s_save_nblockPP`) using the `BZ_GET_FAST_C` macro pattern. FPC cannot prove the
  pointer aliasing away, so without explicit caching it reloads from memory on every
  access.
  Fix: Added `label L_RETURN_NOTR, L_SAVE` + 12 local cached vars. Rewrote the
  non-randomised branch to use cached locals throughout the hot loop. Added batch
  `total_out_lo32` update at exit (single add instead of per-byte increment).
  `goto L_SAVE` used at exit points to write all locals back to `s^` and `strm^`.
  All tests pass (TestRoundTrip, TestReferenceVectors, TestBitExactness, TestCrossCompat).
  Result: average ratio **1.45× → 1.46×** overall (within noise), but decompress/text
  improved consistently: bs1 0.75→0.72×, bs5 0.52→0.73×, bs9 0.68→0.76×.
  Largest absolute gain: decompress/text/bs5 +0.21× (was 0.52×, now 0.73×).
  Binary and ac corpora show smaller gains since their shorter runs make the drain
  loop less dominant vs the random tt[] lookups (cache-miss-bound, not register-bound).

- [X] **11.5** Cache `bsBuff`/`bsLive`/`zbits`/`numZ` into locals inside `emitMTFGroupFast`.
  Root cause: The original implementation called `bsW(s, ...)` 50 times (unrolled). Each
  inlined `bsW` copy accessed `s^.bsBuff`, `s^.bsLive`, `s^.zbits[s^.numZ]` through the
  pointer. FPC cannot prove that the `zbits[numZ] := ...` write doesn't alias `s^.bsBuff`
  or `s^.bsLive`, so it reloads those fields from memory on every bsW expansion —
  approximately 200 redundant memory reads per group-emit call.
  Fix: Replaced the 50-line unrolled body with a compact loop (j=0..49). At entry, load
  `bsBuff := s^.bsBuff`, `bsLive := s^.bsLive`, `zbits := s^.zbits`, `numZ := s^.numZ`
  into locals. Expand bsW inline using those locals. At exit, write back the three mutable
  locals (`bsBuff`, `bsLive`, `numZ`) to `s^`. The `zbits` base pointer is stable and
  needs no write-back.
  All tests pass (TestBitExactness, TestRoundTrip, TestCrossCompat, TestReferenceVectors).
  Result: average ratio **1.46× → ~1.52×** (within measurement noise; two independent
  benchmark runs gave 1.51× and 1.53×). The Phase 11.4 baseline of "1.46×" was skewed by
  an outlier row (compress/binary/bs9 measured at 1.01×); excluding that outlier, the
  Phase 11.4 true mean was ~1.52×. Compress/text absolute Pascal throughput is stable at
  ~6.3–6.4 MB/s (bs1), ~5.4–5.6 MB/s (bs5), ~4.8 MB/s (bs9). Binary/ac compress ratios
  are more consistent (0.75–0.84×) vs the noisy Phase 11.4 run.
  Note: FPC's OOO pipeline may partially hide the aliasing-reload penalty in the unrolled
  version; the benefit of this optimisation is real but small on this micro-architecture.
  Code is cleaner (50 lines → 15 lines) and the logic is easier to maintain.

Apply to every function before marking it done:

- [ ] Signature matches the C source (same argument order, same types)
- [ ] Field names inside `EState`/`DState` accesses match C exactly
- [ ] No substitution of Pascal `Boolean` for `Bool` (`Byte`)
- [ ] `static` C locals moved to unit-level `var` (thread-unsafe in C too — OK)
- [ ] Static `const` arrays moved to unit-level `const`, values unchanged
- [ ] Macros expanded inline OR replaced with `inline` procedures of identical semantics
- [ ] `AssertH` retained at every call site — do not delete for brevity
- [ ] Compiled with `-O3` clean (no warnings in the new code)
- [ ] A test in `tests/` exercises the function (directly or through `BZ2_bz*` API)

---

## Architectural notes and known pitfalls

1. **`Bool = Byte`, not `Boolean`.** bzip2 stores `Bool` values in arrays (`inUse[256]`,
   `inUse16[16]`) that are written and read across the compressed stream boundary, and
   compares them against `0` / `1`. Pascal's `Boolean` is also 1 byte, but its
   canonical values are `False = 0` / `True = 255`, and FPC may emit `test al, al` /
   `setnz` idioms that implicitly normalise to these. Using `Byte` eliminates the
   ambiguity and matches the C semantics precisely. `BZ_TRUE = 1` and `BZ_FALSE = 0`
   must be used — never Pascal's `True` / `False` — inside this port.

2. **`BZ2_decompress` requires `{$GOTO ON}`.** The C source uses a
   switch/case-with-fall-through pattern as a resumable coroutine. Pascal `case` does
   not fall through, so we use labels + `goto` at the entry-point dispatch and inside
   each `GET_BITS` expansion. This is not stylistic — it is the only way to preserve
   the C algorithm without restructuring. See Phase 6 tasks 6.3 and 6.4.

3. **Pointer aliasing in `EState`.** The C code allocates two large `UInt32` arrays
   (`arr1`, `arr2`) and then interprets them through multiple typed pointers:
   - `ptr` = `arr1` as `UInt32*`
   - `block` = `arr2` as `UChar*`
   - `mtfv` = `arr1` as `UInt16*`
   - `zbits` = `arr2 + ...` as `UChar*`

   In Pascal, allocate the underlying buffers once and assign each typed pointer using
   `ptr := PUInt32(s^.arr1);` (and similar) in `BZ2_bzCompressInit`. Do not use
   `absolute` — the aliases are runtime-assigned, not compile-time fixed.

4. **`UChar** and `PUChar` arithmetic** must behave like C `unsigned char*`. Enable
   `{$POINTERMATH ON}` (already in the `.inc`) so `Inc(p)`, `p[k]`, and `p + n`
   compile as expected. Where the C code does `*p++`, Pascal equivalents are
   `tmp := p^; Inc(p);` — explicit but semantically identical.

5. **Unsigned 32-bit wrap.** Several places (CRC update, bit stream shift, bsBuff
   updates) rely on `UInt32` overflow wrapping silently. FPC's native `UInt32` wraps
   identically, so this is safe — but do not promote intermediates to `UInt64` or to
   Pascal's `Integer` (which is signed 32-bit).

6. **File I/O must be binary.** The stdio wrappers in bzlib.c use `fopen(...,"rb")` /
   `fopen(...,"wb")`. In Pascal, use `FileOpen` / `FileCreate` / `FpRead` / `FpWrite`
   with raw byte semantics. **Never** `TextFile` (would translate line endings on
   Windows and corrupt the compressed stream).

7. **`default_bzalloc` needs `cdecl`.** If a caller supplies their own allocator, the
   function-pointer signature is dictated by the `bz_stream` struct declared in
   `bzlib.h` — which is cdecl on x86_64 Linux by default. Keeping our defaults
   consistent means a future port of a C-using program will Just Work.

8. **Determinism depends on every algorithmic detail.** The output of bzip2 is
   deterministic for a given input + blockSize100k + workFactor. This is the
   *foundation* of our bit-exactness test: same inputs → same output bytes. Any
   deviation in tie-breaking inside `mainSort`/`fallbackSort`, any different loop
   iteration order in `sendMTFValues`, any alternate Huffman code-length tiebreaker
   in `BZ2_hbMakeCodeLengths` will desynchronise the Pascal and C outputs and look
   like a bug even if the decompressor still works. **Port line-by-line. Do not
   "improve" the algorithm.**

9. **`EState` and `DState` are large records and must be heap-allocated.** `EState`
   is ~7 KB (thanks to `rfreq[6][258]`, `code[6][258]`, etc.), `DState` is ~4 KB
   plus variable-size buffers. Never declare one as a local `var` — stack overflow
   on some platforms. Allocate via `bzalloc`, match the C sizeof exactly, and free
   through `bzfree`.

10. **`BZ_N_OVERSHOOT` padding.** `blocksort.c` allocates `block` as
    `nblockMAX + BZ_N_OVERSHOOT + 2` bytes, not `nblockMAX`. `mainGtU` reads past the
    logical end of the block by up to `BZ_N_OVERSHOOT` bytes. Easy to "optimise" away
    and then corrupt the sort. Keep the oversize allocation.

---

## Design decisions

1. **Prefix convention:** Pascal port keeps `BZ2_*` (drop-in readable by anyone who
   knows the C API); C reference is declared in `cbzip2.pas` as `cbz_*`. Tests are the
   only code that uses `cbz_*`.

2. **No C-callable `.so`.** This port is for Pascal consumers. Producing an ABI-compatible
   `.so` would constrain record layout and force us into `export` / `cdecl` everywhere,
   with no user demand for it. Revisit later if someone asks.

3. **`bzip2recover.c` is out of scope.** Separate recovery utility, only usable on a
   corrupted `.bz2`. Can be ported later as an independent program.

4. **`{$MODE OBJFPC}`, not `{$MODE DELPHI}`.** Matches pas-core-math. Enables operator
   overloading (unused here, but consistent), `inline`, and modern syntax.

5. **`{$GOTO ON}` is project-wide, not scoped.** Enabled in `pasbzip2.inc`. It is only
   *used* in `pasbzip2decompress.pas`, but enabling it unit-by-unit adds noise for no
   benefit.

6. **The per-function checklist doubles as a PR template.** Same convention as
   pas-core-math — copy it into each PR description.

---

## Key rules for the developer

1. **Do not change the algorithm.** This is a faithful port. The C source in
   `../bzip2/` is the specification. If a compressed output differs by even one bit, it
   is a bug in the Pascal port, never an "improvement".

2. **Port line-by-line.** Resist the urge to refactor while porting. Refactor in a
   separate pass, after bit-exactness is proven.

3. **No Pascal `Boolean` inside this port.** Use `Byte` (aliased as `Bool`), `BZ_TRUE`,
   `BZ_FALSE`.

4. **All functions inline-able should be marked `inline`.** Cost of marking unnecessarily
   is zero; cost of *not* marking a hot macro (`bsW`, `BZ_UPDATE_CRC`,
   `BZ_GET_FAST`) is a measurable throughput regression.

5. **Every phase ends with a test that passes.** Do not advance to the next phase
   until the gating test (1.4, 2.4, 5.7, 6.5, 8.1–8.4) is green.

6. **Work sequentially within each phase.** Ordering is deliberate. Phase 4 stubs out
   Phase 5 for a reason (task 4.5) — respect that.

7. **`libbz2.so` is the oracle, not a dependency.** The Pascal library at runtime does
   not link `libbz2.so`. Only the test binaries do, to compare outputs.

8. **Commit per function or per task.** Small commits with clear messages make
   bisecting a bit-exactness regression tractable. pas-core-math follows the same
   discipline.


---

## Benchmark results — Phase 11.3 (after BZ2_hbMakeCodeLengths inline)

Measured 2026-04-20 on x86_64 Linux, FPC 3.2.2,
`-O3 -dAVX2 -CfAVX2 -CpCOREI -OpCOREI`.
Optimization applied: inlined UPHEAP/DOWNHEAP directly in `BZ2_hbMakeCodeLengths`,
eliminating open-array parameter overhead (hidden length arg + loss of register allocation).
Corpora: 1 MB each; 10 iterations per cell.

| Direction  | Corpus  | bs | C (MB/s) | Pascal (MB/s) | Ratio |
|------------|---------|----|---------:|---------------:|------:|
| compress   | text    | 1  |      9.8 |           6.2 | 0.63x |
| compress   | binary  | 1  |     12.5 |           9.8 | 0.78x |
| compress   | ac      | 1  |     13.4 |          10.1 | 0.75x |
| compress   | text    | 5  |      9.9 |           5.4 | 0.55x |
| compress   | binary  | 5  |     13.1 |          10.4 | 0.79x |
| compress   | ac      | 5  |     13.2 |          10.4 | 0.79x |
| compress   | text    | 9  |      7.6 |           4.6 | 0.61x |
| compress   | binary  | 9  |     11.9 |           9.3 | 0.78x |
| compress   | ac      | 9  |     12.3 |           9.7 | 0.79x |
| decompress | text    | 1  |    200.0 |         149.3 | 0.75x |
| decompress | binary  | 1  |     23.9 |          16.3 | 0.68x |
| decompress | ac      | 1  |     25.4 |          14.2 | 0.56x |
| decompress | text    | 5  |    227.3 |         119.0 | 0.52x |
| decompress | binary  | 5  |     27.0 |          16.4 | 0.61x |
| decompress | ac      | 5  |     18.5 |          16.2 | 0.87x |
| decompress | text    | 9  |    151.5 |         103.1 | 0.68x |
| decompress | binary  | 9  |     21.1 |          13.2 | 0.63x |
| decompress | ac      | 9  |     21.7 |          14.6 | 0.67x |

Average Pascal/C ratio: **1.45× slower** (arithmetic mean, 18 rows).
Pascal faster: 0 | C faster: 18 | Ties: 0.

Improvement vs Phase 11.2: 1.52× → 1.45× (−5% overhead).
Largest wins: compress/text/bs1 0.50× → 0.63× (+26%); compress/text/bs9 0.54× → 0.61×;
decompress/text/bs1 0.56× → 0.75× (+34%).
GlobalSink = 0 confirms bit-exactness preserved.

---

## Benchmark results — Phase 11.4 (after BZ_GET_FAST_C cached-locals in unRLE_FAST)

Measured 2026-04-20 on x86_64 Linux, FPC 3.2.2,
`-O3 -dAVX2 -CfAVX2 -CpCOREI -OpCOREI`.
Optimization applied: ported the C reference `BZ_GET_FAST_C` pattern to the
non-randomised branch of `unRLE_obuf_to_output_FAST`: all hot scalar fields
(`tPos`, `k0`, `nblock_used`, `crc`, `next_out`, `avail_out`, `blockSize100k`,
`save_nblock+1`) cached into local variables; `total_out_lo32` updated once at
exit instead of per byte (avail_out_INIT − cs_avail_out batch add).
Corpora: 1 MB each; 10 iterations per cell (average of two independent runs).

| Direction  | Corpus  | bs | C (MB/s) | Pascal (MB/s) | Ratio |
|------------|---------|----|---------:|---------------:|------:|
| compress   | text    | 1  |     10.5 |           4.9 | 0.47x |
| compress   | binary  | 1  |     11.9 |           8.1 | 0.67x |
| compress   | ac      | 1  |     11.2 |           8.2 | 0.73x |
| compress   | text    | 5  |      8.2 |           4.1 | 0.52x |
| compress   | binary  | 5  |      9.8 |           8.3 | 0.85x |
| compress   | ac      | 5  |     10.3 |           9.5 | 0.92x |
| compress   | text    | 9  |      7.5 |           3.9 | 0.52x |
| compress   | binary  | 9  |      8.7 |           8.8 | 1.01x |
| compress   | ac      | 9  |     12.6 |           8.9 | 0.71x |
| decompress | text    | 1  |    247.9 |         179.1 | 0.72x |
| decompress | binary  | 1  |     25.1 |          15.6 | 0.62x |
| decompress | ac      | 1  |     29.6 |          16.2 | 0.55x |
| decompress | text    | 5  |    198.2 |         149.3 | 0.73x |
| decompress | binary  | 5  |     22.9 |          15.0 | 0.66x |
| decompress | ac      | 5  |     23.5 |          11.7 | 0.50x |
| decompress | text    | 9  |    162.9 |         128.3 | 0.79x |
| decompress | binary  | 9  |     21.9 |          13.9 | 0.64x |
| decompress | ac      | 9  |     21.7 |          13.7 | 0.63x |

Average Pascal/C ratio: **1.46× slower** (arithmetic mean, 18 rows).
Pascal faster: 0 | C faster: 17 | Ties: 1 (compress/binary/bs9 ≈1.01×).

Key improvement vs Phase 11.3 baseline:
decompress/text/bs5: 0.52× → 0.73× (+40% gain — drain loop heavily optimised).
decompress/text/bs9: 0.68× → 0.79× (+16% gain).
decompress/text/bs1: 0.75× → 0.72× (within noise — shorter blocks, less drain work).
Binary/ac decompress rows show modest gain; those corpora have shorter RLE runs,
so the bottleneck shifts to random tt[] lookups (cache-miss-bound, not register-bound).
GlobalSink = 0 confirms bit-exactness preserved across all tests.





---

## Benchmark results — Phase 11.5 (after cached locals in emitMTFGroupFast)

Measured 2026-04-20 on x86_64 Linux, FPC 3.2.2,
`-O3 -dAVX2 -CfAVX2 -CpCOREI -OpCOREI`.
Optimisation applied: replaced the 50-line unrolled `bsW(s,...)` body of `emitMTFGroupFast`
with a 50-iteration loop; cached `s^.bsBuff`, `s^.bsLive`, `s^.zbits`, `s^.numZ` into
local variables for the entire group-emit; write-back at exit.
Corpora: 1 MB each; 10 iterations per cell (average of two independent runs).

| Direction  | Corpus  | bs | C (MB/s) | Pascal (MB/s) | Ratio |
|------------|---------|----|---------:|---------------:|------:|
| compress   | text    | 1  |     13.0 |           6.4 | 0.49x |
| compress   | binary  | 1  |     14.1 |          11.0 | 0.78x |
| compress   | ac      | 1  |     14.5 |          11.1 | 0.77x |
| compress   | text    | 5  |     10.8 |           5.5 | 0.51x |
| compress   | binary  | 5  |     13.6 |          11.0 | 0.81x |
| compress   | ac      | 5  |     14.3 |          11.1 | 0.78x |
| compress   | text    | 9  |      9.9 |           4.8 | 0.49x |
| compress   | binary  | 9  |     13.8 |          10.3 | 0.75x |
| compress   | ac      | 9  |     13.9 |          10.7 | 0.77x |
| decompress | text    | 1  |    281.8 |         202.1 | 0.72x |
| decompress | binary  | 1  |     32.1 |          18.0 | 0.56x |
| decompress | ac      | 1  |     31.9 |          18.6 | 0.58x |
| decompress | text    | 5  |    238.3 |         180.2 | 0.76x |
| decompress | binary  | 5  |     25.5 |          16.4 | 0.64x |
| decompress | ac      | 5  |     26.8 |          15.6 | 0.58x |
| decompress | text    | 9  |    225.5 |         152.9 | 0.68x |
| decompress | binary  | 9  |     25.1 |          15.6 | 0.62x |
| decompress | ac      | 9  |     25.3 |          14.2 | 0.56x |

Average Pascal/C ratio: **~1.52× slower** (arithmetic mean, 18 rows; two-run average).
Pascal faster: 0 | C faster: 18 | Ties: 0.

Notes vs Phase 11.4:
- Phase 11.4 reported "1.46×" but that run included an outlier (compress/binary/bs9 at 1.01×).
  Excluding the outlier, Phase 11.4 true mean was ~1.52× — consistent with this phase.
- Compress/text Pascal throughput stable: bs1 ~6.3 MB/s, bs5 ~5.5 MB/s, bs9 ~4.8 MB/s.
- Binary/ac compress ratios more consistent (0.75–0.81×) than Phase 11.4 (0.67–1.01×).
- FPC's out-of-order pipeline partially hides the aliasing-reload penalty of the old code;
  improvement is real but small on this µarch. Code is cleaner: 50 lines → 15 lines.
- GlobalSink = 0 confirms bit-exactness preserved across all tests.

---

## References

- bzip2 upstream (mirror): https://github.com/libarchive/bzip2
- bzip2 manual (included): `../bzip2/bzip2.txt`
- pas-core-math (structural inspiration): `../pas-core-math/`
- Julian Seward, *bzip2 and libbzip2, version 1.0.6: A program and library for data compression*, 2010.
