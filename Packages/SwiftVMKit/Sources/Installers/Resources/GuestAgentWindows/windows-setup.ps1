# SwiftVM's setup of a new Windows machine. Windows Setup runs it twice, as the answer file that
# SwiftVM wrote says: as SYSTEM before Windows first starts ("specialize"), and when the account first
# logs in. It writes down how far it has come, and the guest agent passes that on to the Mac.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('specialize', 'firstlogon')]
    [string]$Phase
)
$ErrorActionPreference = 'Continue'

$data = Join-Path $env:ProgramData 'SwiftVM\setup'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$log = Join-Path $data 'setup.log'

function Write-Log([string]$Text) {
    Add-Content -Path $log -Value ('{0:s} [{1}] {2}' -f (Get-Date), $Phase, $Text)
}

function Set-Status([string]$State, [string]$Step) {
    $status = @{ state = $State; name = 'Windows' }
    if ($Step) { $status.step = $Step }
    $status | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $data 'status.json') -Encoding UTF8
    Write-Log "$State $Step"
}

if ($Phase -eq 'specialize') {
    Set-Status 'running' 'Installing the guest tools'
    # The setup disc goes once setup is over. What the second phase needs is kept on the disk.
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $data -Recurse -Force
    try {
        & (Join-Path $data 'install.ps1') -Source $data *>> $log
    } catch {
        Write-Log "The guest tools couldn't be installed: $_"
    }
    # A virtual machine is suspended by the Mac, not by Windows, and its display is the window's.
    & powercfg.exe /hibernate off
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change monitor-timeout-ac 0
    Set-Status 'pending' 'Finishing setup'
    exit 0
}

# The first logon.
Set-Status 'running' 'Finishing setup'

# The Mac's network is one of its own: Windows may trust it, which lets the Mac reach SSH.
Get-NetConnectionProfile -ErrorAction SilentlyContinue | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

# SSH, which Windows brings as an optional feature from Windows Update. It takes a few minutes, and a
# machine without a way to the internet goes without.
Set-Status 'running' 'Setting up SSH'
try {
    # Whatever goes wrong here is written down, rather than passed over.
    $ErrorActionPreference = 'Stop'
    $ssh = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($ssh -and $ssh.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name $ssh.Name | Out-Null
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    # A session over SSH starts in PowerShell, as one in Terminal does.
    New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
    # The Mac's key. Administrators sign in with the keys in this one file, which only they may change.
    $keys = Join-Path $data 'authorized_keys'
    if (Test-Path $keys) {
        $authorized = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
        Copy-Item -Path $keys -Destination $authorized -Force
        # By their SIDs: Windows in another language calls the groups otherwise.
        & icacls.exe $authorized /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "The key's file couldn't be made the administrators' alone." }
    }
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
} catch {
    Write-Log "SSH couldn't be set up: $_"
} finally {
    $ErrorActionPreference = 'Continue'
}

Set-Status 'finished'
# Windows starts again, and the Mac with it: its display then follows the window, with the driver
# that was installed before.
& shutdown.exe /r /t 5 /c 'SwiftVM has finished setting up Windows.'
