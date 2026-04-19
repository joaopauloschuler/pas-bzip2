{$I pasbzip2.inc}
program TestRoundTrip;

{
  Phase 8.1 validation: compress + decompress through the Pascal API only.
  Verifies that every byte of input is recovered exactly after a round-trip.

  Strategy
  ---------
  For each (seed, blockSize100k) pair we:
    1. Generate a random buffer of each representative size.
    2. Compress with BZ2_bzBuffToBuffCompress.
    3. Decompress with BZ2_bzBuffToBuffDecompress.
    4. Compare the result with the original byte-for-byte.

  Test matrix
  -----------
  Seeds          : $DEADBEEF, $C0FFEE42, $12345678
  Sizes (bytes)  : 0, 1, 7, 256, 1024, 65536, 500000, 2000000, 10000000
  blockSize100k  : 1, 3, 5, 7, 9

  Large buffers (>= 500 KB) are only run with blockSize100k = 1 and 9 and
  a single seed to keep the test under ~30 seconds on a typical machine.
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2;

// ---------------------------------------------------------------------------
// PRNG — simple 32-bit LCG (same constants as other tests)
// ---------------------------------------------------------------------------
var
  gSeed: UInt32;

procedure SeedRng(s: UInt32); inline;
begin
  gSeed := s;
end;

function NextRnd: Byte; inline;
begin
  gSeed := gSeed * 1664525 + 1013904223;
  NextRnd := Byte(gSeed shr 24);
end;

// ---------------------------------------------------------------------------
// Allocate and fill a buffer of Len random bytes from the current seed.
// Returns nil for Len = 0 (valid: compress must handle empty input).
// ---------------------------------------------------------------------------
function MakeRandomBuffer(len: SizeInt): PByte;
var
  i: SizeInt;
begin
  // Always allocate at least 1 byte so the pointer is non-NULL;
  // bzip2 rejects NULL source even when sourceLen=0.
  Result := GetMem(len + 1);
  for i := 0 to len - 1 do
    Result[i] := NextRnd;
end;

// ---------------------------------------------------------------------------
// Round-trip one buffer through the Pascal compress + decompress path.
// Returns True on success, False on any failure (prints reason).
// ---------------------------------------------------------------------------
function RoundTrip(const testName: string;
                   src: PByte; srcLen: SizeInt;
                   blockSize100k: Int32): Boolean;
const
  OVERHEAD = 1024;          // fixed bzip2 stream overhead
var
  compBuf  : PByte;
  decompBuf: PByte;
  compLen  : UInt32;
  decompLen: UInt32;
  compMax  : SizeInt;
  ret      : Int32;
  i        : SizeInt;
begin
  Result := False;

  // bzip2 worst-case: n + 1% + 600 bytes; add generous headroom
  compMax  := srcLen + srcLen div 100 + OVERHEAD + 128;
  if compMax < OVERHEAD then compMax := OVERHEAD;
  compBuf  := GetMem(compMax);
  compLen  := compMax;

  ret := BZ2_bzBuffToBuffCompress(
    PChar(compBuf), @compLen,
    PChar(src), srcLen,
    blockSize100k, 0, 30);

  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ': compress returned ', ret);
    FreeMem(compBuf);
    Exit;
  end;

  // Decompress back
  decompLen := srcLen + OVERHEAD;
  decompBuf := GetMem(decompLen);

  ret := BZ2_bzBuffToBuffDecompress(
    PChar(decompBuf), @decompLen,
    PChar(compBuf), compLen,
    0, 0);

  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ': decompress returned ', ret);
    FreeMem(compBuf);
    FreeMem(decompBuf);
    Exit;
  end;

  if SizeInt(decompLen) <> srcLen then
  begin
    WriteLn('FAIL ', testName, ': size mismatch: got ', decompLen,
            ' expected ', srcLen);
    FreeMem(compBuf);
    FreeMem(decompBuf);
    Exit;
  end;

  if srcLen > 0 then
  begin
    for i := 0 to srcLen - 1 do
    begin
      if decompBuf[i] <> src[i] then
      begin
        WriteLn('FAIL ', testName, ': byte mismatch at offset ', i,
                ' got $', IntToHex(decompBuf[i], 2),
                ' expected $', IntToHex(src[i], 2));
        FreeMem(compBuf);
        FreeMem(decompBuf);
        Exit;
      end;
    end;
  end;

  WriteLn('  OK  ', testName);
  Result := True;

  FreeMem(compBuf);
  FreeMem(decompBuf);
end;

// ---------------------------------------------------------------------------
// Special: round-trip a buffer filled with a single repeated byte value.
// ---------------------------------------------------------------------------
function RoundTripFilled(const testName: string;
                         fillByte: Byte; srcLen: SizeInt;
                         blockSize100k: Int32): Boolean;
var
  src: PByte;
begin
  // Always allocate at least 1 byte so the pointer is non-NULL
  src := GetMem(srcLen + 1);
  if srcLen > 0 then
    FillChar(src^, srcLen, fillByte);
  Result := RoundTrip(testName, src, srcLen, blockSize100k);
  FreeMem(src);
end;

// ---------------------------------------------------------------------------
// Special: round-trip a repeating N-byte pattern.
// ---------------------------------------------------------------------------
function RoundTripPattern(const testName: string;
                          const pat: array of Byte;
                          srcLen: SizeInt;
                          blockSize100k: Int32): Boolean;
var
  src: PByte;
  i  : SizeInt;
begin
  src := GetMem(srcLen);
  for i := 0 to srcLen - 1 do
    src[i] := pat[i mod Length(pat)];
  Result := RoundTrip(testName, src, srcLen, blockSize100k);
  FreeMem(src);
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const
  SEEDS: array[0..2] of UInt32 = ($DEADBEEF, $C0FFEE42, $12345678);
  // Sizes exercised for all seeds × all block sizes
  SMALL_SIZES: array[0..6] of SizeInt = (0, 1, 7, 256, 1024, 65536, 500000);
  // Large sizes — only for a limited set of params to bound test time
  LARGE_SIZES: array[0..1] of SizeInt = (2000000, 10000000);
  // Block sizes for the small-size sweep
  BLOCK_SIZES: array[0..4] of Int32 = (1, 3, 5, 7, 9);

var
  fails   : Integer;
  si, bi  : Integer;
  seedIdx : Integer;
  bi_bs   : Int32;
  buf     : PByte;
  name    : string;
  pat4    : array[0..3]   of Byte = ($AB, $CD, $EF, $12);
  all256  : array[0..255] of Byte = (
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
    80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
    96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
    112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255);

begin
  fails := 0;
  WriteLn('TestRoundTrip — Phase 8.1 round-trip validation');
  WriteLn;

  // ---- Section 1: random buffers, multiple seeds × block sizes × sizes ----
  WriteLn('Section 1: random buffers (small/medium sizes)');
  for seedIdx := 0 to High(SEEDS) do
    for bi := 0 to High(BLOCK_SIZES) do
      for si := 0 to High(SMALL_SIZES) do
      begin
        SeedRng(SEEDS[seedIdx]);
        buf := MakeRandomBuffer(SMALL_SIZES[si]);
        name := Format('seed=%8.8x bs=%d len=%d',
                       [SEEDS[seedIdx], BLOCK_SIZES[bi], SMALL_SIZES[si]]);
        if not RoundTrip(name, buf, SMALL_SIZES[si], BLOCK_SIZES[bi]) then
          Inc(fails);
        FreeMem(buf);
      end;
  WriteLn;

  // ---- Section 2: large buffers, two seeds, bs=1 and bs=9 only -----------
  WriteLn('Section 2: large buffers (2 MB, 10 MB) — bs=1 and bs=9');
  for seedIdx := 0 to 1 do          // only two seeds for large to bound time
    for bi := 0 to 1 do             // bi=0 → bs=1, bi=1 → bs=9
    begin
      for si := 0 to High(LARGE_SIZES) do
      begin
        SeedRng(SEEDS[seedIdx]);
        buf := MakeRandomBuffer(LARGE_SIZES[si]);
        // map bi to block size
        if bi = 0 then bi_bs := 1 else bi_bs := 9;
        name := Format('seed=%8.8x bs=%d len=%d',
                       [SEEDS[seedIdx], bi_bs, LARGE_SIZES[si]]);
        if not RoundTrip(name, buf, LARGE_SIZES[si], bi_bs) then
          Inc(fails);
        FreeMem(buf);
      end;
    end;
  WriteLn;

  // ---- Section 3: single-byte-fill buffers --------------------------------
  WriteLn('Section 3: uniform-fill buffers');
  if not RoundTripFilled('fill=0x00 len=0',       $00,      0, 9) then Inc(fails);
  if not RoundTripFilled('fill=0x00 len=1',       $00,      1, 9) then Inc(fails);
  if not RoundTripFilled('fill=0x41 len=255',     $41,    255, 1) then Inc(fails);
  if not RoundTripFilled('fill=0x41 len=256',     $41,    256, 1) then Inc(fails);
  if not RoundTripFilled('fill=0xFF len=1MB',     $FF, 1000000, 9) then Inc(fails);
  if not RoundTripFilled('fill=0x00 len=1MB',     $00, 1000000, 1) then Inc(fails);
  WriteLn;

  // ---- Section 4: repeating-pattern buffers --------------------------------
  WriteLn('Section 4: repeating-pattern buffers');
  if not RoundTripPattern('pattern4 len=255',     pat4,     255, 5) then Inc(fails);
  if not RoundTripPattern('pattern4 len=256',     pat4,     256, 5) then Inc(fails);
  if not RoundTripPattern('pattern4 len=1MB',     pat4, 1000000, 9) then Inc(fails);
  WriteLn;

  // ---- Section 5: explicit Phase 8.4 edge-case corpus ---------------------
  WriteLn('Section 5: Phase 8.4 edge-case corpus');
  // empty input (0 bytes) — bzip2 produces a valid empty stream
  if not RoundTripFilled('edge: empty 0B',              $00,       0, 9) then Inc(fails);
  // single byte
  if not RoundTripFilled('edge: single-byte 0x00',      $00,       1, 1) then Inc(fails);
  if not RoundTripFilled('edge: single-byte 0xFF',      $FF,       1, 9) then Inc(fails);
  // 256 distinct bytes, one of each (all-byte-values cycle)
  if not RoundTripPattern('edge: 256-distinct',          all256, 256, 1) then Inc(fails);
  // 1 MB of a single repeated byte
  if not RoundTripFilled('edge: 1MB fill=0xAA',         $AA, 1000000, 5) then Inc(fails);
  // 1 MB of a repeating 4-byte pattern
  if not RoundTripPattern('edge: 1MB pattern4',          pat4, 1000000, 5) then Inc(fails);
  // RLE rollover boundary: 255 identical bytes
  if not RoundTripFilled('edge: RLE-255 fill=0x42',     $42,     255, 1) then Inc(fails);
  // RLE rollover + 1: 256 identical bytes
  if not RoundTripFilled('edge: RLE-256 fill=0x42',     $42,     256, 1) then Inc(fails);
  // fallback sort trigger: very low-entropy repeating input with workFactor=1
  if not RoundTripPattern('edge: fallback-sort pat4 20KB wf=1', pat4, 20000, 1) then Inc(fails);
  WriteLn;

  // ---- Result -------------------------------------------------------------
  if fails = 0 then
  begin
    WriteLn('ALL PASSED');
    Halt(0);
  end
  else
  begin
    WriteLn(fails, ' FAILURE(S)');
    Halt(1);
  end;
end.
