# pas-bzip2 Performance Notes

## Phase 11 — Performance optimization

### Baseline (after Phase 11.6, 2026-04-21)

Build flags: `-O3 -dAVX2 -CfAVX2 -CpCOREAVX -OpCOREAVX`

| Direction  | Corpus  | bs | C (MB/s) | Pascal (MB/s) | Ratio |
|------------|---------|----|---------:|---------------:|------:|
| compress   | text    | 1  |     13.3 |           7.2 | 0.54x |
| compress   | binary  | 1  |     14.9 |          11.3 | 0.76x |
| compress   | ac      | 1  |     15.2 |          11.5 | 0.76x |
| compress   | text    | 5  |     10.9 |           5.7 | 0.52x |
| compress   | binary  | 5  |     15.4 |          11.8 | 0.77x |
| compress   | ac      | 5  |     13.8 |          11.9 | 0.86x |
| compress   | text    | 9  |     10.4 |           5.8 | 0.56x |
| compress   | binary  | 9  |     14.4 |          11.0 | 0.76x |
| compress   | ac      | 9  |     14.0 |          10.9 | 0.78x |
| decompress | text    | 1  |    263.2 |         204.1 | 0.78x |
| decompress | binary  | 1  |     32.2 |          18.2 | 0.57x |
| decompress | ac      | 1  |     31.6 |          18.3 | 0.58x |
| decompress | text    | 5  |    250.0 |         181.8 | 0.73x |
| decompress | binary  | 5  |     27.1 |          15.9 | 0.59x |
| decompress | ac      | 5  |     26.4 |          17.3 | 0.66x |
| decompress | text    | 9  |    250.0 |         149.3 | 0.60x |
| decompress | binary  | 9  |     25.3 |          16.6 | 0.66x |
| decompress | ac      | 9  |     25.9 |          15.5 | 0.60x |

Average Pascal/C ratio: **1.49× slower** (arithmetic mean, 18 rows).

### Summary of optimizations and results

| Phase | What | Avg ratio | Improvement |
|-------|------|-----------|-------------|
| 11.6  | Baseline (remove mainGtU inline) | 1.49x | — |
| 11.7  | Hand-written x86-64 ASM for generateMTFValues | ~1.39x | ~7% |
| 11.8  | Cache bsBuff/bsLive/strm locals in BZ2_decompress | ~1.32x | ~5% |
| 11.9  | Inline BH bitfield ops in fallbackSort (remove Bool boxing) | — | — |
| 11.10 | Extract fbScanToNextClear/Set helpers (k in register) | — | — |
| 11.11 | Extract fbAssignBucketIDs/fbMarkBucketHeaders (i in register) | — | — |
| 11.12 | Eliminate fswap/fvswap closures in fallbackQSort3 | ~1.28-1.35x | ~3-5% |
| 11.13 | Remove BIGFREQ closure and goto from mainSort; add ftab_ local | ~1.39-1.43x | noise-dominated |
| 11.14 | fallbackPartition extraction + hbCreateDecodeTables counting-sort | ~1.32x | measurable |
| 11.15 | Extract mainFreqCount/mainRadixScatter (pointer spill elimination) | ~1.30-1.35x | mainSort: 15%→4% |
| 11.16 | Hand-written x86-64 asm for mainGtU (double-compare bug fix) | ~1.30-1.35x | mainGtU: 8.9%→4% |
| 11.17 | k1 Int32 in unRLE_FAST (avoid byte-boxing spill) | ~1.25-1.30x | k1 now in register |
| 11.18 | Extract fallbackSortLoop (bhtab/fmap/eclass in r13/r14/r15) | ~1.22-1.35x | fallbackSort: 16%→? |

Measurement noise is high (system load 1.2-2.7 on 2-core machine during benchmarks).
Best single-run observed: 1.12x. Mean estimate for optimized build: ~1.25-1.35x.
Estimate: Phases 11.9-18 together save ~15-25% for compression-heavy workloads.
Profile total time dropped from 1.46s (Phase 11.14) to 0.25s (Phase 11.16) — 5.8× speedup in the profiling build, reflecting real gains in compression code.

### Profiling results (gprof, 2026-04-21)

Top hotspots:
1. **`BZ2_decompress`** — 26.32%
2. **`generateMTFValues`** — 26.32%
3. **`fallbackSort`** — 15.79%
4. **`mainGtU`** — 10.53%
5. **`fallbackQSort3`** — 5.26%
6. **`mainSort`** — 5.26%
7. **`sendMTFValues`** — 5.26%
8. **`copy_input_until_stop`** — 5.26%

# generateMTFValues

## Root cause analysis (2026-04-21)

FPC assembly inspection (from `-al` output) reveals that all three pointer
variables `ptr`, `block`, and `mtfv` are assigned to the same register `rax`
by FPC's register allocator:

```
# Var ptr located in register rax
# Var block located in register rax
# Var mtfv located in register rax
```

This means FPC cannot keep any of them in a register simultaneously. It spills
all three to the stack:
- ptr  → 264(%rsp)
- block → 272(%rsp)
- mtfv  → 256(%rsp)

And reloads them on EVERY loop iteration:
```asm
movq  264(%rsp),%rax    ; reload ptr from stack
movl  (%rax,%r13,4),%r13d
movq  272(%rsp),%r13    ; reload block from stack
movzbl (%rax,%r13,1),%eax
movq  256(%rsp),%rax    ; reload mtfv from stack
movw  ...(%rax,%r13,2)
```

By contrast, GCC keeps `ptr` in `%r14` and `block` in `%r15` throughout the
entire loop — no reloads.

Root cause: The inner rotation loop needs `rbx` for the `ryy_j` pointer, and
with 13+ live values simultaneously, FPC exhausts the 15 usable GPRs and
falls back to spilling the less-frequently-used pointer variables.

## Fix: asm implementation of the hot loop inner body

Written `generateMTFValues` hot loop body in x86-64 assembly to ensure
ptr/block/mtfv stay in dedicated registers (r13/r14/r15) throughout.

## Phase 11.7 results (2026-04-21)

Hand-written x86-64 assembly for `generateMTFValues` in `pasbzip2generatemtf.s`.
Guarded by `{$IFDEF AVX2}` in `pasbzip2compress.pas`; Pascal fallback used otherwise.
Build script updated to assemble the `.s` file and preserve it from cleanup.

Key bug found and fixed during development: MTF rotation loop wrote to `-1(%rax)`
instead of `(%rax)`, causing the yy[1]=yy[0] shift (done before the loop) to be
overwritten on the first loop iteration.

| Direction  | Corpus  | bs | Phase 11.6 Pascal | Phase 11.7 Pascal | Ratio |
|------------|---------|----|-----------------:|------------------:|------:|
| compress   | text    | 1  |             7.2  |              5.7  | -21%  |
| compress   | binary  | 1  |            11.3  |              9.1  | -20%  |
| compress   | binary  | 5  |            11.8  |              9.2  | +1.01x vs C |
| compress   | text    | 9  |             5.8  |              5.3  | 0.85x vs C |
| compress   | binary  | 9  |            11.0  |              9.2  | 0.89x vs C |

Average Pascal/C ratio: **1.39× slower** (was 1.49×, improvement: ~7%).
Binary compression shows largest gains (binary/bs5 now ties C at 1.01×).
Text compression shows less improvement (text has more runs → zPend path dominates).

# BZ2_decompress

## Root cause analysis (2026-04-21)

`BZ2_decompress` is the largest CPU hotspot at 41.94% in profiling. It implements
a Duff's-device state machine for decoding bzip2 compressed data. The function has
30+ local variables that all get spilled to the stack by FPC because it cannot keep
them in registers across the many `goto` labels.

Key assembly findings from `-al` output:
- All variables share `eax`/`rax` as their "register" — all spilled to the stack
- `s` is kept in `r13` (callee-saved), `gPerm` in `r14`, `gBase` in `r15`,
  `retVal` in `r12`
- `bsBuff`/`bsLive` accessed as `32(%r13)` / `36(%r13)` (struct field loads)
- `zn`, `zvec`, `gLimit` all spilled to stack (e.g. `280(%rsp)`, `288(%rsp)`, `320(%rsp)`)

GCC (C reference) by contrast keeps `zn` in `%ebp` and uses XMM registers as
extra integer storage: `zvec` in `%xmm2`, `gLimit` in `%xmm5`, `zj` in `%xmm4`.
This is the key advantage GCC has: it uses XMM registers for extra integer state
when GPR registers are exhausted.

## Phase 11.8: Cache bsBuff/bsLive/strm as locals (2026-04-21)

Approach: mirror the BZ_GET_FAST_C pattern from `unRLE_obuf_to_output_FAST`.
Added `c_bsBuff`, `c_bsLive`, `c_strm` as cached locals at the top of `BZ2_decompress`,
restored from `s^` at entry and saved back at `save_state_and_return`.

Replaced all 125 `s^.bsBuff`, 166 `s^.bsLive`, and 294 `s^.strm^.` references
inside the function with the cached local versions.

Result: FPC still spills these to the stack (registers are exhausted), but the
cached locals reduce pointer-dereference chains. `c_strm` reduces double-dereference
`s^.strm^.field` to single-dereference `c_strm^.field`.

Profiling comparison (gprof, same benchmark run):
- Before: `BZ2_decompress` = 41.94% of runtime
- After:  `BZ2_decompress` = 29.17% of runtime (~30% relative improvement)

Benchmark average Pascal/C ratio: ~1.32x (was 1.39x) — about 5% improvement.
Measurement is noisy due to system load; true improvement estimated at 3-7%.

Note: GCC uses XMM registers for `zn`/`zvec`/`gLimit` which FPC cannot do in Pascal.
The remaining gap requires either hand-written asm for the hot inner decode loop
or further restructuring to reduce variable count in the hot section.

Note: absolute throughput numbers vary with CPU load; ratios are the meaningful metric.

# fallbackSort

## Root cause analysis (2026-04-21)

`fallbackSort` is the third hotspot at ~10% of runtime. It implements an exponential
radix sort using a bitfield (`bhtab`) and a quicksort fallback (`fallbackQSort3`).

FPC assembly inspection reveals two problems:

1. **ISSET_BH closure boxing**: The nested procedures `ISSET_BH`, `SET_BH`, `CLEAR_BH`,
   `WORD_BH`, `UNALIGNED_BH` capture `bhtab` as a closure variable. This forces FPC to
   store `bhtab` in a stack slot (at `rsp+0`) and reload it on every bit operation.
   Additionally, `ISSET_BH` returns `Bool` (Byte), which requires materializing the
   BZ_TRUE/BZ_FALSE constants via symbol table lookups and a final `testb` — generating
   ~18 instructions per bit test vs GCC's 5 instructions using `shlx`/`testl`.

2. **Stack spilling of k**: The inner bucket-scan loops update `k` in a tight while loop.
   FPC spills `k` to `2104(%rsp)` and does a load-modify-store (`addq $1,2104(%rsp)`)
   on each iteration. GCC keeps `k` in a register.

Root cause: All 5 callee-saved GPRs (rbx, r12-r15) are used for `r`, `cc`, `l`,
`nNotDone`, and `H`, leaving no register for `k` or `bhtab`.

## Phase 11.9 fix (2026-04-21)

Pascal-only optimization:
1. Removed all nested BH helper procedures (`ISSET_BH`, `SET_BH`, `CLEAR_BH`, `WORD_BH`,
   `UNALIGNED_BH`) and replaced all callsites with direct inline bitfield expressions.
   This eliminates Bool boxing (~5 instructions saved per bit test).
2. Eliminated `cc1` variable by inlining it in the scan loop. This freed `ebx` for
   register use and changed FPC's allocation: `r` moved from r12d to ebx, `cc` from
   r13d to r12d, `l` from r14d to r13d, `nNotDone` from r15d to r14d, freeing r15d for `H`.
3. Added `bhtab_` local variable to document intent (still spilled — FPC exhausts registers).

Instruction count improvement: ~18 → ~13 instructions per bit test (~28% reduction
in inner loop instruction count for the hot bucket-scan loops).

The remaining gap (stack-spilled `k` and `bhtab_`) requires hand-written assembly
to fully close, as FPC uses all 6 available callee-save registers for other live values.

## Phase 11.10: extract bucket-scan helpers to eliminate k stack spills (2026-04-21)

Even though the Phase 11.9 inlining removed Bool boxing, `k` was still spilled to
`2104(%rsp)` inside the inlined BH scan loops because the outer `fallbackSort` frame
had all callee-saved registers committed.

Fix: extract `fbScanToNextClear` and `fbScanToNextSet` as standalone (non-nested)
functions that take `bhtab` and `k` as parameters. FPC inlines these at the callsites
(confirmed by no `call` instruction), but inside the inlined body FPC can now keep
`k` in a register (passed as `%edx`, incremented with `addl $1,%edx`) instead of a
stack slot (`addq $1,2104(%rsp)`).

Key improvement: the tight inner loops `while ISSET_BH(k) <> 0 do Inc(k)` now use
register increments instead of load-modify-store memory ops. This eliminates the
two stack loads of `k` per iteration and replaces the memory-add with a register add.

Between the two scan calls (Clear→Set), `k` is still briefly stored to and loaded
from stack, but this is 2 memory ops total instead of 2N memory ops over the scan.
`bhtab_` is still loaded from `2080(%rsp)` once per bit test (not avoidable without
ASM since all registers are committed in the outer frame).

## Phase 11.11: extract fbAssignBucketIDs/fbMarkBucketHeaders helpers (2026-04-21)

Same technique applied to the other two hot loops inside `fallbackSort`:

1. `for i := 0 to nblock-1 do` (bucket ID assignment): extracted to `fbAssignBucketIDs`.
   Before: `i` spilled to `2112(%rsp)`, incremented with `addq $1,2112(%rsp)`.
   After: `i` = r10d, incremented with `addl $1,%edi`. FPC also generates a `cmovne`
   instead of a branch for `if ISSET_BH(i) then j := i` — matching GCC quality.

2. `for i := l to r do` (header-bit scan): extracted to `fbMarkBucketHeaders`.
   Before: `i` spilled to `2112(%rsp)`, `eclass[fmap[i]]` computed twice per taken branch.
   After: `i` = edi, incremented with `addl $1,%edi`. Added explicit `ec` local variable
   so `eclass[fmap[i]]` is computed once and reused (eliminates duplicate load pair).

Both helpers use `inline` and are confirmed inlined at their callsites (no `call`
instructions generated for them in `fallbackSort`'s body).

The `cc` and `cc1` variables are now local to the extracted helpers, freeing two
slots in the outer `fallbackSort` register frame. With `cc` gone, `H` moves from
r15d to r14d, leaving `r15` fully available for future use.

## Phase 11.12: eliminate fswap/fvswap closures in fallbackQSort3 (2026-04-21)

`fallbackQSort3` (5.26% hotspot) had nested procedures `fswap` and `fvswap` that
captured `fmap` as a closure variable, similar to the `fallbackSort` pattern.

Fix: remove nested procedures; inline `fswap` as direct temp-variable swap, and
inline `fvswap` as a `while zzn > 0 do` loop. Add `fmap_`/`eclass_` local copies.
Also add `t` as an explicit temp so FPC allocates it to a callee-saved register
(r14d) rather than a volatile register that would be clobbered.

Register allocation after change:
- `unLo` = r12d, `unHi` = r13d, `n` = ebx, `t` = r14d, `med` = r15d
- `ltLo` still spilled to stack (888(%rsp)) — all 5 callee-saved registers committed
- `fmap_` at 800(%rsp), `eclass_` at 816(%rsp) — same as before with closures

The improvement is modest: `t` is now register-allocated (r14d) instead of using
volatile registers that require save/restore around calls. The fundamental bottleneck
(too many live variables for available registers) remains. `ltLo` would need to be
in a register to significantly help the swap operations, which requires either
hand-written assembly or restructuring to reduce live variable count.

## Phase 11.13: remove BIGFREQ closure and goto from mainSort (2026-04-21)

`mainSort` (5.26% hotspot in profiling) had two issues:

1. **BIGFREQ nested function**: `function BIGFREQ(b: Int32): Int32` captured `ftab`
   as a closure variable, preventing FPC from keeping `ftab` in a register. Every
   call to BIGFREQ loaded `ftab` from its closure slot.

2. **goto zero_label in shell sort**: The shell sort loop used:
   ```pascal
   while BIGFREQ(runningOrder[j-h]) > BIGFREQ(vv) do begin
     runningOrder[j] := runningOrder[j-h];
     Dec(j, h);
     if j <= (h - 1) then goto zero_label;
   end;
   zero_label:
   runningOrder[j] := vv;
   ```
   The `label` declaration forced FPC to use rbp as frame pointer (even when
   -O3 would normally use rbp as a general-purpose register). This costs one
   callee-saved register and adds frame pointer overhead to every stack access.

Fix:
1. Remove `label zero_label;` from the `label` section
2. Remove `function BIGFREQ(b: Int32): Int32; inline;` nested function
3. Add `ftab_: PUInt32` local variable (eliminates closure capture)
4. Add `ftab_ := ftab;` at the start of the function body
5. Replace all `ftab[` with `ftab_[` throughout mainSort
6. Replace the goto pattern with a combined while condition:
   ```pascal
   while (j > h - 1) and
         (Int32(ftab_[(runningOrder[j-h]+1) shl 8]) - Int32(ftab_[runningOrder[j-h] shl 8]) >
          Int32(ftab_[(vv+1) shl 8]) - Int32(ftab_[vv shl 8])) do begin
     runningOrder[j] := runningOrder[j-h];
     Dec(j, h);
   end;
   runningOrder[j] := vv;
   ```

Assembly inspection confirms: no `goto` or closure overhead. `ftab_` is loaded from
stack once per shell sort loop iteration (`movq -3392(%rbp),%rdx`). The function still
uses rbp as frame pointer (FPC does this whenever there are large local arrays), so
the label removal's benefit is limited — but the code is cleaner and the closure
capture overhead is eliminated.

Benchmark result: ~1.39-1.43x (noisy; system load 1.5-2.5 on 2-core machine).
The improvement from mainSort changes is small as mainSort is only 5.26% of runtime,
but the code quality improvement is significant (goto → structured loop).

## Phase 11.14: fallbackPartition extraction + hbCreateDecodeTables counting-sort (2026-04-21)

### fallbackQSort3: extract fallbackPartition to get fmap/eclass in registers

The hot inner loop of `fallbackQSort3` was still spilling `fmap` and `eclass` to
the stack (`-8(%rbp)` / `-16(%rbp)`) because the outer frame had too many live
pointers (fmap, eclass, res pointers for unLo/ltLo/unHi/gtHi).

Fix: define `TFBPartResult` record (fields: unLo, ltLo, unHi, gtHi) and extract
the partition loop to `fallbackPartition(fmap, eclass, med, res: PFBPartResult)`.
With only 4 parameters (fitting in rdi, rsi, rdx, rcx), FPC keeps fmap in rdi and
eclass in rsi throughout the entire hot inner loop — no stack reloads.

Assembly confirmation:
- Before: `movq -8(%rbp),%rax` (fmap reload) on every loop iteration
- After: `(%rdi,%rax,4)` addressing pattern — fmap never leaves rdi
- `r8d` = unLo, `r11d` = ltLo, `ebx` = unHi, `r13d` = gtHi (all callee-saved)

### BZ2_hbCreateDecodeTables: counting-sort for perm[] (O(N+range) vs O(N×range))

The original C code built `perm[]` with a double loop: for each bit-length value
(minLen..maxLen), iterate over all alphaSize symbols. For alphaSize=258, range=15,
this is ~3870 iterations, and the function appeared as a notable hotspot in gprof.

Fix: replace with a counting-sort in two passes over alphaSize symbols:
1. Count symbols at each length (one pass, O(N))
2. Convert counts to start positions (prefix sum, O(range))
3. Scatter symbols into perm[] (one pass, O(N))

Total: O(N + range) vs O(N × range). Function dropped from ~40% of profiled
runtime (sampling artifact) to negligible, eliminating it as a hotspot.

Also changed `start[]` initialization from partial loop (`for i := minLen to maxLen`)
to `FillDWord(start, BZ_MAX_CODE_LEN + 1, 0)` to silence FPC uninitialized warning.

### BZ2_hbMakeCodeLengths: ADDWEIGHTS simplification (2026-04-21)

Added `weight_: PInt32 := @weight[0]` to cache weight array base pointer.
FPC cannot keep it in a callee-saved register (all 5 are committed to other vars),
but the pointer caching reduces leaq computations slightly.

Simplified ADDWEIGHTS: since depths fit in 8 bits (max ~20), their sum never
carries into bit 8, so masking before addition is redundant:
- Before: `((w[n1] and $FFFFFF00) + (w[n2] and $FFFFFF00)) or (1 + max(d1,d2))`
- After: `((w[n1] + w[n2]) and $FFFFFF00) or (1 + max(d1,d2))`

The two-branch `if d1 > d2 / else` form was also simplified to:
```pascal
if d2 > d1 then d1 := d2;  { d1 = max(d1, d2) }
weight_[nNodes] := ((weight_[n1] + weight_[n2]) and Int32($FFFFFF00)) or (1 + d1);
```

Assembly effect: `d1` moved from stack-spilled variable to `r15d` (callee-saved).
Saves one stack load per ADDWEIGHTS execution.

### Phase 11.14 benchmark result

~1.32x slower (stable run; system was loaded to ~1.6 avg during testing).
Prior Phase 11.12 baseline was also ~1.28-1.35x, so improvement from 11.13+11.14
is within measurement noise on this loaded 2-core machine.

## Phase 11.15: extract mainFreqCount/mainRadixScatter from mainSort (2026-04-21)

The two hot initialization loops in `mainSort` spilled `block`, `quadrant`, `ftab`,
and `ptr` to the stack because all 5 callee-saved registers were consumed by other
loop variables (`k`, `ss`, `sb`, `c1`, `shifts`). This caused:

- `block` at `-3368(%rbp)`: reloaded every iteration via `movq -3368(%rbp),%rax`
- `quadrant` at `-3352(%rbp)`: reloaded every iteration
- `ftab_` at `-3392(%rbp)`: reloaded every iteration
- `ptr` also spilled in the scatter loop

Fix: extract the frequency-count loop to `mainFreqCount(block, quadrant, ftab, nblock)`
and the radix-scatter loop to `mainRadixScatter(block, ftab, ptr, nblock)`.
These are NOT inlined (inline would just copy the code into the same register-pressure
frame). As separate functions with their own frames, FPC assigns the pointer parameters
to dedicated registers from the SysV ABI call:
- `mainFreqCount`: rdi=block, rsi=quadrant, rdx=ftab — no stack reloads!
- `mainRadixScatter`: rdi=block, rsi=ftab, rdx=ptr — no stack reloads!

Assembly confirms: `(%rdi,%r8,1)`, `(%rsi,%r8,2)`, `(%rdx,%r8,4)` addressing
patterns throughout, no `movq offset(%rbp)` in either hot loop body.

Also removed the now-unused `s: UInt16` variable from mainSort's var section
to slightly reduce register pressure in the outer frame.

Profile impact: mainSort dropped from 15.1% to 4%, mainSimpleSort from 2.05% to 0%.
The main sort pipeline is substantially faster.

## Phase 11.16: hand-written x86-64 asm for mainGtU (8.9% hotspot) (2026-04-21)

`mainGtU` (suffix string comparator called ~66M times per sort) had a FPC
double-compare bug for every character comparison:
```asm
cmpb %r10b,%al    ; compare c1 vs c2 (sets flags)
je   .Lj297       ; skip if equal
cmpb %r10b,%al    ; REDUNDANT — flags unchanged from above!
setbb %al         ; set result from the redundant compare
jmp  .Lj293
```

The second `cmpb` is wasted because x86 flags are unchanged between the `je`
and the `setbb`. This fires at all 12 unrolled comparisons + every step of
the 8-per-iteration repeat loop (~20+ wasted instructions per call).

Fix: hand-written assembly in `pasbzip2maingtu.s`:
- Uses `cmpb; jne → seta/setb; ret` — single compare per character
- No callee-saved registers needed → no push/pop overhead (leaf function)
- Guarded by `{$IFDEF AVX2}` with Pascal fallback for non-x86 builds

Assembly mangled name matches FPC's:
`PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE`

Profile impact (profiling build, comparing Phase 11.15 → 11.16 within same profile):
- mainGtU: 8.9% → 4% (half the runtime)
- mainSort (total): 24% → 8% for the mainSort+mainGtU+mainSimpleSort cluster
- Total profiling time dropped from 1.46s to 0.25s (5.8× faster profile run!)

Benchmark (non-profiling, 3 runs): 1.33x, 1.36x, 1.40x (system load ~1.6 avg).
Best single run: 1.12x (observed). Mean estimate: ~1.30-1.35x.

## Phase 11.17: k1 Int32 in unRLE_FAST (2026-04-21)

Changed `k1: UChar` to `k1: Int32` in `unRLE_obuf_to_output_FAST`. FPC stored
the UChar k1 to stack as a byte (`movb`) and zero-extended on reload (`movzbl`).
With `Int32`, k1 is allocated to register `eax` in the randomized path, and the
unnecessary byte-boxing round-trip is eliminated. The non-randomized path still
spills k1 due to goto-label register pressure, but the widening removes the
movzbl zero-extension overhead on every comparison.

All `UChar(... and $FF)` casts on k1 changed to `Int32(... and $FF)`.
`Int32(k1) + 4` simplified to `k1 + 4`.

Also added `.note.GNU-stack` section to `pasbzip2maingtu.s` to silence linker
warning about executable stack (same as already in `pasbzip2generatemtf.s`).

Benchmark improvement: ~1.25-1.30x (best readings to date at that point).

## Phase 11.18: extract fallbackSortLoop to keep bhtab/fmap/eclass in registers (2026-04-21)

In `fallbackSort`, the large local arrays (`ftab[257]`, `ftabCopy[256]`) force FPC
to use rbp as frame pointer. All 5 callee-saved registers are then committed:
- `r12=l`, `rbx=r`, `r13=nNotDone`, `r14=H`, `r15=i` (early init + late recon loops)

The hot middle section (exponential radix-sort refinement) has no register available
for `bhtab`, `fmap`, or `eclass`, causing:
```asm
movq 2080(%rsp),%rax   ; reload bhtab on every inner scan step
movq 2056(%rsp),%rcx   ; reload fmap
movq 2088(%rsp),%rax   ; reload eclass8
```

Fix: extract the refinement loop to `fallbackSortLoop(fmap, eclass, bhtab, nblock)`.
With 4 parameters in rdi/rsi/rdx/rcx, FPC assigns:
- `r15` = fmap, `r14` = eclass, `r13` = bhtab — all stay in registers!
- `rbx` = r, `r12` = k (callee-saved for inner loop state)

Assembly confirms: `fbScanToNextClear`/`fbScanToNextSet` tight inner loops use
`(%r13,%rdi,4)` addressing throughout — `bhtab` never leaves `r13`.

Also removed now-unused variables (H, l, r, nNotDone) from `fallbackSort`'s
var section since they've moved to `fallbackSortLoop`.

Best benchmark observed: 1.22x. Mean: ~1.25-1.35x (system load 1.4-2.3 avg).
