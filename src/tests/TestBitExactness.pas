{$I pasbzip2.inc}
program TestBitExactness;

{
  Phase 5.7 validation: verifies that the Pascal BZ2_blockSort produces
  bit-exact results vs the C reference implementation.

  Strategy
  ---------
  For each test vector we allocate two independent EState instances using
  BZ2_bzCompressInit, fill both with identical block data, then call the
  Pascal BZ2_blockSort on one and the C cbz_blockSort on the other.
  We compare:
    • s.origPtr   — the BWT rotation index
    • s.ptr[0..nblock-1]  — the sorted suffix-array order

  Test vectors
  ------------
    1. Small all-zeros (100 bytes) — exercises fallbackSort path
    2. Small all-same non-zero (200 bytes 'A') — exercises fallbackSort
    3. Small random (1 000 bytes) — exercises fallbackSort
    4. Medium random (50 000 bytes) — exercises mainSort
    5. Large random (900 000 bytes, block-size 9) — exercises mainSort
    6. Highly repetitive (20 000 bytes, 4-byte pattern) — triggers fallback
       from mainSort via budget exhaustion when workFactor = 1
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2tables,
  pasbzip2blocksort,
  pasbzip2,
  cbzip2;

// ---------------------------------------------------------------------------
// Helper — fill a bz_stream/EState using BZ2_bzCompressInit, then
// copy nblock bytes from data[] into s.block[].
// Returns a pointer to the EState cast from strm.state.
// ---------------------------------------------------------------------------
function InitAndFill(out strm: Tbz_stream;
                     const data: PByte; nblock: Int32;
                     blockSize100k: Int32; workFactor: Int32): PEState;
var
  s: PEState;
  ret: Int32;
  i: Int32;
begin
  FillChar(strm, SizeOf(strm), 0);
  ret := BZ2_bzCompressInit(@strm, blockSize100k, 0, workFactor);
  if ret <> BZ_OK then
    raise Exception.CreateFmt('BZ2_bzCompressInit failed: %d', [ret]);

  s := PEState(strm.state);

  // Copy raw bytes into block[].  We bypass the RLE encoder intentionally
  // so that both Pascal and C sort exactly the same byte sequence.
  for i := 0 to nblock-1 do begin
    s^.block[i] := data[i];
    s^.inUse[data[i]] := BZ_TRUE;
  end;
  s^.nblock := nblock;
  BZ_INITIALISE_CRC(s^.blockCRC);
  for i := 0 to nblock-1 do
    BZ_UPDATE_CRC(s^.blockCRC, s^.block[i]);
  BZ_FINALISE_CRC(s^.blockCRC);

  Result := s;
end;

// ---------------------------------------------------------------------------
// Helper — compare ptr[] and origPtr from two EStates.
// ---------------------------------------------------------------------------
function CompareSort(const name: string;
                     sP: PEState; sC: PEState; nblock: Int32): Boolean;
var
  i: Int32;
  firstMismatch: Int32;
begin
  Result := True;
  if sP^.origPtr <> sC^.origPtr then begin
    WriteLn('  FAIL ', name, ': origPtr Pascal=', sP^.origPtr,
            ' C=', sC^.origPtr);
    Result := False;
    Exit;
  end;

  firstMismatch := -1;
  for i := 0 to nblock-1 do begin
    if sP^.ptr[i] <> sC^.ptr[i] then begin
      firstMismatch := i;
      break;
    end;
  end;

  if firstMismatch >= 0 then begin
    WriteLn('  FAIL ', name, ': ptr mismatch at index ', firstMismatch,
            ' Pascal=', sP^.ptr[firstMismatch],
            ' C=', sC^.ptr[firstMismatch]);
    Result := False;
  end else
    WriteLn('  OK  ', name);
end;

// ---------------------------------------------------------------------------
// Run one test: allocate two EStates, sort with Pascal + C, compare.
// ---------------------------------------------------------------------------
var
  fails: Integer;

procedure RunTest(const name: string;
                  data: PByte; nblock: Int32;
                  blockSize100k: Int32; workFactor: Int32);
var
  strmP, strmC: Tbz_stream;
  sP, sC: PEState;
  ok: Boolean;
begin
  sP := InitAndFill(strmP, data, nblock, blockSize100k, workFactor);
  sC := InitAndFill(strmC, data, nblock, blockSize100k, workFactor);

  BZ2_blockSort(sP);         // Pascal implementation
  cbz_blockSort(sC);         // C reference

  ok := CompareSort(name, sP, sC, nblock);
  if not ok then Inc(fails);

  BZ2_bzCompressEnd(@strmP);
  BZ2_bzCompressEnd(@strmC);
end;

// ---------------------------------------------------------------------------
// Large test buffers as globals to avoid stack overflow
// ---------------------------------------------------------------------------
const
  BUF_SMALL  = 200;
  BUF_MEDIUM = 50000;
  BUF_LARGE  = 900000;
  BUF_REPET  = 20000;

var
  gZero:   array[0..BUF_SMALL-1]  of Byte;
  gSame:   array[0..BUF_SMALL-1]  of Byte;
  gSmall:  array[0..999]          of Byte;
  gMedium: array[0..BUF_MEDIUM-1] of Byte;
  gLarge:  array[0..BUF_LARGE-1]  of Byte;
  gRepeat: array[0..BUF_REPET-1]  of Byte;

var
  seed: UInt32;
  i: Integer;

  function NextRnd: Byte; inline;
  begin
    seed := seed * 1664525 + 1013904223;
    NextRnd := Byte(seed shr 24);
  end;

begin
  fails := 0;
  WriteLn('TestBitExactness — Phase 5.7 blockSort validation');
  WriteLn('libbz2 version: ', cbz_bzlibVersion());
  WriteLn;

  // --- Prepare test data ---
  FillChar(gZero,  SizeOf(gZero),  0);
  FillChar(gSame,  SizeOf(gSame),  Ord('A'));

  seed := $DEADBEEF;
  for i := 0 to 999    do gSmall[i]  := NextRnd;

  seed := $CAFEBABE;
  for i := 0 to BUF_MEDIUM-1 do gMedium[i] := NextRnd;

  seed := $12345678;
  for i := 0 to BUF_LARGE-1  do gLarge[i]  := NextRnd;

  for i := 0 to BUF_REPET-1  do gRepeat[i] := Byte(i mod 4);

  WriteLn('Running sort comparison tests ...');

  RunTest('all-zeros 200B (fallback)',   @gZero[0],   200,     1, 30);
  RunTest('all-A 200B (fallback)',       @gSame[0],   200,     1, 30);
  RunTest('random 1000B (fallback)',     @gSmall[0],  1000,    1, 30);
  RunTest('random 50000B (mainSort)',    @gMedium[0], 50000,   1, 30);
  RunTest('random 900000B (mainSort)',   @gLarge[0],  900000,  9, 30);
  RunTest('repetitive 20000B wfact=1',  @gRepeat[0], 20000,   1,  1);

  WriteLn;
  if fails = 0 then begin
    WriteLn('ALL PASSED');
    Halt(0);
  end else begin
    WriteLn(fails, ' FAILURE(S)');
    Halt(1);
  end;
end.
