{$I pasbzip2.inc}
program TestReferenceVectors;

{
  Phase 7 validation: decompresses sample{1,2,3}.bz2 using the Pascal
  BZ2_bzBuffToBuffDecompress and verifies byte-by-byte against the
  corresponding .ref files.
}

uses
  SysUtils,
  pasbzip2types,
  pasbzip2;

const
  MAX_DECOMP_SIZE = 10 * 1024 * 1024; // 10 MB

function LoadFile(const fname: string; out data: PByte; out size: Int64): Boolean;
var
  f: file;
begin
  Result := False;
  if not FileExists(fname) then Exit;
  AssignFile(f, fname);
  Reset(f, 1);
  size := FileSize(f);
  GetMem(data, size);
  BlockRead(f, data^, size);
  CloseFile(f);
  Result := True;
end;

var
  allPassed: Boolean;
  i: Integer;
  sampleName: string;
  bz2File, refFile: string;
  bz2Data, refData: PByte;
  bz2Size, refSize: Int64;
  destBuf: PByte;
  destLen: UInt32;
  ret: Int32;
  ok: Boolean;
  j: Integer;
  vectorDir: string;

begin
  allPassed := True;
  vectorDir := ExtractFilePath(ParamStr(0));
  vectorDir := ExpandFileName(vectorDir + '../src/tests/vectors/');

  for i := 1 to 3 do
  begin
    sampleName := 'sample' + IntToStr(i);
    bz2File := vectorDir + sampleName + '.bz2';
    refFile := vectorDir + sampleName + '.ref';

    if not LoadFile(bz2File, bz2Data, bz2Size) then
    begin
      WriteLn('FAIL ', sampleName, ': cannot open ', bz2File);
      allPassed := False;
      Continue;
    end;

    if not LoadFile(refFile, refData, refSize) then
    begin
      FreeMem(bz2Data);
      WriteLn('FAIL ', sampleName, ': cannot open ', refFile);
      allPassed := False;
      Continue;
    end;

    GetMem(destBuf, MAX_DECOMP_SIZE);
    destLen := MAX_DECOMP_SIZE;

    ret := BZ2_bzBuffToBuffDecompress(
      PChar(destBuf), @destLen,
      PChar(bz2Data), bz2Size,
      0, 0);

    if ret <> BZ_OK then
    begin
      WriteLn('FAIL ', sampleName, ': BZ2_bzBuffToBuffDecompress returned ', ret);
      allPassed := False;
    end
    else if destLen <> UInt32(refSize) then
    begin
      WriteLn('FAIL ', sampleName, ': size mismatch: got ', destLen, ' expected ', refSize);
      allPassed := False;
    end
    else
    begin
      ok := True;
      for j := 0 to Int32(destLen) - 1 do
      begin
        if destBuf[j] <> refData[j] then
        begin
          WriteLn('FAIL ', sampleName, ': byte mismatch at offset ', j,
            ' got $', IntToHex(destBuf[j], 2), ' expected $', IntToHex(refData[j], 2));
          ok := False;
          allPassed := False;
          Break;
        end;
      end;
      if ok then
        WriteLn('PASS ', sampleName);
    end;

    FreeMem(destBuf);
    FreeMem(bz2Data);
    FreeMem(refData);
  end;

  if allPassed then
  begin
    WriteLn('ALL PASSED');
    Halt(0);
  end
  else
    Halt(1);
end.
