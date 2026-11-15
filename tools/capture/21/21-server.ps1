<#
  Scenario 21: everything that runs on the server, one action per call. Copy the folder tools\capture\21 to the
  server (e.g. C:\FiestaServer\capture\21) and run it there in PowerShell. Needs sqlcmd (comes with SQL Server)
  and Windows authentication to the instance (-Instance, default "." = the local default instance).

  .\21-server.ps1 prep              S1 (admin level 100) + check that account B can log in   [admin at login screen]
  .\21-server.ps1 snapshot-before   items / money of the GM character -> out\..._items-snapshot-before.txt
  .\21-server.ps1 snapshot-after    the same -> out\..._items-snapshot-after.txt               [admin at login screen]
  .\21-server.ps1 s16-on | s16-off  run 21b: install / remove the failing tItemOptions trigger
  .\21-server.ps1 s13               run 21c: expire the newest Leather Boots                  [admin at login screen]
  .\21-server.ps1 s13-done          run 21c: drop the S13 save tables after the test
  .\21-server.ps1 x3-apply | x3-restore   run 21d: swap ItemInfo.shn in C:\FiestaServer\2016\9Data\Shine [zones stopped]
  .\21-server.ps1 status            X02 save tables and triggers still in the database
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prep', 'snapshot-before', 'snapshot-after', 's16-on', 's16-off', 's13', 's13-done',
                 'x3-apply', 'x3-restore', 'status')][string]$Action,
    [string]$Instance = '.',
    [string]$Name = '26_11_15_21_items'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here 'out'
New-Item -ItemType Directory -Force $out | Out-Null

function Sql([string]$file, [string]$log) {
    $sqlArgs = @('-S', $Instance, '-E', '-b', '-W', '-s', '|', '-i', (Join-Path $here $file))
    if ($log) { & sqlcmd @sqlArgs -o $log; Get-Content $log } else { & sqlcmd @sqlArgs }
    if ($LASTEXITCODE) { throw "$file failed (sqlcmd exit $LASTEXITCODE)" }
}
function SqlQ([string]$q) { & sqlcmd -S $Instance -E -b -W -Q $q; if ($LASTEXITCODE) { throw "query failed" } }

switch ($Action) {
    'prep'            { Sql '21-prep.sql' (Join-Path $out "$Name-prep.txt") }
    'snapshot-before' { Sql '21-snapshot.sql' (Join-Path $out "$Name-snapshot-before.txt") }
    'snapshot-after'  { Sql '21-snapshot.sql' (Join-Path $out "$Name-snapshot-after.txt") }
    's16-on'          { Sql '21-s16-on.sql' (Join-Path $out "$Name-s16-before.txt") }
    's16-off'         { Sql '21-s16-off.sql' }
    's13'             { Sql '21-s13.sql' (Join-Path $out "$Name-s13.txt") }
    's13-done'        { SqlQ "USE World00_Character; IF OBJECT_ID('dbo.X02_save_13a') IS NOT NULL DROP TABLE dbo.X02_save_13a; IF OBJECT_ID('dbo.X02_save_13b') IS NOT NULL DROP TABLE dbo.X02_save_13b;" }
    'x3-apply'        { & (Join-Path $here '21-x3.ps1') Apply }
    'x3-restore'      { & (Join-Path $here '21-x3.ps1') Restore }
    'status'          { SqlQ "USE World00_Character; SELECT name, type_desc FROM sys.objects WHERE name LIKE 'X02[_]%';" }
}
