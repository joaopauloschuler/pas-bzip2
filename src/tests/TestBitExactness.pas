{$I pasbzip2.inc}
program TestBitExactness;

{
  Phase 5.7 validation: verifies that the Pascal BZ2_blockSort produces
  bit-exact results vs the C reference implementation.

  Phase 8.3 extension: sweeps every blockSize100k value (1..9) and a
  representative set of workFactor values (0, 1, 30, 100, 250) confirming
  byte-equal full compressed output with the C reference.

  Strategy (Phase 5.7)
  ---------------------
  For each test vector we allocate two independent EState instances using
  BZ2_bzCompressInit, fill both with identical block data, then call the
  Pascal BZ2_blockSort on one and the C cbz_blockSort on the other.
  We compare:
    • s.origPtr   — the BWT rotation index
    • s.ptr[0..nblock-1]  — the sorted suffix-array order

  Test vectors (Phase 5.7)
  ------------------------
    1. Small all-zeros (100 bytes) — exercises fallbackSort path
    2. Small all-same non-zero (200 bytes 'A') — exercises fallbackSort
    3. Small random (1 000 bytes) — exercises fallbackSort
    4. Medium random (50 000 bytes) — exercises mainSort
    5. Large random (900 000 bytes, block-size 9) — exercises mainSort
    6. Highly repetitive (20 000 bytes, 4-byte pattern) — triggers fallback
       from mainSort via budget exhaustion when workFactor = 1

  Strategy (Phase 8.3)
  ---------------------
  For each (blockSize100k, workFactor, corpus) triple, compress the same
  buffer with BZ2_bzBuffToBuffCompress (Pascal) and cbz_bzBuffToBuffCompress
  (C reference) and compare the compressed byte streams byte-for-byte.
  workFactor=0 is explicitly included (maps to internal default 30).
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
// Phase 8.3: compare full compressed byte streams Pascal vs C.
// Returns True on exact match, False on any mismatch.
// ---------------------------------------------------------------------------
function SweepOne(srcBuf: PByte; srcLen: Int32;
                  bs8: Int32; wf: Int32;
                  const corpus: string): Boolean;
var
  compBufP, compBufC: PByte;
  pLen, cLen: UInt32;
  cMax: SizeInt;
  ret2: Int32;
  mi: Int32;
begin
  Result := False;
  cMax := srcLen + srcLen div 100 + 1024;
  if cMax < 1024 then cMax := 1024;
  compBufP := GetMem(cMax);
  compBufC := GetMem(cMax);
  pLen := cMax;
  cLen := cMax;

  ret2 := BZ2_bzBuffToBuffCompress(
    PChar(compBufP), @pLen, PChar(srcBuf), srcLen, bs8, 0, wf);
  if ret2 <> BZ_OK then
  begin
    WriteLn('  FAIL ', corpus, ' bs=', bs8, ' wf=', wf,
            ' pascal-compress ret=', ret2);
    FreeMem(compBufP); FreeMem(compBufC);
    Exit;
  end;

  ret2 := cbz_bzBuffToBuffCompress(
    PChar(compBufC), @cLen, PChar(srcBuf), srcLen, bs8, 0, wf);
  if ret2 <> BZ_OK then
  begin
    WriteLn('  FAIL ', corpus, ' bs=', bs8, ' wf=', wf,
            ' c-compress ret=', ret2);
    FreeMem(compBufP); FreeMem(compBufC);
    Exit;
  end;

  if pLen <> cLen then
  begin
    WriteLn('  FAIL ', corpus, ' bs=', bs8, ' wf=', wf,
            ' stream-length mismatch Pascal=', pLen, ' C=', cLen);
    FreeMem(compBufP); FreeMem(compBufC);
    Exit;
  end;

  for mi := 0 to Int32(pLen) - 1 do
  begin
    if compBufP[mi] <> compBufC[mi] then
    begin
      WriteLn('  FAIL ', corpus, ' bs=', bs8, ' wf=', wf,
              ' stream byte mismatch at offset ', mi,
              ' Pascal=$', IntToHex(compBufP[mi], 2),
              ' C=$', IntToHex(compBufC[mi], 2));
      FreeMem(compBufP); FreeMem(compBufC);
      Exit;
    end;
  end;

  WriteLn('  OK  ', corpus, ' bs=', bs8, ' wf=', wf);
  Result := True;
  FreeMem(compBufP);
  FreeMem(compBufC);
end;

const
  WF_VALUES: array[0..4] of Int32 = (0, 1, 30, 100, 250);

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
  litBuf: array[0..4095] of Byte;
  bs, wfi: Integer;

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

  // =========================================================================
  // Phase 8.3 — sweep blockSize100k (1..9) × workFactor × representative
  //             corpora, comparing full compressed byte streams Pascal vs C.
  // =========================================================================
  WriteLn('=== Phase 8.3: full-stream bit-exactness sweep ===');
  WriteLn;

  begin
    for i := 0 to 4095 do
      litBuf[i] := Byte(Ord('Hello, bzip2 world! '[(i mod 20) + 1]));

    for bs := 1 to 9 do
      for wfi := 0 to 4 do
      begin
        if not SweepOne(@litBuf[0],   4096,       bs, WF_VALUES[wfi], 'literal-4KB')  then Inc(fails);
        if not SweepOne(@gMedium[0],  BUF_MEDIUM, bs, WF_VALUES[wfi], 'random-50KB')  then Inc(fails);
        if not SweepOne(@gRepeat[0],  BUF_REPET,  bs, WF_VALUES[wfi], 'repeat4-20KB') then Inc(fails);
      end;

    // Large 900 KB buffer: all block sizes × wf=1 and wf=30 only (time budget)
    for bs := 1 to 9 do
    begin
      if not SweepOne(@gLarge[0], BUF_LARGE, bs,  1, 'random-900KB') then Inc(fails);
      if not SweepOne(@gLarge[0], BUF_LARGE, bs, 30, 'random-900KB') then Inc(fails);
    end;
  end;

  WriteLn;
  if fails = 0 then begin
    WriteLn('ALL PASSED');
    Halt(0);
  end else begin
    WriteLn(fails, ' FAILURE(S)');
    Halt(1);
  end;
end.
