{$I pasbzip2.inc}
program Benchmark;

{
  Phase 9.1 — MB/s throughput benchmark: Pascal vs C libbz2.

  For each of (compress, decompress) x (blockSize100k: 1, 5, 9) x 3 corpora:
    - text   : 1 MB cycling printable ASCII (high compressibility)
    - binary : 1 MB pseudo-random bytes    (low compressibility)
    - ac     : ~1 MB bzip2-compressed random data (already-compressed; resists re-compression)

  Each cell runs BENCH_ITERS back-to-back iterations for both Pascal and C.
  Reports MB/s (input bytes throughput) and Pascal/C ratio for every row.
  A summary table is printed at the end for recording in tasklist.md.
}

uses
  SysUtils, DateUtils,
  pasbzip2types,
  pasbzip2,
  cbzip2;

const
  CORPUS_SIZE   = 1048576;   // 1 MB raw input for compress/decompress
  BENCH_ITERS   = 10;        // iterations per (corpus x bs x direction) cell
  TIE_THRESHOLD = 0.05;      // within 5% => tie

var
  GlobalSink  : UInt32 = 0;
  PWins       : Int32 = 0;
  CWins       : Int32 = 0;
  PTies       : Int32 = 0;
  TotalRows   : Int32 = 0;
  TotalRatio  : Double = 0.0;

// ---------------------------------------------------------------------------
// PRNG — 32-bit LCG (same constants used throughout the test suite)
// ---------------------------------------------------------------------------
var
  gSeed: UInt32;

procedure SeedRng(s: UInt32); inline;
begin
  gSeed := s;
end;

function NextRnd: Byte; inline;
begin
  gSeed := gSeed * 1664525 + 1013904223;
  NextRnd := Byte(gSeed shr 24);
end;

// ---------------------------------------------------------------------------
// Corpus descriptors
// ---------------------------------------------------------------------------
type
  TCorpus = record
    data: PByte;
    size: SizeInt;   // number of valid bytes in data[]
  end;

// 1 MB cycling printable ASCII (0x20 .. 0x7E)
function MakeTextCorpus: TCorpus;
var
  i: SizeInt;
begin
  Result.size := CORPUS_SIZE;
  Result.data := GetMem(CORPUS_SIZE + 1);
  for i := 0 to CORPUS_SIZE - 1 do
    Result.data[i] := Byte(Ord(' ') + (i mod (Ord('~') - Ord(' ') + 1)));
end;

// 1 MB pseudo-random bytes
function MakeBinaryCorpus: TCorpus;
var
  i: SizeInt;
begin
  Result.size := CORPUS_SIZE;
  Result.data := GetMem(CORPUS_SIZE + 1);
  SeedRng($DEADBEEF);
  for i := 0 to CORPUS_SIZE - 1 do
    Result.data[i] := NextRnd;
end;

// "Already-compressed" corpus: compress 1 MB of random bytes with bs=9
// and use the bzip2 output as the corpus.  The resulting data is high-entropy
// and resists further compression, simulating a .bz2 / .mp3 / .jpg payload.
function MakeAlreadyCompressedCorpus: TCorpus;
var
  src  : PByte;
  cMax : SizeInt;
  cLen : UInt32;
  ret  : Int32;
  i    : SizeInt;
begin
  SeedRng($C0FFEE42);
  src := GetMem(CORPUS_SIZE + 1);
  for i := 0 to CORPUS_SIZE - 1 do
    src[i] := NextRnd;

  cMax := CORPUS_SIZE + CORPUS_SIZE div 100 + 1024;
  Result.data := GetMem(cMax + 1);
  cLen := cMax;

  ret := BZ2_bzBuffToBuffCompress(PChar(Result.data), @cLen,
                                  PChar(src), CORPUS_SIZE,
                                  9, 0, 30);
  FreeMem(src);
  if ret <> BZ_OK then
  begin
    WriteLn('WARNING: MakeAlreadyCompressedCorpus: compress failed (ret=', ret, ')');
    FreeMem(Result.data);
    Result.data := nil;
    Result.size := 0;
  end
  else
    Result.size := SizeInt(cLen);
end;

// ---------------------------------------------------------------------------
// Utility: pre-compress a corpus with given block size.
// Caller must FreeMem(cBuf) when done.
// ---------------------------------------------------------------------------
function PreCompress(const corpus: TCorpus; blockSize100k: Int32;
                     out cBuf: PByte; out cSize: SizeInt): Boolean;
var
  cMax: SizeInt;
  cLen: UInt32;
  ret : Int32;
begin
  cMax := corpus.size + corpus.size div 100 + 1024 + 256;
  if cMax < 1024 then cMax := 1024;
  cBuf := GetMem(cMax + 1);
  cLen := cMax;
  ret := BZ2_bzBuffToBuffCompress(PChar(cBuf), @cLen,
                                  PChar(corpus.data), corpus.size,
                                  blockSize100k, 0, 30);
  if ret <> BZ_OK then
  begin
    WriteLn(Format('  PreCompress failed bs=%d ret=%d', [blockSize100k, ret]));
    FreeMem(cBuf);
    cBuf  := nil;
    cSize := 0;
    Result := False;
    Exit;
  end;
  cSize  := SizeInt(cLen);
  Result := True;
end;

// ---------------------------------------------------------------------------
// Record one benchmark row into the global counters + print it.
// ---------------------------------------------------------------------------
procedure RecordRow(const rowName: string; mbP, mbC: Double);
var
  ratio: Double;
  tag  : string;
begin
  if mbC > 0.0 then ratio := mbP / mbC
  else ratio := 0.0;

  if mbP > mbC * (1.0 + TIE_THRESHOLD) then
  begin
    tag := '  FASTER';
    Inc(PWins);
  end
  else if mbC > mbP * (1.0 + TIE_THRESHOLD) then
  begin
    tag := '';
    Inc(CWins);
  end
  else
  begin
    tag := '  TIE';
    Inc(PTies);
  end;

  TotalRatio := TotalRatio + ratio;
  Inc(TotalRows);

  WriteLn(Format('  %-46s  C: %6.1f MB/s  Pascal: %6.1f MB/s  ratio: %.2fx%s',
    [rowName, mbC, mbP, ratio, tag]));
end;

// ---------------------------------------------------------------------------
// Compress benchmark row
// ---------------------------------------------------------------------------
procedure BenchCompress(const rowName: string;
                        const corpus: TCorpus;
                        blockSize100k: Int32);
var
  dstMax  : SizeInt;
  dstPas  : PByte;
  dstC    : PByte;
  dstLen  : UInt32;
  ret     : Int32;
  iter    : Int32;
  t0, t1  : TDateTime;
  msP, msC: Int64;
  mbP, mbC: Double;
  sink    : UInt32;
begin
  if corpus.data = nil then
  begin
    WriteLn(Format('  SKIP %-46s (corpus unavailable)', [rowName]));
    Exit;
  end;

  dstMax := corpus.size + corpus.size div 100 + 1024 + 256;
  if dstMax < 1024 then dstMax := 1024;
  dstPas := GetMem(dstMax + 1);
  dstC   := GetMem(dstMax + 1);
  sink   := 0;

  // Pascal
  t0 := Now;
  for iter := 1 to BENCH_ITERS do
  begin
    dstLen := dstMax;
    ret := BZ2_bzBuffToBuffCompress(PChar(dstPas), @dstLen,
                                    PChar(corpus.data), corpus.size,
                                    blockSize100k, 0, 30);
    if ret <> BZ_OK then
      WriteLn(Format('  WARN Pascal compress iter=%d ret=%d', [iter, ret]));
    sink := sink xor PUInt32(dstPas)^;
  end;
  t1 := Now;
  msP := MillisecondsBetween(t1, t0);

  // C reference
  t0 := Now;
  for iter := 1 to BENCH_ITERS do
  begin
    dstLen := dstMax;
    ret := cbz_bzBuffToBuffCompress(PChar(dstC), @dstLen,
                                    PChar(corpus.data), corpus.size,
                                    blockSize100k, 0, 30);
    if ret <> BZ_OK then
      WriteLn(Format('  WARN C compress iter=%d ret=%d', [iter, ret]));
    sink := sink xor PUInt32(dstC)^;
  end;
  t1 := Now;
  msC := MillisecondsBetween(t1, t0);

  GlobalSink := GlobalSink xor sink;

  if msP > 0 then mbP := (Double(corpus.size) * BENCH_ITERS / 1048576.0) / (msP / 1000.0)
  else mbP := 9999.9;
  if msC > 0 then mbC := (Double(corpus.size) * BENCH_ITERS / 1048576.0) / (msC / 1000.0)
  else mbC := 9999.9;

  RecordRow(rowName, mbP, mbC);

  FreeMem(dstPas);
  FreeMem(dstC);
end;

// ---------------------------------------------------------------------------
// Decompress benchmark row
// Pre-compresses the corpus, then times repeated decompression back.
// Throughput is reported in terms of the original (decompressed) bytes.
// ---------------------------------------------------------------------------
procedure BenchDecompress(const rowName: string;
                          const corpus: TCorpus;
                          blockSize100k: Int32);
var
  cBuf        : PByte;
  cSize       : SizeInt;
  dstPas, dstC: PByte;
  dstLen      : UInt32;
  dstMax      : SizeInt;
  ret         : Int32;
  iter        : Int32;
  t0, t1      : TDateTime;
  msP, msC    : Int64;
  mbP, mbC    : Double;
  sink        : UInt32;
begin
  if corpus.data = nil then
  begin
    WriteLn(Format('  SKIP %-46s (corpus unavailable)', [rowName]));
    Exit;
  end;

  if not PreCompress(corpus, blockSize100k, cBuf, cSize) then
  begin
    WriteLn(Format('  SKIP %-46s (pre-compress failed)', [rowName]));
    Exit;
  end;

  dstMax := corpus.size + 1024;
  dstPas := GetMem(dstMax + 1);
  dstC   := GetMem(dstMax + 1);
  sink   := 0;

  // Pascal
  t0 := Now;
  for iter := 1 to BENCH_ITERS do
  begin
    dstLen := dstMax;
    ret := BZ2_bzBuffToBuffDecompress(PChar(dstPas), @dstLen,
                                      PChar(cBuf), cSize, 0, 0);
    if ret <> BZ_OK then
      WriteLn(Format('  WARN Pascal decompress iter=%d ret=%d', [iter, ret]));
    sink := sink xor PUInt32(dstPas)^;
  end;
  t1 := Now;
  msP := MillisecondsBetween(t1, t0);

  // C reference
  t0 := Now;
  for iter := 1 to BENCH_ITERS do
  begin
    dstLen := dstMax;
    ret := cbz_bzBuffToBuffDecompress(PChar(dstC), @dstLen,
                                      PChar(cBuf), cSize, 0, 0);
    if ret <> BZ_OK then
      WriteLn(Format('  WARN C decompress iter=%d ret=%d', [iter, ret]));
    sink := sink xor PUInt32(dstC)^;
  end;
  t1 := Now;
  msC := MillisecondsBetween(t1, t0);

  GlobalSink := GlobalSink xor sink;

  if msP > 0 then mbP := (Double(corpus.size) * BENCH_ITERS / 1048576.0) / (msP / 1000.0)
  else mbP := 9999.9;
  if msC > 0 then mbC := (Double(corpus.size) * BENCH_ITERS / 1048576.0) / (msC / 1000.0)
  else mbC := 9999.9;

  RecordRow(rowName, mbP, mbC);

  FreeMem(cBuf);
  FreeMem(dstPas);
  FreeMem(dstC);
end;

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
const
  BS_NAMES  : array[0..2] of string = ('bs1', 'bs5', 'bs9');
  BS_VALUES : array[0..2] of Int32  = (1, 5, 9);

var
  textCorpus  : TCorpus;
  binCorpus   : TCorpus;
  acCorpus    : TCorpus;
  bi          : Integer;
  avgRatio    : Double;
begin
  WriteLn('=== pas-bzip2 Benchmark (Phase 9.1) ===');
  WriteLn(Format('Corpora: %d MB each; %d iterations per cell.',
    [CORPUS_SIZE div 1048576, BENCH_ITERS]));
  WriteLn('Throughput = original (uncompressed) bytes per second.');
  WriteLn;

  WriteLn('Building corpora...');
  textCorpus := MakeTextCorpus;
  binCorpus  := MakeBinaryCorpus;
  acCorpus   := MakeAlreadyCompressedCorpus;
  WriteLn(Format('  text:               %d bytes', [textCorpus.size]));
  WriteLn(Format('  binary:             %d bytes', [binCorpus.size]));
  WriteLn(Format('  already-compressed: %d bytes', [acCorpus.size]));
  WriteLn;

  // ---- Compress -----------------------------------------------------------
  WriteLn('--- COMPRESS ---');
  for bi := 0 to 2 do
  begin
    BenchCompress('compress text   ' + BS_NAMES[bi], textCorpus, BS_VALUES[bi]);
    BenchCompress('compress binary ' + BS_NAMES[bi], binCorpus,  BS_VALUES[bi]);
    BenchCompress('compress ac     ' + BS_NAMES[bi], acCorpus,   BS_VALUES[bi]);
  end;
  WriteLn;

  // ---- Decompress ---------------------------------------------------------
  WriteLn('--- DECOMPRESS ---');
  for bi := 0 to 2 do
  begin
    BenchDecompress('decompress text   ' + BS_NAMES[bi], textCorpus, BS_VALUES[bi]);
    BenchDecompress('decompress binary ' + BS_NAMES[bi], binCorpus,  BS_VALUES[bi]);
    BenchDecompress('decompress ac     ' + BS_NAMES[bi], acCorpus,   BS_VALUES[bi]);
  end;
  WriteLn;

  // ---- Summary ------------------------------------------------------------
  WriteLn(Format('Pascal faster: %d  |  C faster: %d  |  Ties (<%d%%): %d',
    [PWins, CWins, Round(TIE_THRESHOLD * 100), PTies]));
  if TotalRows > 0 then
  begin
    avgRatio := TotalRatio / TotalRows;
    if avgRatio >= 1.0 then
      WriteLn(Format('Average Pascal/C ratio: %.2fx faster (arithmetic mean, %d rows)',
        [avgRatio, TotalRows]))
    else
      WriteLn(Format('Average Pascal/C ratio: %.2fx slower (arithmetic mean, %d rows)',
        [1.0 / avgRatio, TotalRows]));
  end;
  WriteLn(Format('GlobalSink = %u (prevents dead-code elimination)', [GlobalSink]));

  // ---- Free corpora -------------------------------------------------------
  FreeMem(textCorpus.data);
  FreeMem(binCorpus.data);
  if acCorpus.data <> nil then
    FreeMem(acCorpus.data);
end.
