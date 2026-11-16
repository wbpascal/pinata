<#
  Scenario 38 (docs/plan/capture-scenarios.md §3 "38"): everything that runs on the server, one action per call.
  Copy the folder tools\capture\38 to the server (e.g. C:\FiestaServer\capture\38) and run it there in an
  ELEVATED PowerShell: resetting one TCP connection and killing / starting server processes need admin rights.
  Needs sqlcmd (comes with SQL Server) and Windows authentication to the instance (-Instance, default ".").

  -Char <name> = the character of account "admin" that plays the run (GM level 100 after prep).

  .\38-server.ps1 prep -Char <name>            S1 (admin level 100) + money / position before   [admin at the login screen]
  .\38-server.ps1 snapshot -Char <name> -Label <text>   money / position as the DB holds them -> out\<Name>-db.txt
  .\38-server.ps1 close-zone-conn              step 3: reset the client's ZONE connection only (the WM one stays)
  .\38-server.ps1 kill-client                  step 4: kill the client process (only if the client runs on this PC)
  .\38-server.ps1 kill-zone -Char <name>       step 5: kill the zone process the client is on (no clean stop),
                                               read the DB, start that zone again and wait until it is linked to the WM
  .\38-server.ps1 getmoney-kill -Char <name>   step 6: "&getmoney 500" into the client, the same kill -DelayMs later
                                               (client on this PC: typed for you; else a countdown tells you when to press Enter)
  .\38-server.ps1 status                       zone processes and ports, WM links, X02 save tables
  .\38-server.ps1 restore-gm                   undo S1 (only when no later scenario needs the GM character) [admin at the login screen]
  .\38-server.ps1 collect -Dest <folder> [-Pcap <file>]   at the end: copies -prep.txt, -db.txt and the capture
                                               (-Pcap, default out\<Name>.pcapng) into <folder> (the notes' folder)

  The zone is found from the client's connection (local ports 9210 / 9212 / 9214 / 9216), so the map does not matter.
  -ZonePort <port> picks the zone when no client is connected (kill-zone) or more than one is.
#>
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('prep', 'snapshot', 'close-zone-conn', 'kill-client', 'kill-zone', 'getmoney-kill', 'status', 'restore-gm', 'collect')]
    [string]$Action,
    [string]$Char,
    [string]$Label = 'snapshot',
    [string]$Instance = '.',
    [string]$Name = '26_11_16_38_session-loss-kicks-char-select',
    [int]$ZonePort = 0,
    [int]$RemotePort = 0,
    [int]$DelayMs = -1,
    [int]$Money = 500,
    [switch]$Countdown,
    [string]$ClientLike = 'Fiesta*',
    [string]$ServerRoot = 'C:\FiestaServer\2016',
    [string]$Dest,
    [string]$Pcap
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$out = Join-Path $here 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$dbLog = Join-Path $out "$Name-db.txt"

# Ports from the install's own ServerInfo.txt: zone client ports = type-20 rows of PG_W00_Z*, WM <- zone = type-6 row of
# PG_W00_WM. The shipped values (9210/9212/9214/9216, 9111) are only the fallback.
$ZonePorts = @(9210, 9212, 9214, 9216)
$WmZonePort = 9111
$WmClientPort = 9110
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
    Write-Host ("ports from {0}: zones {1}, WM client {2}, WM<-zone {3}" -f $si, ($ZonePorts -join '/'), $WmClientPort, $WmZonePort)
} else {
    Write-Warning "$si not found (-ServerRoot): using the shipped ports zones $($ZonePorts -join '/'), WM $WmClientPort / $WmZonePort"
}

function Stamp { (Get-Date).ToString('HH:mm:ss.fff') }

function Sql([string]$file, [hashtable]$vars, [string]$log) {
    $a = @('-S', $Instance, '-E', '-b', '-W', '-s', '|', '-i', (Join-Path $here $file))
    foreach ($k in $vars.Keys) { $a += @('-v', "$k=$($vars[$k])") }
    $o = & sqlcmd @a
    $code = $LASTEXITCODE
    $o | ForEach-Object { Write-Host $_ }
    if ($log) { $o | Add-Content -LiteralPath $log -Encoding UTF8 }
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
function Snapshot([string]$label) {
    Sql '38-snapshot.sql' @{ Char = $Char; Label = ($label -replace '[^\w\-]+', '_') } $dbLog
}
function Need-Char {
    if ($Char -notmatch '^[A-Za-z0-9_]{1,20}$') { throw "-Char <character name> is required for '$Action' (the character that plays this run)" }
}

# --- connections -------------------------------------------------------------------------------------------
function Zone-ClientConns {
    @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
      Where-Object { $_.LocalPort -in $ZonePorts -and ($ZonePort -eq 0 -or $_.LocalPort -eq $ZonePort) -and
                     ($RemotePort -eq 0 -or $_.RemotePort -eq $RemotePort) })
}
function Show-Diag {
    Write-Host "nothing Established on the zone ports $($ZonePorts -join '/'). What the server processes have:"
    $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
    $est = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
    Get-Process | Where-Object { $_.ProcessName -match 'Zone|World|Login' } | ForEach-Object {
        $p = $_
        $lp = ($listen | Where-Object OwningProcess -eq $p.Id | ForEach-Object LocalPort | Sort-Object -Unique) -join ','
        Write-Host ("  {0} pid {1}  listens on: {2}" -f $p.ProcessName, $p.Id, $lp)
        $est | Where-Object { $_.OwningProcess -eq $p.Id -and $_.LocalPort -in ($listen | Where-Object OwningProcess -eq $p.Id).LocalPort } |
            ForEach-Object { Write-Host ("      inbound  {0}:{1} <- {2}:{3}" -f $_.LocalAddress, $_.LocalPort, $_.RemoteAddress, $_.RemotePort) }
    }
    Write-Host 'If a zone has an inbound link from the client on another port, run again with -ZonePort <that port>,'
    Write-Host 'or -ServerRoot <folder that holds 9Data> if the install is not in C:\FiestaServer\2016.'
}
function One-ZoneConn {
    $c = @(Zone-ClientConns)
    if ($c.Count -eq 0) { Show-Diag; throw 'no client is connected to a zone (is the character in the game?)' }
    if ($c.Count -gt 1) {
        $c | ForEach-Object { Write-Host ("  zone port {0}  client {1}:{2}  pid {3}" -f $_.LocalPort, $_.RemoteAddress, $_.RemotePort, $_.OwningProcess) }
        throw 'more than one client is on a zone: give -RemotePort <client port> (or close the other client)'
    }
    $c[0]
}
function Show-ClientLinks {
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @($WmClientPort) + $ZonePorts } |
        ForEach-Object { Write-Host ("  {0,-5} {1}:{2}  ({3})" -f $_.LocalPort, $_.RemoteAddress, $_.RemotePort, $(if ($_.LocalPort -eq $WmClientPort) { 'WM' } else { 'zone' })) }
}

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class X38Tcp {
    [StructLayout(LayoutKind.Sequential)]
    public struct MIB_TCPROW { public uint State, LocalAddr, LocalPort, RemoteAddr, RemotePort; }
    [DllImport("iphlpapi.dll")] public static extern int SetTcpEntry(ref MIB_TCPROW row);
}
'@
function Reset-Conn($c) {
    function Addr([string]$s) { [BitConverter]::ToUInt32(([Net.IPAddress]::Parse($s)).GetAddressBytes(), 0) }
    function Port([int]$p) { [uint32]((($p -band 0xFF) -shl 8) -bor (($p -shr 8) -band 0xFF)) }
    $row = New-Object X38Tcp+MIB_TCPROW
    $row.State = 12                                   # MIB_TCP_STATE_DELETE_TCB: the stack drops it and sends RST
    $row.LocalAddr = Addr $c.LocalAddress; $row.LocalPort = Port $c.LocalPort
    $row.RemoteAddr = Addr $c.RemoteAddress; $row.RemotePort = Port $c.RemotePort
    $r = [X38Tcp]::SetTcpEntry([ref]$row)
    if ($r -ne 0) { throw "SetTcpEntry failed ($r; 317 = not elevated, 87 = not an IPv4 connection)" }
}

# --- zone process ------------------------------------------------------------------------------------------
function Zone-Info([int]$zpid, [int]$port) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$zpid"
    $exe = $p.ExecutablePath
    $cmd = $p.CommandLine
    $args0 = ''
    if ($cmd) { $args0 = ($cmd -replace '^\s*("[^"]*"|\S+)\s*', '') }
    $svc = Get-CimInstance Win32_Service | Where-Object { $_.ProcessId -eq $zpid } | Select-Object -First 1
    [pscustomobject]@{ Pid = $zpid; Port = $port; Exe = $exe; Dir = (Split-Path $exe); Args = $args0; Service = $svc }
}
function Find-Zone {
    $c = @(Zone-ClientConns)
    if ($c.Count -gt 1) { $null = One-ZoneConn }
    if ($c.Count -eq 1) { return Zone-Info $c[0].OwningProcess $c[0].LocalPort }
    if ($ZonePort -eq 0) { Show-Diag; throw 'no client is on a zone right now: give -ZonePort <zone client port>' }
    $l = Get-NetTCPConnection -State Listen -LocalPort $ZonePort -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $l) { throw "nothing listens on $ZonePort" }
    Zone-Info $l.OwningProcess $ZonePort
}
function Kill-Zone($z) {
    Write-Host ("{0} killing zone pid {1} ({2}, client port {3})" -f (Stamp), $z.Pid, $z.Exe, $z.Port)
    Stop-Process -Id $z.Pid -Force
    Wait-Process -Id $z.Pid -Timeout 20 -ErrorAction SilentlyContinue
    Write-Host ("{0} zone process gone" -f (Stamp))
}
function Start-Zone($z) {
    Start-Sleep -Seconds 5                            # let the WM see the link drop before the zone comes back
    if ($z.Service) {
        $s = Get-Service -Name $z.Service.Name
        if ($s.Status -ne 'Running') { Start-Service -Name $z.Service.Name }
        Write-Host ("{0} service {1} started" -f (Stamp), $z.Service.Name)
    } else {
        $sp = @{ FilePath = $z.Exe; WorkingDirectory = $z.Dir }
        if ($z.Args) { $sp.ArgumentList = $z.Args }
        Start-Process @sp
        Write-Host ("{0} started {1} {2}" -f (Stamp), $z.Exe, $z.Args)
    }
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
        $l = Get-NetTCPConnection -State Listen -LocalPort $z.Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($l) {
            $wm = Get-NetTCPConnection -State Established -OwningProcess $l.OwningProcess -RemotePort $WmZonePort -ErrorAction SilentlyContinue
            if ($wm) { Write-Host ("{0} READY: zone pid {1} listens on {2} and is linked to the WM. Log in now." -f (Stamp), $l.OwningProcess, $z.Port); return }
        }
        Start-Sleep -Seconds 2
    }
    Write-Warning 'the zone did not come back within 240 s: check its console / log, start it by hand, then run status'
}

# --- actions -----------------------------------------------------------------------------------------------
switch ($Action) {
    'prep' {
        Need-Char
        Write-Host "scenario 38, prep, character: $Char"
        Sql '38-prep.sql' @{ Char = $Char } (Join-Path $out "$Name-prep.txt")
        Snapshot 'before step 1'
    }
    'snapshot' { Need-Char; Snapshot $Label }
    'close-zone-conn' {
        $c = One-ZoneConn
        Write-Host ("{0} resetting zone connection {1}:{2} <-> {3}:{4} (zone pid {5})" -f (Stamp), $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $c.OwningProcess)
        Reset-Conn $c
        Start-Sleep -Milliseconds 500
        Write-Host ("{0} done. Client links left (the WM one should still be there):" -f (Stamp))
        Show-ClientLinks
    }
    'kill-client' {
        $p = @(Get-Process | Where-Object { $_.ProcessName -like $ClientLike })
        if (-not $p) { Write-Host "no $ClientLike process on this PC: kill it on the client PC (Task Manager -> End task, or Stop-Process -Name $ClientLike -Force)"; break }
        $p | ForEach-Object { Write-Host ("{0} killing {1} pid {2}" -f (Stamp), $_.ProcessName, $_.Id); Stop-Process -Id $_.Id -Force }
    }
    'kill-zone' {
        Need-Char
        $z = Find-Zone
        Kill-Zone $z
        Snapshot 'step 5: after the zone kill'
        Start-Zone $z
    }
    'getmoney-kill' {
        Need-Char
        $z = Find-Zone
        $cl = @(Get-Process | Where-Object { $_.ProcessName -like $ClientLike -and $_.MainWindowHandle -ne 0 })
        $text = "&getmoney $Money"
        if ($cl.Count -eq 1 -and -not $Countdown) {
            if ($DelayMs -lt 0) { $DelayMs = 300 }
            $sh = New-Object -ComObject WScript.Shell
            [void]$sh.AppActivate($cl[0].Id); Start-Sleep -Milliseconds 500
            $sh.SendKeys('{ENTER}'); Start-Sleep -Milliseconds 150
            $sh.SendKeys($text); Start-Sleep -Milliseconds 100
            $sh.SendKeys('{ENTER}')
            Write-Host ("{0} typed '{1}' into the client, kill in {2} ms" -f (Stamp), $text, $DelayMs)
        } else {
            if ($DelayMs -lt 0) { $DelayMs = 1000 }
            if ($cl.Count -gt 1) { Write-Host "$($cl.Count) clients on this PC: countdown mode" }
            Write-Host "In the client: open the chat, type '$text', do NOT press Enter yet."
            [void](Read-Host 'Press Enter here when it is typed')
            3..1 | ForEach-Object { Write-Host "  $_"; Start-Sleep -Seconds 1 }
            Write-Host ("{0}  >>> PRESS ENTER IN THE CLIENT NOW <<<   (kill in {1} ms)" -f (Stamp), $DelayMs)
        }
        Start-Sleep -Milliseconds $DelayMs
        Kill-Zone $z
        Snapshot "step 6: after &getmoney $Money and the zone kill"
        Start-Zone $z
        Write-Host "Last step done. At the end: .\38-server.ps1 collect -Dest <folder of $Name.md> -Pcap <the capture file>"
    }
    'status' {
        foreach ($port in $ZonePorts) {
            $l = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $l) { Write-Host ("zone port {0}: NOT LISTENING" -f $port); continue }
            $wm = Get-NetTCPConnection -State Established -OwningProcess $l.OwningProcess -RemotePort $WmZonePort -ErrorAction SilentlyContinue
            Write-Host ("zone port {0}: pid {1} {2}, WM link {3}" -f $port, $l.OwningProcess, (Get-Process -Id $l.OwningProcess).Path, $(if ($wm) { 'up' } else { 'DOWN' }))
        }
        Write-Host 'client links:'; Show-ClientLinks
        & sqlcmd -S $Instance -E -b -W -Q "USE World00_Character; SELECT name AS x02_object, type_desc FROM sys.objects WHERE name LIKE 'X02[_]%';"
    }
    'collect' { Collect $Dest $Pcap }
    'restore-gm' {
        & sqlcmd -S $Instance -E -b -W -Q "USE World00_Character; IF OBJECT_ID('dbo.X02_save_1') IS NULL PRINT 'no dbo.X02_save_1: nothing to restore' ELSE BEGIN UPDATE c SET nAdminLevel = s.nAdminLevel FROM tCharacter c JOIN dbo.X02_save_1 s ON s.nCharNo = c.nCharNo; SELECT c.sID, c.nAdminLevel FROM tCharacter c JOIN dbo.X02_save_1 s ON s.nCharNo = c.nCharNo; DROP TABLE dbo.X02_save_1; PRINT 'S1 restored'; END"
    }
}
