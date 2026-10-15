# Installs SwiftVM's guest tools in Windows, or replaces older ones: the drivers for the machine's
# devices, and the guest agent. Run as an administrator. On the guest tools disc, install.cmd asks for
# that; a new machine's setup runs this as SYSTEM.
#
# The agent is built here, from its source next to this script, by the C# compiler that comes with
# Windows. The drivers are on the virtio-win disc, which SwiftVM plugs in next to this one.
param([string]$Source = $PSScriptRoot)
$ErrorActionPreference = 'Stop'

$program = Join-Path $env:ProgramFiles 'SwiftVM'
$executable = Join-Path $program 'swiftvm-agent.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

# The drivers. Windows on ARM has none of its own for these devices: the network card, the agent's
# serial line, the display that follows the window, and the rest.
$virtio = Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path $_.Root 'NetKVM\w11\ARM64\netkvm.inf') } | Select-Object -First 1
if ($virtio) {
    foreach ($driver in 'NetKVM', 'vioserial', 'viogpudo', 'viorng', 'vioinput', 'viostor', 'vioscsi', 'pvpanic') {
        $folder = Join-Path $virtio.Root "$driver\w11\ARM64"
        if (Test-Path $folder) {
            & pnputil.exe /add-driver (Join-Path $folder '*.inf') /install | Out-Null
        }
    }
} else {
    Write-Warning 'The virtio-win disc is not plugged in, so no drivers were installed.'
}

if (-not (Test-Path $compiler)) {
    throw 'This Windows has no .NET Framework 4 compiler, which the guest agent is built with.'
}
New-Item -ItemType Directory -Force -Path $program | Out-Null
# Built in the program's own folder, so that it has that folder's permissions: everyone may run it,
# which its half in each session needs. A file moved from SYSTEM's temporary folder keeps that one's.
$built = Join-Path $program "swiftvm-agent-$PID.exe"
$output = & $compiler /nologo /target:winexe /optimize+ "/out:$built" `
    /r:System.ServiceProcess.dll /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll /r:System.Core.dll `
    (Join-Path $Source 'swiftvm-agent.cs') 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "The guest agent couldn't be built: $output"
}

# An older agent goes first: its service, and its halves in the sessions of whoever is logged in.
$service = Get-Service -Name SwiftVMAgent -ErrorAction SilentlyContinue
if ($service) {
    Stop-Service -Name SwiftVMAgent -Force -ErrorAction SilentlyContinue
}
Get-Process -Name swiftvm-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Move-Item -Force -Path $built -Destination $executable
& icacls.exe $executable /reset | Out-Null

if (-not $service) {
    New-Service -Name SwiftVMAgent -BinaryPathName "`"$executable`"" -DisplayName 'SwiftVM Guest Agent' `
        -Description 'Lets SwiftVM on the Mac set the clock, shut Windows down, share the clipboard and run commands.' `
        -StartupType Automatic | Out-Null
}
# A service that fails is started again, a little later each time.
& sc.exe failure SwiftVMAgent reset= 60 actions= restart/2000/restart/5000/restart/10000 | Out-Null
Start-Service -Name SwiftVMAgent

# The Mac's shared folders come over WebDAV, whose client takes files of 50 MB at most unless told
# otherwise.
$webClient = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebClient\Parameters'
if (Test-Path $webClient) {
    Set-ItemProperty -Path $webClient -Name FileSizeLimitInBytes -Value 0xFFFFFFFF -Type DWord
}

# The service starts the agent's half in the session of whoever is logged in, and of whoever logs in
# later.
Write-Output 'The SwiftVM guest tools are installed.'
