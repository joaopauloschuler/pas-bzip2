{$I pasbzip2.inc}
unit cbzip2;

{
  External cdecl declarations of the C reference bzip2 library (libbz2.so).
  All Pascal-side names carry the cbz_ prefix to avoid collision with the
  Pascal port symbols defined in pasbzip2.pas.

  Used by test programs only; never referenced by the Pascal port itself.
}

interface

uses pasbzip2types;

const
  LIBBZ2 = 'bz2';

// ---------------------------------------------------------------------------
// Core (low-level) API
// ---------------------------------------------------------------------------

function cbz_bzCompressInit(strm: Pbz_stream;
    blockSize100k, verbosity, workFactor: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzCompressInit';

function cbz_bzCompress(strm: Pbz_stream; action: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzCompress';

function cbz_bzCompressEnd(strm: Pbz_stream): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzCompressEnd';

function cbz_bzDecompressInit(strm: Pbz_stream;
    verbosity, small: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzDecompressInit';

function cbz_bzDecompress(strm: Pbz_stream): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzDecompress';

function cbz_bzDecompressEnd(strm: Pbz_stream): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzDecompressEnd';

// ---------------------------------------------------------------------------
// One-shot in-memory helpers
// ---------------------------------------------------------------------------

function cbz_bzBuffToBuffCompress(
    dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    blockSize100k, verbosity, workFactor: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzBuffToBuffCompress';

function cbz_bzBuffToBuffDecompress(
    dest: PChar; destLen: PUInt32;
    source: PChar; sourceLen: UInt32;
    small, verbosity: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzBuffToBuffDecompress';

// ---------------------------------------------------------------------------
// Version query
// ---------------------------------------------------------------------------

function cbz_bzlibVersion: PChar;
    cdecl; external LIBBZ2 name 'BZ2_bzlibVersion';

// ---------------------------------------------------------------------------
// stdio wrappers (BZFILE-based)
// ---------------------------------------------------------------------------

function cbz_bzReadOpen(bzerror: PInt32; f: Pointer;
    verbosity, small: Int32; unused: Pointer; nUnused: Int32): Pointer;
    cdecl; external LIBBZ2 name 'BZ2_bzReadOpen';

procedure cbz_bzReadClose(bzerror: PInt32; b: Pointer);
    cdecl; external LIBBZ2 name 'BZ2_bzReadClose';

procedure cbz_bzReadGetUnused(bzerror: PInt32; b: Pointer;
    unused: PPointer; nUnused: PInt32);
    cdecl; external LIBBZ2 name 'BZ2_bzReadGetUnused';

function cbz_bzRead(bzerror: PInt32; b: Pointer;
    buf: Pointer; len: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzRead';

function cbz_bzWriteOpen(bzerror: PInt32; f: Pointer;
    blockSize100k, verbosity, workFactor: Int32): Pointer;
    cdecl; external LIBBZ2 name 'BZ2_bzWriteOpen';

procedure cbz_bzWrite(bzerror: PInt32; b: Pointer;
    buf: Pointer; len: Int32);
    cdecl; external LIBBZ2 name 'BZ2_bzWrite';

procedure cbz_bzWriteClose(bzerror: PInt32; b: Pointer;
    abandon: Int32; nbytes_in, nbytes_out: PUInt32);
    cdecl; external LIBBZ2 name 'BZ2_bzWriteClose';

procedure cbz_bzWriteClose64(bzerror: PInt32; b: Pointer;
    abandon: Int32;
    nbytes_in_lo32, nbytes_in_hi32: PUInt32;
    nbytes_out_lo32, nbytes_out_hi32: PUInt32);
    cdecl; external LIBBZ2 name 'BZ2_bzWriteClose64';

// ---------------------------------------------------------------------------
// zlib-compat helpers
// ---------------------------------------------------------------------------

function cbz_bzopen(path: PChar; mode: PChar): Pointer;
    cdecl; external LIBBZ2 name 'BZ2_bzopen';

function cbz_bzdopen(fd: Int32; mode: PChar): Pointer;
    cdecl; external LIBBZ2 name 'BZ2_bzdopen';

function cbz_bzread(b: Pointer; buf: Pointer; len: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzread';

function cbz_bzwrite(b: Pointer; buf: Pointer; len: Int32): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzwrite';

function cbz_bzflush(b: Pointer): Int32;
    cdecl; external LIBBZ2 name 'BZ2_bzflush';

procedure cbz_bzclose(b: Pointer);
    cdecl; external LIBBZ2 name 'BZ2_bzclose';

function cbz_bzerror(b: Pointer; errnum: PInt32): PChar;
    cdecl; external LIBBZ2 name 'BZ2_bzerror';

implementation

end.
