{$I pasbzip2.inc}
program TestHuffman;

{
  Phase 2 validation: verifies BZ2_hbMakeCodeLengths, BZ2_hbAssignCodes,
  and BZ2_hbCreateDecodeTables against the C libbz2 reference.

  Strategy
  ---------
  For each test case we call both the Pascal and C implementations with
  identical inputs and compare every output array byte-for-byte.

  Test cases:
    (a) Minimal alphabet (2 symbols, equal frequency)
    (b) Small hand-crafted alphabet (8 symbols, unequal frequencies)
    (c) Maximum alphabet (BZ_MAX_ALPHA_SIZE = 258 symbols, flat frequencies)
    (d) Maximum alphabet, random frequencies (several seeds)
    (e) Single symbol (degenerate: 1 symbol, maxLen=17)
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2huffman,
  cbzip2;

var
  fails: Integer;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

procedure Check(const tag: string; ok: Boolean);
begin
  if not ok then
  begin
    WriteLn('  FAIL: ', tag);
    Inc(fails);
  end
  else
    WriteLn('  ok  : ', tag);
end;

// Compare PUChar arrays of length n
function EqualBytes(a, b: PUChar; n: Integer): Boolean;
var i: Integer;
begin
  for i := 0 to n - 1 do
    if a[i] <> b[i] then Exit(False);
  Result := True;
end;

// Compare PInt32 arrays of length n
function EqualInt32s(a, b: PInt32; n: Integer): Boolean;
var i: Integer;
begin
  for i := 0 to n - 1 do
    if a[i] <> b[i] then Exit(False);
  Result := True;
end;

// ---------------------------------------------------------------------------
// RunTestMakeCodeLengths
//   Call both Pascal and C BZ2_hbMakeCodeLengths, compare len[] outputs.
// ---------------------------------------------------------------------------
procedure RunTestMakeCodeLengths(const tag: string;
    freq: PInt32; alphaSize, maxLen: Int32);
var
  lenP, lenC : array[0..BZ_MAX_ALPHA_SIZE - 1] of UChar;
  freqCopy   : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
  i: Integer;
begin
  // Make a copy because the C impl may mutate freq internally
  for i := 0 to alphaSize - 1 do freqCopy[i] := freq[i];

  BZ2_hbMakeCodeLengths(@lenP[0], freq, alphaSize, maxLen);
  cbz_hbMakeCodeLengths(@lenC[0], @freqCopy[0], alphaSize, maxLen);

  Check('MakeCodeLengths:' + tag, EqualBytes(@lenP[0], @lenC[0], alphaSize));
end;

// ---------------------------------------------------------------------------
// RunTestAssignCodes
//   Given identical len[] arrays, compare code[] outputs.
// ---------------------------------------------------------------------------
procedure RunTestAssignCodes(const tag: string;
    length: PUChar; alphaSize: Int32);
var
  codeP, codeC : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
  minLen, maxLen, i: Int32;
begin
  minLen := 255;
  maxLen := 0;
  for i := 0 to alphaSize - 1 do
  begin
    if Int32(length[i]) < minLen then minLen := length[i];
    if Int32(length[i]) > maxLen then maxLen := length[i];
  end;
  if minLen > maxLen then Exit; // empty / degenerate

  BZ2_hbAssignCodes(@codeP[0], length, minLen, maxLen, alphaSize);
  cbz_hbAssignCodes(@codeC[0], length, minLen, maxLen, alphaSize);

  Check('AssignCodes:' + tag, EqualInt32s(@codeP[0], @codeC[0], alphaSize));
end;

// ---------------------------------------------------------------------------
// RunTestCreateDecodeTables
//   Given identical len[] arrays, compare limit/base/perm outputs.
// ---------------------------------------------------------------------------
procedure RunTestCreateDecodeTables(const tag: string;
    length: PUChar; alphaSize: Int32);
var
  limitP, baseP         : array[0..BZ_MAX_CODE_LEN - 1] of Int32;
  limitC, baseC         : array[0..BZ_MAX_CODE_LEN - 1] of Int32;
  permPbig, permCbig   : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
  minLen, maxLen, i: Int32;
begin
  minLen := 255;
  maxLen := 0;
  for i := 0 to alphaSize - 1 do
  begin
    if Int32(length[i]) < minLen then minLen := length[i];
    if Int32(length[i]) > maxLen then maxLen := length[i];
  end;
  if minLen > maxLen then Exit;

  FillChar(limitP,   SizeOf(limitP),   0);
  FillChar(baseP,    SizeOf(baseP),    0);
  FillChar(permPbig, SizeOf(permPbig), 0);
  FillChar(limitC,   SizeOf(limitC),   0);
  FillChar(baseC,    SizeOf(baseC),    0);
  FillChar(permCbig, SizeOf(permCbig), 0);

  BZ2_hbCreateDecodeTables(@limitP[0], @baseP[0], @permPbig[0],
      length, minLen, maxLen, alphaSize);
  cbz_hbCreateDecodeTables(@limitC[0], @baseC[0], @permCbig[0],
      length, minLen, maxLen, alphaSize);

  Check('CreateDecodeTables limit:' + tag, EqualInt32s(@limitP[0], @limitC[0], BZ_MAX_CODE_LEN));
  Check('CreateDecodeTables base:'  + tag, EqualInt32s(@baseP[0],  @baseC[0],  BZ_MAX_CODE_LEN));
  Check('CreateDecodeTables perm:'  + tag, EqualInt32s(@permPbig[0], @permCbig[0], alphaSize));
end;

// ---------------------------------------------------------------------------
// RunFullTest
//   Drive all three function comparisons for one frequency distribution.
// ---------------------------------------------------------------------------
procedure RunFullTest(const tag: string;
    freq: PInt32; alphaSize, maxLen: Int32);
var
  lenP : array[0..BZ_MAX_ALPHA_SIZE - 1] of UChar;
  freqCopy : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
  i: Integer;
begin
  for i := 0 to alphaSize - 1 do freqCopy[i] := freq[i];

  RunTestMakeCodeLengths(tag, freq, alphaSize, maxLen);

  // Use the Pascal-generated lengths for the downstream tests so that any
  // discrepancy in MakeCodeLengths does not cascade.  (We already flagged
  // mismatches above.)  Recompute from the copy so freq is unmodified.
  BZ2_hbMakeCodeLengths(@lenP[0], @freqCopy[0], alphaSize, maxLen);

  RunTestAssignCodes(tag, @lenP[0], alphaSize);
  RunTestCreateDecodeTables(tag, @lenP[0], alphaSize);
end;

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

var
  freq  : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
  seed  : UInt32;
  i, j  : Integer;
  alphaSize: Int32;

begin
  fails := 0;
  WriteLn('TestHuffman — Phase 2 validation');
  WriteLn;

  // (a) Minimal alphabet: 2 symbols, equal frequency
  WriteLn('(a) 2 symbols, equal freq ...');
  freq[0] := 10; freq[1] := 10;
  RunFullTest('2sym-equal', @freq[0], 2, 17);
  WriteLn;

  // (b) Small hand-crafted alphabet (8 symbols)
  WriteLn('(b) 8 symbols, unequal freq ...');
  freq[0] := 5; freq[1] := 10; freq[2] := 20; freq[3] := 40;
  freq[4] := 1;  freq[5] := 2;  freq[6] := 3;  freq[7] := 15;
  RunFullTest('8sym-unequal', @freq[0], 8, 17);
  WriteLn;

  // (c) Maximum alphabet (258 symbols), flat frequencies
  WriteLn('(c) 258 symbols, flat freq ...');
  for i := 0 to BZ_MAX_ALPHA_SIZE - 1 do freq[i] := 100;
  RunFullTest('258sym-flat', @freq[0], BZ_MAX_ALPHA_SIZE, 17);
  WriteLn;

  // (d) Maximum alphabet, random frequencies (4 seeds)
  WriteLn('(d) 258 symbols, random freq (4 seeds) ...');
  for j := 0 to 3 do
  begin
    case j of
      0: seed := $DEADBEEF;
      1: seed := $C0FFEE42;
      2: seed := $12345678;
      3: seed := $AABBCCDD;
    end;
    for i := 0 to BZ_MAX_ALPHA_SIZE - 1 do
    begin
      seed := seed * 1664525 + 1013904223;
      freq[i] := Int32((seed shr 24) and $FF) + 1;  // 1..256; larger values risk Int32 overflow in heap
    end;
    RunFullTest('258sym-rnd#' + IntToStr(j), @freq[0], BZ_MAX_ALPHA_SIZE, 17);
  end;
  WriteLn;

  // (e) Single symbol (degenerate)
  WriteLn('(e) 1 symbol (degenerate) ...');
  freq[0] := 42;
  RunFullTest('1sym', @freq[0], 1, 17);
  WriteLn;

  // (f) Medium alphabet with some zero frequencies
  WriteLn('(f) 50 symbols, some zero freq ...');
  alphaSize := 50;
  for i := 0 to alphaSize - 1 do
    freq[i] := i mod 5;   // every 5th is 0 → treated as 1 internally
  RunFullTest('50sym-zeros', @freq[0], alphaSize, 17);
  WriteLn;

  // Result
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
