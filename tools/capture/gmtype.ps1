<#
.SYNOPSIS
  Types chat lines (GM & commands) into the running Fiesta client, one after another.

.EXAMPLE
  .\gmtype.ps1 -File .\21\21-setup.txt
  .\gmtype.ps1 -Command '&makeitem LeatherBoots' -Repeat 100
  .\gmtype.ps1 -File .\21\21-setup.txt -DryRun

  Lines starting with # and empty lines are skipped; text after " #" is a comment.
  A line "!sleep <s>" waits <s> seconds (e.g. after &linkto, while the map loads).
  Each line is sent as: Enter (open chat), the text, Enter (send).
  Run it from a PowerShell with the same rights as the client (an elevated client ignores input from a
  non-elevated shell). If the client window cannot be found, click into it during the countdown.
  Two clients on one PC: -Client 1 / -Client 2 picks the client by start order (1 = started first);
  -List prints the running clients. -ProcessId <pid> picks one directly.
#>
param(
    [string]$File,
    [string]$Command,
    [int]$Repeat = 1,
    [int]$DelayMs = 700,
    [int]$StartDelay = 3,
    [string]$ProcessLike = 'Fiesta*',
    [int]$Client = 0,
    [int]$ProcessId = 0,
    [switch]$List,
    [switch]$NoOpenChat,
    [switch]$DryRun
)

$clients = @(Get-Process | Where-Object { $_.ProcessName -like $ProcessLike -and $_.MainWindowHandle -ne 0 } | Sort-Object StartTime)
if ($List) {
    $i = 0; foreach ($c in $clients) { $i++; Write-Host ("client {0}: {1} pid {2} started {3:HH:mm:ss}" -f $i, $c.ProcessName, $c.Id, $c.StartTime) }
    if (-not $clients) { Write-Host 'no client window found' }
    exit 0
}

$lines = @()
if ($File)    { $lines += Get-Content -LiteralPath $File -Encoding UTF8 }
if ($Command) { $lines += @($Command) * $Repeat }
$lines = $lines | ForEach-Object { ($_ -replace '\s+#.*$', '').Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
if (-not $lines) { Write-Error 'nothing to type (give -File or -Command)'; exit 1 }

if ($DryRun) { $lines; exit 0 }

$sh = New-Object -ComObject WScript.Shell
if ($ProcessId) { $proc = Get-Process -Id $ProcessId -ErrorAction Stop }
elseif ($Client) {
    if ($Client -gt $clients.Count) { Write-Error "client $Client not running ($($clients.Count) found; -List shows them)"; exit 1 }
    $proc = $clients[$Client - 1]
}
else {
    if ($clients.Count -gt 1) { Write-Warning "$($clients.Count) clients running: typing into the first started; use -Client <n>" }
    $proc = $clients | Select-Object -First 1
}
if ($proc) { [void]$sh.AppActivate($proc.Id); Write-Host "client: $($proc.ProcessName) pid $($proc.Id)" }
else { Write-Host 'client window not found: click into the game window now' }
for ($i = $StartDelay; $i -gt 0; $i--) { Write-Host "  $i"; Start-Sleep -Seconds 1 }

# SendKeys special characters must be wrapped in braces
function Esc([string]$s) { ($s.ToCharArray() | ForEach-Object { if ('+^%~(){}[]'.Contains($_)) { "{$_}" } else { "$_" } }) -join '' }

$n = 0
foreach ($l in $lines) {
    $n++
    if ($l -match '^!sleep\s+(\d+)$') { Write-Host "[$n/$($lines.Count)] waiting $($Matches[1]) s"; Start-Sleep -Seconds $Matches[1]; continue }
    Write-Host ("[{0}/{1}] {2:HH:mm:ss} {3}" -f $n, $lines.Count, (Get-Date), $l)
    if (-not $NoOpenChat) { $sh.SendKeys('{ENTER}'); Start-Sleep -Milliseconds 150 }
    $sh.SendKeys((Esc $l)); Start-Sleep -Milliseconds 100
    $sh.SendKeys('{ENTER}')
    Start-Sleep -Milliseconds $DelayMs
}
