{$I pasbzip2.inc}
unit pasbzip2blocksort;

{
  Pascal port of bzip2/libbzip2 1.1.0 — block sorter.
  Phase 4 STUB: delegates to the C reference implementation via cbzip2.
  Will be replaced by the real Pascal sort in Phase 5.
}

interface

uses
  pasbzip2types;

{ Top-level BWT entry point — called by BZ2_compressBlock. }
procedure BZ2_blockSort(s: PEState);

implementation

uses
  cbzip2;   // cbz_blockSort

procedure BZ2_blockSort(s: PEState);
begin
  cbz_blockSort(s);
end;

end.
