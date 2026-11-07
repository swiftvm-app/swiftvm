# OpenGL for Windows machines with SwiftVM's 3D driver. The driver brings Direct3D, not OpenGL: OpenGL
# comes from Microsoft's OpenCL, OpenGL and Vulkan Compatibility Pack, from the Microsoft Store, which
# draws it with Direct3D 12. That has Direct3D 12 to draw with when the Mac runs the machine's Direct3D
# on D3DMetal; otherwise Windows draws it in software.
#
# Without arguments, installs the pack for whoever runs this, if they don't have it yet. The Store
# installs for an account, not for SYSTEM.
# -Register, as an administrator: does so again whenever someone signs in, which covers an account that
# was offline the first time, and the guest tools that the agent installs as SYSTEM.
param([switch]$Register)
$ErrorActionPreference = 'Stop'

$storeId = '9NQPSL29BFFF'
$package = 'Microsoft.D3DMappingLayers'

if ($Register) {
    $program = Join-Path $env:ProgramFiles 'SwiftVM'
    New-Item -ItemType Directory -Force -Path $program | Out-Null
    $script = Join-Path $program 'opengl.ps1'
    if ($PSCommandPath -ne $script) {
        Copy-Item -Force -LiteralPath $PSCommandPath -Destination $script
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '"')
    # Everyone in Users, by its SID: Windows in another language names the group otherwise.
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -Force -TaskName 'SwiftVM OpenGL' -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn) `
        -Principal $principal -Settings $settings | Out-Null
    return
}

if (Get-AppxPackage -Name $package -ErrorAction SilentlyContinue) { return }

$logs = Join-Path $env:LOCALAPPDATA 'SwiftVM'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$log = Join-Path $logs 'opengl.log'
function Write-Log([string]$Text) {
    Add-Content -Path $log -Value ('{0:s} {1}' -f (Get-Date), $Text)
}

# winget comes with App Installer, which a new account may not have registered yet.
function Find-Winget {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) { return $winget.Source }
    Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction SilentlyContinue
    $path = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (Test-Path $path) { return $path }
        Start-Sleep -Seconds 2
    }
    return $null
}

try {
    $winget = Find-Winget
    if (-not $winget) { throw 'winget is not available.' }
    $output = & $winget install --id $storeId --source msstore --exact --silent --disable-interactivity `
        --accept-package-agreements --accept-source-agreements 2>&1
    # Its last line says how it went; the ones before draw its progress.
    $said = ($output | ForEach-Object { ("$_" -split "`r")[-1].Trim() } | Where-Object { $_ } | Select-Object -Last 1)
    Write-Log "winget ended with $LASTEXITCODE`: $said"
    if (-not (Get-AppxPackage -Name $package -ErrorAction SilentlyContinue)) {
        throw 'The Microsoft Store did not install the OpenCL, OpenGL and Vulkan Compatibility Pack.'
    }
    Write-Log 'The OpenCL, OpenGL and Vulkan Compatibility Pack is installed.'
} catch {
    Write-Log "OpenGL couldn't be set up: $_"
    throw
}
