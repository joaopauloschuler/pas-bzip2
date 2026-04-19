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
// Compression / decompression streaming
// ---------------------------------------------------------------------------
function BZ2_bzCompress(strm: Pbz_stream; action: Int32): Int32;
function BZ2_bzDecompress(strm: Pbz_stream): Int32;

// ---------------------------------------------------------------------------
// Buffer-to-buffer convenience wrappers
// ---------------------------------------------------------------------------
function BZ2_bzBuffToBuffCompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    blockSize100k, verbosity, workFactor: Int32): Int32;
function BZ2_bzBuffToBuffDecompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    small, verbosity: Int32): Int32;

// ---------------------------------------------------------------------------
// Version query
// ---------------------------------------------------------------------------
function BZ2_bzlibVersion: PChar;

implementation

uses
  pasbzip2tables,      // BZ_INITIALISE_CRC
  pasbzip2compress,    // BZ2_bsInitWrite, bsFinishWrite, BZ2_compressBlock
  pasbzip2decompress;  // BZ2_decompress, unRLE_obuf_to_output_FAST/SMALL

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
// isempty_RL  (bzlib.c)
// ---------------------------------------------------------------------------
function isempty_RL(s: PEState): Bool; inline;
begin
  if (s^.state_in_ch < 256) and (s^.state_in_len > 0) then
    Result := BZ_FALSE
  else
    Result := BZ_TRUE;
end;

// ---------------------------------------------------------------------------
// add_pair_to_block  (bzlib.c)
// ---------------------------------------------------------------------------
procedure add_pair_to_block(s: PEState);
var
  i: Int32;
  ch: UChar;
begin
  ch := UChar(s^.state_in_ch);
  for i := 0 to s^.state_in_len - 1 do
    BZ_UPDATE_CRC(s^.blockCRC, ch);
  s^.inUse[s^.state_in_ch] := BZ_TRUE;
  case s^.state_in_len of
    1: begin
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
       end;
    2: begin
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
       end;
    3: begin
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
         s^.block[s^.nblock] := ch; Inc(s^.nblock);
       end;
  else
    s^.inUse[s^.state_in_len - 4] := BZ_TRUE;
    s^.block[s^.nblock] := ch; Inc(s^.nblock);
    s^.block[s^.nblock] := ch; Inc(s^.nblock);
    s^.block[s^.nblock] := ch; Inc(s^.nblock);
    s^.block[s^.nblock] := ch; Inc(s^.nblock);
    s^.block[s^.nblock] := UChar(s^.state_in_len - 4); Inc(s^.nblock);
  end;
end;

// ---------------------------------------------------------------------------
// flush_RL  (bzlib.c)
// ---------------------------------------------------------------------------
procedure flush_RL(s: PEState); inline;
begin
  if s^.state_in_ch < 256 then add_pair_to_block(s);
  init_RL(s);
end;

// ---------------------------------------------------------------------------
// add_char_to_block  — inline equivalent of ADD_CHAR_TO_BLOCK macro
// ---------------------------------------------------------------------------
procedure add_char_to_block(s: PEState; zchh: UInt32); inline;
begin
  { fast track: different char with run length 1 }
  if (zchh <> s^.state_in_ch) and (s^.state_in_len = 1) then
  begin
    BZ_UPDATE_CRC(s^.blockCRC, UChar(s^.state_in_ch));
    s^.inUse[s^.state_in_ch] := BZ_TRUE;
    s^.block[s^.nblock] := UChar(s^.state_in_ch);
    Inc(s^.nblock);
    s^.state_in_ch := zchh;
  end
  else
  { general: different char or run length maxed out }
  if (zchh <> s^.state_in_ch) or (s^.state_in_len = 255) then
  begin
    if s^.state_in_ch < 256 then add_pair_to_block(s);
    s^.state_in_ch  := zchh;
    s^.state_in_len := 1;
  end
  else
    Inc(s^.state_in_len);
end;

// ---------------------------------------------------------------------------
// copy_input_until_stop  (bzlib.c)
// ---------------------------------------------------------------------------
function copy_input_until_stop(s: PEState): Bool;
var
  progress_in: Bool;
begin
  progress_in := BZ_FALSE;
  if s^.mode = BZ_M_RUNNING then
  begin
    while True do
    begin
      if s^.nblock >= s^.nblockMAX then break;
      if s^.strm^.avail_in = 0 then break;
      progress_in := BZ_TRUE;
      add_char_to_block(s, UInt32(PUChar(s^.strm^.next_in)^));
      Inc(s^.strm^.next_in);
      Dec(s^.strm^.avail_in);
      Inc(s^.strm^.total_in_lo32);
      if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
    end;
  end
  else
  begin
    while True do
    begin
      if s^.nblock >= s^.nblockMAX then break;
      if s^.strm^.avail_in = 0 then break;
      if s^.avail_in_expect = 0 then break;
      progress_in := BZ_TRUE;
      add_char_to_block(s, UInt32(PUChar(s^.strm^.next_in)^));
      Inc(s^.strm^.next_in);
      Dec(s^.strm^.avail_in);
      Inc(s^.strm^.total_in_lo32);
      if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
      Dec(s^.avail_in_expect);
    end;
  end;
  Result := progress_in;
end;

// ---------------------------------------------------------------------------
// copy_output_until_stop  (bzlib.c)
// ---------------------------------------------------------------------------
function copy_output_until_stop(s: PEState): Bool;
var
  progress_out: Bool;
begin
  progress_out := BZ_FALSE;
  while True do
  begin
    if s^.strm^.avail_out = 0 then break;
    if s^.state_out_pos >= s^.numZ then break;
    progress_out := BZ_TRUE;
    s^.strm^.next_out^ := Char(s^.zbits[s^.state_out_pos]);
    Inc(s^.state_out_pos);
    Dec(s^.strm^.avail_out);
    Inc(s^.strm^.next_out);
    Inc(s^.strm^.total_out_lo32);
    if s^.strm^.total_out_lo32 = 0 then Inc(s^.strm^.total_out_hi32);
  end;
  Result := progress_out;
end;

// ---------------------------------------------------------------------------
// handle_compress  (bzlib.c)
// ---------------------------------------------------------------------------
function handle_compress(strm: Pbz_stream): Bool;
var
  progress_in:  Bool;
  progress_out: Bool;
  s: PEState;
begin
  progress_in  := BZ_FALSE;
  progress_out := BZ_FALSE;
  s := PEState(strm^.state);
  while True do
  begin
    if s^.state = BZ_S_OUTPUT then
    begin
      if copy_output_until_stop(s) = BZ_TRUE then progress_out := BZ_TRUE;
      if s^.state_out_pos < s^.numZ then break;
      if (s^.mode = BZ_M_FINISHING) and
         (s^.avail_in_expect = 0) and
         (isempty_RL(s) = BZ_TRUE) then break;
      prepare_new_block(s);
      s^.state := BZ_S_INPUT;
      if (s^.mode = BZ_M_FLUSHING) and
         (s^.avail_in_expect = 0) and
         (isempty_RL(s) = BZ_TRUE) then break;
    end;
    if s^.state = BZ_S_INPUT then
    begin
      if copy_input_until_stop(s) = BZ_TRUE then progress_in := BZ_TRUE;
      if (s^.mode <> BZ_M_RUNNING) and (s^.avail_in_expect = 0) then
      begin
        flush_RL(s);
        BZ2_compressBlock(s, Bool(Ord(s^.mode = BZ_M_FINISHING)));
        s^.state := BZ_S_OUTPUT;
      end
      else if s^.nblock >= s^.nblockMAX then
      begin
        BZ2_compressBlock(s, BZ_FALSE);
        s^.state := BZ_S_OUTPUT;
      end
      else if s^.strm^.avail_in = 0 then
        break;
    end;
  end;
  if (progress_in = BZ_TRUE) or (progress_out = BZ_TRUE) then
    Result := BZ_TRUE
  else
    Result := BZ_FALSE;
end;

// ---------------------------------------------------------------------------
// BZ2_bzCompress  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzCompress(strm: Pbz_stream; action: Int32): Int32;
var
  progress: Bool;
  s: PEState;
label
  preswitch;
begin
  if strm = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  s := PEState(strm^.state);
  if s = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  if s^.strm <> strm then begin Result := BZ_PARAM_ERROR; Exit; end;

  preswitch:
  case s^.mode of
    BZ_M_IDLE:
      begin
        Result := BZ_SEQUENCE_ERROR; Exit;
      end;
    BZ_M_RUNNING:
      begin
        if action = BZ_RUN then
        begin
          progress := handle_compress(strm);
          if progress = BZ_TRUE then Result := BZ_RUN_OK else Result := BZ_PARAM_ERROR;
          Exit;
        end
        else if action = BZ_FLUSH then
        begin
          s^.avail_in_expect := strm^.avail_in;
          s^.mode := BZ_M_FLUSHING;
          goto preswitch;
        end
        else if action = BZ_FINISH then
        begin
          s^.avail_in_expect := strm^.avail_in;
          s^.mode := BZ_M_FINISHING;
          goto preswitch;
        end
        else
        begin
          Result := BZ_PARAM_ERROR; Exit;
        end;
      end;
    BZ_M_FLUSHING:
      begin
        if action <> BZ_FLUSH then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
        if s^.avail_in_expect <> strm^.avail_in then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
        progress := handle_compress(strm);
        if (s^.avail_in_expect > 0) or (isempty_RL(s) = BZ_FALSE) or
           (s^.state_out_pos < s^.numZ) then
        begin
          Result := BZ_FLUSH_OK; Exit;
        end;
        s^.mode := BZ_M_RUNNING;
        Result := BZ_RUN_OK; Exit;
      end;
    BZ_M_FINISHING:
      begin
        if action <> BZ_FINISH then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
        if s^.avail_in_expect <> strm^.avail_in then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
        progress := handle_compress(strm);
        if progress = BZ_FALSE then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
        if (s^.avail_in_expect > 0) or (isempty_RL(s) = BZ_FALSE) or
           (s^.state_out_pos < s^.numZ) then
        begin
          Result := BZ_FINISH_OK; Exit;
        end;
        s^.mode := BZ_M_IDLE;
        Result := BZ_STREAM_END; Exit;
      end;
  end;
  Result := BZ_OK; { not reached }
end;

// ---------------------------------------------------------------------------
// BZ2_bzDecompress  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzDecompress(strm: Pbz_stream): Int32;
var
  corrupt: Bool;
  s: PDState;
  r: Int32;
begin
  if strm = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  s := PDState(strm^.state);
  if s = nil then begin Result := BZ_PARAM_ERROR; Exit; end;
  if s^.strm <> strm then begin Result := BZ_PARAM_ERROR; Exit; end;

  while True do
  begin
    if s^.state = BZ_X_IDLE then begin Result := BZ_SEQUENCE_ERROR; Exit; end;
    if s^.state = BZ_X_OUTPUT then
    begin
      if s^.smallDecompress = BZ_TRUE then
        corrupt := unRLE_obuf_to_output_SMALL(s)
      else
        corrupt := unRLE_obuf_to_output_FAST(s);
      if corrupt = BZ_TRUE then begin Result := BZ_DATA_ERROR; Exit; end;
      if (s^.nblock_used = s^.save_nblock + 1) and (s^.state_out_len = 0) then
      begin
        BZ_FINALISE_CRC(s^.calculatedBlockCRC);
        if s^.calculatedBlockCRC <> s^.storedBlockCRC then
        begin
          Result := BZ_DATA_ERROR; Exit;
        end;
        s^.calculatedCombinedCRC :=
          (s^.calculatedCombinedCRC shl 1) or
          (s^.calculatedCombinedCRC shr 31);
        s^.calculatedCombinedCRC := s^.calculatedCombinedCRC xor s^.calculatedBlockCRC;
        s^.state := BZ_X_BLKHDR_1;
      end
      else
      begin
        Result := BZ_OK; Exit;
      end;
    end;
    if s^.state >= BZ_X_MAGIC_1 then
    begin
      r := BZ2_decompress(s);
      if r = BZ_STREAM_END then
      begin
        if s^.calculatedCombinedCRC <> s^.storedCombinedCRC then
        begin
          Result := BZ_DATA_ERROR; Exit;
        end;
        Result := r; Exit;
      end;
      if s^.state <> BZ_X_OUTPUT then begin Result := r; Exit; end;
    end;
  end;
  Result := BZ_OK; { not reached }
end;

// ---------------------------------------------------------------------------
// BZ2_bzBuffToBuffCompress  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzBuffToBuffCompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    blockSize100k, verbosity, workFactor: Int32): Int32;
var
  strm: Tbz_stream;
  ret: Int32;
begin
  if (dest = nil) or (destLen = nil) or (source = nil) or
     (blockSize100k < 1) or (blockSize100k > 9) or
     (verbosity < 0) or (verbosity > 4) or
     (workFactor < 0) or (workFactor > 250) then
  begin
    Result := BZ_PARAM_ERROR; Exit;
  end;
  if workFactor = 0 then workFactor := 30;
  FillChar(strm, SizeOf(strm), 0);
  ret := BZ2_bzCompressInit(@strm, blockSize100k, verbosity, workFactor);
  if ret <> BZ_OK then begin Result := ret; Exit; end;

  strm.next_in   := source;
  strm.next_out  := dest;
  strm.avail_in  := sourceLen;
  strm.avail_out := destLen^;

  ret := BZ2_bzCompress(@strm, BZ_FINISH);
  if ret = BZ_FINISH_OK then
  begin
    BZ2_bzCompressEnd(@strm);
    Result := BZ_OUTBUFF_FULL; Exit;
  end;
  if ret <> BZ_STREAM_END then
  begin
    BZ2_bzCompressEnd(@strm);
    Result := ret; Exit;
  end;
  destLen^ := destLen^ - strm.avail_out;
  BZ2_bzCompressEnd(@strm);
  Result := BZ_OK;
end;

// ---------------------------------------------------------------------------
// BZ2_bzBuffToBuffDecompress  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzBuffToBuffDecompress(dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    small, verbosity: Int32): Int32;
var
  strm: Tbz_stream;
  ret: Int32;
begin
  if (dest = nil) or (destLen = nil) or (source = nil) or
     ((small <> 0) and (small <> 1)) or
     (verbosity < 0) or (verbosity > 4) then
  begin
    Result := BZ_PARAM_ERROR; Exit;
  end;
  FillChar(strm, SizeOf(strm), 0);
  ret := BZ2_bzDecompressInit(@strm, verbosity, small);
  if ret <> BZ_OK then begin Result := ret; Exit; end;

  strm.next_in   := source;
  strm.next_out  := dest;
  strm.avail_in  := sourceLen;
  strm.avail_out := destLen^;

  ret := BZ2_bzDecompress(@strm);
  if ret = BZ_OK then
  begin
    if strm.avail_out > 0 then
    begin
      BZ2_bzDecompressEnd(@strm);
      Result := BZ_UNEXPECTED_EOF; Exit;
    end
    else
    begin
      BZ2_bzDecompressEnd(@strm);
      Result := BZ_OUTBUFF_FULL; Exit;
    end;
  end;
  if ret <> BZ_STREAM_END then
  begin
    BZ2_bzDecompressEnd(@strm);
    Result := ret; Exit;
  end;
  destLen^ := destLen^ - strm.avail_out;
  BZ2_bzDecompressEnd(@strm);
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
