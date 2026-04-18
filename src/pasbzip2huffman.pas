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
// Heap-construction macros (translated from the C macros verbatim)
// ---------------------------------------------------------------------------

// WEIGHTOF / DEPTHOF / ADDWEIGHTS — pack (weight << 8) | depth in one Int32
// These are inline helpers used only inside BZ2_hbMakeCodeLengths.

// UPHEAP: sift element at position z upward
procedure UpHeap(z: Int32; var heap: array of Int32; const weight: array of Int32);
  {$IFDEF FPC} inline; {$ENDIF}
var
  zz, tmp: Int32;
begin
  zz := z;
  tmp := heap[zz];
  while weight[tmp] < weight[heap[zz shr 1]] do
  begin
    heap[zz] := heap[zz shr 1];
    zz := zz shr 1;
  end;
  heap[zz] := tmp;
end;

// DOWNHEAP: sift element at position z downward
procedure DownHeap(z: Int32; nHeap: Int32;
    var heap: array of Int32; const weight: array of Int32);
  {$IFDEF FPC} inline; {$ENDIF}
var
  zz, yy, tmp: Int32;
begin
  zz := z;
  tmp := heap[zz];
  while True do
  begin
    yy := zz shl 1;
    if yy > nHeap then Break;
    if (yy < nHeap) and (weight[heap[yy + 1]] < weight[heap[yy]]) then
      Inc(yy);
    if weight[tmp] < weight[heap[yy]] then Break;
    heap[zz] := heap[yy];
    zz := yy;
  end;
  heap[zz] := tmp;
end;

// ---------------------------------------------------------------------------
// BZ2_hbMakeCodeLengths
// ---------------------------------------------------------------------------
procedure BZ2_hbMakeCodeLengths(len: PUChar; freq: PInt32;
    alphaSize, maxLen: Int32);
var
  nNodes, nHeap, n1, n2, i, j, k, d1, d2: Int32;
  tooLong: Bool;
  heap   : array[0..BZ_MAX_ALPHA_SIZE + 1] of Int32;
  weight : array[0..BZ_MAX_ALPHA_SIZE * 2 - 1] of Int32;
  parent : array[0..BZ_MAX_ALPHA_SIZE * 2 - 1] of Int32;
begin
  // Initialise weights: leaf weight = freq (at least 1), packed in high 24 bits;
  // depth (low 8 bits) = 0.
  for i := 0 to alphaSize - 1 do
  begin
    if freq[i] = 0 then
      weight[i + 1] := 1 shl 8
    else
      weight[i + 1] := freq[i] shl 8;
  end;

  while True do
  begin
    nNodes := alphaSize;
    nHeap  := 0;

    heap[0]   := 0;
    weight[0] := 0;
    parent[0] := -2;

    for i := 1 to alphaSize do
    begin
      parent[i] := -1;
      Inc(nHeap);
      heap[nHeap] := i;
      UpHeap(nHeap, heap, weight);
    end;

    while nHeap > 1 do
    begin
      n1 := heap[1]; heap[1] := heap[nHeap]; Dec(nHeap); DownHeap(1, nHeap, heap, weight);
      n2 := heap[1]; heap[1] := heap[nHeap]; Dec(nHeap); DownHeap(1, nHeap, heap, weight);
      Inc(nNodes);
      parent[n1] := nNodes;
      parent[n2] := nNodes;
      // ADDWEIGHTS: sum the high-24-bit weights, depth = 1 + max of depths
      d1 := weight[n1] and $FF;
      d2 := weight[n2] and $FF;
      if d1 > d2 then
        weight[nNodes] := ((weight[n1] and $FFFFFF00) + (weight[n2] and $FFFFFF00)) or (1 + d1)
      else
        weight[nNodes] := ((weight[n1] and $FFFFFF00) + (weight[n2] and $FFFFFF00)) or (1 + d2);
      parent[nNodes] := -1;
      Inc(nHeap);
      heap[nHeap] := nNodes;
      UpHeap(nHeap, heap, weight);
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
      j := weight[i] shr 8;
      j := 1 + (j div 2);
      weight[i] := j shl 8;
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
procedure BZ2_hbCreateDecodeTables(limit, base, perm: PInt32;
    length: PUChar; minLen, maxLen, alphaSize: Int32);
var
  pp, i, j, vec: Int32;
begin
  pp := 0;
  for i := minLen to maxLen do
    for j := 0 to alphaSize - 1 do
      if length[j] = UChar(i) then
      begin
        perm[pp] := j;
        Inc(pp);
      end;

  for i := 0 to BZ_MAX_CODE_LEN - 1 do base[i] := 0;
  for i := 0 to alphaSize - 1 do
    base[length[i] + 1] += 1;

  for i := 1 to BZ_MAX_CODE_LEN - 1 do
    base[i] += base[i - 1];

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
