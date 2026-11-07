#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'debug',
    [switch]$SkipPubGet,
    # Compile llama.cpp's Vulkan backend into the plugin (Phase 2c). Needs the
    # Vulkan SDK; the app still falls back to the CPU when no Vulkan device is
    # present.
    [switch]$Vulkan,
    # Zip the runner output (exe, DLLs, data/) as
    # build\windows\privatelm-<version>-windows-x64.zip.
    [switch]$Package
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Find-Flutter {
    $command = Get-Command flutter -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $localProperties = Join-Path $root 'android\local.properties'
    if (Test-Path $localProperties) {
        $line = Get-Content $localProperties |
            Where-Object { $_ -match '^flutter\.sdk=' } |
            Select-Object -First 1
        if ($line) {
            $sdk = $line.Substring('flutter.sdk='.Length) -replace '\\\\', '\'
            $candidate = Join-Path $sdk 'bin\flutter.bat'
            if (Test-Path $candidate) { return $candidate }
        }
    }

    $candidates = @(
        'C:\src\flutter\flutter\bin\flutter.bat',
        'C:\flutter\bin\flutter.bat',
        (Join-Path $env:LOCALAPPDATA 'flutter\bin\flutter.bat'),
        (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    throw 'Flutter was not found. Add flutter to PATH or set flutter.sdk in android/local.properties.'
}

$flutter = Find-Flutter
Write-Host "Flutter: $flutter"

$devModeKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
$devMode = (Get-ItemProperty -Path $devModeKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($devMode -ne 1) {
    Write-Warning 'Developer Mode is off. Flutter builds Windows plugins with symlinks; enable it with: start ms-settings:developers'
}

$longPaths = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($longPaths -ne 1) {
    Write-Warning 'Long path support is off. MSBuild fails with MSB3491 on the plugin build tree. Enable it from an elevated shell: Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -Value 1 -Type DWord'
}

if (-not (Get-Command nuget -ErrorAction SilentlyContinue)) {
    Write-Warning 'nuget is not on PATH. flutter_inappwebview_windows needs it; see docs/windows-build.md.'
}

if (-not $SkipPubGet) {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

if ($Vulkan) {
    $env:PRIVATELM_WINDOWS_VULKAN = '1'
    if (-not $env:VULKAN_SDK) {
        Write-Warning 'Vulkan SDK not found in VULKAN_SDK; the build will try C:\Program Files\VulkanSDK\*'
    }
    Write-Host 'Vulkan backend: enabled (runtime falls back to CPU without a Vulkan device)'
}

& $flutter build windows "--$Mode"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# The output directory uses the Visual Studio configuration name, not the
# lowercase flutter flag.
$configName = switch ($Mode) {
    'debug'   { 'Debug' }
    'profile' { 'Profile' }
    'release' { 'Release' }
}
$exe = Join-Path $root "build\windows\x64\runner\$configName\privatelm.exe"
Write-Host "Built: $exe"

if ($Package) {
    if ($Mode -ne 'release') {
        Write-Warning "Packaging a $Mode build. Use -Mode release for a release zip."
    }
    $versionLine = Select-String -Path (Join-Path $root 'pubspec.yaml') `
        -Pattern '^version:\s*(\S+)' | Select-Object -First 1
    if (-not $versionLine) { throw 'Could not read version from pubspec.yaml' }
    $version = $versionLine.Matches[0].Groups[1].Value
    $safeVersion = $version -replace '[^0-9A-Za-z._-]', '-'
    $outDir = Split-Path -Parent $exe
    $zip = Join-Path $root "build\windows\privatelm-$safeVersion-windows-x64.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zip `
        -CompressionLevel Optimal
    Write-Host "Packaged: $zip"
}
