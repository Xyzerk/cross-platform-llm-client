#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'debug',
    [switch]$SkipPubGet
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
