{$I pasbzip2.inc}
program TestCrossCompat;

{
  Phase 8.2 validation: cross-compatibility between the Pascal port and
  the C reference libbz2.

  Two directions are tested for every (seed, blockSize100k, size) triple:

    Direction A — Pascal-compress → C-decompress
      Compress with BZ2_bzBuffToBuffCompress (Pascal).
      Decompress with cbz_bzBuffToBuffDecompress (C libbz2).
      Result must equal the original input.

    Direction B — C-compress → Pascal-decompress
      Compress with cbz_bzBuffToBuffCompress (C libbz2).
      Decompress with BZ2_bzBuffToBuffDecompress (Pascal).
      Result must equal the original input.

  Test matrix
  -----------
  Seeds          : $DEADBEEF, $C0FFEE42, $12345678
  Sizes (bytes)  : 0, 1, 256, 4096, 65536, 500000
  blockSize100k  : 1, 5, 9

  Large buffers (500 KB) are only tested with one seed to keep runtime
  reasonable.
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2,
  cbzip2;

// ---------------------------------------------------------------------------
// PRNG — simple 32-bit LCG
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
// Compare two byte buffers; print first mismatch and return False if unequal.
// ---------------------------------------------------------------------------
function BytesEqual(const testName: string;
                    got: PByte; gotLen: SizeInt;
                    exp: PByte; expLen: SizeInt): Boolean;
var
  i: SizeInt;
begin
  Result := False;
  if gotLen <> expLen then
  begin
    WriteLn('FAIL ', testName, ': size mismatch got=', gotLen,
            ' expected=', expLen);
    Exit;
  end;
  for i := 0 to expLen - 1 do
  begin
    if got[i] <> exp[i] then
    begin
      WriteLn('FAIL ', testName, ': byte mismatch at offset ', i,
              ' got=$', IntToHex(got[i], 2),
              ' exp=$', IntToHex(exp[i], 2));
      Exit;
    end;
  end;
  Result := True;
end;

// ---------------------------------------------------------------------------
// Direction A: Pascal compress → C decompress
// ---------------------------------------------------------------------------
function TestPascalToC(const testName: string;
                       src: PByte; srcLen: SizeInt;
                       blockSize100k: Int32): Boolean;
const
  OVERHEAD = 1024;
var
  compBuf  : PByte;
  decompBuf: PByte;
  compLen  : UInt32;
  decompLen: UInt32;
  compMax  : SizeInt;
  ret      : Int32;
begin
  Result := False;
  compMax := srcLen + srcLen div 100 + OVERHEAD + 128;
  if compMax < OVERHEAD then compMax := OVERHEAD;
  compBuf   := GetMem(compMax);
  compLen   := compMax;

  // Compress with Pascal
  ret := BZ2_bzBuffToBuffCompress(
    PChar(compBuf), @compLen,
    PChar(src), srcLen,
    blockSize100k, 0, 30);
  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ' [A-pascal-compress]: ret=', ret);
    FreeMem(compBuf);
    Exit;
  end;

  // Decompress with C
  decompLen := srcLen + OVERHEAD;
  if decompLen < OVERHEAD then decompLen := OVERHEAD;
  decompBuf := GetMem(decompLen);
  ret := cbz_bzBuffToBuffDecompress(
    PChar(decompBuf), @decompLen,
    PChar(compBuf), compLen,
    0, 0);
  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ' [A-c-decompress]: ret=', ret);
    FreeMem(compBuf);
    FreeMem(decompBuf);
    Exit;
  end;

  Result := BytesEqual(testName + ' [A]', decompBuf, decompLen, src, srcLen);
  if Result then WriteLn('  OK  ', testName, ' [A Pascal→C]');

  FreeMem(compBuf);
  FreeMem(decompBuf);
end;

// ---------------------------------------------------------------------------
// Direction B: C compress → Pascal decompress
// ---------------------------------------------------------------------------
function TestCToPascal(const testName: string;
                       src: PByte; srcLen: SizeInt;
                       blockSize100k: Int32): Boolean;
const
  OVERHEAD = 1024;
var
  compBuf  : PByte;
  decompBuf: PByte;
  compLen  : UInt32;
  decompLen: UInt32;
  compMax  : SizeInt;
  ret      : Int32;
begin
  Result := False;
  compMax := srcLen + srcLen div 100 + OVERHEAD + 128;
  if compMax < OVERHEAD then compMax := OVERHEAD;
  compBuf  := GetMem(compMax);
  compLen  := compMax;

  // Compress with C
  ret := cbz_bzBuffToBuffCompress(
    PChar(compBuf), @compLen,
    PChar(src), srcLen,
    blockSize100k, 0, 30);
  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ' [B-c-compress]: ret=', ret);
    FreeMem(compBuf);
    Exit;
  end;

  // Decompress with Pascal
  decompLen := srcLen + OVERHEAD;
  if decompLen < OVERHEAD then decompLen := OVERHEAD;
  decompBuf := GetMem(decompLen);
  ret := BZ2_bzBuffToBuffDecompress(
    PChar(decompBuf), @decompLen,
    PChar(compBuf), compLen,
    0, 0);
  if ret <> BZ_OK then
  begin
    WriteLn('FAIL ', testName, ' [B-pascal-decompress]: ret=', ret);
    FreeMem(compBuf);
    FreeMem(decompBuf);
    Exit;
  end;

  Result := BytesEqual(testName + ' [B]', decompBuf, decompLen, src, srcLen);
  if Result then WriteLn('  OK  ', testName, ' [B C→Pascal]');

  FreeMem(compBuf);
  FreeMem(decompBuf);
end;

// ---------------------------------------------------------------------------
// Run both directions for one test case; accumulate failures.
// ---------------------------------------------------------------------------
var
  fails: Integer;

procedure RunBoth(const name: string; src: PByte; srcLen: SizeInt;
                  blockSize100k: Int32);
begin
  if not TestPascalToC(name, src, srcLen, blockSize100k) then Inc(fails);
  if not TestCToPascal(name, src, srcLen, blockSize100k) then Inc(fails);
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const
  SEEDS: array[0..2] of UInt32 = ($DEADBEEF, $C0FFEE42, $12345678);
  SMALL_SIZES: array[0..5] of SizeInt = (0, 1, 256, 4096, 65536, 500000);
  BLOCK_SIZES: array[0..2] of Int32   = (1, 5, 9);

var
  si, bi, seedIdx: Integer;
  buf : PByte;
  name: string;
  pat4: array[0..3] of Byte = ($11, $22, $33, $44);
  i   : SizeInt;
  tmpBuf: PByte;

begin
  fails := 0;
  WriteLn('TestCrossCompat — Phase 8.2 cross-compatibility validation');
  WriteLn('libbz2 version: ', cbz_bzlibVersion());
  WriteLn;

  // ---- Section 1: random buffers ------------------------------------------
  WriteLn('Section 1: random buffers');
  for seedIdx := 0 to High(SEEDS) do
    for bi := 0 to High(BLOCK_SIZES) do
      for si := 0 to High(SMALL_SIZES) do
      begin
        SeedRng(SEEDS[seedIdx]);
        buf := MakeRandomBuffer(SMALL_SIZES[si]);
        name := Format('seed=%8.8x bs=%d len=%d',
                       [SEEDS[seedIdx], BLOCK_SIZES[bi], SMALL_SIZES[si]]);
        RunBoth(name, buf, SMALL_SIZES[si], BLOCK_SIZES[bi]);
        FreeMem(buf);
      end;
  WriteLn;

  // ---- Section 2: uniform-fill buffers ------------------------------------
  WriteLn('Section 2: uniform-fill buffers');
  for bi := 0 to High(BLOCK_SIZES) do
  begin
    // zero fill, 1 MB
    tmpBuf := GetMem(1000000);
    FillChar(tmpBuf^, 1000000, 0);
    name := Format('fill=0x00 bs=%d len=1MB', [BLOCK_SIZES[bi]]);
    RunBoth(name, tmpBuf, 1000000, BLOCK_SIZES[bi]);
    FreeMem(tmpBuf);

    // 0xFF fill, 1 MB
    tmpBuf := GetMem(1000000);
    FillChar(tmpBuf^, 1000000, $FF);
    name := Format('fill=0xFF bs=%d len=1MB', [BLOCK_SIZES[bi]]);
    RunBoth(name, tmpBuf, 1000000, BLOCK_SIZES[bi]);
    FreeMem(tmpBuf);
  end;
  WriteLn;

  // ---- Section 3: repeating-pattern buffers --------------------------------
  WriteLn('Section 3: repeating-pattern buffers');
  for bi := 0 to High(BLOCK_SIZES) do
  begin
    tmpBuf := GetMem(1000000);
    for i := 0 to 999999 do
      tmpBuf[i] := pat4[i mod 4];
    name := Format('pattern4 bs=%d len=1MB', [BLOCK_SIZES[bi]]);
    RunBoth(name, tmpBuf, 1000000, BLOCK_SIZES[bi]);
    FreeMem(tmpBuf);
  end;
  WriteLn;

  // ---- Section 4: all 256 distinct bytes (cycle) --------------------------
  WriteLn('Section 4: 256-byte all-distinct cycle');
  begin
    tmpBuf := GetMem(256);
    for i := 0 to 255 do tmpBuf[i] := Byte(i);
    for bi := 0 to High(BLOCK_SIZES) do
    begin
      name := Format('all-256-bytes bs=%d', [BLOCK_SIZES[bi]]);
      RunBoth(name, tmpBuf, 256, BLOCK_SIZES[bi]);
    end;
    FreeMem(tmpBuf);
  end;
  WriteLn;

  // ---- Section 5: Phase 8.4 explicit edge-case corpus ---------------------
  WriteLn('Section 5: Phase 8.4 edge-case corpus (both directions)');
  begin
    // empty input (0 bytes) — uses 1-byte dummy to avoid NULL
    tmpBuf := GetMem(1);
    RunBoth('edge: empty 0B bs=9', tmpBuf, 0, 9);
    FreeMem(tmpBuf);

    // single byte values
    tmpBuf := GetMem(1);
    tmpBuf[0] := $00;
    RunBoth('edge: single-byte 0x00 bs=1', tmpBuf, 1, 1);
    tmpBuf[0] := $FF;
    RunBoth('edge: single-byte 0xFF bs=9', tmpBuf, 1, 9);
    FreeMem(tmpBuf);

    // 256 distinct bytes, one of each
    tmpBuf := GetMem(256);
    for i := 0 to 255 do tmpBuf[i] := Byte(i);
    RunBoth('edge: 256-distinct bs=1', tmpBuf, 256, 1);
    RunBoth('edge: 256-distinct bs=9', tmpBuf, 256, 9);
    FreeMem(tmpBuf);

    // 1 MB of a single repeated byte
    tmpBuf := GetMem(1000000);
    FillChar(tmpBuf^, 1000000, $42);
    RunBoth('edge: 1MB fill=0x42 bs=5', tmpBuf, 1000000, 5);
    FreeMem(tmpBuf);

    // 1 MB of a repeating 4-byte pattern
    tmpBuf := GetMem(1000000);
    for i := 0 to 999999 do tmpBuf[i] := pat4[i mod 4];
    RunBoth('edge: 1MB pattern4 bs=5', tmpBuf, 1000000, 5);
    FreeMem(tmpBuf);

    // RLE rollover boundary: run of 255 identical bytes
    tmpBuf := GetMem(255);
    FillChar(tmpBuf^, 255, $42);
    RunBoth('edge: RLE-255 fill=0x42 bs=1', tmpBuf, 255, 1);
    FreeMem(tmpBuf);

    // RLE rollover + 1: run of 256 identical bytes
    tmpBuf := GetMem(256);
    FillChar(tmpBuf^, 256, $42);
    RunBoth('edge: RLE-256 fill=0x42 bs=1', tmpBuf, 256, 1);
    FreeMem(tmpBuf);

    // fallback sort trigger: very low-entropy repeating input, workFactor=1
    tmpBuf := GetMem(20000);
    for i := 0 to 19999 do tmpBuf[i] := pat4[i mod 4];
    RunBoth('edge: fallback-sort pat4 20KB bs=1', tmpBuf, 20000, 1);
    RunBoth('edge: fallback-sort pat4 20KB bs=9', tmpBuf, 20000, 9);
    FreeMem(tmpBuf);
  end;
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
