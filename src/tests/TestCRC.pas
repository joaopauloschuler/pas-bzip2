{$I pasbzip2.inc}
program TestCRC;

{
  Phase 1 validation: verifies BZ2_crc32Table and the three CRC helper
  inlines against the C libbz2 reference.

  Strategy
  ---------
  1. The C library exports BZ2_crc32Table as a global symbol; we bind it
     via an external var declaration and compare every entry with the
     Pascal constant.
  2. We compute the CRC of several representative buffers using the Pascal
     inlines and then verify the same buffers compressed by libbz2 produce
     a matching CRC (extracted from byte offsets 6..9 of the bzip2 stream,
     which hold the block CRC in big-endian order).
  3. A separate cross-check computes the CRC using the formula directly
     (without the inline helpers) and compares.
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2tables,
  cbzip2;

// ---------------------------------------------------------------------------
// Bind the C table as an external variable (exported by libbz2.so).
// ---------------------------------------------------------------------------
var
  C_crc32Table: array[0..255] of UInt32;
    external 'bz2' name 'BZ2_crc32Table';

// ---------------------------------------------------------------------------
// Helper: compute CRC of Len bytes at Buf using the Pascal inlines.
// ---------------------------------------------------------------------------
function PascalCRC(Buf: PByte; Len: SizeInt): UInt32;
var
  i: SizeInt;
begin
  BZ_INITIALISE_CRC(Result);
  for i := 0 to Len - 1 do
    BZ_UPDATE_CRC(Result, Buf[i]);
  BZ_FINALISE_CRC(Result);
end;

// ---------------------------------------------------------------------------
// Helper: read big-endian UInt32 from 4 bytes.
// ---------------------------------------------------------------------------
function ReadBE32(p: PByte): UInt32; inline;
begin
  Result := (UInt32(p[0]) shl 24) or
            (UInt32(p[1]) shl 16) or
            (UInt32(p[2]) shl  8) or
             UInt32(p[3]);
end;

// ---------------------------------------------------------------------------
// Helper: extract the block-level CRC from a single-block bzip2 stream.
// The bzip2 block header is:
//   bytes 0..3  : 'B','Z','h','0'+blockSize
//   bytes 4..9  : block magic 0x314159265359  (6 bytes)
//   bytes 10..13: block CRC (big-endian)        <-- what we want
// All bit-packed; byte 10 in a one-block stream is at a fixed offset.
// For buffers ≤ blockSize * 100 000 bytes a single block is guaranteed.
// ---------------------------------------------------------------------------
function CRCFromBZ2Stream(compressed: PByte): UInt32;
begin
  // bytes 10..13 hold the 32-bit block CRC, big-endian
  Result := ReadBE32(compressed + 10);
end;

// ---------------------------------------------------------------------------
// Compress Len bytes using the C library; return block CRC from stream.
// ---------------------------------------------------------------------------
function CBZ2BlockCRC(Buf: PByte; Len: SizeInt): UInt32;
var
  outBuf    : PByte;
  outLen    : UInt32;
  bufSize   : SizeInt;
  ret       : Int32;
begin
  // bzip2 worst-case expansion: n + 1% + 600 bytes; add generous margin
  bufSize := Len + Len div 50 + 4096;
  if bufSize < 65536 then bufSize := 65536;
  outBuf := GetMem(bufSize);
  try
    outLen := bufSize;
    ret := cbz_bzBuffToBuffCompress(PChar(outBuf), @outLen,
                                    PChar(Buf), Len,
                                    9,   // blockSize100k
                                    0,   // verbosity
                                    30); // workFactor
    if ret <> BZ_OK then
      raise Exception.CreateFmt('cbz_bzBuffToBuffCompress failed: %d', [ret]);
    Result := CRCFromBZ2Stream(outBuf);
  finally
    FreeMem(outBuf);
  end;
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const
  NTESTS = 5;

var
  fails : Integer;

  procedure Check(const name: string; expected, got: UInt32);
  begin
    if expected = got then
      WriteLn('  OK  ', name)
    else
    begin
      WriteLn('  FAIL ', name,
              ' expected=', IntToHex(expected, 8),
              ' got=',      IntToHex(got, 8));
      Inc(fails);
    end;
  end;

// Large buffers as globals to avoid stack pressure.
var
  g_rnd1KB   : array[0..1023]    of Byte;
  g_rnd1MB   : array[0..819199] of Byte;   // 800 KB — fits in one bzip2 block
  g_zero1MB  : array[0..819199] of Byte;   // 800 KB — fits in one bzip2 block

var
  i        : Integer;
  seed     : UInt32;
  oneByte  : array[0..0]       of Byte;
  pCRC, cCRC : UInt32;
  crcP, crcD : UInt32;
begin
  fails := 0;
  WriteLn('TestCRC — Phase 1 validation');
  WriteLn('libbz2 version: ', cbz_bzlibVersion());
  WriteLn;

  // --- 1. Compare every entry of BZ2_crc32Table against C's copy ----------
  WriteLn('1. Verifying BZ2_crc32Table (256 entries) ...');
  for i := 0 to 255 do
    if BZ2_crc32Table[i] <> C_crc32Table[i] then
    begin
      WriteLn('  FAIL table[', i, '] Pascal=', IntToHex(BZ2_crc32Table[i], 8),
              ' C=', IntToHex(C_crc32Table[i], 8));
      Inc(fails);
    end;
  if fails = 0 then WriteLn('  OK  all 256 entries match');
  WriteLn;

  // --- 2. CRC cross-check: Pascal inline == direct formula -----------------
  WriteLn('2. Verifying BZ_UPDATE_CRC formula (spot-checks) ...');
  begin
    BZ_INITIALISE_CRC(crcP);
    BZ_INITIALISE_CRC(crcD);
    // Feed bytes 0..255 in order
    for i := 0 to 255 do
    begin
      BZ_UPDATE_CRC(crcP, UChar(i));
      // Direct formula (same as macro expansion)
      crcD := (crcD shl 8) xor BZ2_crc32Table[(crcD shr 24) xor UInt32(i)];
    end;
    BZ_FINALISE_CRC(crcP);
    BZ_FINALISE_CRC(crcD);
    Check('all-bytes-0..255 inline vs direct', crcD, crcP);
  end;
  WriteLn;

  // --- 3. CRC of known buffers: Pascal vs C libbz2 block CRC ---------------
  WriteLn('3. Pascal CRC vs C libbz2 block CRC for sample buffers ...');

  // (a) single byte 0x00
  oneByte[0] := $00;
  pCRC := PascalCRC(@oneByte[0], 1);
  cCRC := CBZ2BlockCRC(@oneByte[0], 1);
  Check('1-byte 0x00', cCRC, pCRC);

  // (b) single byte 0xFF
  oneByte[0] := $FF;
  pCRC := PascalCRC(@oneByte[0], 1);
  cCRC := CBZ2BlockCRC(@oneByte[0], 1);
  Check('1-byte 0xFF', cCRC, pCRC);

  // (c) random 1 KB
  seed := $DEADBEEF;
  for i := 0 to 1023 do
  begin
    seed := seed * 1664525 + 1013904223;   // LCG
    g_rnd1KB[i] := Byte(seed shr 24);
  end;
  pCRC := PascalCRC(@g_rnd1KB[0], 1024);
  cCRC := CBZ2BlockCRC(@g_rnd1KB[0], 1024);
  Check('random 1 KB', cCRC, pCRC);

  // (d) random 1 MB
  seed := $C0FFEE42;
  for i := 0 to 819199 do
  begin
    seed := seed * 1664525 + 1013904223;
    g_rnd1MB[i] := Byte(seed shr 24);
  end;
  pCRC := PascalCRC(@g_rnd1MB[0], 819200);
  cCRC := CBZ2BlockCRC(@g_rnd1MB[0], 819200);
  Check('random 800 KB', cCRC, pCRC);

  // (e) 1 MB of zeros
  FillChar(g_zero1MB, SizeOf(g_zero1MB), 0);
  pCRC := PascalCRC(@g_zero1MB[0], 819200);
  cCRC := CBZ2BlockCRC(@g_zero1MB[0], 819200);
  Check('800 KB zeros', cCRC, pCRC);

  WriteLn;

  // --- Result ---------------------------------------------------------------
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
