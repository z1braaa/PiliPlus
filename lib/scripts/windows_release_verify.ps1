$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) { throw 'Windows release verification requires Windows' }
if ($env:version -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\+[1-9]\d{0,4}$') { throw 'Invalid release filename version' }
if ($env:NATIVE_BUILD_NAME -notmatch '^\d+\.\d+\.\d+$' -or $env:NATIVE_BUILD_NUMBER -notmatch '^[1-9]\d{0,4}$') { throw 'Native version environment missing' }

$source = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $source -ne $env:GITHUB_SHA) { throw 'Source SHA differs from workflow SHA' }
$bundle = [IO.Path]::GetFullPath('build/windows/x64/runner/Release')
$reportPath = "PiliPlus_windows_$($env:version)_x64_build-report.json"
$checksumPath = "PiliPlus_windows_$($env:version)_x64_SHA256SUMS.txt"
$verificationDirectory = 'PiliPlus-Windows-Verification'
New-Item -ItemType Directory -Path $verificationDirectory -Force | Out-Null
$report = [ordered]@{
    schema_version = 1
    platform = 'windows-x64'
    source_sha = $source
    build_name = $env:NATIVE_BUILD_NAME
    build_number = [int]$env:NATIVE_BUILD_NUMBER
    display_name = $env:RELEASE_DISPLAY_NAME
    fastforge_version = '0.6.12'
    fastforge_version_source = 'https://pub.dev/api/packages/fastforge'
    runner_os = $env:RUNNER_OS
    runner_environment = $env:RUNNER_ENVIRONMENT
    status = 'running'
    metadata_verified = $false
    bundle_verified = $false
    payload_files = @()
    artifacts = @()
    isolated_install = [ordered]@{ status = 'not_run'; reason = ''; payload_hashes_match = $false; uninstall_verified = $false }
    application_launch = 'not_run_no_account_or_playback_test'
}

function Assert-X64PE([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Missing DOS executable header: $Path" }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) { throw "Invalid PE header offset: $Path" }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Expected x64 PE executable: $Path" }
    }
    finally { $stream.Dispose() }
}

function Assert-X64Aot([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 20 -and $bytes[0] -eq 0x7F -and $bytes[1] -eq 0x45 -and $bytes[2] -eq 0x4C -and $bytes[3] -eq 0x46) {
        if ($bytes[4] -ne 2 -or $bytes[5] -ne 1 -or [BitConverter]::ToUInt16($bytes, 18) -ne 62) { throw 'Expected 64-bit little-endian x86_64 ELF AOT' }
        $report.aot_format = 'elf64-x86_64'
    }
    else {
        Assert-X64PE $Path
        $report.aot_format = 'pe-x64'
    }
    # Check the compiled constants, rather than trusting the adjacent JSON.
    $compiledStrings = [Text.Encoding]::ASCII.GetString($bytes)
    if (-not $compiledStrings.Contains($source) -or -not $compiledStrings.Contains($env:RELEASE_DISPLAY_NAME)) { throw 'Compiled AOT source SHA or display label missing' }
    $report.compiled_source_sha_present = $true
    $report.compiled_display_name_present = $true
}

function Invoke-BoundedInstaller([string]$Path, [string[]]$Arguments) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit(180000)) {
        $process.Kill($true)
        $process.WaitForExit()
        throw 'Installer or uninstaller exceeded three minute limit'
    }
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Installer or uninstaller exited with code $($process.ExitCode)" }
    return $process.ExitCode
}

function Get-ExistingInstallationKeys {
    $appId = '5ef970f9-2b9e-4155-b7d6-a9d4dbd6b226'
    foreach ($root in @('HKCU:', 'HKLM:')) {
        foreach ($uninstallPath in @('Software\Microsoft\Windows\CurrentVersion\Uninstall', 'Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
            foreach ($key in @("${appId}_is1", "{$appId}_is1")) {
                $path = "$root\$uninstallPath\$key"
                if (Test-Path -LiteralPath $path) { $path }
            }
        }
    }
}

$installDirectory = $null
$uninstalled = $false
try {
    $metadata = Get-Content 'pili_release.json' -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata['pili.hash'] -ne $source -or [int]$metadata['pili.code'] -ne [int]$env:NATIVE_BUILD_NUMBER -or $metadata['pili.name'] -ne $env:RELEASE_DISPLAY_NAME -or [long]$metadata['pili.time'] -le 0) { throw 'Dart release metadata mismatch' }
    $pubspecVersion = "version: $($env:NATIVE_BUILD_NAME)+$($env:NATIVE_BUILD_NUMBER)"
    if (@(Get-Content 'pubspec.yaml' | Where-Object { $_ -ceq $pubspecVersion }).Count -ne 1) { throw 'pubspec native version mismatch' }
    $report.metadata_verified = $true
    $report.release_metadata = $metadata

    $requiredCrtFiles = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
    $requiredFiles = @('piliplus.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'libmpv-2.dll') + $requiredCrtFiles
    foreach ($relative in $requiredFiles) {
        $path = Join-Path $bundle $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -le 0) { throw "Required bundle file missing or empty: $relative" }
    }
    if (@(Get-ChildItem (Join-Path $bundle 'data/flutter_assets') -File -Recurse).Count -eq 0) { throw 'Flutter assets missing' }
    # CMake INSTALL records every plugin and native asset actually installed by Flutter.
    $installManifest = 'build/windows/x64/install_manifest.txt'
    if (-not (Test-Path -LiteralPath $installManifest -PathType Leaf)) { throw 'CMake install manifest missing' }
    $manifestFiles = @(Get-Content $installManifest | Where-Object { $_.Trim() -ne '' })
    if ($manifestFiles.Count -eq 0) { throw 'CMake install manifest empty' }
    foreach ($file in $manifestFiles) {
        $fullPath = [IO.Path]::GetFullPath($file)
        if (-not $fullPath.StartsWith($bundle + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw 'CMake manifest entry missing or outside bundle' }
    }
    $manifestFullPaths = @($manifestFiles | ForEach-Object { [IO.Path]::GetFullPath($_) })
    foreach ($requiredCrt in $requiredCrtFiles) {
        if ($manifestFullPaths -notcontains (Join-Path $bundle $requiredCrt)) { throw "Required CRT DLL missing from CMake installation manifest: $requiredCrt" }
    }
    foreach ($peFile in @(Get-ChildItem $bundle -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') })) {
        Assert-X64PE $peFile.FullName
    }
    Assert-X64Aot (Join-Path $bundle 'data/app.so')
    $report.native_dll_files = @(Get-ChildItem $bundle -Recurse -File -Filter '*.dll' | ForEach-Object { [IO.Path]::GetRelativePath($bundle, $_.FullName).Replace('\', '/') } | Sort-Object)
    $report.msvc_runtime = [ordered]@{
        deployment = 'app-local'
        discovery = 'CMake InstallRequiredSystemLibraries from compiler redistributable directory'
        documentation = @('https://cmake.org/cmake/help/latest/module/InstallRequiredSystemLibraries.html', 'https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows', 'https://learn.microsoft.com/en-us/cpp/windows/deployment-in-visual-cpp')
        required_files = $requiredCrtFiles
        files = @(Get-ChildItem $bundle -File -Filter '*.dll' | Where-Object { $_.Name -match '^(msvcp|vcruntime|concrt)\d+.*\.dll$' } | Sort-Object Name | ForEach-Object {
            $dllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName)
            $dllSignature = Get-AuthenticodeSignature -FilePath $_.FullName
            [ordered]@{
                name = $_.Name
                size = $_.Length
                sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                file_version = $dllVersion.FileVersion
                product_version = $dllVersion.ProductVersion
                company = $dllVersion.CompanyName
                authenticode_status = [string]$dllSignature.Status
                cmake_manifest_entry = $manifestFullPaths -contains $_.FullName
            }
        })
    }
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $bundle 'piliplus.exe'))
    $actualVersion = @($versionInfo.FileMajorPart, $versionInfo.FileMinorPart, $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart) -join '.'
    $expectedVersion = "$($env:NATIVE_BUILD_NAME).$($env:NATIVE_BUILD_NUMBER)"
    if ($actualVersion -ne $expectedVersion) { throw "Native executable version mismatch: $actualVersion" }
    $report.native_file_version = $actualVersion
    $report.cmake_manifest_files = $manifestFiles.Count
    $report.payload_files = @(Get-ChildItem $bundle -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        [ordered]@{ path = [IO.Path]::GetRelativePath($bundle, $_.FullName).Replace('\', '/'); size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $report.bundle_verified = $true

    $installers = @(Get-ChildItem 'dist' -Recurse -File -Filter '*.exe')
    if ($installers.Count -ne 1) { throw "Expected exactly one installer, found $($installers.Count)" }
    $installerDirectory = 'PiliPlus-Win-Setup'
    New-Item -ItemType Directory -Path $installerDirectory -Force | Out-Null
    $installerPath = Join-Path $installerDirectory "PiliPlus_windows_$($env:version)_x64_setup.exe"
    Copy-Item -LiteralPath $installers[0].FullName -Destination $installerPath
    $portableRoot = 'Release/PiliPlus-Win'
    New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
    Get-ChildItem $bundle -Force | Copy-Item -Destination $portableRoot -Recurse
    $portablePath = "PiliPlus_windows_$($env:version)_x64_portable.zip"
    Compress-Archive -Path $portableRoot -DestinationPath $portablePath
    foreach ($path in @($installerPath, $portablePath)) {
        $file = Get-Item -LiteralPath $path
        if ($file.Length -le 0) { throw 'Empty release artifact' }
        $report.artifacts += [ordered]@{ name = $file.Name; size = $file.Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $report.installer_authenticode = [string](Get-AuthenticodeSignature -FilePath $installerPath).Status
    $report.artifacts | ForEach-Object { "$($_.sha256)  $($_.name)" } | Set-Content $checksumPath -Encoding ascii

    # This installer writes protocol/uninstall registrations and requires admin.
    # Only run it on a fresh disposable GitHub-hosted Windows runner.
    $isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
        $report.isolated_install.reason = 'not_run_requires_disposable_github_hosted_runner'
    }
    elseif (-not $isAdmin) {
        $report.isolated_install.reason = 'not_run_admin_required_by_existing_installer'
    }
    elseif (@(Get-ExistingInstallationKeys).Count -ne 0 -or (Test-Path 'HKCU:\Software\Classes\bilibili') -or @(Get-Process -Name 'piliplus' -ErrorAction SilentlyContinue).Count -ne 0) {
        $report.isolated_install.reason = 'not_run_existing_application_or_protocol_registration'
    }
    else {
        if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'Runner temporary directory missing' }
        $installDirectory = Join-Path $env:RUNNER_TEMP ('PiliPlus-Install-Acceptance-' + [Guid]::NewGuid().ToString('N'))
        $installLog = [IO.Path]::GetFullPath((Join-Path $verificationDirectory 'install.log'))
        $uninstallLog = [IO.Path]::GetFullPath((Join-Path $verificationDirectory 'uninstall.log'))
        $report.isolated_install.status = 'running'
        $report.isolated_install.install_exit_code = Invoke-BoundedInstaller ([IO.Path]::GetFullPath($installerPath)) @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SP-', '/NORESTART', '/NOCLOSEAPPLICATIONS', '/NORESTARTAPPLICATIONS', '/NOICONS', '/TASKS=""', "/DIR=`"$installDirectory`"", "/LOG=`"$installLog`"")
        foreach ($payloadFile in $report.payload_files) {
            $installedFile = Join-Path $installDirectory $payloadFile.path
            if (-not (Test-Path -LiteralPath $installedFile -PathType Leaf) -or (Get-FileHash -LiteralPath $installedFile -Algorithm SHA256).Hash.ToLowerInvariant() -ne $payloadFile.sha256) { throw "Installed payload mismatch: $($payloadFile.path)" }
        }
        $report.isolated_install.payload_hashes_match = $true
        $uninstallers = @(Get-ChildItem $installDirectory -File -Filter 'unins*.exe')
        if ($uninstallers.Count -ne 1) { throw 'Expected one isolated uninstaller' }
        $report.isolated_install.uninstall_exit_code = Invoke-BoundedInstaller $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$uninstallLog`"")
        $uninstalled = $true
        if ((Test-Path (Join-Path $installDirectory 'piliplus.exe')) -or @(Get-ExistingInstallationKeys).Count -ne 0 -or (Test-Path 'HKCU:\Software\Classes\bilibili')) { throw 'Isolated uninstall left application or registration' }
        $report.isolated_install.uninstall_verified = $true
        $report.isolated_install.status = 'passed'
    }
    $report.status = 'passed'
}
catch {
    $report.status = 'failed'
    $report.error = $_.Exception.Message
    if ($report.isolated_install.status -eq 'running') { $report.isolated_install.status = 'failed' }
    throw
}
finally {
    if ($null -ne $installDirectory -and -not $uninstalled -and (Test-Path -LiteralPath $installDirectory)) {
        try {
            $uninstallers = @(Get-ChildItem $installDirectory -File -Filter 'unins*.exe')
            if ($uninstallers.Count -eq 1) {
                $cleanupLog = [IO.Path]::GetFullPath((Join-Path $verificationDirectory 'cleanup-uninstall.log'))
                $report.isolated_install.cleanup_uninstall_exit_code = Invoke-BoundedInstaller $uninstallers[0].FullName @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$cleanupLog`"")
            }
        }
        catch { $report.isolated_install.cleanup_error = $_.Exception.Message }
    }
    $report.finished_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 12 | Set-Content $reportPath -Encoding utf8NoBOM
}
