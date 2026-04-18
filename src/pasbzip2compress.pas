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

implementation

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

end.
