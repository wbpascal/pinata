<#
  Scenario 37, second run "37b" (docs/plan/capture-scenarios.md §3 "37"): the character-select paths the first run
  (s37) did not reach. Everything that runs on the server, one action per call. Copy tools\capture\37 to the server
  (e.g. C:\FiestaServer\capture\37) and run it there in an ELEVATED PowerShell (dumpcap, killing / starting zones).
  Needs sqlcmd; Windows authentication to -Instance (default .\SQLExpress, insecure connection: sqlcmd -C).

  .\37b-server.ps1 prep            [admin logged out]  '-' name for -DashChar, rename right for -RightChar, DB checks
  .\37b-server.ps1 capture-start   opens dumpcap in its own window (loopback + LAN, filter of capture-guide.md);
                                   stop it with Ctrl+C in THAT window. -NoLan when the client runs on the server PC
  .\37b-server.ps1 stop-zones      step 4: kill every zone process (remembered in out\zones.json)
  .\37b-server.ps1 start-zones     step 4: start them again, wait until each listens and is linked to the WM
  .\37b-server.ps1 snapshot -Label <text>   characters + rename rows of the account -> out\<Name>-db.txt
  .\37b-server.ps1 status          zone ports, WM links, client links, save table
  .\37b-server.ps1 cleanup         [admin logged out]  snapshot, then restore names, remove the rename rows;
                                   with -Dest <folder> it ends with collect
  .\37b-server.ps1 collect -Dest <folder>   copies out\<Name>.pcapng, -prep.txt and -db.txt into <folder> (the notes' folder)

  Defaults: -DashChar X37Del (renamed to -DashName X37-Ren), -RightChar Test2.
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prep', 'capture-start', 'stop-zones', 'start-zones', 'snapshot', 'status', 'cleanup', 'collect')]
    [string]$Action,
    [string]$Instance = '.\SQLExpress',
    [string]$CharDb = 'World00_Character',
    [string]$DashChar = 'X37Del',
    [string]$DashName = 'X37-Ren',
    [string]$RightChar = 'Test2',
    [string]$Label = 'snapshot',
    [string]$Name = '26_11_16_37b_char-select-rename-refusals',
    [string]$ServerRoot = 'C:\FiestaServer\2016',
    [string]$Dumpcap = 'C:\Program Files\Wireshark\dumpcap.exe',
    [string]$Dest,
    [switch]$NoLan
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$dbLog = Join-Path $out "$Name-db.txt"
$zonesJson = Join-Path $out 'zones.json'
foreach ($n in $DashChar, $DashName, $RightChar) { if ($n -notmatch '^[A-Za-z0-9_\-]{1,16}$') { throw "bad character name '$n'" } }
if ($DashName -notmatch '-') { throw "-DashName must contain '-' (that is what makes the client ask for the rename)" }

# Ports from the install's ServerInfo.txt (as 38-server.ps1): zone client ports = type-20 rows of PG_W*_Z*,
# WM <- zone = type-6 row of PG_W*_WM. Shipped values are the fallback.
$ZonePorts = @(9210, 9212, 9214, 9216); $WmZonePort = 9111; $WmClientPort = 9110
$si = Join-Path $ServerRoot '9Data\ServerInfo\ServerInfo.txt'
if (Test-Path -LiteralPath $si) {
    $rows = Get-Content -LiteralPath $si | Where-Object { $_ -match '^\s*SERVER_INFO\s' } | ForEach-Object {
        $f = ($_ -replace '^\s*SERVER_INFO\s+', '') -split ',' | ForEach-Object { $_.Trim().Trim('"') }
        if ($f.Count -ge 7) { [pscustomobject]@{ Name = $f[0]; Type = [int]$f[4]; Port = [int]$f[6] } }
    }
    $zp = @($rows | Where-Object { $_.Name -like 'PG_W*_Z*' -and $_.Type -eq 20 } | ForEach-Object Port)
    if ($zp) { $ZonePorts = $zp }
    $w6 = $rows | Where-Object { $_.Name -like 'PG_W*_WM' -and $_.Type -eq 6 } | Select-Object -First 1
    if ($w6) { $WmZonePort = $w6.Port }
    $w20 = $rows | Where-Object { $_.Name -like 'PG_W*_WM' -and $_.Type -eq 20 } | Select-Object -First 1
    if ($w20) { $WmClientPort = $w20.Port }
} else { Write-Warning "$si not found (-ServerRoot): shipped ports used" }

function Stamp { (Get-Date).ToString('HH:mm:ss.fff') }
function Sql([string]$file, [hashtable]$vars, [string]$log) {
    $a = @('-S', $Instance, '-E', '-C', '-b', '-W', '-s', '|', '-i', (Join-Path $here $file), '-v', "CharDb=$CharDb")
    foreach ($k in $vars.Keys) { $a += @('-v', "$k=$($vars[$k])") }
    $o = & sqlcmd @a
    $code = $LASTEXITCODE
    $o | ForEach-Object { Write-Host $_ }
    if ($log) { "---- $(Stamp) $file" | Add-Content -LiteralPath $log -Encoding UTF8; $o | Add-Content -LiteralPath $log -Encoding UTF8 }
    if ($code) { throw "$file failed (sqlcmd exit $code)" }
}
# collect (X07): the run's files next to its notes. s38 lost its -db.txt because only the pcapng was copied by hand.
function Collect([string]$dest, [string]$pcap) {
    if (-not $dest) { throw "collect needs -Dest <folder>: the folder of the notes file (re-data\captures of a checkout, a share or a USB stick)" }
    New-Item -ItemType Directory -Force $dest | Out-Null
    if (-not $pcap) { $pcap = Join-Path $out "$Name.pcapng" }
    $missing = @()
    $files = [ordered]@{ $pcap = "$Name" + [IO.Path]::GetExtension($pcap); (Join-Path $out "$Name-prep.txt") = "$Name-prep.txt"; $dbLog = "$Name-db.txt" }
    foreach ($src in $files.Keys) {
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dest $files[$src]) -Force
            Write-Host "copied $src -> $(Join-Path $dest $files[$src])"
        } else { $missing += $src }
    }
    if ($missing) { Write-Warning ("missing, copy by hand if it exists elsewhere: " + ($missing -join ', ')) }
    else { Write-Host "all files of $Name are in $dest" }
}
function Snapshot([string]$label) { Sql '37b-snapshot.sql' @{ RightChar = $RightChar; Label = ($label -replace '[^\w\-]+', '_') } $dbLog }

function Zone-Listeners {
    foreach ($port in $ZonePorts) {
        $l = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        $wm = $null
        if ($l) { $wm = Get-NetTCPConnection -State Established -OwningProcess $l.OwningProcess -RemotePort $WmZonePort -ErrorAction SilentlyContinue }
        [pscustomobject]@{ Port = $port; Pid = $(if ($l) { $l.OwningProcess } else { 0 }); Linked = [bool]$wm }
    }
}
function Show-ClientLinks {
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @($WmClientPort) + $ZonePorts } |
        ForEach-Object { Write-Host ("  {0,-5} {1}:{2}  ({3})" -f $_.LocalPort, $_.RemoteAddress, $_.RemotePort, $(if ($_.LocalPort -eq $WmClientPort) { 'WM' } else { 'zone' })) }
}

switch ($Action) {
    'prep' {
        Write-Host "scenario 37b prep: $DashChar -> $DashName (plain rename), rename right for $RightChar"
        Sql '37b-prep.sql' @{ DashChar = $DashChar; DashName = $DashName; RightChar = $RightChar } (Join-Path $out "$Name-prep.txt")
        Snapshot 'after prep'
        Write-Host 'zones now:'; Zone-Listeners | Format-Table -AutoSize | Out-Host
    }
    'capture-start' {
        if (-not (Test-Path -LiteralPath $Dumpcap)) { throw "dumpcap not found at $Dumpcap (-Dumpcap <path>)" }
        $ifs = @('\Device\NPF_Loopback')
        if (-not $NoLan) {
            $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
            $ad = Get-NetAdapter -InterfaceIndex $r.ifIndex
            $ifs += "\Device\NPF_$($ad.InterfaceGuid)"
            Write-Host "LAN interface: $($ad.Name) ($($ad.InterfaceDescription))"
        }
        $filter = 'tcp portrange 9000-9011 or tcp portrange 9110-9111 or tcp portrange 9210-9221 or tcp port 9311 or tcp port 9411 or tcp port 9511'
        $file = Join-Path $out "$Name.pcapng"
        if (Test-Path -LiteralPath $file) { throw "$file exists: move it away first" }
        $argline = "-f `"$filter`" " + (($ifs | ForEach-Object { "-i `"$_`"" }) -join ' ') + " -w `"$file`""
        Start-Process -FilePath $Dumpcap -ArgumentList $argline
        Write-Host "$(Stamp) dumpcap started -> $file"
        Write-Host 'Check its window shows "Capturing on ..." for both interfaces. Stop it with Ctrl+C in that window.'
    }
    'stop-zones' {
        $z = @(Zone-Listeners | Where-Object Pid -ne 0)
        if (-not $z) { throw 'no zone process listens on the zone ports' }
        $info = foreach ($pp in ($z | Select-Object -ExpandProperty Pid -Unique)) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$pp"
            $a0 = ''; if ($p.CommandLine) { $a0 = ($p.CommandLine -replace '^\s*("[^"]*"|\S+)\s*', '') }
            $svc = Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -eq $pp } | Select-Object -First 1
            [pscustomobject]@{ Pid = $pp; Exe = $p.ExecutablePath; Dir = (Split-Path $p.ExecutablePath); Args = $a0
                               Service = $(if ($svc) { $svc.Name } else { '' })
                               Ports = @($z | Where-Object Pid -eq $pp | ForEach-Object Port) }
        }
        $info | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $zonesJson -Encoding UTF8
        foreach ($i in $info) {
            Write-Host ("{0} killing zone pid {1} {2} (ports {3})" -f (Stamp), $i.Pid, $i.Exe, ($i.Ports -join ','))
            Stop-Process -Id $i.Pid -Force
        }
        $info | ForEach-Object { Wait-Process -Id $_.Pid -Timeout 20 -ErrorAction SilentlyContinue }
        Write-Host ("{0} all zones gone. Now select the character in the client." -f (Stamp))
    }
    'start-zones' {
        if (-not (Test-Path -LiteralPath $zonesJson)) { throw "no ${zonesJson}: stop-zones was not run" }
        $info = @(Get-Content -LiteralPath $zonesJson -Raw | ConvertFrom-Json)
        foreach ($i in $info) {
            if ($i.Service) {
                if ((Get-Service -Name $i.Service).Status -ne 'Running') { Start-Service -Name $i.Service }
                Write-Host ("{0} service {1} started" -f (Stamp), $i.Service)
            } else {
                $sp = @{ FilePath = $i.Exe; WorkingDirectory = $i.Dir }
                if ($i.Args) { $sp.ArgumentList = $i.Args }
                Start-Process @sp
                Write-Host ("{0} started {1} {2}" -f (Stamp), $i.Exe, $i.Args)
            }
        }
        $want = @($info | ForEach-Object { $_.Ports }) | ForEach-Object { [int]$_ }
        $deadline = (Get-Date).AddSeconds(300)
        while ((Get-Date) -lt $deadline) {
            $st = @(Zone-Listeners | Where-Object { $_.Port -in $want })
            if (@($st | Where-Object { -not $_.Linked }).Count -eq 0) {
                Write-Host ("{0} READY: every zone listens and is linked to the WM. Select the character again." -f (Stamp))
                Remove-Item -LiteralPath $zonesJson
                return
            }
            Start-Sleep -Seconds 2
        }
        Write-Warning 'not every zone came back within 300 s: check their consoles / logs, start them by hand, then run status'
    }
    'snapshot' { Snapshot $Label }
    'status' {
        Zone-Listeners | Format-Table -AutoSize | Out-Host
        Write-Host 'client links:'; Show-ClientLinks
        & sqlcmd -S $Instance -E -C -b -W -Q "USE $CharDb; SELECT name AS open_x02_or_x37_object FROM sys.objects WHERE name LIKE 'X02[_]%' OR name LIKE 'X37[_]%';"
    }
    'cleanup' {
        if (@(Get-NetTCPConnection -State Established -LocalPort $WmClientPort -ErrorAction SilentlyContinue).Count) {
            Write-Warning "a client is still connected to the WM (port $WmClientPort): log admin out first, or the WM keeps the run's names"
        }
        Snapshot 'before cleanup'
        Sql '37b-cleanup.sql' @{} $dbLog
        if (Test-Path -LiteralPath $zonesJson) { Write-Warning "$zonesJson still there: start-zones was not completed" }
        if ($Dest) { Collect $Dest '' } else { Write-Host "Next: .\37b-server.ps1 collect -Dest <folder of $Name.md> (pcapng, -prep.txt and -db.txt)" }
    }
    'collect' { Collect $Dest '' }
}
