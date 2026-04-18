{$I pasbzip2.inc}
unit pasbzip2types;

{
  Pascal port of bzip2/libbzip2 1.1.0 — type definitions.
  Mirrors bzlib_private.h field-for-field.
}

interface

// ---------------------------------------------------------------------------
// Primitive type aliases
// FPC already provides Int32, UInt32, Int16, UInt16, Byte, Char/AnsiChar and
// their pointer forms — do not redefine them.  Only genuinely new names here.
// ---------------------------------------------------------------------------
type
  Bool   = Byte;     // bzip2 stores {0, 1} in arrays — NOT Pascal's Boolean
  UChar  = Byte;     // cosmetic alias matching C source spelling
  PBool  = ^Bool;
  PUChar = ^UChar;

const
  BZ_TRUE  : Bool = 1;
  BZ_FALSE : Bool = 0;

// ---------------------------------------------------------------------------
// Error / return-code constants  (bzlib.h)
// ---------------------------------------------------------------------------
const
  BZ_OK                = 0;
  BZ_RUN_OK            = 1;
  BZ_FLUSH_OK          = 2;
  BZ_FINISH_OK         = 3;
  BZ_STREAM_END        = 4;
  BZ_SEQUENCE_ERROR    = -1;
  BZ_PARAM_ERROR       = -2;
  BZ_MEM_ERROR         = -3;
  BZ_DATA_ERROR        = -4;
  BZ_DATA_ERROR_MAGIC  = -5;
  BZ_IO_ERROR          = -6;
  BZ_UNEXPECTED_EOF    = -7;
  BZ_OUTBUFF_FULL      = -8;
  BZ_CONFIG_ERROR      = -9;

// Stream-action constants  (bzlib.h)
const
  BZ_RUN    = 0;
  BZ_FLUSH  = 1;
  BZ_FINISH = 2;

// Header magic bytes  (bzlib_private.h)
const
  BZ_HDR_B = $42;   // 'B'
  BZ_HDR_Z = $5A;   // 'Z'
  BZ_HDR_h = $68;   // 'h'
  BZ_HDR_0 = $30;   // '0'

// ---------------------------------------------------------------------------
// Compression state-machine modes / sub-states  (bzlib_private.h)
// ---------------------------------------------------------------------------
const
  BZ_M_IDLE      = 1;
  BZ_M_RUNNING   = 2;
  BZ_M_FLUSHING  = 3;
  BZ_M_FINISHING = 4;

  BZ_S_OUTPUT    = 1;
  BZ_S_INPUT     = 2;

// Block-sort internal constants
const
  BZ_N_RADIX    = 2;
  BZ_N_QSORT    = 12;
  BZ_N_SHELL    = 18;
  BZ_N_OVERSHOOT = BZ_N_RADIX + BZ_N_QSORT + BZ_N_SHELL + 2;  // = 34

// Back-end Huffman constants
const
  BZ_MAX_ALPHA_SIZE = 258;
  BZ_MAX_CODE_LEN   = 23;
  BZ_RUNA           = 0;
  BZ_RUNB           = 1;
  BZ_N_GROUPS       = 6;
  BZ_G_SIZE         = 50;
  BZ_N_ITERS        = 4;
  BZ_MAX_SELECTORS  = 2 + (900000 div BZ_G_SIZE);  // = 18002

// Fast MTF decoder constants
const
  MTFA_SIZE = 4096;
  MTFL_SIZE = 16;

// Decompressor state constants  (bzlib_private.h)
const
  BZ_X_IDLE       = 1;
  BZ_X_OUTPUT     = 2;
  BZ_X_MAGIC_1    = 10;
  BZ_X_MAGIC_2    = 11;
  BZ_X_MAGIC_3    = 12;
  BZ_X_MAGIC_4    = 13;
  BZ_X_BLKHDR_1   = 14;
  BZ_X_BLKHDR_2   = 15;
  BZ_X_BLKHDR_3   = 16;
  BZ_X_BLKHDR_4   = 17;
  BZ_X_BLKHDR_5   = 18;
  BZ_X_BLKHDR_6   = 19;
  BZ_X_BCRC_1     = 20;
  BZ_X_BCRC_2     = 21;
  BZ_X_BCRC_3     = 22;
  BZ_X_BCRC_4     = 23;
  BZ_X_RANDBIT    = 24;
  BZ_X_ORIGPTR_1  = 25;
  BZ_X_ORIGPTR_2  = 26;
  BZ_X_ORIGPTR_3  = 27;
  BZ_X_MAPPING_1  = 28;
  BZ_X_MAPPING_2  = 29;
  BZ_X_SELECTOR_1 = 30;
  BZ_X_SELECTOR_2 = 31;
  BZ_X_SELECTOR_3 = 32;
  BZ_X_CODING_1   = 33;
  BZ_X_CODING_2   = 34;
  BZ_X_CODING_3   = 35;
  BZ_X_MTF_1      = 36;
  BZ_X_MTF_2      = 37;
  BZ_X_MTF_3      = 38;
  BZ_X_MTF_4      = 39;
  BZ_X_MTF_5      = 40;
  BZ_X_MTF_6      = 41;
  BZ_X_ENDHDR_2   = 42;
  BZ_X_ENDHDR_3   = 43;
  BZ_X_ENDHDR_4   = 44;
  BZ_X_ENDHDR_5   = 45;
  BZ_X_ENDHDR_6   = 46;
  BZ_X_CCRC_1     = 47;
  BZ_X_CCRC_2     = 48;
  BZ_X_CCRC_3     = 49;
  BZ_X_CCRC_4     = 50;

// ---------------------------------------------------------------------------
// bz_stream  (bzlib.h)
// ---------------------------------------------------------------------------
type
  Tbz_alloc_fn = function (opaque: Pointer; items, size: Int32): Pointer; cdecl;
  Tbz_free_fn  = procedure (opaque: Pointer; address: Pointer); cdecl;

  Pbz_stream = ^Tbz_stream;
  Tbz_stream = record
    next_in        : PChar;
    avail_in       : UInt32;
    total_in_lo32  : UInt32;
    total_in_hi32  : UInt32;

    next_out       : PChar;
    avail_out      : UInt32;
    total_out_lo32 : UInt32;
    total_out_hi32 : UInt32;

    state          : Pointer;

    bzalloc        : Tbz_alloc_fn;
    bzfree         : Tbz_free_fn;
    opaque         : Pointer;
  end;

// ---------------------------------------------------------------------------
// EState — compression side  (bzlib_private.h)
// ---------------------------------------------------------------------------
type
  PEState = ^TEState;
  TEState = record
    // pointer back to the struct bz_stream
    strm            : Pbz_stream;

    // mode this stream is in, and whether inputting or outputting data
    mode            : Int32;
    state           : Int32;

    // remembers avail_in when flush/finish requested
    avail_in_expect : UInt32;

    // for doing the block sorting
    arr1            : PUInt32;
    arr2            : PUInt32;
    ftab            : PUInt32;
    origPtr         : Int32;

    // aliases for arr1 and arr2
    ptr             : PUInt32;
    block           : PUChar;
    mtfv            : PUInt16;
    zbits           : PUChar;

    // for deciding when to use the fallback sorting algorithm
    workFactor      : Int32;

    // run-length-encoding of the input
    state_in_ch     : UInt32;
    state_in_len    : Int32;
    rNToGo          : Int32;   // BZ_RAND_DECLS
    rTPos           : Int32;   // BZ_RAND_DECLS

    // input and output limits and current positions
    nblock          : Int32;
    nblockMAX       : Int32;
    numZ            : Int32;
    state_out_pos   : Int32;

    // map of bytes used in block
    nInUse          : Int32;
    inUse           : array[0..255] of Bool;
    unseqToSeq      : array[0..255] of UChar;

    // the buffer for bit stream creation
    bsBuff          : UInt32;
    bsLive          : Int32;

    // block and combined CRCs
    blockCRC        : UInt32;
    combinedCRC     : UInt32;

    // misc administratium
    verbosity       : Int32;
    blockNo         : Int32;
    blockSize100k   : Int32;

    // stuff for coding the MTF values
    nMTF            : Int32;
    mtfFreq         : array[0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    selector        : array[0..BZ_MAX_SELECTORS - 1]  of UChar;
    selectorMtf     : array[0..BZ_MAX_SELECTORS - 1]  of UChar;

    len             : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of UChar;
    code            : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    rfreq           : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    // second dimension: only 3 needed; 4 makes index calculations faster
    len_pack        : array[0..BZ_MAX_ALPHA_SIZE - 1, 0..3] of UInt32;
  end;

// ---------------------------------------------------------------------------
// DState — decompression side  (bzlib_private.h)
// ---------------------------------------------------------------------------
type
  PDState = ^TDState;
  TDState = record
    // pointer back to the struct bz_stream
    strm                  : Pbz_stream;

    // state indicator for this stream
    state                 : Int32;

    // for doing the final run-length decoding
    state_out_ch          : UChar;
    state_out_len         : Int32;
    blockRandomised       : Bool;
    rNToGo                : Int32;   // BZ_RAND_DECLS
    rTPos                 : Int32;   // BZ_RAND_DECLS

    // the buffer for bit stream reading
    bsBuff                : UInt32;
    bsLive                : Int32;

    // misc administratium
    blockSize100k         : Int32;
    smallDecompress       : Bool;
    currBlockNo           : Int32;
    verbosity             : Int32;

    // for undoing the Burrows-Wheeler transform
    origPtr               : Int32;
    tPos                  : UInt32;
    k0                    : Int32;
    unzftab               : array[0..255] of Int32;
    nblock_used           : Int32;
    cftab                 : array[0..256] of Int32;
    cftabCopy             : array[0..256] of Int32;

    // for undoing the BWT (FAST path)
    tt                    : PUInt32;

    // for undoing the BWT (SMALL path)
    ll16                  : PUInt16;
    ll4                   : PUChar;

    // stored and calculated CRCs
    storedBlockCRC        : UInt32;
    storedCombinedCRC     : UInt32;
    calculatedBlockCRC    : UInt32;
    calculatedCombinedCRC : UInt32;

    // map of bytes used in block
    nInUse                : Int32;
    inUse                 : array[0..255] of Bool;
    inUse16               : array[0..15]  of Bool;
    seqToUnseq            : array[0..255] of UChar;

    // for decoding the MTF values
    mtfa                  : array[0..MTFA_SIZE - 1]        of UChar;
    mtfbase               : array[0..(256 div MTFL_SIZE) - 1] of Int32;
    selector              : array[0..BZ_MAX_SELECTORS - 1] of UChar;
    selectorMtf           : array[0..BZ_MAX_SELECTORS - 1] of UChar;
    len                   : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of UChar;

    limit                 : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    base                  : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    perm                  : array[0..BZ_N_GROUPS - 1, 0..BZ_MAX_ALPHA_SIZE - 1] of Int32;
    minLens               : array[0..BZ_N_GROUPS - 1] of Int32;

    // save area for scalars in the main decompress code
    save_i                : Int32;
    save_j                : Int32;
    save_t                : Int32;
    save_alphaSize        : Int32;
    save_nGroups          : Int32;
    save_nSelectors       : Int32;
    save_EOB              : Int32;
    save_groupNo          : Int32;
    save_groupPos         : Int32;
    save_nextSym          : Int32;
    save_nblockMAX        : Int32;
    save_nblock           : Int32;
    save_es               : Int32;
    save_N                : Int32;
    save_curr             : Int32;
    save_zt               : Int32;
    save_zn               : Int32;
    save_zvec             : Int32;
    save_zj               : Int32;
    save_gSel             : Int32;
    save_gMinlen          : Int32;
    save_gLimit           : PInt32;
    save_gBase            : PInt32;
    save_gPerm            : PInt32;
  end;

implementation

end.
