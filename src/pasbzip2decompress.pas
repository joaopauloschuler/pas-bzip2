{$I pasbzip2.inc}
unit pasbzip2decompress;

{
  Pascal port of bzip2/libbzip2 1.1.0 — decompression.
  Mirrors decompress.c (makeMaps_d, BZ2_decompress) plus the output helpers
  from bzlib.c (BZ2_indexIntoF, unRLE_obuf_to_output_FAST/SMALL).
}

interface

uses
  pasbzip2types;

procedure makeMaps_d(s: PDState);

function BZ2_indexIntoF(indx: Int32; cftab: PInt32): Int32; inline;

{ Returns True iff data corruption is detected. }
function unRLE_obuf_to_output_FAST(s: PDState): Bool;
function unRLE_obuf_to_output_SMALL(s: PDState): Bool;

function BZ2_decompress(s: PDState): Int32;

implementation

uses
  pasbzip2tables,
  pasbzip2huffman;

// ---------------------------------------------------------------------------
// Local assertion helper
// ---------------------------------------------------------------------------
procedure AssertH(cond: Bool; errcode: Int32); inline;
begin
  if cond = 0 then
  begin
    WriteLn(StdErr, 'bzip2: internal error number ', errcode, '.');
    Halt(3);
  end;
end;

// ---------------------------------------------------------------------------
// GET_LL / SET_LL helpers for the small-decompress path
// ---------------------------------------------------------------------------
function GET_LL4(s: PDState; i: UInt32): UInt32; inline;
begin
  Result := (UInt32(s^.ll4[i shr 1]) shr ((i shl 2) and 4)) and $F;
end;

function GET_LL(s: PDState; i: UInt32): UInt32; inline;
begin
  Result := UInt32(s^.ll16[i]) or (GET_LL4(s, i) shl 16);
end;

procedure SET_LL4(s: PDState; i: UInt32; n: UInt32); inline;
begin
  if (i and 1) = 0 then
    s^.ll4[i shr 1] := (s^.ll4[i shr 1] and $F0) or UChar(n and $F)
  else
    s^.ll4[i shr 1] := (s^.ll4[i shr 1] and $0F) or UChar((n and $F) shl 4);
end;

procedure SET_LL(s: PDState; i: UInt32; n: UInt32); inline;
begin
  s^.ll16[i] := UInt16(n and $FFFF);
  SET_LL4(s, i, n shr 16);
end;

// ---------------------------------------------------------------------------
// makeMaps_d  (decompress.c lines 26-34)
// ---------------------------------------------------------------------------
procedure makeMaps_d(s: PDState);
var
  i: Int32;
begin
  s^.nInUse := 0;
  for i := 0 to 255 do
    if s^.inUse[i] <> 0 then
    begin
      s^.seqToUnseq[s^.nInUse] := UChar(i);
      Inc(s^.nInUse);
    end;
end;

// ---------------------------------------------------------------------------
// BZ2_indexIntoF  (bzlib.c)
// ---------------------------------------------------------------------------
function BZ2_indexIntoF(indx: Int32; cftab: PInt32): Int32;
var
  nb, na, mid: Int32;
begin
  nb := 0;
  na := 256;
  repeat
    mid := (nb + na) shr 1;
    if indx >= cftab[mid] then nb := mid else na := mid;
  until na - nb = 1;
  Result := nb;
end;

// ---------------------------------------------------------------------------
// unRLE_obuf_to_output_FAST  (bzlib.c)
// Implements the slow-path structure for both randomised and non-randomised.
// Returns True iff data corruption is detected.
// ---------------------------------------------------------------------------
function unRLE_obuf_to_output_FAST(s: PDState): Bool;
var
  k1  : UChar;
  strm: Pbz_stream;  { cached — avoids double-deref in the hot output loop }
begin
  strm := s^.strm;
  if s^.blockRandomised <> 0 then
  begin
    { ---- randomised branch ---- }
    while True do
    begin
      { drain current run }
      while True do
      begin
        if strm^.avail_out = 0 then begin Result := BZ_FALSE; Exit; end;
        if s^.state_out_len = 0 then Break;
        PUChar(strm^.next_out)^ := s^.state_out_ch;
        BZ_UPDATE_CRC(s^.calculatedBlockCRC, s^.state_out_ch);
        Dec(s^.state_out_len);
        Inc(strm^.next_out);
        Dec(strm^.avail_out);
        Inc(strm^.total_out_lo32);
        if strm^.total_out_lo32 = 0 then Inc(strm^.total_out_hi32);
      end;

      if s^.nblock_used = s^.save_nblock + 1 then begin Result := BZ_FALSE; Exit; end;
      if s^.nblock_used > s^.save_nblock + 1 then begin Result := BZ_TRUE; Exit; end;

      s^.state_out_len := 1;
      s^.state_out_ch  := s^.k0;

      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      { BZ_RAND_UPD_MASK; k1 ^= BZ_RAND_MASK }
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 2;
      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 3;
      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      s^.state_out_len := Int32(k1) + 4;

      { BZ_GET_FAST(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      s^.k0 := Int32(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then s^.k0 := s^.k0 xor 1;
      Inc(s^.nblock_used);
    end; { while True - randomised }
  end
  else
  begin
    { ---- non-randomised branch (slow-path structure) ---- }
    while True do
    begin
      { drain current run }
      while True do
      begin
        if strm^.avail_out = 0 then begin Result := BZ_FALSE; Exit; end;
        if s^.state_out_len = 0 then Break;
        PUChar(strm^.next_out)^ := s^.state_out_ch;
        BZ_UPDATE_CRC(s^.calculatedBlockCRC, s^.state_out_ch);
        Dec(s^.state_out_len);
        Inc(strm^.next_out);
        Dec(strm^.avail_out);
        Inc(strm^.total_out_lo32);
        if strm^.total_out_lo32 = 0 then Inc(strm^.total_out_hi32);
      end;

      if s^.nblock_used = s^.save_nblock + 1 then begin Result := BZ_FALSE; Exit; end;
      if s^.nblock_used > s^.save_nblock + 1 then begin Result := BZ_TRUE; Exit; end;

      s^.state_out_len := 1;
      s^.state_out_ch  := s^.k0;

      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 2;
      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 3;
      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      { BZ_GET_FAST(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      k1 := UChar(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
      s^.state_out_len := Int32(k1) + 4;

      { BZ_GET_FAST(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.tPos := s^.tt[s^.tPos];
      s^.k0 := Int32(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
    end; { while True - non-randomised }
  end;

  Result := BZ_FALSE;
end;

// ---------------------------------------------------------------------------
// unRLE_obuf_to_output_SMALL  (bzlib.c)
// ---------------------------------------------------------------------------
function unRLE_obuf_to_output_SMALL(s: PDState): Bool;
var
  k1  : UChar;
  strm: Pbz_stream;  { cached — avoids double-deref in the hot output loop }
begin
  strm := s^.strm;
  if s^.blockRandomised <> 0 then
  begin
    { ---- randomised branch ---- }
    while True do
    begin
      while True do
      begin
        if strm^.avail_out = 0 then begin Result := BZ_FALSE; Exit; end;
        if s^.state_out_len = 0 then Break;
        PUChar(strm^.next_out)^ := s^.state_out_ch;
        BZ_UPDATE_CRC(s^.calculatedBlockCRC, s^.state_out_ch);
        Dec(s^.state_out_len);
        Inc(strm^.next_out);
        Dec(strm^.avail_out);
        Inc(strm^.total_out_lo32);
        if strm^.total_out_lo32 = 0 then Inc(strm^.total_out_hi32);
      end;

      if s^.nblock_used = s^.save_nblock + 1 then begin Result := BZ_FALSE; Exit; end;
      if s^.nblock_used > s^.save_nblock + 1 then begin Result := BZ_TRUE; Exit; end;

      s^.state_out_len := 1;
      s^.state_out_ch  := s^.k0;

      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 2;
      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 3;
      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then k1 := k1 xor 1;
      Inc(s^.nblock_used);
      s^.state_out_len := Int32(k1) + 4;

      { BZ_GET_SMALL(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.k0 := BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]);
      s^.tPos := GET_LL(s, s^.tPos);
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then s^.k0 := s^.k0 xor 1;
      Inc(s^.nblock_used);
    end; { while True - randomised }
  end
  else
  begin
    { ---- non-randomised branch ---- }
    while True do
    begin
      while True do
      begin
        if strm^.avail_out = 0 then begin Result := BZ_FALSE; Exit; end;
        if s^.state_out_len = 0 then Break;
        PUChar(strm^.next_out)^ := s^.state_out_ch;
        BZ_UPDATE_CRC(s^.calculatedBlockCRC, s^.state_out_ch);
        Dec(s^.state_out_len);
        Inc(strm^.next_out);
        Dec(strm^.avail_out);
        Inc(strm^.total_out_lo32);
        if strm^.total_out_lo32 = 0 then Inc(strm^.total_out_hi32);
      end;

      if s^.nblock_used = s^.save_nblock + 1 then begin Result := BZ_FALSE; Exit; end;
      if s^.nblock_used > s^.save_nblock + 1 then begin Result := BZ_TRUE; Exit; end;

      s^.state_out_len := 1;
      s^.state_out_ch  := s^.k0;

      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 2;
      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      s^.state_out_len := 3;
      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
      if s^.nblock_used = s^.save_nblock + 1 then Continue;
      if k1 <> s^.k0 then begin s^.k0 := k1; Continue; end;

      { BZ_GET_SMALL(k1) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      k1 := UChar(BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]));
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
      s^.state_out_len := Int32(k1) + 4;

      { BZ_GET_SMALL(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then begin Result := BZ_TRUE; Exit; end;
      s^.k0 := BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]);
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
    end; { while True - non-randomised }
  end;

  Result := BZ_FALSE;
end;

// ---------------------------------------------------------------------------
// BZ2_decompress  (decompress.c)
//
// Duff's-device state machine ported via {$GOTO ON}.
// Each GET_BITS(lll,vvv,nnn) becomes a label L_lll plus an inner while loop.
// The dispatch case at the top jumps to the appropriate label on resume.
// ---------------------------------------------------------------------------
function BZ2_decompress(s: PDState): Int32;
label
  L_BZ_X_MAGIC_1,   L_BZ_X_MAGIC_2,   L_BZ_X_MAGIC_3,   L_BZ_X_MAGIC_4,
  L_BZ_X_BLKHDR_1,  L_BZ_X_BLKHDR_2,  L_BZ_X_BLKHDR_3,  L_BZ_X_BLKHDR_4,
  L_BZ_X_BLKHDR_5,  L_BZ_X_BLKHDR_6,
  L_BZ_X_BCRC_1,    L_BZ_X_BCRC_2,    L_BZ_X_BCRC_3,    L_BZ_X_BCRC_4,
  L_BZ_X_RANDBIT,
  L_BZ_X_ORIGPTR_1, L_BZ_X_ORIGPTR_2, L_BZ_X_ORIGPTR_3,
  L_BZ_X_MAPPING_1, L_BZ_X_MAPPING_2,
  L_BZ_X_SELECTOR_1, L_BZ_X_SELECTOR_2, L_BZ_X_SELECTOR_3,
  L_BZ_X_CODING_1,  L_BZ_X_CODING_2,  L_BZ_X_CODING_3,
  L_BZ_X_MTF_1,     L_BZ_X_MTF_2,
  L_BZ_X_MTF_3,     L_BZ_X_MTF_4,
  L_BZ_X_MTF_5,     L_BZ_X_MTF_6,
  L_BZ_X_ENDHDR_2,  L_BZ_X_ENDHDR_3,  L_BZ_X_ENDHDR_4,
  L_BZ_X_ENDHDR_5,  L_BZ_X_ENDHDR_6,
  L_BZ_X_CCRC_1,    L_BZ_X_CCRC_2,    L_BZ_X_CCRC_3,    L_BZ_X_CCRC_4,
  L_endhdr_2,
  save_state_and_return;
var
  uc        : UChar;
  retVal    : Int32;
  minLen    : Int32;
  maxLen    : Int32;
  { saved/restored scalars }
  i         : Int32;
  j         : Int32;
  t         : Int32;
  alphaSize : Int32;
  nGroups   : Int32;
  nSelectors: Int32;
  EOB       : Int32;
  groupNo   : Int32;
  groupPos  : Int32;
  nextSym   : Int32;
  nblockMAX : Int32;
  nblock    : Int32;
  es        : Int32;
  N         : Int32;
  curr      : Int32;
  zt        : Int32;
  zn        : Int32;
  zvec      : Int32;
  zj        : Int32;
  gSel      : Int32;
  gMinlen   : Int32;
  gLimit    : PInt32;
  gBase     : PInt32;
  gPerm     : PInt32;
  { MTF local variables }
  ii        : Int32;
  jj        : Int32;
  kk        : Int32;
  pp        : Int32;
  lno       : Int32;
  off       : Int32;
  nn        : UInt32;
  { selector MTF decode }
  pos       : array[0..BZ_N_GROUPS - 1] of UChar;
  sel_v     : UChar;
  sel_tmp   : UChar;
  { pointer-reversal temp }
  pr_tmp    : Int32;
begin
  { ---- Initialise save area on first call ---- }
  if s^.state = BZ_X_MAGIC_1 then
  begin
    s^.save_i          := 0;
    s^.save_j          := 0;
    s^.save_t          := 0;
    s^.save_alphaSize  := 0;
    s^.save_nGroups    := 0;
    s^.save_nSelectors := 0;
    s^.save_EOB        := 0;
    s^.save_groupNo    := 0;
    s^.save_groupPos   := 0;
    s^.save_nextSym    := 0;
    s^.save_nblockMAX  := 0;
    s^.save_nblock     := 0;
    s^.save_es         := 0;
    s^.save_N          := 0;
    s^.save_curr       := 0;
    s^.save_zt         := 0;
    s^.save_zn         := 0;
    s^.save_zvec       := 0;
    s^.save_zj         := 0;
    s^.save_gSel       := 0;
    s^.save_gMinlen    := 0;
    s^.save_gLimit     := nil;
    s^.save_gBase      := nil;
    s^.save_gPerm      := nil;
  end;

  { ---- Restore locals from save area ---- }
  i          := s^.save_i;
  j          := s^.save_j;
  t          := s^.save_t;
  alphaSize  := s^.save_alphaSize;
  nGroups    := s^.save_nGroups;
  nSelectors := s^.save_nSelectors;
  EOB        := s^.save_EOB;
  groupNo    := s^.save_groupNo;
  groupPos   := s^.save_groupPos;
  nextSym    := s^.save_nextSym;
  nblockMAX  := s^.save_nblockMAX;
  nblock     := s^.save_nblock;
  es         := s^.save_es;
  N          := s^.save_N;
  curr       := s^.save_curr;
  zt         := s^.save_zt;
  zn         := s^.save_zn;
  zvec       := s^.save_zvec;
  zj         := s^.save_zj;
  gSel       := s^.save_gSel;
  gMinlen    := s^.save_gMinlen;
  gLimit     := s^.save_gLimit;
  gBase      := s^.save_gBase;
  gPerm      := s^.save_gPerm;

  retVal := BZ_OK;

  { ---- Dispatch: jump to the label matching the current state ---- }
  case s^.state of
    BZ_X_MAGIC_1   : goto L_BZ_X_MAGIC_1;
    BZ_X_MAGIC_2   : goto L_BZ_X_MAGIC_2;
    BZ_X_MAGIC_3   : goto L_BZ_X_MAGIC_3;
    BZ_X_MAGIC_4   : goto L_BZ_X_MAGIC_4;
    BZ_X_BLKHDR_1  : goto L_BZ_X_BLKHDR_1;
    BZ_X_BLKHDR_2  : goto L_BZ_X_BLKHDR_2;
    BZ_X_BLKHDR_3  : goto L_BZ_X_BLKHDR_3;
    BZ_X_BLKHDR_4  : goto L_BZ_X_BLKHDR_4;
    BZ_X_BLKHDR_5  : goto L_BZ_X_BLKHDR_5;
    BZ_X_BLKHDR_6  : goto L_BZ_X_BLKHDR_6;
    BZ_X_BCRC_1    : goto L_BZ_X_BCRC_1;
    BZ_X_BCRC_2    : goto L_BZ_X_BCRC_2;
    BZ_X_BCRC_3    : goto L_BZ_X_BCRC_3;
    BZ_X_BCRC_4    : goto L_BZ_X_BCRC_4;
    BZ_X_RANDBIT   : goto L_BZ_X_RANDBIT;
    BZ_X_ORIGPTR_1 : goto L_BZ_X_ORIGPTR_1;
    BZ_X_ORIGPTR_2 : goto L_BZ_X_ORIGPTR_2;
    BZ_X_ORIGPTR_3 : goto L_BZ_X_ORIGPTR_3;
    BZ_X_MAPPING_1 : goto L_BZ_X_MAPPING_1;
    BZ_X_MAPPING_2 : goto L_BZ_X_MAPPING_2;
    BZ_X_SELECTOR_1: goto L_BZ_X_SELECTOR_1;
    BZ_X_SELECTOR_2: goto L_BZ_X_SELECTOR_2;
    BZ_X_SELECTOR_3: goto L_BZ_X_SELECTOR_3;
    BZ_X_CODING_1  : goto L_BZ_X_CODING_1;
    BZ_X_CODING_2  : goto L_BZ_X_CODING_2;
    BZ_X_CODING_3  : goto L_BZ_X_CODING_3;
    BZ_X_MTF_1     : goto L_BZ_X_MTF_1;
    BZ_X_MTF_2     : goto L_BZ_X_MTF_2;
    BZ_X_MTF_3     : goto L_BZ_X_MTF_3;
    BZ_X_MTF_4     : goto L_BZ_X_MTF_4;
    BZ_X_MTF_5     : goto L_BZ_X_MTF_5;
    BZ_X_MTF_6     : goto L_BZ_X_MTF_6;
    BZ_X_ENDHDR_2  : goto L_BZ_X_ENDHDR_2;
    BZ_X_ENDHDR_3  : goto L_BZ_X_ENDHDR_3;
    BZ_X_ENDHDR_4  : goto L_BZ_X_ENDHDR_4;
    BZ_X_ENDHDR_5  : goto L_BZ_X_ENDHDR_5;
    BZ_X_ENDHDR_6  : goto L_BZ_X_ENDHDR_6;
    BZ_X_CCRC_1    : goto L_BZ_X_CCRC_1;
    BZ_X_CCRC_2    : goto L_BZ_X_CCRC_2;
    BZ_X_CCRC_3    : goto L_BZ_X_CCRC_3;
    BZ_X_CCRC_4    : goto L_BZ_X_CCRC_4;
  else
    AssertH(BZ_FALSE, 4001);
  end;

  { ================================================================== }
  { GET_UCHAR(BZ_X_MAGIC_1, uc) }
  L_BZ_X_MAGIC_1:
  s^.state := BZ_X_MAGIC_1;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> BZ_HDR_B then begin retVal := BZ_DATA_ERROR_MAGIC; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_MAGIC_2, uc) }
  L_BZ_X_MAGIC_2:
  s^.state := BZ_X_MAGIC_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> BZ_HDR_Z then begin retVal := BZ_DATA_ERROR_MAGIC; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_MAGIC_3, uc) }
  L_BZ_X_MAGIC_3:
  s^.state := BZ_X_MAGIC_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> BZ_HDR_h then begin retVal := BZ_DATA_ERROR_MAGIC; goto save_state_and_return; end;

  { GET_BITS(BZ_X_MAGIC_4, s^.blockSize100k, 8) }
  L_BZ_X_MAGIC_4:
  s^.state := BZ_X_MAGIC_4;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      s^.blockSize100k := Int32((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if (s^.blockSize100k < (BZ_HDR_0 + 1)) or (s^.blockSize100k > (BZ_HDR_0 + 9)) then
    begin retVal := BZ_DATA_ERROR_MAGIC; goto save_state_and_return; end;
  Dec(s^.blockSize100k, BZ_HDR_0);

  if s^.smallDecompress <> 0 then
  begin
    s^.ll16 := PUInt16(s^.strm^.bzalloc(s^.strm^.opaque,
                 s^.blockSize100k * 100000 * SizeOf(UInt16), 1));
    s^.ll4  := PUChar(s^.strm^.bzalloc(s^.strm^.opaque,
                 ((1 + s^.blockSize100k * 100000) shr 1) * SizeOf(UChar), 1));
    if (s^.ll16 = nil) or (s^.ll4 = nil) then
      begin retVal := BZ_MEM_ERROR; goto save_state_and_return; end;
  end
  else
  begin
    s^.tt := PUInt32(s^.strm^.bzalloc(s^.strm^.opaque,
               s^.blockSize100k * 100000 * SizeOf(UInt32), 1));
    if s^.tt = nil then
      begin retVal := BZ_MEM_ERROR; goto save_state_and_return; end;
  end;

  { ---- block header loop: re-entered at BZ_X_BLKHDR_1 each new block ---- }

  { GET_UCHAR(BZ_X_BLKHDR_1, uc) }
  L_BZ_X_BLKHDR_1:
  s^.state := BZ_X_BLKHDR_1;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc = $17 then goto L_endhdr_2;
  if uc <> $31 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_BLKHDR_2, uc) }
  L_BZ_X_BLKHDR_2:
  s^.state := BZ_X_BLKHDR_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $41 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_BLKHDR_3, uc) }
  L_BZ_X_BLKHDR_3:
  s^.state := BZ_X_BLKHDR_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $59 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_BLKHDR_4, uc) }
  L_BZ_X_BLKHDR_4:
  s^.state := BZ_X_BLKHDR_4;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $26 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_BLKHDR_5, uc) }
  L_BZ_X_BLKHDR_5:
  s^.state := BZ_X_BLKHDR_5;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $53 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_UCHAR(BZ_X_BLKHDR_6, uc) }
  L_BZ_X_BLKHDR_6:
  s^.state := BZ_X_BLKHDR_6;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $59 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  Inc(s^.currBlockNo);

  { Assemble storedBlockCRC from 4 bytes }
  s^.storedBlockCRC := 0;

  { GET_UCHAR(BZ_X_BCRC_1, uc) }
  L_BZ_X_BCRC_1:
  s^.state := BZ_X_BCRC_1;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedBlockCRC := (s^.storedBlockCRC shl 8) or UInt32(uc);

  { GET_UCHAR(BZ_X_BCRC_2, uc) }
  L_BZ_X_BCRC_2:
  s^.state := BZ_X_BCRC_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedBlockCRC := (s^.storedBlockCRC shl 8) or UInt32(uc);

  { GET_UCHAR(BZ_X_BCRC_3, uc) }
  L_BZ_X_BCRC_3:
  s^.state := BZ_X_BCRC_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedBlockCRC := (s^.storedBlockCRC shl 8) or UInt32(uc);

  { GET_UCHAR(BZ_X_BCRC_4, uc) }
  L_BZ_X_BCRC_4:
  s^.state := BZ_X_BCRC_4;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedBlockCRC := (s^.storedBlockCRC shl 8) or UInt32(uc);

  { GET_BITS(BZ_X_RANDBIT, s^.blockRandomised, 1) }
  L_BZ_X_RANDBIT:
  s^.state := BZ_X_RANDBIT;
  while True do
  begin
    if s^.bsLive >= 1 then
    begin
      s^.blockRandomised := Bool((s^.bsBuff shr (s^.bsLive - 1)) and 1);
      Dec(s^.bsLive, 1);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;

  { Assemble origPtr from 3 bytes }
  s^.origPtr := 0;

  { GET_UCHAR(BZ_X_ORIGPTR_1, uc) }
  L_BZ_X_ORIGPTR_1:
  s^.state := BZ_X_ORIGPTR_1;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.origPtr := (s^.origPtr shl 8) or Int32(uc);

  { GET_UCHAR(BZ_X_ORIGPTR_2, uc) }
  L_BZ_X_ORIGPTR_2:
  s^.state := BZ_X_ORIGPTR_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.origPtr := (s^.origPtr shl 8) or Int32(uc);

  { GET_UCHAR(BZ_X_ORIGPTR_3, uc) }
  L_BZ_X_ORIGPTR_3:
  s^.state := BZ_X_ORIGPTR_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.origPtr := (s^.origPtr shl 8) or Int32(uc);

  if s^.origPtr < 0 then
    begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
  if s^.origPtr > 10 + 100000 * s^.blockSize100k then
    begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { ---- Receive the mapping table ---- }
  { for i = 0..15: GET_BIT(BZ_X_MAPPING_1, uc); inUse16[i] = (uc==1) }
  i := 0;
  while i < 16 do
  begin
    L_BZ_X_MAPPING_1:
    s^.state := BZ_X_MAPPING_1;
    while True do
    begin
      if s^.bsLive >= 1 then
      begin
        uc := UChar((s^.bsBuff shr (s^.bsLive - 1)) and 1);
        Dec(s^.bsLive, 1);
        Break;
      end;
      if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
      s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
      Inc(s^.bsLive, 8);
      Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
      Inc(s^.strm^.total_in_lo32);
      if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
    end;
    if uc = 1 then s^.inUse16[i] := BZ_TRUE else s^.inUse16[i] := BZ_FALSE;
    Inc(i);
  end;

  for i := 0 to 255 do s^.inUse[i] := BZ_FALSE;

  { for i=0..15: if inUse16[i]: for j=0..15: GET_BIT(BZ_X_MAPPING_2, uc) }
  i := 0;
  while i < 16 do
  begin
    if s^.inUse16[i] <> 0 then
    begin
      j := 0;
      while j < 16 do
      begin
        L_BZ_X_MAPPING_2:
        s^.state := BZ_X_MAPPING_2;
        while True do
        begin
          if s^.bsLive >= 1 then
          begin
            uc := UChar((s^.bsBuff shr (s^.bsLive - 1)) and 1);
            Dec(s^.bsLive, 1);
            Break;
          end;
          if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
          s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
          Inc(s^.bsLive, 8);
          Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
          Inc(s^.strm^.total_in_lo32);
          if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
        end;
        if uc = 1 then s^.inUse[i * 16 + j] := BZ_TRUE;
        Inc(j);
      end;
    end;
    Inc(i);
  end;

  makeMaps_d(s);
  if s^.nInUse = 0 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
  alphaSize := s^.nInUse + 2;

  { ---- Selectors ---- }

  { GET_BITS(BZ_X_SELECTOR_1, nGroups, 3) }
  L_BZ_X_SELECTOR_1:
  s^.state := BZ_X_SELECTOR_1;
  while True do
  begin
    if s^.bsLive >= 3 then
    begin
      nGroups := Int32((s^.bsBuff shr (s^.bsLive - 3)) and 7);
      Dec(s^.bsLive, 3);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if (nGroups < 2) or (nGroups > BZ_N_GROUPS) then
    begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { GET_BITS(BZ_X_SELECTOR_2, nSelectors, 15) }
  L_BZ_X_SELECTOR_2:
  s^.state := BZ_X_SELECTOR_2;
  while True do
  begin
    if s^.bsLive >= 15 then
    begin
      nSelectors := Int32((s^.bsBuff shr (s^.bsLive - 15)) and $7FFF);
      Dec(s^.bsLive, 15);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if nSelectors < 1 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { Receive selector MTF values }
  i := 0;
  while i < nSelectors do
  begin
    j := 0;
    while True do
    begin
      L_BZ_X_SELECTOR_3:
      s^.state := BZ_X_SELECTOR_3;
      while True do
      begin
        if s^.bsLive >= 1 then
        begin
          uc := UChar((s^.bsBuff shr (s^.bsLive - 1)) and 1);
          Dec(s^.bsLive, 1);
          Break;
        end;
        if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
        s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
        Inc(s^.bsLive, 8);
        Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
        Inc(s^.strm^.total_in_lo32);
        if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
      end;
      if uc = 0 then Break;
      Inc(j);
      if j >= nGroups then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
    end;
    if i < BZ_MAX_SELECTORS then s^.selectorMtf[i] := UChar(j);
    Inc(i);
  end;
  if nSelectors > BZ_MAX_SELECTORS then nSelectors := BZ_MAX_SELECTORS;

  { Undo MTF for selectors }
  for i := 0 to nGroups - 1 do pos[i] := UChar(i);
  for i := 0 to nSelectors - 1 do
  begin
    sel_v   := s^.selectorMtf[i];
    sel_tmp := pos[sel_v];
    while sel_v > 0 do
    begin
      pos[sel_v] := pos[sel_v - 1];
      Dec(sel_v);
    end;
    pos[0] := sel_tmp;
    s^.selector[i] := sel_tmp;
  end;

  { ---- Coding tables ---- }
  t := 0;
  while t < nGroups do
  begin
    { GET_BITS(BZ_X_CODING_1, curr, 5) }
    L_BZ_X_CODING_1:
    s^.state := BZ_X_CODING_1;
    while True do
    begin
      if s^.bsLive >= 5 then
      begin
        curr := Int32((s^.bsBuff shr (s^.bsLive - 5)) and $1F);
        Dec(s^.bsLive, 5);
        Break;
      end;
      if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
      s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
      Inc(s^.bsLive, 8);
      Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
      Inc(s^.strm^.total_in_lo32);
      if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
    end;
    i := 0;
    while i < alphaSize do
    begin
      while True do
      begin
        if (curr < 1) or (curr > 20) then
          begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
        { GET_BIT(BZ_X_CODING_2, uc) }
        L_BZ_X_CODING_2:
        s^.state := BZ_X_CODING_2;
        while True do
        begin
          if s^.bsLive >= 1 then
          begin
            uc := UChar((s^.bsBuff shr (s^.bsLive - 1)) and 1);
            Dec(s^.bsLive, 1);
            Break;
          end;
          if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
          s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
          Inc(s^.bsLive, 8);
          Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
          Inc(s^.strm^.total_in_lo32);
          if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
        end;
        if uc = 0 then Break;
        { GET_BIT(BZ_X_CODING_3, uc) }
        L_BZ_X_CODING_3:
        s^.state := BZ_X_CODING_3;
        while True do
        begin
          if s^.bsLive >= 1 then
          begin
            uc := UChar((s^.bsBuff shr (s^.bsLive - 1)) and 1);
            Dec(s^.bsLive, 1);
            Break;
          end;
          if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
          s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
          Inc(s^.bsLive, 8);
          Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
          Inc(s^.strm^.total_in_lo32);
          if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
        end;
        if uc = 0 then Inc(curr) else Dec(curr);
      end;
      s^.len[t][i] := UChar(curr);
      Inc(i);
    end;
    Inc(t);
  end;

  { ---- Create Huffman decode tables ---- }
  for t := 0 to nGroups - 1 do
  begin
    minLen := 32;
    maxLen := 0;
    for i := 0 to alphaSize - 1 do
    begin
      if s^.len[t][i] > UChar(maxLen) then maxLen := s^.len[t][i];
      if s^.len[t][i] < UChar(minLen) then minLen := s^.len[t][i];
    end;
    BZ2_hbCreateDecodeTables(
      @s^.limit[t][0], @s^.base[t][0], @s^.perm[t][0],
      @s^.len[t][0], minLen, maxLen, alphaSize);
    s^.minLens[t] := minLen;
  end;

  { ---- MTF decode ---- }
  EOB       := s^.nInUse + 1;
  nblockMAX := 100000 * s^.blockSize100k;
  groupNo   := -1;
  groupPos  := 0;

  for i := 0 to 255 do s^.unzftab[i] := 0;

  { MTF initialisation }
  kk := MTFA_SIZE - 1;
  ii := 256 div MTFL_SIZE - 1;
  while ii >= 0 do
  begin
    jj := MTFL_SIZE - 1;
    while jj >= 0 do
    begin
      s^.mtfa[kk] := UChar(ii * MTFL_SIZE + jj);
      Dec(kk);
      Dec(jj);
    end;
    s^.mtfbase[ii] := kk + 1;
    Dec(ii);
  end;

  nblock := 0;

  { GET_MTF_VAL(BZ_X_MTF_1, BZ_X_MTF_2, nextSym) }
  if groupPos = 0 then
  begin
    Inc(groupNo);
    if groupNo >= nSelectors then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
    groupPos := BZ_G_SIZE;
    gSel    := Int32(s^.selector[groupNo]);
    gMinlen := s^.minLens[gSel];
    gLimit  := @s^.limit[gSel][0];
    gPerm   := @s^.perm[gSel][0];
    gBase   := @s^.base[gSel][0];
  end;
  Dec(groupPos);
  zn := gMinlen;

  L_BZ_X_MTF_1:
  s^.state := BZ_X_MTF_1;
  while True do
  begin
    if s^.bsLive >= zn then
    begin
      zvec := Int32((s^.bsBuff shr (s^.bsLive - zn)) and ((1 shl zn) - 1));
      Dec(s^.bsLive, zn);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  while True do
  begin
    if zn > 20 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
    if zvec <= gLimit[zn] then Break;
    Inc(zn);
    L_BZ_X_MTF_2:
    s^.state := BZ_X_MTF_2;
    while True do
    begin
      if s^.bsLive >= 1 then
      begin
        zj := Int32((s^.bsBuff shr (s^.bsLive - 1)) and 1);
        Dec(s^.bsLive, 1);
        Break;
      end;
      if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
      s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
      Inc(s^.bsLive, 8);
      Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
      Inc(s^.strm^.total_in_lo32);
      if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
    end;
    zvec := (zvec shl 1) or zj;
  end;
  if (zvec - gBase[zn] < 0) or (zvec - gBase[zn] >= BZ_MAX_ALPHA_SIZE) then
    begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
  nextSym := gPerm[zvec - gBase[zn]];

  { ---- Main MTF symbol loop ---- }
  while True do
  begin
    if nextSym = EOB then Break;

    if (nextSym = BZ_RUNA) or (nextSym = BZ_RUNB) then
    begin
      es := -1;
      N  := 1;
      repeat
        if N >= 2 * 1024 * 1024 then
          begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
        if nextSym = BZ_RUNA then
          Inc(es, N)         { es = es + (0+1)*N }
        else
          Inc(es, 2 * N);    { es = es + (1+1)*N }
        N := N * 2;

        { GET_MTF_VAL(BZ_X_MTF_3, BZ_X_MTF_4, nextSym) }
        if groupPos = 0 then
        begin
          Inc(groupNo);
          if groupNo >= nSelectors then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
          groupPos := BZ_G_SIZE;
          gSel    := Int32(s^.selector[groupNo]);
          gMinlen := s^.minLens[gSel];
          gLimit  := @s^.limit[gSel][0];
          gPerm   := @s^.perm[gSel][0];
          gBase   := @s^.base[gSel][0];
        end;
        Dec(groupPos);
        zn := gMinlen;

        L_BZ_X_MTF_3:
        s^.state := BZ_X_MTF_3;
        while True do
        begin
          if s^.bsLive >= zn then
          begin
            zvec := Int32((s^.bsBuff shr (s^.bsLive - zn)) and ((1 shl zn) - 1));
            Dec(s^.bsLive, zn);
            Break;
          end;
          if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
          s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
          Inc(s^.bsLive, 8);
          Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
          Inc(s^.strm^.total_in_lo32);
          if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
        end;
        while True do
        begin
          if zn > 20 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
          if zvec <= gLimit[zn] then Break;
          Inc(zn);
          L_BZ_X_MTF_4:
          s^.state := BZ_X_MTF_4;
          while True do
          begin
            if s^.bsLive >= 1 then
            begin
              zj := Int32((s^.bsBuff shr (s^.bsLive - 1)) and 1);
              Dec(s^.bsLive, 1);
              Break;
            end;
            if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
            s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
            Inc(s^.bsLive, 8);
            Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
            Inc(s^.strm^.total_in_lo32);
            if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
          end;
          zvec := (zvec shl 1) or zj;
        end;
        if (zvec - gBase[zn] < 0) or (zvec - gBase[zn] >= BZ_MAX_ALPHA_SIZE) then
          begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
        nextSym := gPerm[zvec - gBase[zn]];
      until not ((nextSym = BZ_RUNA) or (nextSym = BZ_RUNB));

      Inc(es);
      uc := s^.seqToUnseq[s^.mtfa[s^.mtfbase[0]]];
      Inc(s^.unzftab[uc], es);

      if s^.smallDecompress <> 0 then
      begin
        while es > 0 do
        begin
          if nblock >= nblockMAX then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
          s^.ll16[nblock] := UInt16(uc);
          Inc(nblock);
          Dec(es);
        end;
      end
      else
      begin
        while es > 0 do
        begin
          if nblock >= nblockMAX then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
          s^.tt[nblock] := UInt32(uc);
          Inc(nblock);
          Dec(es);
        end;
      end;
      Continue;
    end
    else
    begin
      { nextSym >= 1 and not EOB: ordinary symbol }
      if nblock >= nblockMAX then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

      { uc = MTF(nextSym - 1) }
      nn := UInt32(nextSym - 1);
      if nn < MTFL_SIZE then
      begin
        pp := s^.mtfbase[0];
        uc := s^.mtfa[pp + Int32(nn)];
        while nn > 3 do
        begin
          kk := pp + Int32(nn);
          s^.mtfa[kk]     := s^.mtfa[kk - 1];
          s^.mtfa[kk - 1] := s^.mtfa[kk - 2];
          s^.mtfa[kk - 2] := s^.mtfa[kk - 3];
          s^.mtfa[kk - 3] := s^.mtfa[kk - 4];
          Dec(nn, 4);
        end;
        while nn > 0 do
        begin
          s^.mtfa[pp + Int32(nn)] := s^.mtfa[pp + Int32(nn) - 1];
          Dec(nn);
        end;
        s^.mtfa[pp] := uc;
      end
      else
      begin
        lno := Int32(nn) div MTFL_SIZE;
        off := Int32(nn) mod MTFL_SIZE;
        pp  := s^.mtfbase[lno] + off;
        uc  := s^.mtfa[pp];
        while pp > s^.mtfbase[lno] do
        begin
          s^.mtfa[pp] := s^.mtfa[pp - 1];
          Dec(pp);
        end;
        Inc(s^.mtfbase[lno]);
        while lno > 0 do
        begin
          Dec(s^.mtfbase[lno]);
          s^.mtfa[s^.mtfbase[lno]] := s^.mtfa[s^.mtfbase[lno - 1] + MTFL_SIZE - 1];
          Dec(lno);
        end;
        Dec(s^.mtfbase[0]);
        s^.mtfa[s^.mtfbase[0]] := uc;
        if s^.mtfbase[0] = 0 then
        begin
          kk := MTFA_SIZE - 1;
          ii := 256 div MTFL_SIZE - 1;
          while ii >= 0 do
          begin
            jj := MTFL_SIZE - 1;
            while jj >= 0 do
            begin
              s^.mtfa[kk] := s^.mtfa[s^.mtfbase[ii] + jj];
              Dec(kk);
              Dec(jj);
            end;
            s^.mtfbase[ii] := kk + 1;
            Dec(ii);
          end;
        end;
      end;

      Inc(s^.unzftab[s^.seqToUnseq[uc]]);
      if s^.smallDecompress <> 0 then
        s^.ll16[nblock] := UInt16(s^.seqToUnseq[uc])
      else
        s^.tt[nblock] := UInt32(s^.seqToUnseq[uc]);
      Inc(nblock);

      { GET_MTF_VAL(BZ_X_MTF_5, BZ_X_MTF_6, nextSym) }
      if groupPos = 0 then
      begin
        Inc(groupNo);
        if groupNo >= nSelectors then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
        groupPos := BZ_G_SIZE;
        gSel    := Int32(s^.selector[groupNo]);
        gMinlen := s^.minLens[gSel];
        gLimit  := @s^.limit[gSel][0];
        gPerm   := @s^.perm[gSel][0];
        gBase   := @s^.base[gSel][0];
      end;
      Dec(groupPos);
      zn := gMinlen;

      L_BZ_X_MTF_5:
      s^.state := BZ_X_MTF_5;
      while True do
      begin
        if s^.bsLive >= zn then
        begin
          zvec := Int32((s^.bsBuff shr (s^.bsLive - zn)) and ((1 shl zn) - 1));
          Dec(s^.bsLive, zn);
          Break;
        end;
        if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
        s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
        Inc(s^.bsLive, 8);
        Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
        Inc(s^.strm^.total_in_lo32);
        if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
      end;
      while True do
      begin
        if zn > 20 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
        if zvec <= gLimit[zn] then Break;
        Inc(zn);
        L_BZ_X_MTF_6:
        s^.state := BZ_X_MTF_6;
        while True do
        begin
          if s^.bsLive >= 1 then
          begin
            zj := Int32((s^.bsBuff shr (s^.bsLive - 1)) and 1);
            Dec(s^.bsLive, 1);
            Break;
          end;
          if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
          s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
          Inc(s^.bsLive, 8);
          Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
          Inc(s^.strm^.total_in_lo32);
          if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
        end;
        zvec := (zvec shl 1) or zj;
      end;
      if (zvec - gBase[zn] < 0) or (zvec - gBase[zn] >= BZ_MAX_ALPHA_SIZE) then
        begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
      nextSym := gPerm[zvec - gBase[zn]];
      Continue;
    end;
  end; { while True: main MTF symbol loop }

  { ---- Validate origPtr now that we know nblock ---- }
  if (s^.origPtr < 0) or (s^.origPtr >= nblock) then
    begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { ---- Validate and build cftab ---- }
  for i := 0 to 255 do
    if (s^.unzftab[i] < 0) or (s^.unzftab[i] > nblock) then
      begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  s^.cftab[0] := 0;
  for i := 1 to 256 do s^.cftab[i] := s^.unzftab[i - 1];
  for i := 1 to 256 do Inc(s^.cftab[i], s^.cftab[i - 1]);

  for i := 0 to 256 do
    if (s^.cftab[i] < 0) or (s^.cftab[i] > nblock) then
      begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
  for i := 1 to 256 do
    if s^.cftab[i - 1] > s^.cftab[i] then
      begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  s^.state_out_len := 0;
  s^.state_out_ch  := 0;
  BZ_INITIALISE_CRC(s^.calculatedBlockCRC);
  s^.state := BZ_X_OUTPUT;

  if s^.smallDecompress <> 0 then
  begin
    { Copy cftab }
    for i := 0 to 256 do s^.cftabCopy[i] := s^.cftab[i];

    { Compute T vector: SET_LL(i, cftabCopy[ll16[i]]) for each i }
    for i := 0 to nblock - 1 do
    begin
      uc := UChar(s^.ll16[i] and $FF);
      SET_LL(s, UInt32(i), UInt32(s^.cftabCopy[uc]));
      Inc(s^.cftabCopy[uc]);
    end;

    { Compute T^(-1) by pointer reversal on T }
    i := s^.origPtr;
    j := Int32(GET_LL(s, UInt32(i)));
    repeat
      pr_tmp := Int32(GET_LL(s, UInt32(j)));
      SET_LL(s, UInt32(j), UInt32(i));
      i := j;
      j := pr_tmp;
    until i = s^.origPtr;

    s^.tPos        := UInt32(s^.origPtr);
    s^.nblock_used := 0;

    if s^.blockRandomised <> 0 then
    begin
      s^.rNToGo := 0; s^.rTPos := 0;   { BZ_RAND_INIT_MASK }
      { BZ_GET_SMALL(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then
        begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
      s^.k0   := BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]);
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
      { BZ_RAND_UPD_MASK; k0 ^= BZ_RAND_MASK }
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then s^.k0 := s^.k0 xor 1;
    end
    else
    begin
      { BZ_GET_SMALL(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then
        begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
      s^.k0   := BZ2_indexIntoF(Int32(s^.tPos), @s^.cftab[0]);
      s^.tPos := GET_LL(s, s^.tPos);
      Inc(s^.nblock_used);
    end;
  end
  else
  begin
    { FAST path: compute T^(-1) inline }
    for i := 0 to nblock - 1 do
    begin
      uc := UChar(s^.tt[i] and $FF);
      s^.tt[s^.cftab[uc]] := s^.tt[s^.cftab[uc]] or (UInt32(i) shl 8);
      Inc(s^.cftab[uc]);
    end;
    s^.tPos        := s^.tt[s^.origPtr] shr 8;
    s^.nblock_used := 0;

    if s^.blockRandomised <> 0 then
    begin
      s^.rNToGo := 0; s^.rTPos := 0;   { BZ_RAND_INIT_MASK }
      { BZ_GET_FAST(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then
        begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
      s^.tPos := s^.tt[s^.tPos];
      s^.k0   := Int32(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
      { BZ_RAND_UPD_MASK; k0 ^= BZ_RAND_MASK }
      if s^.rNToGo = 0 then
      begin
        s^.rNToGo := BZ2_rNums[s^.rTPos];
        Inc(s^.rTPos);
        if s^.rTPos = 512 then s^.rTPos := 0;
      end;
      Dec(s^.rNToGo);
      if s^.rNToGo = 1 then s^.k0 := s^.k0 xor 1;
    end
    else
    begin
      { BZ_GET_FAST(s^.k0) }
      if s^.tPos >= UInt32(100000) * UInt32(s^.blockSize100k) then
        begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;
      s^.tPos := s^.tt[s^.tPos];
      s^.k0   := Int32(s^.tPos and $FF);
      s^.tPos := s^.tPos shr 8;
      Inc(s^.nblock_used);
    end;
  end;

  retVal := BZ_OK;
  goto save_state_and_return;

  { ---- End-of-stream header ---- }
  L_endhdr_2:
  L_BZ_X_ENDHDR_2:
  s^.state := BZ_X_ENDHDR_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $72 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  L_BZ_X_ENDHDR_3:
  s^.state := BZ_X_ENDHDR_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $45 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  L_BZ_X_ENDHDR_4:
  s^.state := BZ_X_ENDHDR_4;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $38 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  L_BZ_X_ENDHDR_5:
  s^.state := BZ_X_ENDHDR_5;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $50 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  L_BZ_X_ENDHDR_6:
  s^.state := BZ_X_ENDHDR_6;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  if uc <> $90 then begin retVal := BZ_DATA_ERROR; goto save_state_and_return; end;

  { Assemble storedCombinedCRC from 4 bytes }
  s^.storedCombinedCRC := 0;

  L_BZ_X_CCRC_1:
  s^.state := BZ_X_CCRC_1;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedCombinedCRC := (s^.storedCombinedCRC shl 8) or UInt32(uc);

  L_BZ_X_CCRC_2:
  s^.state := BZ_X_CCRC_2;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedCombinedCRC := (s^.storedCombinedCRC shl 8) or UInt32(uc);

  L_BZ_X_CCRC_3:
  s^.state := BZ_X_CCRC_3;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedCombinedCRC := (s^.storedCombinedCRC shl 8) or UInt32(uc);

  L_BZ_X_CCRC_4:
  s^.state := BZ_X_CCRC_4;
  while True do
  begin
    if s^.bsLive >= 8 then
    begin
      uc := UChar((s^.bsBuff shr (s^.bsLive - 8)) and $FF);
      Dec(s^.bsLive, 8);
      Break;
    end;
    if s^.strm^.avail_in = 0 then begin retVal := BZ_OK; goto save_state_and_return; end;
    s^.bsBuff := (s^.bsBuff shl 8) or UInt32(PUChar(s^.strm^.next_in)^);
    Inc(s^.bsLive, 8);
    Inc(s^.strm^.next_in); Dec(s^.strm^.avail_in);
    Inc(s^.strm^.total_in_lo32);
    if s^.strm^.total_in_lo32 = 0 then Inc(s^.strm^.total_in_hi32);
  end;
  s^.storedCombinedCRC := (s^.storedCombinedCRC shl 8) or UInt32(uc);

  s^.state := BZ_X_IDLE;
  retVal := BZ_STREAM_END;
  goto save_state_and_return;

  AssertH(BZ_FALSE, 4002);

  { ---- Save state and return ---- }
  save_state_and_return:
  s^.save_i          := i;
  s^.save_j          := j;
  s^.save_t          := t;
  s^.save_alphaSize  := alphaSize;
  s^.save_nGroups    := nGroups;
  s^.save_nSelectors := nSelectors;
  s^.save_EOB        := EOB;
  s^.save_groupNo    := groupNo;
  s^.save_groupPos   := groupPos;
  s^.save_nextSym    := nextSym;
  s^.save_nblockMAX  := nblockMAX;
  s^.save_nblock     := nblock;
  s^.save_es         := es;
  s^.save_N          := N;
  s^.save_curr       := curr;
  s^.save_zt         := zt;
  s^.save_zn         := zn;
  s^.save_zvec       := zvec;
  s^.save_zj         := zj;
  s^.save_gSel       := gSel;
  s^.save_gMinlen    := gMinlen;
  s^.save_gLimit     := gLimit;
  s^.save_gBase      := gBase;
  s^.save_gPerm      := gPerm;

  Result := retVal;
end;

end.
