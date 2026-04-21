{$I pasbzip2.inc}
unit pasbzip2blocksort;

{
  Pascal port of bzip2/libbzip2 1.1.0 — block sorter (blocksort.c).
  Implements BZ2_blockSort and all supporting sort functions.
  Phase 5 — replaces the Phase-4 stub that delegated to the C reference.
}

interface

uses
  pasbzip2types;

procedure BZ2_blockSort(s: PEState);

implementation

uses
  SysUtils;

// ---------------------------------------------------------------------------
// Local assertion helpers (mirrors the definitions in pasbzip2compress.pas)
// ---------------------------------------------------------------------------

procedure AssertH(cond: Bool; errcode: Int32); inline;
begin
  if cond = 0 then begin
    WriteLn(StdErr, 'bzip2: internal error number ', errcode, '.');
    Halt(3);
  end;
end;

procedure AssertD({%H-}cond: Bool; {%H-}const msg: PChar); inline;
begin
  // debug-only assertion — no-op in release builds
end;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  FALLBACK_QSORT_SMALL_THRESH = 10;
  FALLBACK_QSORT_STACK_SIZE   = 100;

  MAIN_QSORT_SMALL_THRESH = 20;
  MAIN_QSORT_DEPTH_THRESH = BZ_N_RADIX + BZ_N_QSORT;
  MAIN_QSORT_STACK_SIZE   = 100;

  BS_SETMASK   : UInt32 = $00200000;  { 1 shl 21 }
  BS_CLEARMASK : UInt32 = $FFDFFFFF;  { not (1 shl 21) }

  main_incs : array[0..13] of Int32 = (
    1, 4, 13, 40, 121, 364, 1093, 3280,
    9841, 29524, 88573, 265720,
    797161, 2391484
  );

// ---------------------------------------------------------------------------
// Fallback sort helpers — O(N log(N)^2) for repetitive blocks
// ---------------------------------------------------------------------------

procedure fallbackSimpleSort(fmap: PUInt32; eclass: PUInt32;
                              lo, hi: Int32); inline;
var
  i, j, tmp: Int32;
  ec_tmp: UInt32;
begin
  if lo = hi then Exit;

  if hi - lo > 3 then begin
    i := hi - 4;
    while i >= lo do begin
      tmp    := Int32(fmap[i]);
      ec_tmp := eclass[tmp];
      j      := i + 4;
      while (j <= hi) and (ec_tmp > eclass[fmap[j]]) do begin
        fmap[j-4] := fmap[j];
        Inc(j, 4);
      end;
      fmap[j-4] := UInt32(tmp);
      Dec(i);
    end;
  end;

  i := hi - 1;
  while i >= lo do begin
    tmp    := Int32(fmap[i]);
    ec_tmp := eclass[tmp];
    j      := i + 1;
    while (j <= hi) and (ec_tmp > eclass[fmap[j]]) do begin
      fmap[j-1] := fmap[j];
      Inc(j);
    end;
    fmap[j-1] := UInt32(tmp);
    Dec(i);
  end;
end;

procedure fallbackQSort3(fmap: PUInt32; eclass: PUInt32; loSt, hiSt: Int32);
var
  unLo, unHi, ltLo, gtHi, n, m: Int32;
  sp, lo, hi: Int32;
  med, r, r3: UInt32;
  stackLo: array[0..FALLBACK_QSORT_STACK_SIZE-1] of Int32;
  stackHi: array[0..FALLBACK_QSORT_STACK_SIZE-1] of Int32;

  procedure fswap(var a, b: UInt32); inline;
  var t: UInt32;
  begin t := a; a := b; b := t; end;

  procedure fvswap(zzp1, zzp2, zzn: Int32); inline;
  begin
    while zzn > 0 do begin
      fswap(fmap[zzp1], fmap[zzp2]);
      Inc(zzp1); Inc(zzp2); Dec(zzn);
    end;
  end;

  function fmin(a, b: Int32): Int32; inline;
  begin if a < b then fmin := a else fmin := b; end;

begin
  r  := 0;
  sp := 0;
  stackLo[sp] := loSt; stackHi[sp] := hiSt; Inc(sp);

  while sp > 0 do begin
    AssertH(Bool(Ord(sp < FALLBACK_QSORT_STACK_SIZE - 1)), 1004);

    Dec(sp);
    lo := stackLo[sp]; hi := stackHi[sp];

    if hi - lo < FALLBACK_QSORT_SMALL_THRESH then begin
      fallbackSimpleSort(fmap, eclass, lo, hi);
      continue;
    end;

    r  := ((r * 7621) + 1) mod 32768;
    r3 := r mod 3;
    if r3 = 0 then      med := eclass[fmap[lo]]
    else if r3 = 1 then med := eclass[fmap[(lo+hi) shr 1]]
    else                med := eclass[fmap[hi]];

    unLo := lo; ltLo := lo;
    unHi := hi; gtHi := hi;

    while True do begin
      while True do begin
        if unLo > unHi then break;
        n := Int32(eclass[fmap[unLo]]) - Int32(med);
        if n = 0 then begin
          fswap(fmap[unLo], fmap[ltLo]);
          Inc(ltLo); Inc(unLo);
          continue;
        end;
        if n > 0 then break;
        Inc(unLo);
      end;
      while True do begin
        if unLo > unHi then break;
        n := Int32(eclass[fmap[unHi]]) - Int32(med);
        if n = 0 then begin
          fswap(fmap[unHi], fmap[gtHi]);
          Dec(gtHi); Dec(unHi);
          continue;
        end;
        if n < 0 then break;
        Dec(unHi);
      end;
      if unLo > unHi then break;
      fswap(fmap[unLo], fmap[unHi]); Inc(unLo); Dec(unHi);
    end;

    AssertD(Bool(Ord(unHi = unLo - 1)), 'fallbackQSort3(2)');

    if gtHi < ltLo then continue;

    n := fmin(ltLo - lo, unLo - ltLo); fvswap(lo, unLo - n, n);
    m := fmin(hi - gtHi, gtHi - unHi); fvswap(unLo, hi - m + 1, m);

    n := lo + unLo - ltLo - 1;
    m := hi - (gtHi - unHi) + 1;

    if n - lo > hi - m then begin
      stackLo[sp] := lo; stackHi[sp] := n; Inc(sp);
      stackLo[sp] := m;  stackHi[sp] := hi; Inc(sp);
    end else begin
      stackLo[sp] := m;  stackHi[sp] := hi; Inc(sp);
      stackLo[sp] := lo; stackHi[sp] := n; Inc(sp);
    end;
  end;
end;

// Assign bucket IDs for one refinement level. Extracted from fallbackSort so
// FPC can keep i in a register (the outer frame commits all callee-saves).
// For each position i: if BH[i] is set, that position starts a new bucket (j := i).
// We write: eclass[fmap[i] - H mod nblock] := j  (the bucket-start position).
procedure fbAssignBucketIDs(fmap: PUInt32; eclass: PUInt32; bhtab: PUInt32;
                             nblock: Int32; H: Int32); inline;
var
  i, j, k: Int32;
begin
  j := 0;
  for i := 0 to nblock-1 do begin
    if (bhtab[i shr 5] and (UInt32(1) shl (i and 31))) <> 0 then j := i;
    k := Int32(fmap[i]) - H;
    if k < 0 then Inc(k, nblock);
    eclass[k] := UInt32(j);
  end;
end;

// Scan a sorted bucket [l..r] and set BH header bits where the sort key changes.
// Extracted from fallbackSort so FPC can keep i in a register.
procedure fbMarkBucketHeaders(fmap: PUInt32; eclass: PUInt32; bhtab: PUInt32;
                               l: Int32; r: Int32); inline;
var
  i, cc, ec: Int32;
begin
  cc := -1;
  for i := l to r do begin
    ec := Int32(eclass[fmap[i]]);  // compute once; avoids double load on branch taken
    if cc <> ec then begin
      cc := ec;
      bhtab[i shr 5] := bhtab[i shr 5] or (UInt32(1) shl (i and 31));
    end;
  end;
end;

// Scan forward past all set BH bits (find the first clear bit >= k).
// Extracted from fallbackSort so FPC can keep bhtab/k in registers here.
function fbScanToNextClear(bhtab: PUInt32; k: Int32): Int32; inline;
begin
  // Advance past any bits that are 1 in the current word
  while ((bhtab[k shr 5] and (UInt32(1) shl (k and 31))) <> 0) and ((k and 31) <> 0) do Inc(k);
  if (bhtab[k shr 5] and (UInt32(1) shl (k and 31))) <> 0 then begin
    while bhtab[k shr 5] = $FFFFFFFF do Inc(k, 32);
    while (bhtab[k shr 5] and (UInt32(1) shl (k and 31))) <> 0 do Inc(k);
  end;
  fbScanToNextClear := k;
end;

// Scan forward past all clear BH bits (find the first set bit >= k).
// Extracted from fallbackSort so FPC can keep bhtab/k in registers here.
function fbScanToNextSet(bhtab: PUInt32; k: Int32): Int32; inline;
begin
  while ((bhtab[k shr 5] and (UInt32(1) shl (k and 31))) = 0) and ((k and 31) <> 0) do Inc(k);
  if (bhtab[k shr 5] and (UInt32(1) shl (k and 31))) = 0 then begin
    while bhtab[k shr 5] = $00000000 do Inc(k, 32);
    while (bhtab[k shr 5] and (UInt32(1) shl (k and 31))) = 0 do Inc(k);
  end;
  fbScanToNextSet := k;
end;

procedure fallbackSort(fmap: PUInt32; eclass: PUInt32; bhtab: PUInt32;
                       nblock: Int32; {%H-}verb: Int32);
var
  ftab:     array[0..256] of Int32;
  ftabCopy: array[0..255] of Int32;
  H, i, j, k, l, r: Int32;
  nNotDone: Int32;
  nBhtab: Int32;
  eclass8: PUChar;
  // Local copy of bhtab pointer; no longer used for closure capture.
  // cc, cc1 eliminated — those vars now live in the extracted helper functions.
  bhtab_: PUInt32;

begin
  bhtab_ := bhtab;
  eclass8 := PUChar(eclass);

  // Initial 1-char radix sort to generate fmap and BH bits
  for i := 0 to 256 do ftab[i] := 0;
  for i := 0 to nblock-1 do Inc(ftab[eclass8[i]]);
  for i := 0 to 255 do ftabCopy[i] := ftab[i];
  for i := 1 to 256 do ftab[i] := ftab[i] + ftab[i-1];

  for i := 0 to nblock-1 do begin
    j := eclass8[i];
    k := ftab[j] - 1;
    ftab[j] := k;
    fmap[k] := UInt32(i);
  end;

  nBhtab := 2 + (nblock div 32);
  for i := 0 to nBhtab-1 do bhtab_[i] := 0;
  // SET_BH inlined: bhtab_[zz shr 5] |= (1 shl (zz and 31))
  for i := 0 to 255 do
    bhtab_[ftab[i] shr 5] := bhtab_[ftab[i] shr 5] or (UInt32(1) shl (ftab[i] and 31));

  // Sentinel bits for block-end detection — SET_BH / CLEAR_BH inlined
  for i := 0 to 31 do begin
    j := nblock + 2*i;
    bhtab_[j shr 5] := bhtab_[j shr 5] or (UInt32(1) shl (j and 31));
    j := nblock + 2*i + 1;
    bhtab_[j shr 5] := bhtab_[j shr 5] and not (UInt32(1) shl (j and 31));
  end;

  // Exponential radix sort — log(N) refinement loop
  H := 1;
  while True do begin
    // Assign bucket IDs: for each i, write j (the last BH-set index ≤ i) into
    // eclass[fmap[i]-H mod nblock]. Extracted so FPC keeps i in a register.
    fbAssignBucketIDs(fmap, eclass, bhtab_, nblock, H);

    nNotDone := 0;
    r := -1;
    while True do begin
      // Find the next non-singleton bucket
      // fbScanToNextClear: advance past set bits to find the bucket start
      k := fbScanToNextClear(bhtab_, r + 1);
      l := k - 1;
      if l >= nblock then break;
      // fbScanToNextSet: advance past clear bits to find the bucket end
      k := fbScanToNextSet(bhtab_, k);
      r := k - 1;
      if r >= nblock then break;

      // [l, r] brackets the current bucket
      if r > l then begin
        Inc(nNotDone, r - l + 1);
        fallbackQSort3(fmap, eclass, l, r);
        // Scan bucket and set BH header bits where sort key changes.
        // Extracted so FPC keeps i in a register.
        fbMarkBucketHeaders(fmap, eclass, bhtab_, l, r);
      end;
    end;

    H := H * 2;
    if (H > nblock) or (nNotDone = 0) then break;
  end;

  // Reconstruct original block in eclass8[0..nblock-1]
  j := 0;
  for i := 0 to nblock-1 do begin
    while ftabCopy[j] = 0 do Inc(j);
    Dec(ftabCopy[j]);
    eclass8[fmap[i]] := UChar(j);
  end;
  AssertH(Bool(Ord(j < 256)), 1005);
end;

// ---------------------------------------------------------------------------
// Main sort helpers — O(N^2 log N), faster for non-repetitive blocks
// ---------------------------------------------------------------------------

// mainGtU — suffix comparison for BZ2_blockSort.
// NOT inline: with 6 register parameters (all fit in x86_64 SysV %rdi..%r9),
// FPC keeps block (%rdx) and quadrant (%rcx) in registers throughout the
// function body. The inlined version caused FPC to spill both pointers to the
// stack (reloaded 2× per byte comparison) because mainSimpleSort had too many
// live variables. The function-call overhead (~14 cycles) is outweighed by the
// savings on comparisons longer than ~5 bytes.
function mainGtU(i1, i2: UInt32; block: PUChar; quadrant: PUInt16;
                 nblock: UInt32; budget: PInt32): Bool;
var
  k: Int32;
  c1, c2: UChar;
  s1, s2: UInt16;
begin
  AssertD(Bool(Ord(i1 <> i2)), 'mainGtU');

  // Unrolled first 12 char comparisons (no quadrant needed yet)
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);
  c1 := block[i1]; c2 := block[i2];
  if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
  Inc(i1); Inc(i2);

  k := Int32(nblock) + 8;
  repeat
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);
    c1 := block[i1]; c2 := block[i2];
    if c1 <> c2 then begin mainGtU := Bool(Ord(c1 > c2)); Exit; end;
    s1 := quadrant[i1]; s2 := quadrant[i2];
    if s1 <> s2 then begin mainGtU := Bool(Ord(s1 > s2)); Exit; end;
    Inc(i1); Inc(i2);

    if i1 >= nblock then Dec(i1, nblock);
    if i2 >= nblock then Dec(i2, nblock);

    Dec(k, 8);
    Dec(budget^);
  until k < 0;

  mainGtU := BZ_FALSE;
end;

procedure mainSimpleSort(ptr: PUInt32; block: PUChar; quadrant: PUInt16;
                         nblock, lo, hi, d: Int32; budget: PInt32);
var
  i, j, h, bigN, hp: Int32;
  v: UInt32;
begin
  bigN := hi - lo + 1;
  if bigN < 2 then Exit;

  hp := 0;
  while main_incs[hp] < bigN do Inc(hp);
  Dec(hp);

  while hp >= 0 do begin
    h := main_incs[hp];
    i := lo + h;
    while True do begin
      // copy 1
      if i > hi then break;
      v := ptr[i]; j := i;
      while mainGtU(ptr[j-h] + UInt32(d), v + UInt32(d),
                    block, quadrant, UInt32(nblock), budget) <> 0 do begin
        ptr[j] := ptr[j-h];
        Dec(j, h);
        if j <= (lo + h - 1) then break;
      end;
      ptr[j] := v; Inc(i);

      // copy 2
      if i > hi then break;
      v := ptr[i]; j := i;
      while mainGtU(ptr[j-h] + UInt32(d), v + UInt32(d),
                    block, quadrant, UInt32(nblock), budget) <> 0 do begin
        ptr[j] := ptr[j-h];
        Dec(j, h);
        if j <= (lo + h - 1) then break;
      end;
      ptr[j] := v; Inc(i);

      // copy 3
      if i > hi then break;
      v := ptr[i]; j := i;
      while mainGtU(ptr[j-h] + UInt32(d), v + UInt32(d),
                    block, quadrant, UInt32(nblock), budget) <> 0 do begin
        ptr[j] := ptr[j-h];
        Dec(j, h);
        if j <= (lo + h - 1) then break;
      end;
      ptr[j] := v; Inc(i);

      if budget^ < 0 then Exit;
    end;
    Dec(hp);
  end;
end;

function mmed3(a, b, c: UChar): UChar; inline;
var
  t: UChar;
begin
  if a > b then begin t := a; a := b; b := t; end;
  if b > c then begin
    b := c;
    if a > b then b := a;
  end;
  mmed3 := b;
end;

procedure mainQSort3(ptr: PUInt32; block: PUChar; quadrant: PUInt16;
                     nblock, loSt, hiSt, dSt: Int32; budget: PInt32);
var
  unLo, unHi, ltLo, gtHi, n, m, med: Int32;
  sp, lo, hi, d: Int32;
  stackLo: array[0..MAIN_QSORT_STACK_SIZE-1] of Int32;
  stackHi: array[0..MAIN_QSORT_STACK_SIZE-1] of Int32;
  stackD:  array[0..MAIN_QSORT_STACK_SIZE-1] of Int32;
  nextLo: array[0..2] of Int32;
  nextHi: array[0..2] of Int32;
  nextD:  array[0..2] of Int32;

  procedure mswap(var a, b: UInt32); inline;
  var t: UInt32;
  begin t := a; a := b; b := t; end;

  procedure mvswap(zzp1, zzp2, zzn: Int32); inline;
  begin
    while zzn > 0 do begin
      mswap(ptr[zzp1], ptr[zzp2]);
      Inc(zzp1); Inc(zzp2); Dec(zzn);
    end;
  end;

  function mmin(a, b: Int32): Int32; inline;
  begin if a < b then mmin := a else mmin := b; end;

  function mnextsize(az: Int32): Int32; inline;
  begin mnextsize := nextHi[az] - nextLo[az]; end;

  procedure mnextswap(az, bz: Int32); inline;
  var tz: Int32;
  begin
    tz := nextLo[az]; nextLo[az] := nextLo[bz]; nextLo[bz] := tz;
    tz := nextHi[az]; nextHi[az] := nextHi[bz]; nextHi[bz] := tz;
    tz := nextD [az]; nextD [az] := nextD [bz]; nextD [bz] := tz;
  end;

begin
  sp := 0;
  stackLo[sp] := loSt; stackHi[sp] := hiSt; stackD[sp] := dSt; Inc(sp);

  while sp > 0 do begin
    AssertH(Bool(Ord(sp < MAIN_QSORT_STACK_SIZE - 2)), 1001);

    Dec(sp);
    lo := stackLo[sp]; hi := stackHi[sp]; d := stackD[sp];

    if (hi - lo < MAIN_QSORT_SMALL_THRESH) or (d > MAIN_QSORT_DEPTH_THRESH) then begin
      mainSimpleSort(ptr, block, quadrant, nblock, lo, hi, d, budget);
      if budget^ < 0 then Exit;
      continue;
    end;

    med := Int32(mmed3(block[ptr[lo]        + UInt32(d)],
                       block[ptr[hi]        + UInt32(d)],
                       block[ptr[(lo+hi) shr 1] + UInt32(d)]));

    unLo := lo; ltLo := lo;
    unHi := hi; gtHi := hi;

    while True do begin
      while True do begin
        if unLo > unHi then break;
        n := Int32(block[ptr[unLo] + UInt32(d)]) - med;
        if n = 0 then begin
          mswap(ptr[unLo], ptr[ltLo]); Inc(ltLo); Inc(unLo); continue;
        end;
        if n > 0 then break;
        Inc(unLo);
      end;
      while True do begin
        if unLo > unHi then break;
        n := Int32(block[ptr[unHi] + UInt32(d)]) - med;
        if n = 0 then begin
          mswap(ptr[unHi], ptr[gtHi]); Dec(gtHi); Dec(unHi); continue;
        end;
        if n < 0 then break;
        Dec(unHi);
      end;
      if unLo > unHi then break;
      mswap(ptr[unLo], ptr[unHi]); Inc(unLo); Dec(unHi);
    end;

    AssertD(Bool(Ord(unHi = unLo - 1)), 'mainQSort3(2)');

    if gtHi < ltLo then begin
      stackLo[sp] := lo; stackHi[sp] := hi; stackD[sp] := d+1; Inc(sp);
      continue;
    end;

    n := mmin(ltLo - lo, unLo - ltLo); mvswap(lo, unLo - n, n);
    m := mmin(hi - gtHi, gtHi - unHi); mvswap(unLo, hi - m + 1, m);

    n := lo + unLo - ltLo - 1;
    m := hi - (gtHi - unHi) + 1;

    nextLo[0] := lo;  nextHi[0] := n;   nextD[0] := d;
    nextLo[1] := m;   nextHi[1] := hi;  nextD[1] := d;
    nextLo[2] := n+1; nextHi[2] := m-1; nextD[2] := d+1;

    if mnextsize(0) < mnextsize(1) then mnextswap(0, 1);
    if mnextsize(1) < mnextsize(2) then mnextswap(1, 2);
    if mnextsize(0) < mnextsize(1) then mnextswap(0, 1);

    AssertD(Bool(Ord(mnextsize(0) >= mnextsize(1))), 'mainQSort3(8)');
    AssertD(Bool(Ord(mnextsize(1) >= mnextsize(2))), 'mainQSort3(9)');

    stackLo[sp] := nextLo[0]; stackHi[sp] := nextHi[0]; stackD[sp] := nextD[0]; Inc(sp);
    stackLo[sp] := nextLo[1]; stackHi[sp] := nextHi[1]; stackD[sp] := nextD[1]; Inc(sp);
    stackLo[sp] := nextLo[2]; stackHi[sp] := nextHi[2]; stackD[sp] := nextD[2]; Inc(sp);
  end;
end;

procedure mainSort(ptr: PUInt32; block: PUChar; quadrant: PUInt16;
                   ftab: PUInt32; nblock: Int32; {%H-}verb: Int32; budget: PInt32);
label
  zero_label;
var
  i, j, k, ss, sb: Int32;
  runningOrder: array[0..255] of Int32;
  bigDone:      array[0..255] of Bool;
  copyStart:    array[0..255] of Int32;
  copyEnd:      array[0..255] of Int32;
  c1: UChar;
  numQSorted: Int32;
  s: UInt16;
  lo, hi: Int32;
  vv: Int32;
  h: Int32;
  bbStart, bbSize, shifts: Int32;
  a2update: Int32;
  qVal: UInt16;

  function BIGFREQ(b: Int32): Int32; inline;
  begin BIGFREQ := Int32(ftab[(b+1) shl 8]) - Int32(ftab[b shl 8]); end;

begin
  // Set up 2-byte frequency table
  for i := 65536 downto 0 do ftab[i] := 0;

  j := Int32(block[0]) shl 8;
  i := nblock - 1;
  while i >= 3 do begin
    quadrant[i] := 0;
    j := (j shr 8) or (Int32(block[i]) shl 8);   Inc(ftab[j]);
    quadrant[i-1] := 0;
    j := (j shr 8) or (Int32(block[i-1]) shl 8); Inc(ftab[j]);
    quadrant[i-2] := 0;
    j := (j shr 8) or (Int32(block[i-2]) shl 8); Inc(ftab[j]);
    quadrant[i-3] := 0;
    j := (j shr 8) or (Int32(block[i-3]) shl 8); Inc(ftab[j]);
    Dec(i, 4);
  end;
  while i >= 0 do begin
    quadrant[i] := 0;
    j := (j shr 8) or (Int32(block[i]) shl 8);
    Inc(ftab[j]);
    Dec(i);
  end;

  for i := 0 to BZ_N_OVERSHOOT-1 do begin
    block[nblock+i]    := block[i];
    quadrant[nblock+i] := 0;
  end;

  // Complete initial radix sort
  for i := 1 to 65536 do ftab[i] := ftab[i] + ftab[i-1];

  s := UInt16(Int32(block[0]) shl 8);
  i := nblock - 1;
  while i >= 3 do begin
    s := UInt16((Int32(s) shr 8) or (Int32(block[i])   shl 8));
    j := Int32(ftab[s]) - 1; ftab[s] := UInt32(j); ptr[j] := UInt32(i);
    s := UInt16((Int32(s) shr 8) or (Int32(block[i-1]) shl 8));
    j := Int32(ftab[s]) - 1; ftab[s] := UInt32(j); ptr[j] := UInt32(i-1);
    s := UInt16((Int32(s) shr 8) or (Int32(block[i-2]) shl 8));
    j := Int32(ftab[s]) - 1; ftab[s] := UInt32(j); ptr[j] := UInt32(i-2);
    s := UInt16((Int32(s) shr 8) or (Int32(block[i-3]) shl 8));
    j := Int32(ftab[s]) - 1; ftab[s] := UInt32(j); ptr[j] := UInt32(i-3);
    Dec(i, 4);
  end;
  while i >= 0 do begin
    s := UInt16((Int32(s) shr 8) or (Int32(block[i]) shl 8));
    j := Int32(ftab[s]) - 1; ftab[s] := UInt32(j); ptr[j] := UInt32(i);
    Dec(i);
  end;

  // Calculate running order (smallest to largest big bucket) via shell sort
  for i := 0 to 255 do begin
    bigDone[i]      := BZ_FALSE;
    runningOrder[i] := i;
  end;

  h := 1;
  while h <= 256 do h := 3 * h + 1;
  repeat
    h := h div 3;
    for i := h to 255 do begin
      vv := runningOrder[i];
      j  := i;
      while BIGFREQ(runningOrder[j-h]) > BIGFREQ(vv) do begin
        runningOrder[j] := runningOrder[j-h];
        Dec(j, h);
        if j <= (h - 1) then goto zero_label;
      end;
      zero_label:
      runningOrder[j] := vv;
    end;
  until h = 1;

  numQSorted := 0;

  for i := 0 to 255 do begin
    ss := runningOrder[i];

    // Step 1: complete big bucket [ss] by quicksorting unsorted small buckets
    for j := 0 to 255 do begin
      if j <> ss then begin
        sb := (ss shl 8) + j;
        if (ftab[sb] and BS_SETMASK) = 0 then begin
          lo := Int32(ftab[sb]   and BS_CLEARMASK);
          hi := Int32(ftab[sb+1] and BS_CLEARMASK) - 1;
          if hi > lo then begin
            mainQSort3(ptr, block, quadrant, nblock,
                       lo, hi, BZ_N_RADIX, budget);
            Inc(numQSorted, hi - lo + 1);
            if budget^ < 0 then Exit;
          end;
        end;
        ftab[sb] := ftab[sb] or BS_SETMASK;
      end;
    end;

    AssertH(Bool(Ord(bigDone[ss] = 0)), 1006);

    // Step 2: scan big bucket [ss] to synthesise sorted order for [t, ss]
    for j := 0 to 255 do begin
      copyStart[j] := Int32( ftab[(j shl 8) + ss]     and BS_CLEARMASK);
      copyEnd  [j] := Int32((ftab[(j shl 8) + ss + 1] and BS_CLEARMASK)) - 1;
    end;
    j := Int32(ftab[ss shl 8] and BS_CLEARMASK);
    while j < copyStart[ss] do begin
      k := Int32(ptr[j]) - 1; if k < 0 then Inc(k, nblock);
      c1 := block[k];
      if bigDone[c1] = 0 then begin
        ptr[copyStart[c1]] := UInt32(k);
        Inc(copyStart[c1]);
      end;
      Inc(j);
    end;
    j := Int32(ftab[(ss+1) shl 8] and BS_CLEARMASK) - 1;
    while j > copyEnd[ss] do begin
      k := Int32(ptr[j]) - 1; if k < 0 then Inc(k, nblock);
      c1 := block[k];
      if bigDone[c1] = 0 then begin
        ptr[copyEnd[c1]] := UInt32(k);
        Dec(copyEnd[c1]);
      end;
      Dec(j);
    end;

    AssertH(Bool(Ord(
      (copyStart[ss] - 1 = copyEnd[ss]) or
      ((copyStart[ss] = 0) and (copyEnd[ss] = nblock-1))
    )), 1007);

    for j := 0 to 255 do ftab[(j shl 8) + ss] := ftab[(j shl 8) + ss] or BS_SETMASK;

    // Step 3: mark [ss] done and update quadrant descriptors
    bigDone[ss] := BZ_TRUE;

    if i < 255 then begin
      bbStart := Int32(ftab[ss shl 8] and BS_CLEARMASK);
      bbSize  := Int32(ftab[(ss+1) shl 8] and BS_CLEARMASK) - bbStart;
      shifts  := 0;
      while (bbSize shr shifts) > 65534 do Inc(shifts);
      for j := bbSize-1 downto 0 do begin
        a2update := Int32(ptr[bbStart + j]);
        qVal := UInt16(j shr shifts);
        quadrant[a2update] := qVal;
        if a2update < BZ_N_OVERSHOOT then
          quadrant[a2update + nblock] := qVal;
      end;
      AssertH(Bool(Ord(((bbSize-1) shr shifts) <= 65535)), 1002);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// BZ2_blockSort — public entry point (mirrors BZ2_blockSort in blocksort.c)
// ---------------------------------------------------------------------------

procedure BZ2_blockSort(s: PEState);
var
  ptr:        PUInt32;
  block:      PUChar;
  ftab:       PUInt32;
  nblock:     Int32;
  verb:       Int32;
  wfact:      Int32;
  quadrant:   PUInt16;
  budget:     Int32;
  budgetInit: Int32;
  i:          Int32;
begin
  ptr    := s^.ptr;
  block  := s^.block;
  ftab   := s^.ftab;
  nblock := s^.nblock;
  verb   := s^.verbosity;
  wfact  := s^.workFactor;

  if nblock < 10000 then begin
    fallbackSort(s^.arr1, s^.arr2, ftab, nblock, verb);
  end else begin
    // Compute quadrant pointer after block[] with alignment padding
    i := nblock + BZ_N_OVERSHOOT;
    if (i and 1) <> 0 then Inc(i);
    quadrant := PUInt16(@block[i]);

    if wfact < 1   then wfact := 1;
    if wfact > 100 then wfact := 100;
    budgetInit := nblock * ((wfact - 1) div 3);
    budget     := budgetInit;

    mainSort(ptr, block, quadrant, ftab, nblock, verb, @budget);
    if budget < 0 then
      fallbackSort(s^.arr1, s^.arr2, ftab, nblock, verb);
  end;

  s^.origPtr := -1;
  for i := 0 to s^.nblock-1 do
    if ptr[i] = 0 then begin
      s^.origPtr := i;
      break;
    end;

  AssertH(Bool(Ord(s^.origPtr <> -1)), 1003);
end;

end.
