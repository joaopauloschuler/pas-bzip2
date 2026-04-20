{$I pasbzip2.inc}
program bzip2;

{
  bzip2.pas — Pascal port of bzip2.c (bzip2 1.1.0)
  Faithful line-by-line port of the bzip2 CLI tool from C to Free Pascal.
  Uses THandle (POSIX file descriptors) throughout instead of FILE*.
}

uses
  pasbzip2,
  pasbzip2types,
  BaseUnix,
  Unix,
  SysUtils;

{$LINKLIB c}

{ ----------------------------------------------------------- }
{ --- External C functions not in FPC RTL                 --- }
{ ----------------------------------------------------------- }

function  fchmod(fd: cint; mode: mode_t): cint; cdecl; external 'c';
function  fchown(fd: cint; owner: uid_t; grp: gid_t): cint; cdecl; external 'c';
function  c_strerror(errnum: cint): PAnsiChar; cdecl; external 'c' name 'strerror';
function  isatty(fd: cint): cint; cdecl; external 'c';

{ ----------------------------------------------------------- }
{ --- Constants                                           --- }
{ ----------------------------------------------------------- }

const
  SM_I2O = 1;
  SM_F2O = 2;
  SM_F2F = 3;

  OM_Z    = 1;
  OM_UNZ  = 2;
  OM_TEST = 3;

  FILE_NAME_LEN = 1034;

  PATH_SEP = '/';

  BZ_N_SUFFIX_PAIRS = 4;

{ ----------------------------------------------------------- }
{ --- Types                                               --- }
{ ----------------------------------------------------------- }

type
  TFileName = array[0..FILE_NAME_LEN-1] of AnsiChar;

  TCell = record
    name : PAnsiChar;
    link : ^TCell;
  end;
  PCell = ^TCell;

{ ----------------------------------------------------------- }
{ --- Global variables                                    --- }
{ --- inName/outName/tmpName/progNameReally are PAnsiChar  --- }
{ --- backed by static TFileName buffers (initialized     --- }
{ --- at program start).                                  --- }
{ ----------------------------------------------------------- }

var
  verbosity             : Int32;
  keepInputFiles        : Bool;
  smallMode             : Bool;
  deleteOutputOnInterrupt : Bool;
  forceOverwrite        : Bool;
  testFailsExist        : Bool;
  unzFailsExist         : Bool;
  noisy                 : Bool;
  numFileNames          : Int32;
  numFilesProcessed     : Int32;
  blockSize100k         : Int32;
  exitValue             : Int32;

  opMode                : Int32;
  srcMode               : Int32;

  longestFileName       : Int32;

  { Static backing buffers for the filename strings }
  inNameBuf         : TFileName;
  outNameBuf        : TFileName;
  tmpNameBuf        : TFileName;
  progNameReallyBuf : TFileName;

  { PAnsiChar views of the above buffers (set at startup) }
  inName         : PAnsiChar;
  outName        : PAnsiChar;
  tmpName        : PAnsiChar;
  progNameReally : PAnsiChar;
  progName       : PAnsiChar;

  outputHandleJustInCase: THandle;
  workFactor            : Int32;

  fileMetaInfo          : Stat;

  zSuffix  : array[0..BZ_N_SUFFIX_PAIRS-1] of PAnsiChar = (
               '.bz2', '.bz', '.tbz2', '.tbz');
  unzSuffix: array[0..BZ_N_SUFFIX_PAIRS-1] of PAnsiChar = (
               '', '', '.tar', '.tar');

{ ----------------------------------------------------------- }
{ --- Forward declarations                                --- }
{ ----------------------------------------------------------- }

procedure panic(s: PAnsiChar); forward;
procedure ioError; forward;
procedure outOfMemory; forward;
procedure configError; forward;
procedure crcError; forward;
procedure cleanUpAndFail(ec: Int32); forward;
procedure compressedStreamEOF; forward;

{ ----------------------------------------------------------- }
{ --- my_strerror                                         --- }
{ ----------------------------------------------------------- }

function my_strerror: AnsiString;
begin
  Result := AnsiString(c_strerror(fpgeterrno));
end;

{ ----------------------------------------------------------- }
{ --- setExit                                             --- }
{ ----------------------------------------------------------- }

procedure setExit(v: Int32);
begin
  if v > exitValue then exitValue := v;
end;

{ ----------------------------------------------------------- }
{ --- myfeof                                              --- }
{ ----------------------------------------------------------- }

function myfeof(f: THandle): Bool;
var
  c: UChar;
  n: SizeInt;
begin
  n := fpRead(f, c, 1);
  if n <= 0 then
    Exit(BZ_TRUE);
  { "unget" — seek back one byte }
  fpLSeek(f, -1, SEEK_CUR);
  Result := BZ_FALSE;
end;

{ ----------------------------------------------------------- }
{ --- applySavedFileAttrToOutputFile                      --- }
{ ----------------------------------------------------------- }

procedure applySavedFileAttrToOutputFile(fd: THandle);
var
  retVal: cint;
begin
  retVal := fchmod(cint(fd), fileMetaInfo.st_mode);
  if retVal <> 0 then ioError;
  { fchown may fail with EPERM — ignore it (same as C version) }
  fchown(cint(fd), fileMetaInfo.st_uid, fileMetaInfo.st_gid);
end;

{ ----------------------------------------------------------- }
{ --- compressStream                                      --- }
{ ----------------------------------------------------------- }

procedure compressStream(stream: THandle; zStream: THandle);
label
  errhandler, errhandler_io;
var
  bzf                                  : BZFILE;
  ibuf                                 : array[0..4999] of UChar;
  nIbuf                                : Int32;
  nbytes_in_lo32, nbytes_in_hi32       : UInt32;
  nbytes_out_lo32, nbytes_out_hi32     : UInt32;
  bzerr, bzerr_dummy                   : Int32;
  nbytes_in, nbytes_out                : UInt64;
  nbytes_in_d, nbytes_out_d            : Double;
  buf_nin, buf_nout                    : AnsiString;
  nread                                : SizeInt;
begin
  bzf := nil;

  bzf := BZ2_bzWriteOpen(@bzerr, zStream, blockSize100k, verbosity, workFactor);
  if bzerr <> BZ_OK then goto errhandler;

  if verbosity >= 2 then
    Write(ErrOutput, #10);

  { Read until EOF — avoid myfeof on pipes (ungetc not possible on raw fds) }
  while True do
  begin
    nread := fpRead(stream, ibuf[0], 5000);
    if nread < 0 then goto errhandler_io;
    if nread = 0 then Break;   { EOF }
    nIbuf := Int32(nread);
    BZ2_bzWrite(@bzerr, bzf, @ibuf[0], nIbuf);
    if bzerr <> BZ_OK then goto errhandler;
  end;

  BZ2_bzWriteClose64(@bzerr, bzf, 0,
                     @nbytes_in_lo32, @nbytes_in_hi32,
                     @nbytes_out_lo32, @nbytes_out_hi32);
  if bzerr <> BZ_OK then goto errhandler;

  { skip fflush — no-op for raw fd }
  if zStream <> THandle(1) then
  begin
    applySavedFileAttrToOutputFile(zStream);
    fpClose(zStream);
    outputHandleJustInCase := THandle(-1);
  end;
  outputHandleJustInCase := THandle(-1);
  if stream <> THandle(0) then
    fpClose(stream);

  if verbosity >= 1 then
  begin
    if (nbytes_in_lo32 = 0) and (nbytes_in_hi32 = 0) then
      Write(ErrOutput, ' no data compressed.' + #10)
    else
    begin
      nbytes_in  := (UInt64(nbytes_in_hi32)  shl 32) or UInt64(nbytes_in_lo32);
      nbytes_out := (UInt64(nbytes_out_hi32) shl 32) or UInt64(nbytes_out_lo32);
      nbytes_in_d  := nbytes_in;
      nbytes_out_d := nbytes_out;
      buf_nin  := IntToStr(nbytes_in);
      buf_nout := IntToStr(nbytes_out);
      Write(ErrOutput,
        Format('%6.3f:1, %6.3f bits/byte, %5.2f%% saved, %s in, %s out.' + #10,
          [ nbytes_in_d / nbytes_out_d,
            (8.0 * nbytes_out_d) / nbytes_in_d,
            100.0 * (1.0 - nbytes_out_d / nbytes_in_d),
            buf_nin,
            buf_nout ]));
    end;
  end;

  Exit;

errhandler:
  BZ2_bzWriteClose64(@bzerr_dummy, bzf, 1,
                     @nbytes_in_lo32, @nbytes_in_hi32,
                     @nbytes_out_lo32, @nbytes_out_hi32);
  case bzerr of
    BZ_CONFIG_ERROR: configError;
    BZ_MEM_ERROR:    outOfMemory;
    BZ_IO_ERROR:
      begin
      errhandler_io:
        ioError;
      end;
    else
      panic('compress:unexpected error');
  end;
  panic('compress:end');
end;

{ ----------------------------------------------------------- }
{ --- uncompressStream                                    --- }
{ ----------------------------------------------------------- }

function uncompressStream(zStream: THandle; stream: THandle): Bool;
label
  closeok, trycat, errhandler, errhandler_io;
var
  bzf                   : BZFILE;
  bzerr, bzerr_dummy    : Int32;
  nread                 : Int32;
  streamNo, i           : Int32;
  obuf                  : array[0..4999] of UChar;
  unused                : array[0..BZ_MAX_UNUSED-1] of UChar;
  nUnused               : Int32;
  unusedTmpV            : Pointer;
  unusedTmp             : PByte;
  nw                    : SizeInt;
begin
  Result := BZ_FALSE;
  bzf := nil;
  nUnused := 0;
  streamNo := 0;

  while True do
  begin
    bzf := BZ2_bzReadOpen(@bzerr, zStream, verbosity,
                          Int32(smallMode), @unused[0], nUnused);
    if (bzf = nil) or (bzerr <> BZ_OK) then goto errhandler;
    Inc(streamNo);

    while bzerr = BZ_OK do
    begin
      nread := BZ2_bzRead(@bzerr, bzf, @obuf[0], 5000);
      if bzerr = BZ_DATA_ERROR_MAGIC then goto trycat;
      if ((bzerr = BZ_OK) or (bzerr = BZ_STREAM_END)) and (nread > 0) then
      begin
        nw := fpWrite(stream, obuf[0], nread);
        if nw < 0 then goto errhandler_io;
      end;
    end;
    if bzerr <> BZ_STREAM_END then goto errhandler;

    BZ2_bzReadGetUnused(@bzerr, bzf, @unusedTmpV, @nUnused);
    if bzerr <> BZ_OK then panic('decompress:bzReadGetUnused');

    unusedTmp := PByte(unusedTmpV);
    for i := 0 to nUnused - 1 do
      unused[i] := unusedTmp[i];

    BZ2_bzReadClose(@bzerr, bzf);
    bzf := nil;
    if bzerr <> BZ_OK then panic('decompress:bzReadGetUnused');

    { Check for more streams. If no unused data, peek one byte.
      Cannot use fpLSeek on pipes, so we put any peeked byte into unused[]. }
    if nUnused = 0 then
    begin
      nread := fpRead(zStream, unused[0], 1);
      if nread <= 0 then Break;   { EOF — done }
      nUnused := 1;
    end;
  end;   { while True }

closeok:
  if stream <> THandle(1) then
    applySavedFileAttrToOutputFile(stream);
  if zStream <> THandle(0) then
    fpClose(zStream);
  if stream <> THandle(1) then
  begin
    fpClose(stream);
    outputHandleJustInCase := THandle(-1);
  end;
  outputHandleJustInCase := THandle(-1);
  if verbosity >= 2 then
    Write(ErrOutput, #10 + '    ');
  Result := BZ_TRUE;
  Exit;

trycat:
  if forceOverwrite <> 0 then
  begin
    fpLSeek(zStream, 0, SEEK_SET);
    while True do
    begin
      nread := fpRead(zStream, obuf[0], 5000);
      if nread <= 0 then Break;
      nw := fpWrite(stream, obuf[0], nread);
      if nw < 0 then goto errhandler_io;
    end;
    goto closeok;
  end;

errhandler:
  BZ2_bzReadClose(@bzerr_dummy, bzf);
  case bzerr of
    BZ_CONFIG_ERROR: configError;
    BZ_IO_ERROR:
      begin
      errhandler_io:
        ioError;
      end;
    BZ_DATA_ERROR:    crcError;
    BZ_MEM_ERROR:     outOfMemory;
    BZ_UNEXPECTED_EOF: compressedStreamEOF;
    BZ_DATA_ERROR_MAGIC:
      begin
        if zStream <> THandle(0) then fpClose(zStream);
        if stream  <> THandle(1) then fpClose(stream);
        if streamNo = 1 then
          Result := BZ_FALSE
        else
        begin
          if noisy <> 0 then
            Write(ErrOutput,
              Format(#10 + '%s: %s: trailing garbage after EOF ignored' + #10,
                     [progName, inName]));
          Result := BZ_TRUE;
        end;
        Exit;
      end;
    else
      panic('decompress:unexpected error');
  end;
  panic('decompress:end');
  Result := BZ_TRUE; { notreached }
end;

{ ----------------------------------------------------------- }
{ --- testStream                                          --- }
{ ----------------------------------------------------------- }

function testStream(zStream: THandle): Bool;
label
  errhandler, errhandler_io;
var
  bzf                : BZFILE;
  bzerr, bzerr_dummy : Int32;
  streamNo, i        : Int32;
  obuf               : array[0..4999] of UChar;
  unused             : array[0..BZ_MAX_UNUSED-1] of UChar;
  nUnused            : Int32;
  unusedTmpV         : Pointer;
  unusedTmp          : PByte;
  nrPeek             : SizeInt;
begin
  Result := BZ_FALSE;
  bzf := nil;
  nUnused := 0;
  streamNo := 0;

  while True do
  begin
    bzf := BZ2_bzReadOpen(@bzerr, zStream, verbosity,
                          Int32(smallMode), @unused[0], nUnused);
    if (bzf = nil) or (bzerr <> BZ_OK) then goto errhandler;
    Inc(streamNo);

    while bzerr = BZ_OK do
    begin
      BZ2_bzRead(@bzerr, bzf, @obuf[0], 5000);
      if bzerr = BZ_DATA_ERROR_MAGIC then goto errhandler;
    end;
    if bzerr <> BZ_STREAM_END then goto errhandler;

    BZ2_bzReadGetUnused(@bzerr, bzf, @unusedTmpV, @nUnused);
    if bzerr <> BZ_OK then panic('test:bzReadGetUnused');

    unusedTmp := PByte(unusedTmpV);
    for i := 0 to nUnused - 1 do
      unused[i] := unusedTmp[i];

    BZ2_bzReadClose(@bzerr, bzf);
    bzf := nil;
    if bzerr <> BZ_OK then panic('test:bzReadGetUnused');
    { Check for more streams; peek a byte if no unused data }
    if nUnused = 0 then
    begin
      nrPeek := fpRead(zStream, unused[0], 1);
      if nrPeek <= 0 then Break;   { EOF — done }
      nUnused := 1;
    end;
  end;

  fpClose(zStream);
  if verbosity >= 2 then
    Write(ErrOutput, #10 + '    ');
  Result := BZ_TRUE;
  Exit;

errhandler:
  BZ2_bzReadClose(@bzerr_dummy, bzf);
  if verbosity = 0 then
    Write(ErrOutput, Format('%s: %s: ', [progName, inName]));
  case bzerr of
    BZ_CONFIG_ERROR: configError;
    BZ_IO_ERROR:
      begin
      errhandler_io:
        ioError;
      end;
    BZ_DATA_ERROR:
      begin
        Write(ErrOutput, 'data integrity (CRC) error in data' + #10);
        Result := BZ_FALSE;
        Exit;
      end;
    BZ_MEM_ERROR: outOfMemory;
    BZ_UNEXPECTED_EOF:
      begin
        Write(ErrOutput, 'file ends unexpectedly' + #10);
        Result := BZ_FALSE;
        Exit;
      end;
    BZ_DATA_ERROR_MAGIC:
      begin
        if zStream <> THandle(0) then fpClose(zStream);
        if streamNo = 1 then
        begin
          Write(ErrOutput, 'bad magic number (file not created by bzip2)' + #10);
          Result := BZ_FALSE;
        end else
        begin
          if noisy <> 0 then
            Write(ErrOutput, 'trailing garbage after EOF ignored' + #10);
          Result := BZ_TRUE;
        end;
        Exit;
      end;
    else
      panic('test:unexpected error');
  end;
  panic('test:end');
  Result := BZ_TRUE; { notreached }
end;

{ ----------------------------------------------------------- }
{ --- cadvise                                             --- }
{ ----------------------------------------------------------- }

procedure cadvise;
begin
  if noisy <> 0 then
    Write(ErrOutput,
      #10 + 'It is possible that the compressed file(s) have become corrupted.' + #10 +
      'You can use the -tvv option to test integrity of such files.' + #10 + #10 +
      'You can use the `bzip2recover'' program to attempt to recover' + #10 +
      'data from undamaged sections of corrupted files.' + #10 + #10);
end;

{ ----------------------------------------------------------- }
{ --- showFileNames                                       --- }
{ ----------------------------------------------------------- }

procedure showFileNames;
begin
  if noisy <> 0 then
    Write(ErrOutput,
      Format(#9 + 'Input file = %s, output file = %s' + #10,
             [inName, outName]));
end;

{ ----------------------------------------------------------- }
{ --- cleanUpAndFail                                      --- }
{ ----------------------------------------------------------- }

procedure cleanUpAndFail(ec: Int32);
var
  statBuf : Stat;
  retVal  : cint;
begin
  if (srcMode = SM_F2F) and (opMode <> OM_TEST) and (deleteOutputOnInterrupt <> 0) then
  begin
    retVal := fpStat(inName, statBuf);
    if retVal = 0 then
    begin
      if noisy <> 0 then
        Write(ErrOutput,
          Format('%s: Deleting output file %s, if it exists.' + #10,
                 [progName, outName]));
      if outputHandleJustInCase <> THandle(-1) then
        fpClose(outputHandleJustInCase);
      retVal := fpUnlink(outName);
      if retVal <> 0 then
        Write(ErrOutput,
          Format('%s: WARNING: deletion of output file (apparently) failed.' + #10,
                 [progName]));
    end else
    begin
      Write(ErrOutput,
        Format('%s: WARNING: deletion of output file suppressed' + #10, [progName]));
      Write(ErrOutput,
        Format('%s:    since input file no longer exists.  Output file' + #10, [progName]));
      Write(ErrOutput,
        Format('%s:    `%s'' may be incomplete.' + #10, [progName, outName]));
      Write(ErrOutput,
        Format('%s:    I suggest doing an integrity test (bzip2 -tv) of it.' + #10,
               [progName]));
    end;
  end;

  if (noisy <> 0) and (numFileNames > 0) and (numFilesProcessed < numFileNames) then
    Write(ErrOutput,
      Format('%s: WARNING: some files have not been processed:' + #10 +
             '%s:    %d specified on command line, %d not processed yet.' + #10 + #10,
             [progName, progName, numFileNames, numFileNames - numFilesProcessed]));

  setExit(ec);
  Halt(exitValue);
end;

{ ----------------------------------------------------------- }
{ --- panic                                               --- }
{ ----------------------------------------------------------- }

procedure panic(s: PAnsiChar);
begin
  Write(ErrOutput,
    Format(#10 + '%s: PANIC -- internal consistency error:' + #10 +
           #9 + '%s' + #10 +
           #9 + 'This is a BUG.  Please report it at:' + #10 +
           #9 + 'https://gitlab.com/bzip2/bzip2/-/issues' + #10,
           [progName, s]));
  showFileNames;
  cleanUpAndFail(3);
end;

{ ----------------------------------------------------------- }
{ --- crcError                                            --- }
{ ----------------------------------------------------------- }

procedure crcError;
begin
  Write(ErrOutput,
    Format(#10 + '%s: Data integrity error when decompressing.' + #10,
           [progName]));
  showFileNames;
  cadvise;
  cleanUpAndFail(2);
end;

{ ----------------------------------------------------------- }
{ --- compressedStreamEOF                                 --- }
{ ----------------------------------------------------------- }

procedure compressedStreamEOF;
begin
  if noisy <> 0 then
  begin
    Write(ErrOutput,
      Format(#10 + '%s: Compressed file ends unexpectedly;' + #10 + #9 +
             'perhaps it is corrupted?  *Possible* reason follows.' + #10,
             [progName]));
    Write(ErrOutput, Format('%s: %s' + #10, [progName, my_strerror]));
    showFileNames;
    cadvise;
  end;
  cleanUpAndFail(2);
end;

{ ----------------------------------------------------------- }
{ --- ioError                                             --- }
{ ----------------------------------------------------------- }

procedure ioError;
begin
  Write(ErrOutput,
    Format(#10 + '%s: I/O or other error, bailing out.  Possible reason follows.' + #10,
           [progName]));
  Write(ErrOutput, Format('%s: %s' + #10, [progName, my_strerror]));
  showFileNames;
  cleanUpAndFail(1);
end;

{ ----------------------------------------------------------- }
{ --- outOfMemory                                         --- }
{ ----------------------------------------------------------- }

procedure outOfMemory;
begin
  Write(ErrOutput,
    Format(#10 + '%s: couldn''t allocate enough memory' + #10, [progName]));
  showFileNames;
  cleanUpAndFail(1);
end;

{ ----------------------------------------------------------- }
{ --- configError                                         --- }
{ ----------------------------------------------------------- }

procedure configError;
begin
  Write(ErrOutput,
    'bzip2: I''m not configured correctly for this platform!' + #10 +
    #9 + 'I require Int32, Int16 and Char to have sizes' + #10 +
    #9 + 'of 4, 2 and 1 bytes to run properly, and they don''t.' + #10 +
    #9 + 'Probably you can fix this by defining them correctly,' + #10 +
    #9 + 'and recompiling.  Bye!' + #10);
  setExit(3);
  Halt(exitValue);
end;

{ ----------------------------------------------------------- }
{ --- Signal handlers                                     --- }
{ ----------------------------------------------------------- }

procedure mySignalCatcher(n: longint); cdecl;
begin
  Write(ErrOutput,
    Format(#10 + '%s: Control-C or similar caught, quitting.' + #10, [progName]));
  cleanUpAndFail(1);
end;

procedure mySIGSEGVorSIGBUScatcher(n: longint); cdecl;
const
  msgCompress: AnsiString =
    ': Caught a SIGSEGV or SIGBUS whilst compressing.' + #10 +
    #10 +
    '   Possible causes are (most likely first):' + #10 +
    '   (1) This computer has unreliable memory or cache hardware' + #10 +
    '       (a surprisingly common problem; try a different machine.)' + #10 +
    '   (2) A bug in the compiler used to create this executable' + #10 +
    '       (unlikely, if you didn''t compile bzip2 yourself.)' + #10 +
    '   (3) A real bug in bzip2 -- I hope this should never be the case.' + #10 +
    '   The user''s manual, Section 4.3, has more info on (1) and (2).' + #10 +
    '   ' + #10 +
    '   If you suspect this is a bug in bzip2, or are unsure about (1)' + #10 +
    '   or (2), report it at: https://gitlab.com/bzip2/bzip2/-/issues' + #10 +
    '   Section 4.3 of the user''s manual describes the info a useful' + #10 +
    '   bug report should have.  If the manual is available on your' + #10 +
    '   system, please try and read it before mailing me.  If you don''t' + #10 +
    '   have the manual or can''t be bothered to read it, mail me anyway.' + #10 +
    #10;
  msgDecompress: AnsiString =
    ': Caught a SIGSEGV or SIGBUS whilst decompressing.' + #10 +
    #10 +
    '   Possible causes are (most likely first):' + #10 +
    '   (1) The compressed data is corrupted, and bzip2''s usual checks' + #10 +
    '       failed to detect this.  Try bzip2 -tvv my_file.bz2.' + #10 +
    '   (2) This computer has unreliable memory or cache hardware' + #10 +
    '       (a surprisingly common problem; try a different machine.)' + #10 +
    '   (3) A bug in the compiler used to create this executable' + #10 +
    '       (unlikely, if you didn''t compile bzip2 yourself.)' + #10 +
    '   (4) A real bug in bzip2 -- I hope this should never be the case.' + #10 +
    '   The user''s manual, Section 4.3, has more info on (2) and (3).' + #10 +
    '   ' + #10 +
    '   If you suspect this is a bug in bzip2, or are unsure about (2)' + #10 +
    '   or (3), report it at: https://gitlab.com/bzip2/bzip2/-/issues' + #10 +
    '   Section 4.3 of the user''s manual describes the info a useful' + #10 +
    '   bug report should have.  If the manual is available on your' + #10 +
    '   system, please try and read it before mailing me.  If you don''t' + #10 +
    '   have the manual or can''t be bothered to read it, mail me anyway.' + #10 +
    #10;
var
  msg  : PAnsiChar;
  nl   : AnsiChar;
  msgIn, msgOut : AnsiString;
begin
  nl := #10;
  msgIn  := #9 + 'Input file = ';
  msgOut := #9 + 'Output file = ';

  if opMode = OM_Z then
    msg := PAnsiChar(msgCompress)
  else
    msg := PAnsiChar(msgDecompress);

  fpWrite(2, nl,           1);
  fpWrite(2, progName^,    StrLen(progName));
  fpWrite(2, msg^,         StrLen(msg));
  fpWrite(2, PAnsiChar(msgIn)^,  Length(msgIn));
  fpWrite(2, inName^,      StrLen(inName));
  fpWrite(2, nl,           1);
  fpWrite(2, PAnsiChar(msgOut)^, Length(msgOut));
  fpWrite(2, outName^,     StrLen(outName));
  fpWrite(2, nl,           1);

  if opMode = OM_Z then setExit(3) else setExit(2);
  Halt(exitValue);
end;

{ ----------------------------------------------------------- }
{ --- pad                                                 --- }
{ ----------------------------------------------------------- }

procedure pad(s: PAnsiChar);
var
  i: Int32;
begin
  if Int32(StrLen(s)) >= longestFileName then Exit;
  for i := 1 to longestFileName - Int32(StrLen(s)) do
    Write(ErrOutput, ' ');
end;

{ ----------------------------------------------------------- }
{ --- copyFileName                                        --- }
{ ----------------------------------------------------------- }

procedure copyFileName(to_: PAnsiChar; from: PAnsiChar);
begin
  if StrLen(from) > FILE_NAME_LEN - 10 then
  begin
    Write(ErrOutput,
      Format('bzip2: file name' + #10 + '`%s''' + #10 +
             'is suspiciously (more than %d chars) long.' + #10 +
             'Try using a reasonable file name instead.  Sorry! :-)' + #10,
             [from, FILE_NAME_LEN - 10]));
    setExit(1);
    Halt(exitValue);
  end;
  StrLCopy(to_, from, FILE_NAME_LEN - 10);
  to_[FILE_NAME_LEN - 10] := #0;
end;

{ ----------------------------------------------------------- }
{ --- fileExists                                          --- }
{ ----------------------------------------------------------- }

function fileExists(name: PAnsiChar): Bool;
var
  fd: THandle;
begin
  fd := fpOpen(name, O_RDONLY);
  if fd < 0 then
  begin
    Result := BZ_FALSE;
    Exit;
  end;
  fpClose(fd);
  Result := BZ_TRUE;
end;

{ ----------------------------------------------------------- }
{ --- notAStandardFile                                    --- }
{ ----------------------------------------------------------- }

function notAStandardFile(name: PAnsiChar): Bool;
var
  i      : cint;
  statBuf: Stat;
begin
  FillChar(statBuf, SizeOf(statBuf), 0);
  i := fpLStat(name, statBuf);
  if i <> 0 then begin Result := BZ_TRUE; Exit; end;
  if fpS_ISREG(statBuf.st_mode) then begin Result := BZ_FALSE; Exit; end;
  Result := BZ_TRUE;
end;

{ ----------------------------------------------------------- }
{ --- countHardLinks                                      --- }
{ ----------------------------------------------------------- }

function countHardLinks(name: PAnsiChar): Int32;
var
  i      : cint;
  statBuf: Stat;
begin
  FillChar(statBuf, SizeOf(statBuf), 0);
  i := fpLStat(name, statBuf);
  if i <> 0 then begin Result := 0; Exit; end;
  Result := Int32(statBuf.st_nlink) - 1;
end;

{ ----------------------------------------------------------- }
{ --- saveInputFileMetaInfo                               --- }
{ ----------------------------------------------------------- }

procedure saveInputFileMetaInfo(srcName: PAnsiChar);
var
  retVal: cint;
begin
  retVal := fpStat(srcName, fileMetaInfo);
  if retVal <> 0 then ioError;
end;

{ ----------------------------------------------------------- }
{ --- applySavedTimeInfoToOutputFile                      --- }
{ ----------------------------------------------------------- }

procedure applySavedTimeInfoToOutputFile(dstName: PAnsiChar);
var
  retVal  : cint;
  uTimBuf : TUTimBuf;
begin
  uTimBuf.actime  := fileMetaInfo.st_atime;
  uTimBuf.modtime := fileMetaInfo.st_mtime;
  retVal := FpUtime(dstName, @uTimBuf);
  if retVal <> 0 then ioError;
end;

{ ----------------------------------------------------------- }
{ --- containsDubiousChars (always False on Unix)         --- }
{ ----------------------------------------------------------- }

function containsDubiousChars(name: PAnsiChar): Bool;
begin
  { On Unix, the shell handles wildcard expansion }
  Result := BZ_FALSE;
end;

{ ----------------------------------------------------------- }
{ --- hasSuffix / mapSuffix                               --- }
{ ----------------------------------------------------------- }

function hasSuffix(s: PAnsiChar; const suffix: PAnsiChar): Bool;
var
  ns, nx: Int32;
begin
  ns := Int32(StrLen(s));
  nx := Int32(StrLen(suffix));
  if ns < nx then begin Result := BZ_FALSE; Exit; end;
  if StrComp(s + ns - nx, suffix) = 0 then
    Result := BZ_TRUE
  else
    Result := BZ_FALSE;
end;

function mapSuffix(name: PAnsiChar; const oldSuffix: PAnsiChar;
                   const newSuffix: PAnsiChar): Bool;
begin
  if hasSuffix(name, oldSuffix) = 0 then begin Result := BZ_FALSE; Exit; end;
  name[StrLen(name) - StrLen(oldSuffix)] := #0;
  StrCat(name, newSuffix);
  Result := BZ_TRUE;
end;

{ ----------------------------------------------------------- }
{ --- compress                                            --- }
{ ----------------------------------------------------------- }

procedure compress(name: PAnsiChar);
var
  inStr, outStr: THandle;
  n, i         : Int32;
  statBuf      : Stat;
  sLink        : AnsiString;
begin
  inStr  := THandle(-1);
  outStr := THandle(-1);
  deleteOutputOnInterrupt := BZ_FALSE;

  if (name = nil) and (srcMode <> SM_I2O) then
    panic('compress: bad modes');

  case srcMode of
    SM_I2O:
      begin
        copyFileName(inName,  '(stdin)');
        copyFileName(outName, '(stdout)');
      end;
    SM_F2F:
      begin
        copyFileName(inName, name);
        copyFileName(outName, name);
        StrCat(outName, '.bz2');
      end;
    SM_F2O:
      begin
        copyFileName(inName, name);
        copyFileName(outName, '(stdout)');
      end;
  end;

  if (srcMode <> SM_I2O) and (containsDubiousChars(inName) <> 0) then
  begin
    if noisy <> 0 then
      Write(ErrOutput, Format('%s: There are no files matching `%s''.' + #10,
                              [progName, inName]));
    setExit(1);
    Exit;
  end;
  if (srcMode <> SM_I2O) and (fileExists(inName) = 0) then
  begin
    Write(ErrOutput, Format('%s: Can''t open input file %s: %s.' + #10,
                            [progName, inName, my_strerror]));
    setExit(1);
    Exit;
  end;
  for i := 0 to BZ_N_SUFFIX_PAIRS - 1 do
  begin
    if hasSuffix(inName, zSuffix[i]) <> 0 then
    begin
      if noisy <> 0 then
        Write(ErrOutput,
          Format('%s: Input file %s already has %s suffix.' + #10,
                 [progName, inName, zSuffix[i]]));
      setExit(1);
      Exit;
    end;
  end;
  if (srcMode = SM_F2F) or (srcMode = SM_F2O) then
  begin
    fpStat(inName, statBuf);
    if fpS_ISDIR(statBuf.st_mode) then
    begin
      Write(ErrOutput, Format('%s: Input file %s is a directory.' + #10,
                              [progName, inName]));
      setExit(1);
      Exit;
    end;
  end;
  if (srcMode = SM_F2F) and (forceOverwrite = 0) and (notAStandardFile(inName) <> 0) then
  begin
    if noisy <> 0 then
      Write(ErrOutput, Format('%s: Input file %s is not a normal file.' + #10,
                              [progName, inName]));
    setExit(1);
    Exit;
  end;
  if (srcMode = SM_F2F) and (fileExists(outName) <> 0) then
  begin
    if forceOverwrite <> 0 then
      fpUnlink(outName)
    else
    begin
      Write(ErrOutput, Format('%s: Output file %s already exists.' + #10,
                              [progName, outName]));
      setExit(1);
      Exit;
    end;
  end;
  if (srcMode = SM_F2F) and (forceOverwrite = 0) then
  begin
    n := countHardLinks(inName);
    if n > 0 then
    begin
      if n > 1 then sLink := 's' else sLink := '';
      Write(ErrOutput, Format('%s: Input file %s has %d other link%s.' + #10,
                              [progName, inName, n, sLink]));
      setExit(1);
      Exit;
    end;
  end;

  if srcMode = SM_F2F then
    saveInputFileMetaInfo(inName);

  case srcMode of
    SM_I2O:
      begin
        inStr  := THandle(0);
        outStr := THandle(1);
        if isatty(1) <> 0 then
        begin
          Write(ErrOutput, Format(
            '%s: I won''t write compressed data to a terminal.' + #10 +
            '%s: For help, type: `%s --help''.' + #10,
            [progName, progName, progName]));
          setExit(1);
          Exit;
        end;
      end;
    SM_F2O:
      begin
        inStr  := fpOpen(inName, O_RDONLY);
        outStr := THandle(1);
        if isatty(1) <> 0 then
        begin
          Write(ErrOutput, Format(
            '%s: I won''t write compressed data to a terminal.' + #10 +
            '%s: For help, type: `%s --help''.' + #10,
            [progName, progName, progName]));
          if inStr >= 0 then fpClose(inStr);
          setExit(1);
          Exit;
        end;
        if inStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t open input file %s: %s.' + #10,
                                  [progName, inName, my_strerror]));
          setExit(1);
          Exit;
        end;
      end;
    SM_F2F:
      begin
        inStr  := fpOpen(inName, O_RDONLY);
        outStr := fpOpen(outName, O_WRONLY or O_CREAT or O_EXCL,
                         S_IWUSR or S_IRUSR);
        if outStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t create output file %s: %s.' + #10,
                                  [progName, outName, my_strerror]));
          if inStr >= 0 then fpClose(inStr);
          setExit(1);
          Exit;
        end;
        if inStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t open input file %s: %s.' + #10,
                                  [progName, inName, my_strerror]));
          if outStr >= 0 then fpClose(outStr);
          setExit(1);
          Exit;
        end;
      end;
    else
      panic('compress: bad srcMode');
  end;

  if verbosity >= 1 then
  begin
    Write(ErrOutput, Format('  %s: ', [inName]));
    pad(inName);
  end;

  outputHandleJustInCase := outStr;
  deleteOutputOnInterrupt := BZ_TRUE;
  compressStream(inStr, outStr);
  outputHandleJustInCase := THandle(-1);

  if srcMode = SM_F2F then
  begin
    applySavedTimeInfoToOutputFile(outName);
    deleteOutputOnInterrupt := BZ_FALSE;
    if keepInputFiles = 0 then
    begin
      if fpUnlink(inName) <> 0 then ioError;
    end;
  end;

  deleteOutputOnInterrupt := BZ_FALSE;
end;

{ ----------------------------------------------------------- }
{ --- uncompress                                          --- }
{ ----------------------------------------------------------- }

procedure uncompress(name: PAnsiChar);
label
  zzz;
var
  inStr, outStr  : THandle;
  n, i           : Int32;
  magicNumberOK  : Bool;
  cantGuess      : Bool;
  statBuf        : Stat;
  sLink          : AnsiString;
begin
  inStr  := THandle(-1);
  outStr := THandle(-1);
  deleteOutputOnInterrupt := BZ_FALSE;

  if (name = nil) and (srcMode <> SM_I2O) then
    panic('uncompress: bad modes');

  cantGuess := BZ_FALSE;
  case srcMode of
    SM_I2O:
      begin
        copyFileName(inName,  '(stdin)');
        copyFileName(outName, '(stdout)');
      end;
    SM_F2F:
      begin
        copyFileName(inName, name);
        copyFileName(outName, name);
        for i := 0 to BZ_N_SUFFIX_PAIRS - 1 do
          if mapSuffix(outName, zSuffix[i], unzSuffix[i]) <> 0 then
            goto zzz;
        cantGuess := BZ_TRUE;
        StrCat(outName, '.out');
      end;
    SM_F2O:
      begin
        copyFileName(inName,  name);
        copyFileName(outName, '(stdout)');
      end;
  end;

  zzz:
  if (srcMode <> SM_I2O) and (containsDubiousChars(inName) <> 0) then
  begin
    if noisy <> 0 then
      Write(ErrOutput, Format('%s: There are no files matching `%s''.' + #10,
                              [progName, inName]));
    setExit(1);
    Exit;
  end;
  if (srcMode <> SM_I2O) and (fileExists(inName) = 0) then
  begin
    Write(ErrOutput, Format('%s: Can''t open input file %s: %s.' + #10,
                            [progName, inName, my_strerror]));
    setExit(1);
    Exit;
  end;
  if (srcMode = SM_F2F) or (srcMode = SM_F2O) then
  begin
    fpStat(inName, statBuf);
    if fpS_ISDIR(statBuf.st_mode) then
    begin
      Write(ErrOutput, Format('%s: Input file %s is a directory.' + #10,
                              [progName, inName]));
      setExit(1);
      Exit;
    end;
  end;
  if (srcMode = SM_F2F) and (forceOverwrite = 0) and (notAStandardFile(inName) <> 0) then
  begin
    if noisy <> 0 then
      Write(ErrOutput, Format('%s: Input file %s is not a normal file.' + #10,
                              [progName, inName]));
    setExit(1);
    Exit;
  end;
  if cantGuess <> 0 then
  begin
    if noisy <> 0 then
      Write(ErrOutput,
        Format('%s: Can''t guess original name for %s -- using %s' + #10,
               [progName, inName, outName]));
    { just a warning, no return }
  end;
  if (srcMode = SM_F2F) and (fileExists(outName) <> 0) then
  begin
    if forceOverwrite <> 0 then
      fpUnlink(outName)
    else
    begin
      Write(ErrOutput, Format('%s: Output file %s already exists.' + #10,
                              [progName, outName]));
      setExit(1);
      Exit;
    end;
  end;
  if (srcMode = SM_F2F) and (forceOverwrite = 0) then
  begin
    n := countHardLinks(inName);
    if n > 0 then
    begin
      if n > 1 then sLink := 's' else sLink := '';
      Write(ErrOutput, Format('%s: Input file %s has %d other link%s.' + #10,
                              [progName, inName, n, sLink]));
      setExit(1);
      Exit;
    end;
  end;

  if srcMode = SM_F2F then
    saveInputFileMetaInfo(inName);

  case srcMode of
    SM_I2O:
      begin
        inStr  := THandle(0);
        outStr := THandle(1);
        if isatty(0) <> 0 then
        begin
          Write(ErrOutput, Format(
            '%s: I won''t read compressed data from a terminal.' + #10 +
            '%s: For help, type: `%s --help''.' + #10,
            [progName, progName, progName]));
          setExit(1);
          Exit;
        end;
      end;
    SM_F2O:
      begin
        inStr  := fpOpen(inName, O_RDONLY);
        outStr := THandle(1);
        if inStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t open input file %s:%s.' + #10,
                                  [progName, inName, my_strerror]));
          setExit(1);
          Exit;
        end;
      end;
    SM_F2F:
      begin
        inStr  := fpOpen(inName, O_RDONLY);
        outStr := fpOpen(outName, O_WRONLY or O_CREAT or O_EXCL,
                         S_IWUSR or S_IRUSR);
        if outStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t create output file %s: %s.' + #10,
                                  [progName, outName, my_strerror]));
          if inStr >= 0 then fpClose(inStr);
          setExit(1);
          Exit;
        end;
        if inStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t open input file %s: %s.' + #10,
                                  [progName, inName, my_strerror]));
          if outStr >= 0 then fpClose(outStr);
          setExit(1);
          Exit;
        end;
      end;
    else
      panic('uncompress: bad srcMode');
  end;

  if verbosity >= 1 then
  begin
    Write(ErrOutput, Format('  %s: ', [inName]));
    pad(inName);
  end;

  outputHandleJustInCase := outStr;
  deleteOutputOnInterrupt := BZ_TRUE;
  magicNumberOK := uncompressStream(inStr, outStr);
  outputHandleJustInCase := THandle(-1);

  if magicNumberOK <> 0 then
  begin
    if srcMode = SM_F2F then
    begin
      applySavedTimeInfoToOutputFile(outName);
      deleteOutputOnInterrupt := BZ_FALSE;
      if keepInputFiles = 0 then
      begin
        if fpUnlink(inName) <> 0 then ioError;
      end;
    end;
  end else
  begin
    unzFailsExist := BZ_TRUE;
    deleteOutputOnInterrupt := BZ_FALSE;
    if srcMode = SM_F2F then
    begin
      if fpUnlink(outName) <> 0 then ioError;
    end;
  end;
  deleteOutputOnInterrupt := BZ_FALSE;

  if magicNumberOK <> 0 then
  begin
    if verbosity >= 1 then
      Write(ErrOutput, 'done' + #10);
  end else
  begin
    setExit(2);
    if verbosity >= 1 then
      Write(ErrOutput, 'not a bzip2 file.' + #10)
    else
      Write(ErrOutput, Format('%s: %s is not a bzip2 file.' + #10,
                              [progName, inName]));
  end;
end;

{ ----------------------------------------------------------- }
{ --- testf                                               --- }
{ ----------------------------------------------------------- }

procedure testf(name: PAnsiChar);
var
  inStr  : THandle;
  allOK  : Bool;
  statBuf: Stat;
begin
  inStr := THandle(-1);
  deleteOutputOnInterrupt := BZ_FALSE;

  if (name = nil) and (srcMode <> SM_I2O) then
    panic('testf: bad modes');

  copyFileName(outName, '(none)');
  case srcMode of
    SM_I2O: copyFileName(inName, '(stdin)');
    SM_F2F: copyFileName(inName, name);
    SM_F2O: copyFileName(inName, name);
  end;

  if (srcMode <> SM_I2O) and (containsDubiousChars(inName) <> 0) then
  begin
    if noisy <> 0 then
      Write(ErrOutput, Format('%s: There are no files matching `%s''.' + #10,
                              [progName, inName]));
    setExit(1);
    Exit;
  end;
  if (srcMode <> SM_I2O) and (fileExists(inName) = 0) then
  begin
    Write(ErrOutput, Format('%s: Can''t open input %s: %s.' + #10,
                            [progName, inName, my_strerror]));
    setExit(1);
    Exit;
  end;
  if srcMode <> SM_I2O then
  begin
    fpStat(inName, statBuf);
    if fpS_ISDIR(statBuf.st_mode) then
    begin
      Write(ErrOutput, Format('%s: Input file %s is a directory.' + #10,
                              [progName, inName]));
      setExit(1);
      Exit;
    end;
  end;

  case srcMode of
    SM_I2O:
      begin
        if isatty(0) <> 0 then
        begin
          Write(ErrOutput, Format(
            '%s: I won''t read compressed data from a terminal.' + #10 +
            '%s: For help, type: `%s --help''.' + #10,
            [progName, progName, progName]));
          setExit(1);
          Exit;
        end;
        inStr := THandle(0);
      end;
    SM_F2O, SM_F2F:
      begin
        inStr := fpOpen(inName, O_RDONLY);
        if inStr < 0 then
        begin
          Write(ErrOutput, Format('%s: Can''t open input file %s:%s.' + #10,
                                  [progName, inName, my_strerror]));
          setExit(1);
          Exit;
        end;
      end;
    else
      panic('testf: bad srcMode');
  end;

  if verbosity >= 1 then
  begin
    Write(ErrOutput, Format('  %s: ', [inName]));
    pad(inName);
  end;

  outputHandleJustInCase := THandle(-1);
  allOK := testStream(inStr);

  if (allOK <> 0) and (verbosity >= 1) then
    Write(ErrOutput, 'ok' + #10);
  if allOK = 0 then
    testFailsExist := BZ_TRUE;
end;

{ ----------------------------------------------------------- }
{ --- license                                             --- }
{ ----------------------------------------------------------- }

procedure license;
begin
  Write(
    Format(
      'bzip2, a block-sorting file compressor.  Version %s.' + #10 +
      '   ' + #10 +
      '   Copyright (C) 1996-2010 by Julian Seward.' + #10 +
      '   ' + #10 +
      '   This program is free software; you can redistribute it and/or modify' + #10 +
      '   it under the terms set out in the LICENSE file, which is included' + #10 +
      '   in the bzip2-1.0.6 source distribution.' + #10 +
      '   ' + #10 +
      '   This program is distributed in the hope that it will be useful,' + #10 +
      '   but WITHOUT ANY WARRANTY; without even the implied warranty of' + #10 +
      '   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the' + #10 +
      '   LICENSE file for more details.' + #10 +
      '   ' + #10,
      [BZ2_bzlibVersion]));
end;

{ ----------------------------------------------------------- }
{ --- usage                                               --- }
{ ----------------------------------------------------------- }

procedure usage(fullProgName: PAnsiChar);
begin
  Write(ErrOutput,
    Format(
      'bzip2, a block-sorting file compressor.  Version %s.' + #10 +
      #10 + '   usage: %s [flags and input files in any order]' + #10 +
      #10 +
      '   -h --help           print this message' + #10 +
      '   -d --decompress     force decompression' + #10 +
      '   -z --compress       force compression' + #10 +
      '   -k --keep           keep (don''t delete) input files' + #10 +
      '   -f --force          overwrite existing output files' + #10 +
      '   -t --test           test compressed file integrity' + #10 +
      '   -c --stdout         output to standard out' + #10 +
      '   -q --quiet          suppress noncritical error messages' + #10 +
      '   -v --verbose        be verbose (a 2nd -v gives more)' + #10 +
      '   -L --license        display software version & license' + #10 +
      '   -V --version        display software version & license' + #10 +
      '   -s --small          use less memory (at most 2500k)' + #10 +
      '   -1 .. -9            set block size to 100k .. 900k' + #10 +
      '   --fast              alias for -1' + #10 +
      '   --best              alias for -9' + #10 +
      #10 +
      '   If invoked as `bzip2'', default action is to compress.' + #10 +
      '              as `bunzip2'',  default action is to decompress.' + #10 +
      '              as `bzcat'', default action is to decompress to stdout.' + #10 +
      #10 +
      '   If no file names are given, bzip2 compresses or decompresses' + #10 +
      '   from standard input to standard output.  You can combine' + #10 +
      '   short flags, so `-v -4'' means the same as -v4 or -4v, &c.' + #10 +
      #10,
      [BZ2_bzlibVersion, fullProgName]));
end;

{ ----------------------------------------------------------- }
{ --- redundant                                           --- }
{ ----------------------------------------------------------- }

procedure redundant(flag: PAnsiChar);
begin
  Write(ErrOutput,
    Format('%s: %s is redundant in versions 0.9.5 and above' + #10,
           [progName, flag]));
end;

{ ----------------------------------------------------------- }
{ --- myMalloc                                            --- }
{ ----------------------------------------------------------- }

function myMalloc(n: Int32): Pointer;
var
  p: Pointer;
begin
  GetMem(p, n);
  if p = nil then outOfMemory;
  Result := p;
end;

{ ----------------------------------------------------------- }
{ --- mkCell / snocString                                 --- }
{ ----------------------------------------------------------- }

function mkCell: PCell;
var
  c: PCell;
begin
  c := PCell(myMalloc(SizeOf(TCell)));
  c^.name := nil;
  c^.link := nil;
  Result := c;
end;

function snocString(root: PCell; name: PAnsiChar): PCell;
var
  tmp: PCell;
begin
  if root = nil then
  begin
    tmp := mkCell;
    tmp^.name := PAnsiChar(myMalloc(5 + Int32(StrLen(name))));
    StrCopy(tmp^.name, name);
    Result := tmp;
  end else
  begin
    tmp := root;
    while tmp^.link <> nil do
      tmp := tmp^.link;
    tmp^.link := snocString(tmp^.link, name);
    Result := root;
  end;
end;

{ ----------------------------------------------------------- }
{ --- addFlagsFromEnvVar                                  --- }
{ ----------------------------------------------------------- }

procedure addFlagsFromEnvVar(var argList: PCell; varName: PAnsiChar);
var
  envbase, p: PAnsiChar;
  i, j, k  : Int32;
  envStr    : AnsiString;
begin
  envStr := GetEnvironmentVariable(AnsiString(varName));
  if envStr = '' then Exit;

  envbase := PAnsiChar(envStr);
  p := envbase;
  i := 0;
  while True do
  begin
    if p[i] = #0 then Break;
    p := p + i;
    i := 0;
    while (p[0] = ' ') or (p[0] = #9) or (p[0] = #10) or (p[0] = #13) do
      Inc(p);
    while (p[i] <> #0) and (p[i] <> ' ') and (p[i] <> #9) and
          (p[i] <> #10) and (p[i] <> #13) do
      Inc(i);
    if i > 0 then
    begin
      k := i;
      if k > FILE_NAME_LEN - 10 then k := FILE_NAME_LEN - 10;
      for j := 0 to k - 1 do
        tmpName[j] := p[j];
      tmpName[k] := #0;
      argList := snocString(argList, tmpName);
    end;
  end;
end;

{ ----------------------------------------------------------- }
{ --- Main program                                        --- }
{ ----------------------------------------------------------- }

var
  i, j     : Int32;
  tmp      : PAnsiChar;
  argList  : PCell;
  aa, aa2  : PCell;
  decode   : Bool;
  sArg     : AnsiString;

begin
  { Set up PAnsiChar views of the static filename buffers }
  inName         := @inNameBuf[0];
  outName        := @outNameBuf[0];
  tmpName        := @tmpNameBuf[0];
  progNameReally := @progNameReallyBuf[0];

  { Sanity check sizes (compile-time assertions — catches wrong platform at build time) }
  {$IF SizeOf(Int32) <> 4}    {$ERROR 'Int32 must be 4 bytes'}    {$ENDIF}
  {$IF SizeOf(UInt32) <> 4}   {$ERROR 'UInt32 must be 4 bytes'}   {$ENDIF}
  {$IF SizeOf(Int16) <> 2}    {$ERROR 'Int16 must be 2 bytes'}    {$ENDIF}
  {$IF SizeOf(UInt16) <> 2}   {$ERROR 'UInt16 must be 2 bytes'}   {$ENDIF}
  {$IF SizeOf(AnsiChar) <> 1} {$ERROR 'AnsiChar must be 1 byte'}  {$ENDIF}
  {$IF SizeOf(UChar) <> 1}    {$ERROR 'UChar must be 1 byte'}     {$ENDIF}

  { Initialise }
  outputHandleJustInCase  := THandle(-1);
  smallMode               := BZ_FALSE;
  keepInputFiles          := BZ_FALSE;
  forceOverwrite          := BZ_FALSE;
  noisy                   := BZ_TRUE;
  verbosity               := 0;
  blockSize100k           := 9;
  testFailsExist          := BZ_FALSE;
  unzFailsExist           := BZ_FALSE;
  numFileNames            := 0;
  numFilesProcessed       := 0;
  workFactor              := 30;
  deleteOutputOnInterrupt := BZ_FALSE;
  exitValue               := 0;
  i := 0; j := 0;

  { Set up signal handlers for memory access errors }
  fpSignal(SIGSEGV, @mySIGSEGVorSIGBUScatcher);
  fpSignal(SIGBUS,  @mySIGSEGVorSIGBUScatcher);

  copyFileName(inName,  '(none)');
  copyFileName(outName, '(none)');

  { Build progName from argv[0] }
  sArg := ParamStr(0);
  copyFileName(progNameReally, PAnsiChar(sArg));
  progName := progNameReally;
  tmp := progNameReally;
  while tmp^ <> #0 do
  begin
    if tmp^ = PATH_SEP then progName := tmp + 1;
    Inc(tmp);
  end;

  { Copy flags from env vars BZIP2 and BZIP, then append command-line args }
  argList := nil;
  addFlagsFromEnvVar(argList, 'BZIP2');
  addFlagsFromEnvVar(argList, 'BZIP');
  for i := 1 to ParamCount do
  begin
    sArg := ParamStr(i);
    argList := snocString(argList, PAnsiChar(sArg));
  end;

  { Find length of longest filename }
  longestFileName := 7;
  numFileNames    := 0;
  decode          := BZ_TRUE;
  aa := argList;
  while aa <> nil do
  begin
    if StrComp(aa^.name, '--') = 0 then begin decode := BZ_FALSE; aa := aa^.link; Continue; end;
    if (aa^.name[0] = '-') and (decode <> 0) then begin aa := aa^.link; Continue; end;
    Inc(numFileNames);
    if longestFileName < Int32(StrLen(aa^.name)) then
      longestFileName := Int32(StrLen(aa^.name));
    aa := aa^.link;
  end;

  { Determine source modes }
  if numFileNames = 0 then srcMode := SM_I2O
  else srcMode := SM_F2F;

  { Determine operation mode from program name }
  opMode := OM_Z;

  if (StrPos(progName, 'unzip') <> nil) or (StrPos(progName, 'UNZIP') <> nil) then
    opMode := OM_UNZ;

  if (StrPos(progName, 'z2cat') <> nil) or (StrPos(progName, 'Z2CAT') <> nil) or
     (StrPos(progName, 'zcat')  <> nil) or (StrPos(progName, 'ZCAT')  <> nil) then
  begin
    opMode := OM_UNZ;
    if numFileNames = 0 then srcMode := SM_I2O
    else srcMode := SM_F2O;
  end;

  { Process short flags }
  aa := argList;
  while aa <> nil do
  begin
    if StrComp(aa^.name, '--') = 0 then Break;
    if (aa^.name[0] = '-') and (aa^.name[1] <> '-') then
    begin
      j := 1;
      while aa^.name[j] <> #0 do
      begin
        case aa^.name[j] of
          'c': srcMode        := SM_F2O;
          'd': opMode         := OM_UNZ;
          'z': opMode         := OM_Z;
          'f': forceOverwrite := BZ_TRUE;
          't': opMode         := OM_TEST;
          'k': keepInputFiles := BZ_TRUE;
          's': smallMode      := BZ_TRUE;
          'q': noisy          := BZ_FALSE;
          '1': blockSize100k  := 1;
          '2': blockSize100k  := 2;
          '3': blockSize100k  := 3;
          '4': blockSize100k  := 4;
          '5': blockSize100k  := 5;
          '6': blockSize100k  := 6;
          '7': blockSize100k  := 7;
          '8': blockSize100k  := 8;
          '9': blockSize100k  := 9;
          'V', 'L':
            begin
              license;
              Halt(0);
            end;
          'v': Inc(verbosity);
          'h':
            begin
              usage(progName);
              Halt(0);
            end;
          else
            begin
              Write(ErrOutput, Format('%s: Bad flag `%s''' + #10,
                                      [progName, aa^.name]));
              usage(progName);
              Halt(1);
            end;
        end;
        Inc(j);
      end;
    end;
    aa := aa^.link;
  end;

  { Process long flags }
  aa := argList;
  while aa <> nil do
  begin
    if StrComp(aa^.name, '--') = 0 then Break;

    if      StrComp(aa^.name, '--stdout')          = 0 then srcMode        := SM_F2O
    else if StrComp(aa^.name, '--decompress')       = 0 then opMode         := OM_UNZ
    else if StrComp(aa^.name, '--compress')         = 0 then opMode         := OM_Z
    else if StrComp(aa^.name, '--force')            = 0 then forceOverwrite := BZ_TRUE
    else if StrComp(aa^.name, '--test')             = 0 then opMode         := OM_TEST
    else if StrComp(aa^.name, '--keep')             = 0 then keepInputFiles := BZ_TRUE
    else if StrComp(aa^.name, '--small')            = 0 then smallMode      := BZ_TRUE
    else if StrComp(aa^.name, '--quiet')            = 0 then noisy          := BZ_FALSE
    else if StrComp(aa^.name, '--version')          = 0 then begin license; Halt(0); end
    else if StrComp(aa^.name, '--license')          = 0 then begin license; Halt(0); end
    else if StrComp(aa^.name, '--exponential')      = 0 then workFactor     := 1
    else if StrComp(aa^.name, '--repetitive-best')  = 0 then redundant(aa^.name)
    else if StrComp(aa^.name, '--repetitive-fast')  = 0 then redundant(aa^.name)
    else if StrComp(aa^.name, '--fast')             = 0 then blockSize100k  := 1
    else if StrComp(aa^.name, '--best')             = 0 then blockSize100k  := 9
    else if StrComp(aa^.name, '--verbose')          = 0 then Inc(verbosity)
    else if StrComp(aa^.name, '--help')             = 0 then begin usage(progName); Halt(0); end
    else if StrLComp(aa^.name, '--', 2) = 0 then
    begin
      Write(ErrOutput, Format('%s: Bad flag `%s''' + #10, [progName, aa^.name]));
      usage(progName);
      Halt(1);
    end;

    aa := aa^.link;
  end;

  if verbosity > 4 then verbosity := 4;
  if (opMode = OM_Z) and (smallMode <> 0) and (blockSize100k > 2) then
    blockSize100k := 2;

  if (opMode = OM_TEST) and (srcMode = SM_F2O) then
  begin
    Write(ErrOutput, Format('%s: -c and -t cannot be used together.' + #10,
                            [progName]));
    Halt(1);
  end;

  if (srcMode = SM_F2O) and (numFileNames = 0) then
    srcMode := SM_I2O;

  if opMode <> OM_Z then blockSize100k := 0;

  if srcMode = SM_F2F then
  begin
    fpSignal(SIGINT,  @mySignalCatcher);
    fpSignal(SIGTERM, @mySignalCatcher);
    fpSignal(SIGHUP,  @mySignalCatcher);
  end;

  if opMode = OM_Z then
  begin
    if srcMode = SM_I2O then
      compress(nil)
    else
    begin
      decode := BZ_TRUE;
      aa := argList;
      while aa <> nil do
      begin
        if StrComp(aa^.name, '--') = 0 then begin decode := BZ_FALSE; aa := aa^.link; Continue; end;
        if (aa^.name[0] = '-') and (decode <> 0) then begin aa := aa^.link; Continue; end;
        Inc(numFilesProcessed);
        compress(aa^.name);
        aa := aa^.link;
      end;
    end;
  end else

  if opMode = OM_UNZ then
  begin
    unzFailsExist := BZ_FALSE;
    if srcMode = SM_I2O then
      uncompress(nil)
    else
    begin
      decode := BZ_TRUE;
      aa := argList;
      while aa <> nil do
      begin
        if StrComp(aa^.name, '--') = 0 then begin decode := BZ_FALSE; aa := aa^.link; Continue; end;
        if (aa^.name[0] = '-') and (decode <> 0) then begin aa := aa^.link; Continue; end;
        Inc(numFilesProcessed);
        uncompress(aa^.name);
        aa := aa^.link;
      end;
    end;
    if unzFailsExist <> 0 then
    begin
      setExit(2);
      Halt(exitValue);
    end;
  end else

  begin
    { OM_TEST }
    testFailsExist := BZ_FALSE;
    if srcMode = SM_I2O then
      testf(nil)
    else
    begin
      decode := BZ_TRUE;
      aa := argList;
      while aa <> nil do
      begin
        if StrComp(aa^.name, '--') = 0 then begin decode := BZ_FALSE; aa := aa^.link; Continue; end;
        if (aa^.name[0] = '-') and (decode <> 0) then begin aa := aa^.link; Continue; end;
        Inc(numFilesProcessed);
        testf(aa^.name);
        aa := aa^.link;
      end;
    end;
    if testFailsExist <> 0 then
    begin
      if noisy <> 0 then
        Write(ErrOutput,
          #10 +
          'You can use the `bzip2recover'' program to attempt to recover' + #10 +
          'data from undamaged sections of corrupted files.' + #10 + #10);
      setExit(2);
      Halt(exitValue);
    end;
  end;

  { Free the argument list }
  aa := argList;
  while aa <> nil do
  begin
    aa2 := aa^.link;
    if aa^.name <> nil then FreeMem(aa^.name);
    FreeMem(aa);
    aa := aa2;
  end;

  Halt(exitValue);
end.

{-----------------------------------------------------------}
{--- end                                        bzip2.pas ---}
{-----------------------------------------------------------}
