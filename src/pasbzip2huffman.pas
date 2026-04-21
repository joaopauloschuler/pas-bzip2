{$I pasbzip2.inc}
unit pasbzip2huffman;

{
  Pascal port of bzip2/libbzip2 1.1.0 — Huffman coding primitives.
  Mirrors huffman.c exactly: BZ2_hbMakeCodeLengths, BZ2_hbAssignCodes,
  and BZ2_hbCreateDecodeTables.
}

interface

uses
  pasbzip2types;

procedure BZ2_hbMakeCodeLengths(len: PUChar; freq: PInt32;
    alphaSize, maxLen: Int32);

procedure BZ2_hbAssignCodes(code: PInt32; length: PUChar;
    minLen, maxLen, alphaSize: Int32);

procedure BZ2_hbCreateDecodeTables(limit, base, perm: PInt32;
    length: PUChar; minLen, maxLen, alphaSize: Int32);

implementation

// ---------------------------------------------------------------------------
// BZ2_hbMakeCodeLengths
// ---------------------------------------------------------------------------
// The C source uses UPHEAP/DOWNHEAP macros that expand inline with direct
// access to the enclosing function's local heap[]/weight[] arrays.  Translating
// them as procedures with open-array parameters passes a hidden length argument
// and prevents FPC from keeping the array base-pointers in registers (the hot
// path reads heap/weight on every sift step).  We therefore expand all three
// call sites (two DOWNHEAP + one UPHEAP per outer iteration) directly, sharing
// the locals zz/yy/tmp.  Semantics are bit-identical to the C reference.
procedure BZ2_hbMakeCodeLengths(len: PUChar; freq: PInt32;
    alphaSize, maxLen: Int32);
var
  nNodes, nHeap, n1, n2, i, j, k, d1, d2: Int32;
  zz, yy, tmp: Int32;
  tooLong: Bool;
  heap   : array[0..BZ_MAX_ALPHA_SIZE + 1] of Int32;
  weight : array[0..BZ_MAX_ALPHA_SIZE * 2 - 1] of Int32;
  parent : array[0..BZ_MAX_ALPHA_SIZE * 2 - 1] of Int32;
  { Phase 11.14: cache weight base pointer to encourage FPC to keep it in a
    callee-saved register, eliminating repeated leaq offset(%rsp) computations
    in the UPHEAP/DOWNHEAP inner loops. }
  weight_: PInt32;
begin
  weight_ := @weight[0];
  // Initialise weights: leaf weight = freq (at least 1), packed in high 24 bits;
  // depth (low 8 bits) = 0.
  for i := 0 to alphaSize - 1 do
  begin
    if freq[i] = 0 then
      weight_[i + 1] := 1 shl 8
    else
      weight_[i + 1] := freq[i] shl 8;
  end;

  while True do
  begin
    nNodes := alphaSize;
    nHeap  := 0;

    heap[0]    := 0;
    weight_[0] := 0;
    parent[0]  := -2;

    for i := 1 to alphaSize do
    begin
      parent[i] := -1;
      Inc(nHeap);
      heap[nHeap] := i;
      // UPHEAP inline: sift heap[nHeap] upward
      zz := nHeap; tmp := heap[zz];
      while weight_[tmp] < weight_[heap[zz shr 1]] do
      begin
        heap[zz] := heap[zz shr 1];
        zz := zz shr 1;
      end;
      heap[zz] := tmp;
    end;

    while nHeap > 1 do
    begin
      // pop minimum (n1) ---------------------------------------------------
      n1 := heap[1]; heap[1] := heap[nHeap]; Dec(nHeap);
      // DOWNHEAP inline
      zz := 1; tmp := heap[zz];
      while True do
      begin
        yy := zz shl 1;
        if yy > nHeap then Break;
        if (yy < nHeap) and (weight_[heap[yy + 1]] < weight_[heap[yy]]) then Inc(yy);
        if weight_[tmp] < weight_[heap[yy]] then Break;
        heap[zz] := heap[yy]; zz := yy;
      end;
      heap[zz] := tmp;

      // pop next minimum (n2) ----------------------------------------------
      n2 := heap[1]; heap[1] := heap[nHeap]; Dec(nHeap);
      // DOWNHEAP inline
      zz := 1; tmp := heap[zz];
      while True do
      begin
        yy := zz shl 1;
        if yy > nHeap then Break;
        if (yy < nHeap) and (weight_[heap[yy + 1]] < weight_[heap[yy]]) then Inc(yy);
        if weight_[tmp] < weight_[heap[yy]] then Break;
        heap[zz] := heap[yy]; zz := yy;
      end;
      heap[zz] := tmp;

      Inc(nNodes);
      parent[n1] := nNodes;
      parent[n2] := nNodes;
      // ADDWEIGHTS: sum weight parts (high 24 bits), depth = 1 + max(d1,d2).
      // Since depths fit in 8 bits (max ~20), their sum never carries into bit 8,
      // so (w1 and $FFFFFF00) + (w2 and $FFFFFF00) = (w1+w2) and $FFFFFF00.
      d1 := weight_[n1] and $FF;
      d2 := weight_[n2] and $FF;
      if d2 > d1 then d1 := d2;  { d1 = max(d1, d2) }
      weight_[nNodes] := ((weight_[n1] + weight_[n2]) and Int32($FFFFFF00)) or (1 + d1);
      parent[nNodes] := -1;
      Inc(nHeap);
      heap[nHeap] := nNodes;
      // UPHEAP inline: sift the new internal node upward
      zz := nHeap; tmp := heap[zz];
      while weight_[tmp] < weight_[heap[zz shr 1]] do
      begin
        heap[zz] := heap[zz shr 1];
        zz := zz shr 1;
      end;
      heap[zz] := tmp;
    end;

    tooLong := BZ_FALSE;
    for i := 1 to alphaSize do
    begin
      j := 0;
      k := i;
      while parent[k] >= 0 do
      begin
        k := parent[k];
        Inc(j);
      end;
      len[i - 1] := UChar(j);
      if j > maxLen then tooLong := BZ_TRUE;
    end;

    if tooLong = BZ_FALSE then Break;

    // Scale down weights to prevent overflow (same logic as C)
    for i := 1 to alphaSize do
    begin
      j := weight_[i] shr 8;
      j := 1 + (j div 2);
      weight_[i] := j shl 8;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// BZ2_hbAssignCodes
// ---------------------------------------------------------------------------
procedure BZ2_hbAssignCodes(code: PInt32; length: PUChar;
    minLen, maxLen, alphaSize: Int32);
var
  n, vec, i: Int32;
begin
  vec := 0;
  for n := minLen to maxLen do
  begin
    for i := 0 to alphaSize - 1 do
      if length[i] = UChar(n) then
      begin
        code[i] := vec;
        Inc(vec);
      end;
    vec := vec shl 1;
  end;
end;

// ---------------------------------------------------------------------------
// BZ2_hbCreateDecodeTables
// ---------------------------------------------------------------------------
// Optimisation (Phase 11.14): replace the O(alphaSize × range) double loop
// that built perm[] with a counting-sort in O(alphaSize + range).
// The original C code iterates over all alphaSize symbols for each bit-length
// value (minLen..maxLen), producing ~3870 iterations for alphaSize=258,
// range=15.  The new code makes a single pass over the length[] array to
// compute starting positions per length, then a second pass to fill perm[].
// All other parts of the function are unchanged.
procedure BZ2_hbCreateDecodeTables(limit, base, perm: PInt32;
    length: PUChar; minLen, maxLen, alphaSize: Int32);
var
  pp, i, j, vec: Int32;
  { counting-sort temporaries: start[k] = first perm index for bit-length k.
    Only start[minLen..maxLen] is used; FPC warns about partial init but
    length[j] is always in minLen..maxLen so uninitialized slots are safe. }
  start: array[0..BZ_MAX_CODE_LEN] of Int32;
begin
  { ---- Build perm[] via counting sort: O(alphaSize + range) ---- }
  { zero the count array for lengths minLen..maxLen }
  FillDWord(start, BZ_MAX_CODE_LEN + 1, 0);  { zero all slots to silence warning }
  { count symbols at each length }
  for j := 0 to alphaSize - 1 do
    Inc(start[length[j]]);
  { convert counts to start positions (prefix sum) }
  pp := 0;
  for i := minLen to maxLen do
  begin
    j := start[i];       { count for length i }
    start[i] := pp;      { first insertion index }
    Inc(pp, j);
  end;
  { scatter symbols into perm[] in length order }
  for j := 0 to alphaSize - 1 do
  begin
    i := length[j];
    perm[start[i]] := j;
    Inc(start[i]);
  end;

  { ---- Build base[] ---- }
  for i := 0 to BZ_MAX_CODE_LEN - 1 do base[i] := 0;
  for i := 0 to alphaSize - 1 do
    base[length[i] + 1] += 1;

  for i := 1 to BZ_MAX_CODE_LEN - 1 do
    base[i] += base[i - 1];

  { ---- Build limit[] ---- }
  for i := 0 to BZ_MAX_CODE_LEN - 1 do limit[i] := 0;
  vec := 0;

  for i := minLen to maxLen do
  begin
    vec += (base[i + 1] - base[i]);
    limit[i] := vec - 1;
    vec := vec shl 1;
  end;
  for i := minLen + 1 to maxLen do
    base[i] := ((limit[i - 1] + 1) shl 1) - base[i];
end;

end.
