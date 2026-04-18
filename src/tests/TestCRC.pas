{$I pasbzip2.inc}
program TestCRC;

{
  Smoke test for the bzip2 build infrastructure.
  Loads libbz2.so via cbzip2, calls cbz_bzlibVersion and prints the result.
  If this runs successfully, the C shared library is reachable and the
  Pascal build chain works end-to-end.
}

uses
  SysUtils,
  pasbzip2types,
  cbzip2;

begin
  WriteLn('TestCRC — build-system smoke test');
  WriteLn('libbz2 version: ', cbz_bzlibVersion());
  WriteLn('PASSED');
end.
