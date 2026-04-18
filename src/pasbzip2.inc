{$IFDEF FPC}
  {$MODE OBJFPC}
  {$H+}               // long strings
  {$INLINE ON}
  {$GOTO ON}          // required by Phase 6 (BZ2_decompress resume dispatch)
  {$COPERATORS ON}
  {$MACRO ON}
  {$CODEPAGE UTF8}
  {$POINTERMATH ON}   // pointer arithmetic: Inc(p), p[k], p + n
  {$IFDEF CPU32BITS} {$DEFINE CPU32} {$ENDIF}
  {$IFDEF CPU64BITS} {$DEFINE CPU64} {$ENDIF}
{$ENDIF}
