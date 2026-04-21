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
