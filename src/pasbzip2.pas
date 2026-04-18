{$I pasbzip2.inc}
unit pasbzip2;

{
  Pascal port of bzip2/libbzip2 1.1.0 — public API and stream management.
  Mirrors bzlib.c: default_bzalloc/bzfree, AssertH fail, BZ2_bzCompressInit/
  End, BZ2_bzDecompressInit/End, and BZ2_bzlibVersion.

  Phases 4–7 will add BZ2_bzCompress, BZ2_bzDecompress, BZ2_bzBuffToBuffer*,
  stdio wrappers, etc.
}

interface

uses
  pasbzip2types;

// ---------------------------------------------------------------------------
// Internal error reporter — prints to stderr and halts with exit code 3.
// Declared here so that the AssertH macro (used in other units) can call it.
// ---------------------------------------------------------------------------
procedure BZ2_bz__AssertH__fail(errcode: Int32);

// ---------------------------------------------------------------------------
// Stream life-cycle
// ---------------------------------------------------------------------------
function BZ2_bzCompressInit(strm: Pbz_stream;
    blockSize100k, verbosity, workFactor: Int32): Int32;

function BZ2_bzCompressEnd(strm: Pbz_stream): Int32;

function BZ2_bzDecompressInit(strm: Pbz_stream;
    verbosity, small: Int32): Int32;

function BZ2_bzDecompressEnd(strm: Pbz_stream): Int32;

// ---------------------------------------------------------------------------
// Version query
// ---------------------------------------------------------------------------
function BZ2_bzlibVersion: PChar;

implementation

uses
  pasbzip2tables,    // BZ_INITIALISE_CRC
  pasbzip2compress;  // BZ2_bsInitWrite, bsFinishWrite

// ---------------------------------------------------------------------------
// Version string  (must match bz_version.h exactly)
// ---------------------------------------------------------------------------
const
  BZ_VERSION_STR : PChar = '1.1.0';

// ---------------------------------------------------------------------------
// Platform sanity check (mirrors bz_config_ok in bzlib.c)
// ---------------------------------------------------------------------------
function bz_config_ok: Boolean; inline;
begin
  Result := (SizeOf(Int32) = 4) and (SizeOf(Int16) = 2) and (SizeOf(Byte) = 1);
end;

// ---------------------------------------------------------------------------
// Default allocator / deallocator  (bzlib.c: default_bzalloc / default_bzfree)
// These are installed as cdecl callbacks, so they must be declared cdecl.
// ---------------------------------------------------------------------------
function default_bzalloc(opaque: Pointer; items, size: Int32): Pointer; cdecl;
begin
  GetMem(Result, items * size);
end;

procedure default_bzfree(opaque: Pointer; addr: Pointer); cdecl;
begin
  if addr <> nil then FreeMem(addr);
end;

// ---------------------------------------------------------------------------
// BZALLOC / BZFREE  — macros in bzlib_private.h, inline helpers here
// ---------------------------------------------------------------------------
function BZALLOC(strm: Pbz_stream; nnn: Int32): Pointer; inline;
begin
  Result := strm^.bzalloc(strm^.opaque, nnn, 1);
end;

procedure BZFREE(strm: Pbz_stream; ppp: Pointer); inline;
begin
  strm^.bzfree(strm^.opaque, ppp);
end;

// ---------------------------------------------------------------------------
// BZ2_bz__AssertH__fail  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bz__AssertH__fail(errcode: Int32);
begin
  WriteLn(StdErr);
  WriteLn(StdErr,
    'bzip2/libbzip2: internal error number ', errcode, '.');
  WriteLn(StdErr,
    'This is a bug in bzip2/libbzip2, ', BZ2_bzlibVersion, '.');
  WriteLn(StdErr,
    'Please report it at: https://gitlab.com/bzip2/bzip2/-/issues');
  WriteLn(StdErr,
    'If this happened when you were using some program which uses');
  WriteLn(StdErr,
    'libbzip2 as a component, you should also report this bug to');
  WriteLn(StdErr,
    'the author(s) of that program.');
  WriteLn(StdErr,
    'Please make an effort to report this bug;');
  WriteLn(StdErr,
    'timely and accurate bug reports eventually lead to higher');
  WriteLn(StdErr,
    'quality software.  Thanks.');
  WriteLn(StdErr);
  if errcode = 1007 then begin
    WriteLn(StdErr);
    WriteLn(StdErr, '*** A special note about internal error number 1007 ***');
    WriteLn(StdErr);
    WriteLn(StdErr,
      'Experience suggests that a common cause of i.e. 1007');
    WriteLn(StdErr,
      'is unreliable memory or other hardware.  The 1007 assertion');
    WriteLn(StdErr,
      'just happens to cross-check the results of huge numbers of');
    WriteLn(StdErr,
      'memory reads/writes, and so acts (unintendedly) as a stress');
    WriteLn(StdErr, 'test of your memory system.');
    WriteLn(StdErr);
    WriteLn(StdErr,
      '* If the error cannot be reproduced, and/or happens at different');
    WriteLn(StdErr,
      '  points in compression, you may have a flaky memory system.');
    WriteLn(StdErr,
      '  Try a memory-test program.  I have used Memtest86');
    WriteLn(StdErr,
      '  (www.memtest86.com).  At the time of writing it is free (GPLd).');
    WriteLn(StdErr,
      '  Memtest86 tests memory much more thorougly than your BIOSs');
    WriteLn(StdErr,
      '  power-on test, and may find failures that the BIOS doesn''t.');
    WriteLn(StdErr);
    WriteLn(StdErr,
      '* If the error can be repeatably reproduced, this is a bug in');
    WriteLn(StdErr,
      '  bzip2, and I would very much like to hear about it.  Please');
    WriteLn(StdErr,
      '  let me know, and, ideally, save a copy of the file causing the');
    WriteLn(StdErr,
      '  problem -- without which I will be unable to investigate it.');
    WriteLn(StdErr);
  end;
  Halt(3);
end;

// ---------------------------------------------------------------------------
// prepare_new_block  (bzlib.c static helper)
// ---------------------------------------------------------------------------
procedure prepare_new_block(s: PEState);
var i: Int32;
begin
  s^.nblock       := 0;
  s^.numZ         := 0;
  s^.state_out_pos := 0;
  BZ_INITIALISE_CRC(s^.blockCRC);
  for i := 0 to 255 do s^.inUse[i] := BZ_FALSE;
  Inc(s^.blockNo);
end;

// ---------------------------------------------------------------------------
// init_RL  (bzlib.c static helper)
// ---------------------------------------------------------------------------
procedure init_RL(s: PEState); inline;
begin
  s^.state_in_ch  := 256;
  s^.state_in_len := 0;
end;

// ---------------------------------------------------------------------------
// BZ2_bzCompressInit  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzCompressInit(strm: Pbz_stream;
    blockSize100k, verbosity, workFactor: Int32): Int32;
var
  n: Int32;
  s: PEState;
begin
  if not bz_config_ok then begin Result := BZ_CONFIG_ERROR; Exit; end;

  if (strm = nil) or
     (blockSize100k < 1) or (blockSize100k > 9) or
     (workFactor < 0) or (workFactor > 250) then begin
    Result := BZ_PARAM_ERROR; Exit;
  end;

  if workFactor = 0 then workFactor := 30;
  if strm^.bzalloc = nil then strm^.bzalloc := @default_bzalloc;
  if strm^.bzfree  = nil then strm^.bzfree  := @default_bzfree;

  s := PEState(BZALLOC(strm, SizeOf(TEState)));
  if s = nil then begin Result := BZ_MEM_ERROR; Exit; end;
  s^.strm := strm;

  s^.arr1 := nil;
  s^.arr2 := nil;
  s^.ftab := nil;

  n := 100000 * blockSize100k;
  s^.arr1 := PUInt32(BZALLOC(strm,  n                   * SizeOf(UInt32)));
  s^.arr2 := PUInt32(BZALLOC(strm, (n + BZ_N_OVERSHOOT) * SizeOf(UInt32)));
  s^.ftab := PUInt32(BZALLOC(strm,  65537               * SizeOf(UInt32)));

  if (s^.arr1 = nil) or (s^.arr2 = nil) or (s^.ftab = nil) then begin
    if s^.arr1 <> nil then BZFREE(strm, s^.arr1);
    if s^.arr2 <> nil then BZFREE(strm, s^.arr2);
    if s^.ftab <> nil then BZFREE(strm, s^.ftab);
    BZFREE(strm, s);
    Result := BZ_MEM_ERROR; Exit;
  end;

  s^.blockNo       := 0;
  s^.state         := BZ_S_INPUT;
  s^.mode          := BZ_M_RUNNING;
  s^.combinedCRC   := 0;
  s^.blockSize100k := blockSize100k;
  s^.nblockMAX     := 100000 * blockSize100k - 19;
  s^.verbosity     := verbosity;
  s^.workFactor    := workFactor;

  s^.block  := PUChar(s^.arr2);
  s^.mtfv   := PUInt16(s^.arr1);
  s^.zbits  := nil;
  s^.ptr    := PUInt32(s^.arr1);

  strm^.state          := s;
  strm^.total_in_lo32  := 0;
  strm^.total_in_hi32  := 0;
  strm^.total_out_lo32 := 0;
  strm^.total_out_hi32 := 0;
  init_RL(s);
  prepare_new_block(s);
  Result := BZ_OK;
end;

// ---------------------------------------------------------------------------
// BZ2_bzCompressEnd  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzCompressEnd(strm: Pbz_stream): Int32;
var s: PEState;
begin
  if strm = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  s := PEState(strm^.state);
  if s = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  if s^.strm <> strm then begin Result := BZ_PARAM_ERROR; Exit; end;

  if s^.arr1 <> nil then BZFREE(strm, s^.arr1);
  if s^.arr2 <> nil then BZFREE(strm, s^.arr2);
  if s^.ftab <> nil then BZFREE(strm, s^.ftab);
  BZFREE(strm, strm^.state);
  strm^.state := nil;
  Result := BZ_OK;
end;

// ---------------------------------------------------------------------------
// BZ2_bzDecompressInit  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzDecompressInit(strm: Pbz_stream;
    verbosity, small: Int32): Int32;
var s: PDState;
begin
  if not bz_config_ok then begin Result := BZ_CONFIG_ERROR; Exit; end;

  if strm = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  if (small <> 0) and (small <> 1) then begin Result := BZ_PARAM_ERROR; Exit; end;
  if (verbosity < 0) or (verbosity > 4) then begin Result := BZ_PARAM_ERROR; Exit; end;

  if strm^.bzalloc = nil then strm^.bzalloc := @default_bzalloc;
  if strm^.bzfree  = nil then strm^.bzfree  := @default_bzfree;

  s := PDState(BZALLOC(strm, SizeOf(TDState)));
  if s = nil then begin Result := BZ_MEM_ERROR; Exit; end;

  s^.strm                  := strm;
  strm^.state              := s;
  s^.state                 := BZ_X_MAGIC_1;
  s^.bsLive                := 0;
  s^.bsBuff                := 0;
  s^.calculatedCombinedCRC := 0;
  strm^.total_in_lo32      := 0;
  strm^.total_in_hi32      := 0;
  strm^.total_out_lo32     := 0;
  strm^.total_out_hi32     := 0;
  s^.smallDecompress       := Bool(small);
  s^.ll4                   := nil;
  s^.ll16                  := nil;
  s^.tt                    := nil;
  s^.currBlockNo           := 0;
  s^.verbosity             := verbosity;
  Result := BZ_OK;
end;

// ---------------------------------------------------------------------------
// BZ2_bzDecompressEnd  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzDecompressEnd(strm: Pbz_stream): Int32;
var s: PDState;
begin
  if strm = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  s := PDState(strm^.state);
  if s = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  if s^.strm <> strm then begin Result := BZ_PARAM_ERROR; Exit; end;

  if s^.tt   <> nil then BZFREE(strm, s^.tt);
  if s^.ll16 <> nil then BZFREE(strm, s^.ll16);
  if s^.ll4  <> nil then BZFREE(strm, s^.ll4);
  BZFREE(strm, strm^.state);
  strm^.state := nil;
  Result := BZ_OK;
end;

// ---------------------------------------------------------------------------
// BZ2_bzlibVersion  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzlibVersion: PChar;
begin
  Result := BZ_VERSION_STR;
end;

end.
