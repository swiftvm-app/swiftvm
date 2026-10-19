# Task Scheduler owns the installer so replacing the agent cannot end it halfway through.
$ErrorActionPreference = 'Stop'
$d = Join-Path $env:ProgramFiles 'SwiftVM\Reinstall-@@token@@'
# Program Files keeps other accounts from replacing the staged installer before SYSTEM runs it.
New-Item -ItemType Directory -Path $d | Out-Null
$disc = $null
for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $disc = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.VolumeName -eq 'SWIFTVM' } | Select-Object -First 1
    if ($disc) { break }
    Start-Sleep -Milliseconds 200
}
if (-not $disc) { throw 'The guest tools disc did not appear.' }
$source = $disc.DeviceID + '\'
foreach ($file in 'install.ps1', 'swiftvm-agent.cs') {
    Copy-Item -LiteralPath (Join-Path $source $file) -Destination $d
}
if (Test-Path -LiteralPath (Join-Path $source 'graphics-driver.zip')) {
    Copy-Item -LiteralPath (Join-Path $source 'graphics-driver.zip') -Destination $d
}
@'
$ErrorActionPreference = 'Stop'
$d = $PSScriptRoot
$lock = $null
try {
    # The handle also excludes an installer whose host has stopped waiting for it.
    $lock = [IO.File]::Open((Join-Path $env:ProgramFiles 'SwiftVM\reinstall.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    & (Join-Path $d 'install.ps1') -Source $d *> (Join-Path $d 'install.log')
    'ok' | Set-Content -LiteralPath (Join-Path $d 'status.new')
} catch {
    ('failed: ' + $_.Exception.Message) | Set-Content -LiteralPath (Join-Path $d 'status.new')
} finally {
    if ($lock) { $lock.Dispose() }
}
Move-Item -LiteralPath (Join-Path $d 'status.new') -Destination (Join-Path $d 'status')
'@ | Set-Content -LiteralPath (Join-Path $d 'run.ps1')
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $d + '\run.ps1"')
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 150)
Register-ScheduledTask -TaskName 'SwiftVM-Reinstall-@@token@@' -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest | Out-Null
Start-ScheduledTask -TaskName 'SwiftVM-Reinstall-@@token@@'
