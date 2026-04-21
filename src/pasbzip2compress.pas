{$I pasbzip2.inc}
unit pasbzip2compress;

{
  Pascal port of bzip2/libbzip2 1.1.0 — bit-stream writer.
  Mirrors the opening section of compress.c (lines 37–104):
    BZ2_bsInitWrite, bsFinishWrite, bsW, bsPutUInt32, bsPutUChar.

  All five are marked inline to match the C __inline__ annotation and to
  keep per-bit overhead negligible.
}

interface

uses
  pasbzip2types;

{ Initialise the bit-stream writer (zero buffer and live-bit count). }
procedure BZ2_bsInitWrite(s: PEState); inline;


{ Flush any remaining bits (padding with zeros to the next byte boundary)
  into zbits and advance numZ accordingly. }
procedure bsFinishWrite(s: PEState); inline;

{ Emit the low n bits of v into the compressed bit stream. }
procedure bsW(s: PEState; n: Int32; v: UInt32); inline;

{ Write a 32-bit value as four big-endian bytes via bsW. }
procedure bsPutUInt32(s: PEState; u: UInt32); inline;

{ Write a single byte via bsW. }
procedure bsPutUChar(s: PEState; c: UChar); inline;

procedure BZ2_compressBlock(s: PEState; is_last_block: Bool);

implementation

uses
  SysUtils,
  pasbzip2tables,
  pasbzip2huffman,
  pasbzip2blocksort;


// ---------------------------------------------------------------------------
// BZ2_bsInitWrite
// ---------------------------------------------------------------------------
procedure BZ2_bsInitWrite(s: PEState);
begin
  s^.bsLive := 0;
  s^.bsBuff := 0;
end;

// ---------------------------------------------------------------------------
// bsFinishWrite
// Drain any bits left in bsBuff to zbits, padding with zeros to byte
// boundary.  Mirrors the C loop exactly.
// ---------------------------------------------------------------------------
procedure bsFinishWrite(s: PEState);
begin
  while s^.bsLive > 0 do begin
    s^.zbits[s^.numZ] := UChar(s^.bsBuff shr 24);
    Inc(s^.numZ);
    s^.bsBuff := s^.bsBuff shl 8;
    Dec(s^.bsLive, 8);
  end;
end;

// ---------------------------------------------------------------------------
// bsW  (bsNEEDW inlined)
// Flush full bytes from the top of bsBuff while there are at least 8 live
// bits, then insert the low n bits of v.
// ---------------------------------------------------------------------------
procedure bsW(s: PEState; n: Int32; v: UInt32);
begin
  { bsNEEDW: flush complete bytes from the buffer }
  while s^.bsLive >= 8 do begin
    s^.zbits[s^.numZ] := UChar(s^.bsBuff shr 24);
    Inc(s^.numZ);
    s^.bsBuff := s^.bsBuff shl 8;
    Dec(s^.bsLive, 8);
  end;
  { deposit the low n bits of v into the high part of bsBuff }
  s^.bsBuff := s^.bsBuff or (v shl (32 - s^.bsLive - n));
  Inc(s^.bsLive, n);
end;

// ---------------------------------------------------------------------------
// bsPutUInt32
// ---------------------------------------------------------------------------
procedure bsPutUInt32(s: PEState; u: UInt32);
begin
  bsW(s, 8, (u shr 24) and $FF);
  bsW(s, 8, (u shr 16) and $FF);
  bsW(s, 8, (u shr  8) and $FF);
  bsW(s, 8,  u         and $FF);
end;

// ---------------------------------------------------------------------------
// bsPutUChar
// ---------------------------------------------------------------------------
procedure bsPutUChar(s: PEState; c: UChar);
begin
  bsW(s, 8, UInt32(c));
end;

// ---------------------------------------------------------------------------
// Local assertion helpers
// ---------------------------------------------------------------------------

procedure AssertH(cond: Bool; errcode: Int32); inline;
begin
  if cond = 0 then begin
    WriteLn(StdErr, 'bzip2: internal error number ', errcode, '.');
    Halt(3);
  end;
end;

procedure AssertD(cond: Bool; const msg: PChar); inline;
begin
  // debug-only assertion — no-op in release
end;

// ---------------------------------------------------------------------------
// makeMaps_e  (compress.c lines ~107-115)
// ---------------------------------------------------------------------------
procedure makeMaps_e(s: PEState);
var
  i: Int32;
begin
  s^.nInUse := 0;
  for i := 0 to 255 do
    if s^.inUse[i] <> 0 then begin
      s^.unseqToSeq[i] := UChar(s^.nInUse);
      Inc(s^.nInUse);
    end;
end;

// ---------------------------------------------------------------------------
// generateMTFNonMatch  — helper for generateMTFValues non-match branch
//
// Called when yy[0] != ll_i. Handles: flush of pending run-length codes
// (zPend), MTF array rotation, and emission of the MTF position symbol.
//
// Extracted into a separate (non-inline) procedure to reduce register
// pressure in the outer generateMTFValues loop.  With this code extracted,
// FPC's register allocator can assign ptr/block/mtfv to dedicated callee-
// saved registers (r12/r13/r14) in the outer loop instead of spilling them
// to the stack on every iteration.
//
// Parameters are chosen to fit in the 6 SysV integer argument registers
// (rdi, rsi, rdx, rcx, r8, r9) — same technique as mainGtU (Phase 11.6).
// ---------------------------------------------------------------------------
procedure generateMTFNonMatch(yy: PUChar; ll_i: UChar;
                              mtfv: PUInt16; mtfFreq: PInt32;
                              var wr: Int32; var zPend: Int32);
var
  rtmp, rtmp2 : UChar;
  ryy_j       : PUChar;
  j           : Int32;
begin
  if zPend > 0 then begin
    Dec(zPend);
    while True do begin
      if (zPend and 1) <> 0 then begin
        mtfv[wr] := BZ_RUNB; Inc(wr);
        Inc(mtfFreq[BZ_RUNB]);
      end else begin
        mtfv[wr] := BZ_RUNA; Inc(wr);
        Inc(mtfFreq[BZ_RUNA]);
      end;
      if zPend < 2 then Break;
      zPend := (zPend - 2) div 2;
    end;
    zPend := 0;
  end;

  rtmp  := yy[1];
  yy[1] := yy[0];
  ryy_j := yy + 1;
  while ll_i <> rtmp do begin
    Inc(ryy_j);
    rtmp2  := rtmp;
    rtmp   := ryy_j^;
    ryy_j^ := rtmp2;
  end;
  yy[0] := rtmp;
  j := ryy_j - yy;
  mtfv[wr] := UInt16(j + 1); Inc(wr);
  Inc(mtfFreq[j + 1]);
end;

// ---------------------------------------------------------------------------
// generateMTFValues  (compress.c lines ~119-231)
//
// Phase 11.7 optimisation: when compiled with -dAVX2, the implementation is
// provided by hand-written x86-64 assembly in pasbzip2generatemtf.s.
// That version keeps ptr/block/mtfv/unseqToSeq in dedicated callee-saved
// registers (rbx, r12, r13, r14, r15) throughout the hot loop, eliminating
// 4+ stack spill/reload per iteration caused by FPC's register allocator.
// Without AVX2 (generic build), the Pascal version below is used instead.
// ---------------------------------------------------------------------------
{$IFDEF AVX2}

// Link the pre-assembled object; the symbol matches FPC's name mangling.
{$L pasbzip2generatemtf.o}
procedure generateMTFValues(s: PEState);
  external name 'PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE';

{$ELSE}

// Pascal fallback for non-AVX2 builds.
// Uses the same generateMTFNonMatch helper to keep the outer loop compact.
procedure generateMTFValues(s: PEState);
var
  yy         : array[0..255] of UChar;
  i          : Int32;
  zPend      : Int32;
  wr         : Int32;
  EOB        : Int32;
  nblock     : Int32;
  ptr        : PUInt32;
  block      : PUChar;
  mtfv       : PUInt16;
  mtfFreq    : PInt32;
  unseqToSeq : PUChar;
  ll_i       : UChar;
  j          : Int32;
begin
  FillChar(yy, SizeOf(yy), 0);
  ptr        := s^.ptr;
  block      := s^.block;
  mtfv       := s^.mtfv;
  unseqToSeq := @s^.unseqToSeq[0];
  mtfFreq    := @s^.mtfFreq[0];
  nblock     := s^.nblock;

  makeMaps_e(s);
  EOB := s^.nInUse + 1;

  for i := 0 to EOB do mtfFreq[i] := 0;

  wr    := 0;
  zPend := 0;
  for i := 0 to s^.nInUse - 1 do yy[i] := UChar(i);

  for i := 0 to nblock - 1 do begin
    AssertD(Bool(Ord(wr <= i)), 'generateMTFValues(1)');
    j := Int32(ptr[i]) - 1;
    if j < 0 then j += nblock;
    ll_i := unseqToSeq[block[j]];
    AssertD(Bool(Ord(ll_i < s^.nInUse)), 'generateMTFValues(2a)');

    if yy[0] = ll_i then
      Inc(zPend)
    else
      generateMTFNonMatch(@yy[0], ll_i, mtfv, mtfFreq, wr, zPend);
  end;

  if zPend > 0 then begin
    Dec(zPend);
    while True do begin
      if (zPend and 1) <> 0 then begin
        mtfv[wr] := BZ_RUNB; Inc(wr);
        Inc(mtfFreq[BZ_RUNB]);
      end else begin
        mtfv[wr] := BZ_RUNA; Inc(wr);
        Inc(mtfFreq[BZ_RUNA]);
      end;
      if zPend < 2 then Break;
      zPend := (zPend - 2) div 2;
    end;
  end;

  mtfv[wr] := UInt16(EOB); Inc(wr);
  Inc(mtfFreq[EOB]);

  s^.nMTF := wr;
end;

{$ENDIF AVX2}

// ---------------------------------------------------------------------------
// computeGroupCosts6  — fast-track cost accumulation for sendMTFValues
//
// Accumulates packed costs for 50 MTF symbols when nGroups=6.
// Extracted from sendMTFValues as a separate (non-inline) function so FPC
// gives it its own register frame: mtfv_gs in rdi, len_pack in rsi,
// cost01/cost23/cost45 in three callee-saved registers (rbx, r12, r13).
// Eliminates ~300 stack spills/reloads per group that occur in the
// monolithic sendMTFValues frame.
// ---------------------------------------------------------------------------
procedure computeGroupCosts6(mtfv_gs: PUInt16; len_pack: PUInt32;
                              var cost01, cost23, cost45: UInt32);
{ NOT inline — own register frame essential for performance }
var
  c01, c23, c45: UInt32;
  icv: UInt32;
  base: PUInt32;
begin
  c01 := 0; c23 := 0; c45 := 0;
  { len_pack layout: len_pack[icv][0..2] at byte offset icv*16 }
  { Each len_pack[icv] entry is 3 UInt32 (indices 0,1,2) }
  icv := mtfv_gs[ 0]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 1]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 2]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 3]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 4]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 5]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 6]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 7]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 8]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[ 9]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[10]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[11]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[12]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[13]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[14]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[15]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[16]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[17]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[18]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[19]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[20]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[21]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[22]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[23]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[24]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[25]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[26]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[27]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[28]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[29]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[30]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[31]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[32]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[33]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[34]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[35]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[36]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[37]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[38]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[39]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[40]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[41]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[42]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[43]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[44]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[45]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[46]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[47]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[48]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  icv := mtfv_gs[49]; base := len_pack + icv * 4; c01 += base[0]; c23 += base[1]; c45 += base[2];
  cost01 := c01;
  cost23 := c23;
  cost45 := c45;
end;

// ---------------------------------------------------------------------------
// accumGroupFreqs6  — fast-track frequency accumulation for sendMTFValues
//
// Increments rfreq[0..alphaSize-1] for 50 MTF symbols when nGroups=6.
// Extracted so FPC gives it its own register frame: mtfv_gs in rdi,
// rfreq_bt in rsi — the two hot pointers stay in dedicated registers
// throughout all 50 increments, eliminating ~200 stack reloads per group.
// ---------------------------------------------------------------------------
procedure accumGroupFreqs6(mtfv_gs: PUInt16; rfreq_bt: PInt32);
{ NOT inline — own register frame essential for performance }
begin
  Inc(rfreq_bt[mtfv_gs[ 0]]);
  Inc(rfreq_bt[mtfv_gs[ 1]]);
  Inc(rfreq_bt[mtfv_gs[ 2]]);
  Inc(rfreq_bt[mtfv_gs[ 3]]);
  Inc(rfreq_bt[mtfv_gs[ 4]]);
  Inc(rfreq_bt[mtfv_gs[ 5]]);
  Inc(rfreq_bt[mtfv_gs[ 6]]);
  Inc(rfreq_bt[mtfv_gs[ 7]]);
  Inc(rfreq_bt[mtfv_gs[ 8]]);
  Inc(rfreq_bt[mtfv_gs[ 9]]);
  Inc(rfreq_bt[mtfv_gs[10]]);
  Inc(rfreq_bt[mtfv_gs[11]]);
  Inc(rfreq_bt[mtfv_gs[12]]);
  Inc(rfreq_bt[mtfv_gs[13]]);
  Inc(rfreq_bt[mtfv_gs[14]]);
  Inc(rfreq_bt[mtfv_gs[15]]);
  Inc(rfreq_bt[mtfv_gs[16]]);
  Inc(rfreq_bt[mtfv_gs[17]]);
  Inc(rfreq_bt[mtfv_gs[18]]);
  Inc(rfreq_bt[mtfv_gs[19]]);
  Inc(rfreq_bt[mtfv_gs[20]]);
  Inc(rfreq_bt[mtfv_gs[21]]);
  Inc(rfreq_bt[mtfv_gs[22]]);
  Inc(rfreq_bt[mtfv_gs[23]]);
  Inc(rfreq_bt[mtfv_gs[24]]);
  Inc(rfreq_bt[mtfv_gs[25]]);
  Inc(rfreq_bt[mtfv_gs[26]]);
  Inc(rfreq_bt[mtfv_gs[27]]);
  Inc(rfreq_bt[mtfv_gs[28]]);
  Inc(rfreq_bt[mtfv_gs[29]]);
  Inc(rfreq_bt[mtfv_gs[30]]);
  Inc(rfreq_bt[mtfv_gs[31]]);
  Inc(rfreq_bt[mtfv_gs[32]]);
  Inc(rfreq_bt[mtfv_gs[33]]);
  Inc(rfreq_bt[mtfv_gs[34]]);
  Inc(rfreq_bt[mtfv_gs[35]]);
  Inc(rfreq_bt[mtfv_gs[36]]);
  Inc(rfreq_bt[mtfv_gs[37]]);
  Inc(rfreq_bt[mtfv_gs[38]]);
  Inc(rfreq_bt[mtfv_gs[39]]);
  Inc(rfreq_bt[mtfv_gs[40]]);
  Inc(rfreq_bt[mtfv_gs[41]]);
  Inc(rfreq_bt[mtfv_gs[42]]);
  Inc(rfreq_bt[mtfv_gs[43]]);
  Inc(rfreq_bt[mtfv_gs[44]]);
  Inc(rfreq_bt[mtfv_gs[45]]);
  Inc(rfreq_bt[mtfv_gs[46]]);
  Inc(rfreq_bt[mtfv_gs[47]]);
  Inc(rfreq_bt[mtfv_gs[48]]);
  Inc(rfreq_bt[mtfv_gs[49]]);
end;

// ---------------------------------------------------------------------------
// emitMTFGroupFast  — helper for the sendMTFValues hot path
//
// Emits exactly 50 Huffman-coded MTF symbols from mtfv[0..49].
// Extracted into a separate (non-inline) procedure so that FPC keeps the
// EState pointer in a callee register rather than spilling it to the stack
// inside the large sendMTFValues frame.
//
// Phase 11.5 optimisation: cache s^.bsBuff, s^.bsLive, s^.zbits, s^.numZ
// into locals for the entire 50-symbol emit.  bsW is expanded inline using
// the cached locals, eliminating ~200 s^ field reloads per group call.
// Locals are written back to s^ once at exit.
// ---------------------------------------------------------------------------
procedure emitMTFGroupFast(s: PEState; mtfv: PUInt16;
                           lenPtr: PUChar; codePtr: PInt32);
var
  j      : Int32;
  sym    : UInt16;
  n      : Int32;
  v      : UInt32;
  bsBuff : UInt32;
  bsLive : Int32;
  zbits  : PUChar;
  numZ   : Int32;
begin
  { Load hot fields once — FPC keeps these locals in registers }
  bsBuff := s^.bsBuff;
  bsLive := s^.bsLive;
  zbits  := s^.zbits;
  numZ   := s^.numZ;

  for j := 0 to 49 do begin
    sym := mtfv[j];
    n   := lenPtr[sym];
    v   := UInt32(codePtr[sym]);
    { bsW expanded inline with cached locals }
    while bsLive >= 8 do begin
      zbits[numZ] := UChar(bsBuff shr 24);
      Inc(numZ);
      bsBuff := bsBuff shl 8;
      Dec(bsLive, 8);
    end;
    bsBuff := bsBuff or (v shl (32 - bsLive - n));
    Inc(bsLive, n);
  end;

  { Write-back — zbits base pointer is stable, no write-back needed for it }
  s^.bsBuff := bsBuff;
  s^.bsLive := bsLive;
  s^.numZ   := numZ;
end;

// ---------------------------------------------------------------------------
// sendMTFValues  (compress.c lines ~234-597)
// ---------------------------------------------------------------------------
procedure sendMTFValues(s: PEState);
const
  BZ_LESSER_ICOST  = 0;
  BZ_GREATER_ICOST = 15;
var
  v, t, i, j, gs, ge, totc, bt, bc, iter : Int32;
  nSelectors, alphaSize, minLen, maxLen, selCtr : Int32;
  nGroups, nBytes : Int32;
  cost  : array[0..BZ_N_GROUPS - 1] of UInt16;
  fave  : array[0..BZ_N_GROUPS - 1] of Int32;
  mtfv  : PUInt16;
  // fast-path cost accumulators
  cost01, cost23, cost45 : UInt32;
  icv   : UInt16;
  // selector MTF
  pos   : array[0..BZ_N_GROUPS - 1] of UChar;
  ll_i, tmp2, tmp : UChar;
  // inUse16
  inUse16 : array[0..15] of Bool;
  // initial groups
  nPart, remF, tFreq, aFreq : Int32;
begin
  mtfv := s^.mtfv;
  FillChar(cost, SizeOf(cost), 0);
  FillChar(fave, SizeOf(fave), 0);
  FillChar(pos,  SizeOf(pos),  0);

  if s^.verbosity >= 3 then
    WriteLn(StdErr, Format('      %d in block, %d after MTF & 1-2 coding, %d+2 syms in use',
      [s^.nblock, s^.nMTF, s^.nInUse]));

  alphaSize := s^.nInUse + 2;
  for t := 0 to BZ_N_GROUPS - 1 do
    for v := 0 to alphaSize - 1 do
      s^.len[t][v] := BZ_GREATER_ICOST;

  // Decide number of coding tables
  AssertH(Bool(Ord(s^.nMTF > 0)), 3001);
  if      s^.nMTF < 200  then nGroups := 2
  else if s^.nMTF < 600  then nGroups := 3
  else if s^.nMTF < 1200 then nGroups := 4
  else if s^.nMTF < 2400 then nGroups := 5
  else                         nGroups := 6;

  // Generate initial set of coding tables
  nPart := nGroups;
  remF  := s^.nMTF;
  gs    := 0;
  while nPart > 0 do begin
    tFreq := remF div nPart;
    ge    := gs - 1;
    aFreq := 0;
    while (aFreq < tFreq) and (ge < alphaSize - 1) do begin
      Inc(ge);
      Inc(aFreq, s^.mtfFreq[ge]);
    end;

    if (ge > gs)
       and (nPart <> nGroups) and (nPart <> 1)
       and (((nGroups - nPart) mod 2) = 1) then begin
      Dec(aFreq, s^.mtfFreq[ge]);
      Dec(ge);
    end;

    if s^.verbosity >= 3 then
      WriteLn(StdErr, Format('      initial group %d, [%d .. %d], has %d syms (%4.1f%%)',
        [nPart, gs, ge, aFreq, (100.0 * aFreq) / s^.nMTF]));

    for v := 0 to alphaSize - 1 do
      if (v >= gs) and (v <= ge) then
        s^.len[nPart - 1][v] := BZ_LESSER_ICOST
      else
        s^.len[nPart - 1][v] := BZ_GREATER_ICOST;

    Dec(nPart);
    gs   := ge + 1;
    Dec(remF, aFreq);
  end;

  // Iterate BZ_N_ITERS times to improve the tables
  for iter := 0 to BZ_N_ITERS - 1 do begin

    for t := 0 to nGroups - 1 do fave[t] := 0;
    for t := 0 to nGroups - 1 do
      for v := 0 to alphaSize - 1 do
        s^.rfreq[t][v] := 0;

    // Set up auxiliary length table for fast path (nGroups=6)
    if nGroups = 6 then begin
      for v := 0 to alphaSize - 1 do begin
        s^.len_pack[v][0] := (UInt32(s^.len[1][v]) shl 16) or s^.len[0][v];
        s^.len_pack[v][1] := (UInt32(s^.len[3][v]) shl 16) or s^.len[2][v];
        s^.len_pack[v][2] := (UInt32(s^.len[5][v]) shl 16) or s^.len[4][v];
      end;
    end;

    nSelectors := 0;
    totc := 0;
    gs   := 0;
    while True do begin
      if gs >= s^.nMTF then Break;
      ge := gs + BZ_G_SIZE - 1;
      if ge >= s^.nMTF then ge := s^.nMTF - 1;

      for t := 0 to nGroups - 1 do cost[t] := 0;

      if (nGroups = 6) and (50 = ge - gs + 1) then begin
        // fast track: nGroups=6, group size=50
        // Delegate to computeGroupCosts6 which gets its own register frame
        // (mtfv+gs in rdi, len_pack in rsi) — eliminates ~300 stack spills.
        computeGroupCosts6(mtfv + gs, @s^.len_pack[0][0],
                           cost01, cost23, cost45);
        cost[0] := UInt16(cost01 and $FFFF); cost[1] := UInt16(cost01 shr 16);
        cost[2] := UInt16(cost23 and $FFFF); cost[3] := UInt16(cost23 shr 16);
        cost[4] := UInt16(cost45 and $FFFF); cost[5] := UInt16(cost45 shr 16);

      end else begin
        // slow version
        for i := gs to ge do begin
          icv := mtfv[i];
          for t := 0 to nGroups - 1 do
            cost[t] += s^.len[t][icv];
        end;
      end;

      // Find best coding table for this group
      bc := 999999999; bt := -1;
      for t := 0 to nGroups - 1 do
        if cost[t] < bc then begin bc := cost[t]; bt := t; end;
      Inc(totc, bc);
      Inc(fave[bt]);
      s^.selector[nSelectors] := UChar(bt);
      Inc(nSelectors);

      // Accumulate symbol frequencies for the selected table
      if (nGroups = 6) and (50 = ge - gs + 1) then begin
        // fast track: delegate to accumGroupFreqs6 for its own register frame
        // (mtfv+gs in rdi, rfreq[bt] in rsi) — eliminates ~200 stack reloads.
        accumGroupFreqs6(mtfv + gs, @s^.rfreq[bt][0]);
      end else begin
        // slow version
        for i := gs to ge do
          Inc(s^.rfreq[bt][mtfv[i]]);
      end;

      gs := ge + 1;
    end; // while True (group loop)

    if s^.verbosity >= 3 then begin
      Write(StdErr, Format('      pass %d: size is %d, grp uses are ', [iter + 1, totc div 8]));
      for t := 0 to nGroups - 1 do
        Write(StdErr, Format('%d ', [fave[t]]));
      WriteLn(StdErr);
    end;

    // Recompute tables from accumulated frequencies
    for t := 0 to nGroups - 1 do
      BZ2_hbMakeCodeLengths(@s^.len[t][0], @s^.rfreq[t][0], alphaSize, 17);

  end; // for iter

  AssertH(Bool(Ord(nGroups < 8)), 3002);
  AssertH(Bool(Ord((nSelectors < 32768) and (nSelectors <= BZ_MAX_SELECTORS))), 3003);

  // Compute MTF values for the selectors
  for i := 0 to nGroups - 1 do pos[i] := UChar(i);
  for i := 0 to nSelectors - 1 do begin
    ll_i := s^.selector[i];
    j    := 0;
    tmp  := pos[j];
    while ll_i <> tmp do begin
      Inc(j);
      tmp2   := tmp;
      tmp    := pos[j];
      pos[j] := tmp2;
    end;
    pos[0]            := tmp;
    s^.selectorMtf[i] := UChar(j);
  end;

  // Assign actual codes for the tables
  for t := 0 to nGroups - 1 do begin
    minLen := 32;
    maxLen := 0;
    for i := 0 to alphaSize - 1 do begin
      if s^.len[t][i] > maxLen then maxLen := s^.len[t][i];
      if s^.len[t][i] < minLen then minLen := s^.len[t][i];
    end;
    AssertH(Bool(Ord(not (maxLen > 17))), 3004);
    AssertH(Bool(Ord(not (minLen < 1))),  3005);
    BZ2_hbAssignCodes(@s^.code[t][0], @s^.len[t][0], minLen, maxLen, alphaSize);
  end;

  // Transmit the mapping table
  for i := 0 to 15 do begin
    inUse16[i] := BZ_FALSE;
    for j := 0 to 15 do
      if s^.inUse[i * 16 + j] <> 0 then inUse16[i] := BZ_TRUE;
  end;

  nBytes := s^.numZ;
  for i := 0 to 15 do
    if inUse16[i] <> 0 then bsW(s, 1, 1) else bsW(s, 1, 0);
  for i := 0 to 15 do
    if inUse16[i] <> 0 then
      for j := 0 to 15 do
        if s^.inUse[i * 16 + j] <> 0 then bsW(s, 1, 1) else bsW(s, 1, 0);

  if s^.verbosity >= 3 then
    Write(StdErr, Format('      bytes: mapping %d, ', [s^.numZ - nBytes]));

  // Selectors
  nBytes := s^.numZ;
  bsW(s, 3, nGroups);
  bsW(s, 15, nSelectors);
  for i := 0 to nSelectors - 1 do begin
    for j := 0 to s^.selectorMtf[i] - 1 do bsW(s, 1, 1);
    bsW(s, 1, 0);
  end;
  if s^.verbosity >= 3 then
    Write(StdErr, Format('selectors %d, ', [s^.numZ - nBytes]));

  // Coding tables
  nBytes := s^.numZ;
  for t := 0 to nGroups - 1 do begin
    j := s^.len[t][0];  // curr
    bsW(s, 5, j);
    for i := 0 to alphaSize - 1 do begin
      while j < s^.len[t][i] do begin bsW(s, 2, 2); Inc(j); end;
      while j > s^.len[t][i] do begin bsW(s, 2, 3); Dec(j); end;
      bsW(s, 1, 0);
    end;
  end;

  if s^.verbosity >= 3 then
    Write(StdErr, Format('code lengths %d, ', [s^.numZ - nBytes]));

  // Block data proper
  nBytes  := s^.numZ;
  selCtr  := 0;
  gs      := 0;
  while True do begin
    if gs >= s^.nMTF then Break;
    ge := gs + BZ_G_SIZE - 1;
    if ge >= s^.nMTF then ge := s^.nMTF - 1;
    AssertH(Bool(Ord(s^.selector[selCtr] < nGroups)), 3006);

    if (nGroups = 6) and (50 = ge - gs + 1) then begin
      // fast track: delegate to emitMTFGroupFast to reduce register pressure
      emitMTFGroupFast(s, mtfv + gs,
                       @s^.len [s^.selector[selCtr]][0],
                       @s^.code[s^.selector[selCtr]][0]);

    end else begin
      // slow version
      for i := gs to ge do
        bsW(s, s^.len[s^.selector[selCtr]][mtfv[i]],
               UInt32(s^.code[s^.selector[selCtr]][mtfv[i]]));
    end;

    gs := ge + 1;
    Inc(selCtr);
  end; // while True (block data loop)

  AssertH(Bool(Ord(selCtr = nSelectors)), 3007);

  if s^.verbosity >= 3 then
    WriteLn(StdErr, Format('codes %d', [s^.numZ - nBytes]));
end;

// ---------------------------------------------------------------------------
// BZ2_compressBlock  (compress.c lines ~600-666)
// ---------------------------------------------------------------------------
procedure BZ2_compressBlock(s: PEState; is_last_block: Bool);
begin
  if s^.nblock > 0 then begin
    BZ_FINALISE_CRC(s^.blockCRC);
    s^.combinedCRC := (s^.combinedCRC shl 1) or (s^.combinedCRC shr 31);
    s^.combinedCRC := s^.combinedCRC xor s^.blockCRC;
    if s^.blockNo > 1 then s^.numZ := 0;

    if s^.verbosity >= 2 then
      WriteLn(StdErr, Format('    block %d: crc = 0x%08x, combined CRC = 0x%08x, size = %d',
        [s^.blockNo, s^.blockCRC, s^.combinedCRC, s^.nblock]));

    BZ2_blockSort(s);
  end;

  s^.zbits := PUChar(s^.arr2) + s^.nblock;

  // First block: create stream header
  if s^.blockNo = 1 then begin
    BZ2_bsInitWrite(s);
    bsPutUChar(s, BZ_HDR_B);
    bsPutUChar(s, BZ_HDR_Z);
    bsPutUChar(s, BZ_HDR_h);
    bsPutUChar(s, UChar(BZ_HDR_0 + s^.blockSize100k));
  end;

  if s^.nblock > 0 then begin
    // Block magic
    bsPutUChar(s, $31); bsPutUChar(s, $41);
    bsPutUChar(s, $59); bsPutUChar(s, $26);
    bsPutUChar(s, $53); bsPutUChar(s, $59);

    // Block CRC
    bsPutUInt32(s, s^.blockCRC);

    // Randomised bit — always 0 (no randomisation since 0.9.5)
    bsW(s, 1, 0);

    // origPtr (24 bits)
    bsW(s, 24, UInt32(s^.origPtr));

    generateMTFValues(s);
    sendMTFValues(s);
  end;

  // Last block: stream trailer
  if is_last_block <> 0 then begin
    bsPutUChar(s, $17); bsPutUChar(s, $72);
    bsPutUChar(s, $45); bsPutUChar(s, $38);
    bsPutUChar(s, $50); bsPutUChar(s, $90);
    bsPutUInt32(s, s^.combinedCRC);
    if s^.verbosity >= 2 then
      WriteLn(StdErr, Format('    final combined CRC = 0x%08x', [s^.combinedCRC]));
    bsFinishWrite(s);
  end;
end;

end.
