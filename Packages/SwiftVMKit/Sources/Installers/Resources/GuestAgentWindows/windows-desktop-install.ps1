# Called by the guest tools installer under its installation lock. The archive is pinned and checked
# before any program from it runs. A failed download leaves the previous installation in place.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$version = '1.0.2'
$directory = Join-Path $env:ProgramFiles 'SwiftVM'
$installed = Join-Path $directory 'agent-desktop'
$architecture = $env:PROCESSOR_ARCHITEW6432
if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
switch ($architecture) {
    'ARM64' { $target = 'aarch64-pc-windows-msvc'; $digest = 'a0ecd6e17e60a0bcfbb45533a72f2d3a7a73508769588273ef08b0477d2b9687' }
    'AMD64' { $target = 'x86_64-pc-windows-msvc'; $digest = '2186c76e7df197c0e67365e45d36d869f74714c56bb8a73817e2a66f3e18e222' }
    default { throw 'agent-desktop has no native release for this architecture.' }
}
$receipt = Join-Path $installed '.swiftvm-version'
$executable = Join-Path $installed 'agent-desktop.exe'
if ((Test-Path $receipt) -and (Test-Path $executable) -and (Get-Content -Raw $receipt).Trim() -eq $version) {
    & $executable --version | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
}
$work = Join-Path $directory ('.agent-desktop-' + [Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $archive = Join-Path $work 'archive.tar.gz'
    $url = "https://github.com/vercel-labs/agent-desktop/releases/download/v$version/agent-desktop-v$version-$target.tar.gz"
    & curl.exe --fail --location --silent --show-error --connect-timeout 10 --max-time 60 $url -o $archive
    if ($LASTEXITCODE -ne 0) { throw 'agent-desktop could not be downloaded. Check the guest network and reinstall Guest Tools.' }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant() -ne $digest) {
        throw 'agent-desktop download failed its SHA-256 check.'
    }
    $staged = Join-Path $work 'new'
    New-Item -ItemType Directory -Path $staged | Out-Null
    & tar.exe -xzf $archive -C $staged
    if ($LASTEXITCODE -ne 0) { throw 'agent-desktop could not be unpacked.' }
    # The native release links to the VC runtime, which a new Windows installation does not include.
    if (-not (Test-Path (Join-Path $env:WINDIR 'System32\vcruntime140.dll'))) {
        $runtimeArchitecture = if ($architecture -eq 'ARM64') { 'arm64' } else { 'x64' }
        $runtime = Join-Path $work 'vc_redist.exe'
        & curl.exe --fail --location --silent --show-error --connect-timeout 10 --max-time 30 "https://aka.ms/vc14/vc_redist.$runtimeArchitecture.exe" -o $runtime
        if ($LASTEXITCODE -ne 0) { throw 'The Visual C++ runtime could not be downloaded. Reinstall Guest Tools when the guest is online.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $runtime
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw 'The Visual C++ runtime download has no valid Microsoft signature.'
        }
        $process = Start-Process -FilePath $runtime -ArgumentList '/install', '/quiet', '/norestart' -PassThru
        try {
            if (-not $process.WaitForExit(30000)) { throw 'The Visual C++ runtime installation is still running. Wait for it to finish, then reinstall Guest Tools.' }
            if ($process.ExitCode -notin 0,3010) { throw "The Visual C++ runtime could not be installed (exit $($process.ExitCode))." }
        } finally {
            $process.Dispose()
        }
    }
    & (Join-Path $staged 'agent-desktop.exe') --version
    if ($LASTEXITCODE -ne 0) { throw "agent-desktop does not run on this Windows (exit $LASTEXITCODE). Check the Visual C++ runtime and application control settings in the guest." }
    Set-Content -LiteralPath (Join-Path $staged '.swiftvm-version') -Value $version -Encoding ASCII
    $previous = Join-Path $work 'previous'
    if (Test-Path $installed) { Move-Item -LiteralPath $installed -Destination $previous }
    try {
        Move-Item -LiteralPath $staged -Destination $installed
    } catch {
        if (Test-Path $previous) { Move-Item -LiteralPath $previous -Destination $installed }
        throw
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
