{$IFDEF FPC}
  {$COPERATORS ON}
  {$MODE OBJFPC}
  {$ASMMODE INTEL}
  {$INLINE ON}
  {$GOTO ON}          // required by Phase 6 (BZ2_decompress resume dispatch)
  {$MACRO ON}
  {$LONGSTRINGS ON}
  {$CODEPAGE UTF8}
  {$FPUTYPE SSE64}
  {$POINTERMATH ON}   // pointer arithmetic: Inc(p), p[k], p + n
  {$IFDEF CPU32BITS}
    {$DEFINE CPU32}
  {$ENDIF}
  {$IFDEF CPU64BITS}
    {$DEFINE CPU64}
  {$ENDIF}
  {$IFDEF CPUARM}
    {$DEFINE NOTAVX}
  {$ENDIF}
  {$IFDEF CPUAARCH64}
    {$DEFINE NOTAVX}
  {$ENDIF}
  {$IFDEF CPUPOWERPC}
    {$DEFINE NOTAVX}
  {$ENDIF}
  {$IFDEF CPUM68K}
    {$DEFINE NOTAVX}
  {$ENDIF}
  {$IFDEF NOTAVX}
    {$UNDEF AVX}
    {$UNDEF AVX2}
    {$UNDEF AVX512}
    {$UNDEF AVXANY}
  {$ENDIF}
  // Phase 10 — performance optimizations (task 10.2 / 10.3)
  // Keep local variables in registers wherever possible.
  {$OPTIMIZATION REGVAR}
  // Common-subexpression elimination and data-flow analysis allow the compiler
  // to hoist repeated address calculations out of tight loops.
  {$OPTIMIZATION CSE}
  {$OPTIMIZATION DFA}
  // Constant propagation lets the compiler fold invariant guard expressions
  // (e.g. bounds checks on array indices that are loop-invariant) at compile time.
  {$OPTIMIZATION CONSTPROP}
{$ELSE}
  // AVX code is supported only under FPC
  {$UNDEF AVX}
  {$UNDEF AVX2}
  {$UNDEF AVX512}
  {$UNDEF AVXANY}
  {$IFDEF CPU32BITS}
    {$DEFINE CPU32}
  {$ENDIF}
  {$IFDEF CPU64BITS}
    {$DEFINE CPU64}
  {$ENDIF}
{$ENDIF}

{$IFDEF CPU32}
  {$IFDEF AVX}
    {$DEFINE AVX32}
  {$ENDIF}
  {$IFDEF AVX2}
    {$DEFINE AVX32}
  {$ENDIF}
{$ENDIF}

{$IFDEF CPU64}
  {$IFDEF AVX}
    {$DEFINE AVX64}
  {$ENDIF}
  {$IFDEF AVX2}
    {$DEFINE AVX64}
  {$ENDIF}
{$ENDIF}

{$IFDEF AVX512}
  {$DEFINE AVX64}
  {$UNDEF AVX32}
{$ENDIF}

{$IFDEF AVX32}
  {$DEFINE AVXANY}
{$ENDIF}

{$IFDEF AVX64}
  {$DEFINE AVXANY}
{$ENDIF}
