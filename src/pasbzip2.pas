{$I pasbzip2.inc}
unit pasbzip2;

{
  Pascal port of bzip2/libbzip2 1.1.0 — public API and stream management.
  Mirrors bzlib.c: default_bzalloc/bzfree, AssertH fail, BZ2_bzCompressInit/
  End, BZ2_bzDecompressInit/End, BZ2_bzlibVersion, and all stdio wrappers.
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

// ---------------------------------------------------------------------------
// stdio wrappers — Task 7.4
// In Pascal, the C FILE* is replaced by a THandle (raw OS file descriptor).
// BZFILE is an opaque Pointer that actually points to a heap-allocated TbzFile.
// ---------------------------------------------------------------------------
const
  BZ_MAX_UNUSED = 5000;

type
  BZFILE = Pointer;

  PbzFile = ^TbzFile;
  TbzFile = record
    handle        : THandle;
    buf           : array[0..BZ_MAX_UNUSED - 1] of UChar;
    bufN          : Int32;
    writing       : Bool;
    strm          : Tbz_stream;
    lastErr       : Int32;
    initialisedOk : Bool;
    // EOF / error flags replacing C's ferror() / myfeof()
    atEof         : Bool;
    hasIOErr      : Bool;
  end;

function  BZ2_bzWriteOpen(bzerror: PInt32; f: THandle;
              blockSize100k, verbosity, workFactor: Int32): BZFILE;
procedure BZ2_bzWrite(bzerror: PInt32; b: BZFILE; buf: Pointer; len: Int32);
procedure BZ2_bzWriteClose(bzerror: PInt32; b: BZFILE; abandon: Int32;
              nbytes_in, nbytes_out: PUInt32);
procedure BZ2_bzWriteClose64(bzerror: PInt32; b: BZFILE; abandon: Int32;
              nbytes_in_lo32, nbytes_in_hi32,
              nbytes_out_lo32, nbytes_out_hi32: PUInt32);
function  BZ2_bzReadOpen(bzerror: PInt32; f: THandle;
              verbosity, small: Int32;
              unused: Pointer; nUnused: Int32): BZFILE;
procedure BZ2_bzReadClose(bzerror: PInt32; b: BZFILE);
function  BZ2_bzRead(bzerror: PInt32; b: BZFILE;
              buf: Pointer; len: Int32): Int32;
procedure BZ2_bzReadGetUnused(bzerror: PInt32; b: BZFILE;
              unused: PPointer; nUnused: PInt32);

// ---------------------------------------------------------------------------
// zlib-compat helpers — Task 7.5
// ---------------------------------------------------------------------------
function  BZ2_bzopen(path: PChar; mode: PChar): BZFILE;
function  BZ2_bzdopen(fd: Int32; mode: PChar): BZFILE;
function  BZ2_bzread(b: BZFILE; buf: Pointer; len: Int32): Int32;
function  BZ2_bzwrite(b: BZFILE; buf: Pointer; len: Int32): Int32;
function  BZ2_bzflush(b: BZFILE): Int32;
procedure BZ2_bzclose(b: BZFILE);
function  BZ2_bzerror(b: BZFILE; errnum: PInt32): PChar;

implementation

uses
  BaseUnix,
  Unix,
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

// ===========================================================================
// Internal helpers for stdio wrappers
// ===========================================================================

{ BZ_SETERR — mirrors the C macro: set *bzerror and bzf^.lastErr }
procedure BzSetErr(bzerror: PInt32; bzf: PbzFile; eee: Int32); inline;
begin
  if bzerror <> nil then bzerror^ := eee;
  if bzf <> nil then bzf^.lastErr := eee;
end;

// ---------------------------------------------------------------------------
// BZ2_bzWriteOpen  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzWriteOpen(bzerror: PInt32; f: THandle;
    blockSize100k, verbosity, workFactor: Int32): BZFILE;
var
  ret  : Int32;
  bzf  : PbzFile;
begin
  BzSetErr(bzerror, nil, BZ_OK);

  if (f < 0) or
     (blockSize100k < 1) or (blockSize100k > 9) or
     (workFactor < 0) or (workFactor > 250) or
     (verbosity < 0) or (verbosity > 4) then
  begin
    BzSetErr(bzerror, nil, BZ_PARAM_ERROR);
    Result := nil; Exit;
  end;

  bzf := GetMem(SizeOf(TbzFile));
  if bzf = nil then
  begin
    BzSetErr(bzerror, nil, BZ_MEM_ERROR);
    Result := nil; Exit;
  end;

  BzSetErr(bzerror, bzf, BZ_OK);
  bzf^.initialisedOk := BZ_FALSE;
  bzf^.bufN          := 0;
  bzf^.handle        := f;
  bzf^.writing       := BZ_TRUE;
  bzf^.atEof         := BZ_FALSE;
  bzf^.hasIOErr      := BZ_FALSE;
  bzf^.strm.bzalloc  := nil;
  bzf^.strm.bzfree   := nil;
  bzf^.strm.opaque   := nil;

  if workFactor = 0 then workFactor := 30;
  ret := BZ2_bzCompressInit(@bzf^.strm, blockSize100k, verbosity, workFactor);
  if ret <> BZ_OK then
  begin
    BzSetErr(bzerror, bzf, ret);
    FreeMem(bzf);
    Result := nil; Exit;
  end;

  bzf^.strm.avail_in := 0;
  bzf^.initialisedOk := BZ_TRUE;
  Result := bzf;
end;

// ---------------------------------------------------------------------------
// BZ2_bzWrite  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzWrite(bzerror: PInt32; b: BZFILE; buf: Pointer; len: Int32);
var
  n, n2, ret : Int32;
  bzf         : PbzFile;
begin
  bzf := PbzFile(b);
  BzSetErr(bzerror, bzf, BZ_OK);

  if (bzf = nil) or (buf = nil) or (len < 0) then
  begin BzSetErr(bzerror, bzf, BZ_PARAM_ERROR); Exit; end;
  if bzf^.writing = BZ_FALSE then
  begin BzSetErr(bzerror, bzf, BZ_SEQUENCE_ERROR); Exit; end;
  if bzf^.hasIOErr = BZ_TRUE then
  begin BzSetErr(bzerror, bzf, BZ_IO_ERROR); Exit; end;
  if len = 0 then
  begin BzSetErr(bzerror, bzf, BZ_OK); Exit; end;

  bzf^.strm.avail_in := len;
  bzf^.strm.next_in  := PChar(buf);

  while True do
  begin
    bzf^.strm.avail_out := BZ_MAX_UNUSED;
    bzf^.strm.next_out  := PChar(@bzf^.buf[0]);
    ret := BZ2_bzCompress(@bzf^.strm, BZ_RUN);
    if ret <> BZ_RUN_OK then
    begin BzSetErr(bzerror, bzf, ret); Exit; end;

    if bzf^.strm.avail_out < BZ_MAX_UNUSED then
    begin
      n  := BZ_MAX_UNUSED - Int32(bzf^.strm.avail_out);
      n2 := FpWrite(bzf^.handle, bzf^.buf[0], n);
      if n2 <> n then
      begin
        bzf^.hasIOErr := BZ_TRUE;
        BzSetErr(bzerror, bzf, BZ_IO_ERROR); Exit;
      end;
    end;

    if bzf^.strm.avail_in = 0 then
    begin BzSetErr(bzerror, bzf, BZ_OK); Exit; end;
  end;
end;

// ---------------------------------------------------------------------------
// BZ2_bzWriteClose  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzWriteClose(bzerror: PInt32; b: BZFILE; abandon: Int32;
    nbytes_in, nbytes_out: PUInt32);
begin
  BZ2_bzWriteClose64(bzerror, b, abandon,
      nbytes_in, nil, nbytes_out, nil);
end;

// ---------------------------------------------------------------------------
// BZ2_bzWriteClose64  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzWriteClose64(bzerror: PInt32; b: BZFILE; abandon: Int32;
    nbytes_in_lo32, nbytes_in_hi32,
    nbytes_out_lo32, nbytes_out_hi32: PUInt32);
var
  n, n2, ret : Int32;
  bzf         : PbzFile;
begin
  bzf := PbzFile(b);

  if bzf = nil then begin BzSetErr(bzerror, nil, BZ_OK); Exit; end;
  if bzf^.writing = BZ_FALSE then
  begin BzSetErr(bzerror, bzf, BZ_SEQUENCE_ERROR); Exit; end;
  if bzf^.hasIOErr = BZ_TRUE then
  begin BzSetErr(bzerror, bzf, BZ_IO_ERROR); Exit; end;

  if nbytes_in_lo32  <> nil then nbytes_in_lo32^  := 0;
  if nbytes_in_hi32  <> nil then nbytes_in_hi32^  := 0;
  if nbytes_out_lo32 <> nil then nbytes_out_lo32^ := 0;
  if nbytes_out_hi32 <> nil then nbytes_out_hi32^ := 0;

  if (abandon = 0) and (bzf^.lastErr = BZ_OK) then
  begin
    while True do
    begin
      bzf^.strm.avail_out := BZ_MAX_UNUSED;
      bzf^.strm.next_out  := PChar(@bzf^.buf[0]);
      ret := BZ2_bzCompress(@bzf^.strm, BZ_FINISH);
      if (ret <> BZ_FINISH_OK) and (ret <> BZ_STREAM_END) then
      begin BzSetErr(bzerror, bzf, ret); Exit; end;

      if bzf^.strm.avail_out < BZ_MAX_UNUSED then
      begin
        n  := BZ_MAX_UNUSED - Int32(bzf^.strm.avail_out);
        n2 := FpWrite(bzf^.handle, bzf^.buf[0], n);
        if n2 <> n then
        begin
          bzf^.hasIOErr := BZ_TRUE;
          BzSetErr(bzerror, bzf, BZ_IO_ERROR); Exit;
        end;
      end;

      if ret = BZ_STREAM_END then Break;
    end;
  end;

  // Raw fd: no buffered data to flush; skip fflush equivalent.

  if nbytes_in_lo32  <> nil then nbytes_in_lo32^  := bzf^.strm.total_in_lo32;
  if nbytes_in_hi32  <> nil then nbytes_in_hi32^  := bzf^.strm.total_in_hi32;
  if nbytes_out_lo32 <> nil then nbytes_out_lo32^ := bzf^.strm.total_out_lo32;
  if nbytes_out_hi32 <> nil then nbytes_out_hi32^ := bzf^.strm.total_out_hi32;

  BzSetErr(bzerror, bzf, BZ_OK);
  BZ2_bzCompressEnd(@bzf^.strm);
  FreeMem(bzf);
end;

// ---------------------------------------------------------------------------
// BZ2_bzReadOpen  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzReadOpen(bzerror: PInt32; f: THandle;
    verbosity, small: Int32;
    unused: Pointer; nUnused: Int32): BZFILE;
var
  bzf : PbzFile;
  ret : Int32;
  i   : Int32;
  src : PUChar;
begin
  BzSetErr(bzerror, nil, BZ_OK);

  if (f < 0) or
     ((small <> 0) and (small <> 1)) or
     (verbosity < 0) or (verbosity > 4) or
     ((unused = nil) and (nUnused <> 0)) or
     ((unused <> nil) and ((nUnused < 0) or (nUnused > BZ_MAX_UNUSED))) then
  begin
    BzSetErr(bzerror, nil, BZ_PARAM_ERROR);
    Result := nil; Exit;
  end;

  bzf := GetMem(SizeOf(TbzFile));
  if bzf = nil then
  begin
    BzSetErr(bzerror, nil, BZ_MEM_ERROR);
    Result := nil; Exit;
  end;

  BzSetErr(bzerror, bzf, BZ_OK);
  bzf^.initialisedOk := BZ_FALSE;
  bzf^.handle        := f;
  bzf^.bufN          := 0;
  bzf^.writing       := BZ_FALSE;
  bzf^.atEof         := BZ_FALSE;
  bzf^.hasIOErr      := BZ_FALSE;
  bzf^.strm.bzalloc  := nil;
  bzf^.strm.bzfree   := nil;
  bzf^.strm.opaque   := nil;

  // pre-load any caller-supplied unused bytes
  src := PUChar(unused);
  for i := 0 to nUnused - 1 do
  begin
    bzf^.buf[bzf^.bufN] := src^;
    Inc(src);
    Inc(bzf^.bufN);
  end;

  ret := BZ2_bzDecompressInit(@bzf^.strm, verbosity, small);
  if ret <> BZ_OK then
  begin
    BzSetErr(bzerror, bzf, ret);
    FreeMem(bzf);
    Result := nil; Exit;
  end;

  bzf^.strm.avail_in := bzf^.bufN;
  bzf^.strm.next_in  := PChar(@bzf^.buf[0]);

  bzf^.initialisedOk := BZ_TRUE;
  Result := bzf;
end;

// ---------------------------------------------------------------------------
// BZ2_bzReadClose  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzReadClose(bzerror: PInt32; b: BZFILE);
var
  bzf : PbzFile;
begin
  bzf := PbzFile(b);
  BzSetErr(bzerror, bzf, BZ_OK);

  if bzf = nil then begin BzSetErr(bzerror, nil, BZ_OK); Exit; end;
  if bzf^.writing = BZ_TRUE then
  begin BzSetErr(bzerror, bzf, BZ_SEQUENCE_ERROR); Exit; end;

  if bzf^.initialisedOk = BZ_TRUE then
    BZ2_bzDecompressEnd(@bzf^.strm);
  FreeMem(bzf);
end;

// ---------------------------------------------------------------------------
// BZ2_bzRead  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzRead(bzerror: PInt32; b: BZFILE;
    buf: Pointer; len: Int32): Int32;
var
  n, ret : Int32;
  bzf     : PbzFile;
begin
  bzf := PbzFile(b);
  BzSetErr(bzerror, bzf, BZ_OK);

  if (bzf = nil) or (buf = nil) or (len < 0) then
  begin BzSetErr(bzerror, bzf, BZ_PARAM_ERROR); Result := 0; Exit; end;
  if bzf^.writing = BZ_TRUE then
  begin BzSetErr(bzerror, bzf, BZ_SEQUENCE_ERROR); Result := 0; Exit; end;
  if len = 0 then
  begin BzSetErr(bzerror, bzf, BZ_OK); Result := 0; Exit; end;

  bzf^.strm.avail_out := len;
  bzf^.strm.next_out  := PChar(buf);

  while True do
  begin
    if bzf^.hasIOErr = BZ_TRUE then
    begin BzSetErr(bzerror, bzf, BZ_IO_ERROR); Result := 0; Exit; end;

    if (bzf^.strm.avail_in = 0) and (bzf^.atEof = BZ_FALSE) then
    begin
      n := FpRead(bzf^.handle, bzf^.buf[0], BZ_MAX_UNUSED);
      if n < 0 then
      begin
        bzf^.hasIOErr := BZ_TRUE;
        BzSetErr(bzerror, bzf, BZ_IO_ERROR); Result := 0; Exit;
      end;
      if n = 0 then
        bzf^.atEof := BZ_TRUE
      else
      begin
        bzf^.bufN          := n;
        bzf^.strm.avail_in := n;
        bzf^.strm.next_in  := PChar(@bzf^.buf[0]);
      end;
    end;

    ret := BZ2_bzDecompress(@bzf^.strm);
    if (ret <> BZ_OK) and (ret <> BZ_STREAM_END) then
    begin BzSetErr(bzerror, bzf, ret); Result := 0; Exit; end;

    if (ret = BZ_OK) and (bzf^.atEof = BZ_TRUE) and
       (bzf^.strm.avail_in = 0) and (bzf^.strm.avail_out > 0) then
    begin BzSetErr(bzerror, bzf, BZ_UNEXPECTED_EOF); Result := 0; Exit; end;

    if ret = BZ_STREAM_END then
    begin
      BzSetErr(bzerror, bzf, BZ_STREAM_END);
      Result := len - Int32(bzf^.strm.avail_out); Exit;
    end;
    if bzf^.strm.avail_out = 0 then
    begin BzSetErr(bzerror, bzf, BZ_OK); Result := len; Exit; end;
  end;

  Result := 0; // not reached
end;

// ---------------------------------------------------------------------------
// BZ2_bzReadGetUnused  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzReadGetUnused(bzerror: PInt32; b: BZFILE;
    unused: PPointer; nUnused: PInt32);
var
  bzf : PbzFile;
begin
  bzf := PbzFile(b);
  if bzf = nil then begin BzSetErr(bzerror, nil, BZ_PARAM_ERROR); Exit; end;
  if bzf^.lastErr <> BZ_STREAM_END then
  begin BzSetErr(bzerror, bzf, BZ_SEQUENCE_ERROR); Exit; end;
  if (unused = nil) or (nUnused = nil) then
  begin BzSetErr(bzerror, bzf, BZ_PARAM_ERROR); Exit; end;

  BzSetErr(bzerror, bzf, BZ_OK);
  nUnused^ := bzf^.strm.avail_in;
  unused^  := bzf^.strm.next_in;
end;

// ===========================================================================
// zlib-compat helpers — Task 7.5
// ===========================================================================

{ Error string table mirroring C's bzerrorstrings[] }
const
  BzErrorStrings : array[0..9] of PChar = (
    'OK',
    'SEQUENCE_ERROR',
    'PARAM_ERROR',
    'MEM_ERROR',
    'DATA_ERROR',
    'DATA_ERROR_MAGIC',
    'IO_ERROR',
    'UNEXPECTED_EOF',
    'OUTBUFF_FULL',
    'CONFIG_ERROR'
  );

{ Internal: open or attach — mirrors bzopen_or_bzdopen in bzlib.c }
function bzopen_or_bzdopen(path: PChar; fd: Int32;
    mode: PChar; open_mode: Int32): BZFILE;
var
  bzerr        : Int32;
  blockSize100k : Int32;
  writing       : Int32;
  verbosity     : Int32;
  workFactor    : Int32;
  smallMode     : Int32;
  nUnused       : Int32;
  fp            : THandle;
  bzfp          : BZFILE;
  p             : PChar;
  unused        : array[0..BZ_MAX_UNUSED - 1] of Char;
  flags         : Int32;
begin
  blockSize100k := 9;
  writing       := 0;
  verbosity     := 0;
  workFactor    := 30;
  smallMode     := 0;
  nUnused       := 0;
  fp            := -1;
  bzfp          := nil;

  if mode = nil then begin Result := nil; Exit; end;
  p := mode;
  while p^ <> #0 do
  begin
    case p^ of
      'r': writing := 0;
      'w': writing := 1;
      's': smallMode := 1;
      else
        if (p^ >= '1') and (p^ <= '9') then
          blockSize100k := Ord(p^) - BZ_HDR_0;
    end;
    Inc(p);
  end;

  if open_mode = 0 then
  begin
    // bzopen: open by path (or use stdin/stdout for empty path)
    if (path = nil) or (path^ = #0) then
    begin
      if writing <> 0 then fp := StdOutputHandle
      else fp := StdInputHandle;
    end
    else
    begin
      if writing <> 0 then
        flags := O_WRONLY or O_CREAT or O_TRUNC
      else
        flags := O_RDONLY;
      fp := fpOpen(path, flags, &644);
    end;
  end
  else
  begin
    // bzdopen: fd already provided
    fp := THandle(fd);
  end;

  if fp < 0 then begin Result := nil; Exit; end;

  if writing <> 0 then
  begin
    if blockSize100k < 1 then blockSize100k := 1;
    if blockSize100k > 9 then blockSize100k := 9;
    bzfp := BZ2_bzWriteOpen(@bzerr, fp, blockSize100k, verbosity, workFactor);
  end
  else
  begin
    bzfp := BZ2_bzReadOpen(@bzerr, fp, verbosity, smallMode, @unused[0], nUnused);
  end;

  if bzfp = nil then
  begin
    // close the fd only if we opened it ourselves
    if (open_mode = 0) and (fp <> StdInputHandle) and (fp <> StdOutputHandle) then
      fpClose(fp);
    Result := nil; Exit;
  end;
  Result := bzfp;
end;

// ---------------------------------------------------------------------------
// BZ2_bzopen  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzopen(path: PChar; mode: PChar): BZFILE;
begin
  Result := bzopen_or_bzdopen(path, -1, mode, 0);
end;

// ---------------------------------------------------------------------------
// BZ2_bzdopen  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzdopen(fd: Int32; mode: PChar): BZFILE;
begin
  Result := bzopen_or_bzdopen(nil, fd, mode, 1);
end;

// ---------------------------------------------------------------------------
// BZ2_bzread  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzread(b: BZFILE; buf: Pointer; len: Int32): Int32;
var
  bzerr  : Int32;
  nread  : Int32;
begin
  if PbzFile(b)^.lastErr = BZ_STREAM_END then begin Result := 0; Exit; end;
  nread := BZ2_bzRead(@bzerr, b, buf, len);
  if (bzerr = BZ_OK) or (bzerr = BZ_STREAM_END) then
    Result := nread
  else
    Result := -1;
end;

// ---------------------------------------------------------------------------
// BZ2_bzwrite  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzwrite(b: BZFILE; buf: Pointer; len: Int32): Int32;
var
  bzerr : Int32;
begin
  BZ2_bzWrite(@bzerr, b, buf, len);
  if bzerr = BZ_OK then Result := len
  else Result := -1;
end;

// ---------------------------------------------------------------------------
// BZ2_bzflush  (bzlib.c) — intentional no-op (matches the C source)
// ---------------------------------------------------------------------------
function BZ2_bzflush(b: BZFILE): Int32;
begin
  Result := 0;
end;

// ---------------------------------------------------------------------------
// BZ2_bzclose  (bzlib.c)
// ---------------------------------------------------------------------------
procedure BZ2_bzclose(b: BZFILE);
var
  bzerr : Int32;
  fp    : THandle;
begin
  if b = nil then Exit;
  fp := PbzFile(b)^.handle;
  if PbzFile(b)^.writing = BZ_TRUE then
  begin
    BZ2_bzWriteClose(@bzerr, b, 0, nil, nil);
    if bzerr <> BZ_OK then
      BZ2_bzWriteClose(nil, b, 1, nil, nil);
  end
  else
    BZ2_bzReadClose(@bzerr, b);
  if (fp <> StdInputHandle) and (fp <> StdOutputHandle) then
    fpClose(fp);
end;

// ---------------------------------------------------------------------------
// BZ2_bzerror  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_bzerror(b: BZFILE; errnum: PInt32): PChar;
var
  err : Int32;
begin
  err := PbzFile(b)^.lastErr;
  if err > 0 then err := 0;
  errnum^ := err;
  err := -err;
  if err > 9 then err := 0; // guard against unknown codes
  Result := BzErrorStrings[err];
end;

end.
