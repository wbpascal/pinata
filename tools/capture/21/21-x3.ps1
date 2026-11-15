<#
  Scenario 21 step 12, run "21d": X3 (capture-scenarios.md §9.4): BestLowHpPotion MaxLot 50 -> 49.
  ItemInfo.shn is hashed against the client's copy, so the server AND the client file are swapped.
  No Python needed here: ItemInfo.x3.shn (next to this script) was built from the repository's
  Files/Server/2016/9Data/Shine/ItemInfo.shn with docs/plan/status/X02-shnset.py; the shipped server and client
  files are byte-identical to it, which the hash check below makes sure of.

  Server:     .\21-x3.ps1 Apply      /  .\21-x3.ps1 Restore      (default target C:\FiestaServer\2016\9Data\Shine)
  Client PC:  .\21-x3.ps1 Apply -Target '<client folder>\ressystem'  /  ... Restore -Target ...

  Stop all four Zone processes (server) and close the client (client PC) first; start them again afterwards.
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('Apply', 'Restore')][string]$Action,
    [string]$Target = 'C:\FiestaServer\2016\9Data\Shine'
)
$ErrorActionPreference = 'Stop'
$orig_sha = '8DD333D1C6546D840B68C5E6CA4FE09E6EE8BA08C9D5DA988BEC71DDF56B4F20'   # shipped ItemInfo.shn (2016)
$x3_sha   = '657494A148D23F653CEDD65AB1E4ADCC08930EC7811E8FCF774F1BD786BDBE09'   # ItemInfo.x3.shn
$t = Join-Path $Target 'ItemInfo.shn'
$x3 = Join-Path $PSScriptRoot 'ItemInfo.x3.shn'

if (Get-Process | Where-Object { $_.ProcessName -like 'Zone*' -or $_.ProcessName -like 'Fiesta*' }) {
    throw 'a Zone or client process is still running: stop it first'
}
if (-not (Test-Path $t)) { throw "$t not found" }

if ($Action -eq 'Apply') {
    if (Test-Path "$t.orig") { throw "$t.orig exists: run Restore first" }
    if ((Get-FileHash $x3).Hash -ne $x3_sha) { throw "$x3 is missing or damaged" }
    if ((Get-FileHash $t).Hash -ne $orig_sha) { throw "$t is not the shipped 2016 file: X3 was built for that one, stop" }
    Copy-Item $t "$t.orig"; Copy-Item $x3 $t -Force
    Write-Host "patched $t (MaxLot of BestLowHpPotion = 49; original: $t.orig)"
} else {
    if (-not (Test-Path "$t.orig")) { throw "no $t.orig: nothing to restore" }
    Move-Item "$t.orig" $t -Force
    $ok = (Get-FileHash $t).Hash -eq $orig_sha
    Write-Host "restored $t (shipped file: $ok)"
}
