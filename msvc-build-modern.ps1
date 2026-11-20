# Modern MSBuild wrapper for basil00/WinDivert (Visual Studio 2019, 2022, 2026).
# Run from any working directory; outputs go to install/MSVC/{i386,amd64}.
[CmdletBinding()]
param(
    [ValidateSet('Auto', '2019', '2022', '2026')]
    [string]$VSVersion = 'Auto',
    [ValidateSet('Both', 'x86', 'x64')]
    [string]$Architecture = 'Both',
    [switch]$SkipExamples,
    [switch]$IncludeDriver,
    [string]$Toolset = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0
$repo = $PSScriptRoot

# Detect installed VS/Build Tools using the Microsoft-supported vswhere utility.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "Visual Studio Installer's vswhere.exe not found at $vswhere. Install Visual Studio with C++ and MSBuild."
}

$vsArgs = @('-latest', '-products', '*', '-requires', 'Microsoft.Component.MSBuild', '-property', 'installationPath')
$versionRange = switch ($VSVersion) {
    '2019' { '[16.0,17.0)' }
    '2022' { '[17.0,18.0)' }
    '2026' { '[18.0,19.0)' }
    default { $null }
}
if ($versionRange) { $vsArgs += @('-version', $versionRange) }
$vsPath = (& $vswhere @vsArgs | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $vsPath) {
    throw "No supported Visual Studio / Build Tools installation found (requested: $VSVersion)."
}
$vsPath = $vsPath.Trim()
$msbuild = Join-Path $vsPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild.exe not found: $msbuild"
}

# Installation version is used rather than the install directory name. VS2026
# can be installed in ...\18\Enterprise instead of ...\2026\Enterprise.
$installations = & $vswhere '-products' '*' '-format' 'json' | ConvertFrom-Json
$matching = $installations | Where-Object { $_.installationPath -eq $vsPath } | Select-Object -First 1
if (-not $matching) { throw "Cannot determine Visual Studio version for $vsPath" }
$versionText = $matching.installationVersion
$major = [int]($versionText.Split('.')[0])
if (-not $Toolset) {
    $Toolset = switch ($major) {
        16 { 'v142' }
        17 { 'v143' }
        18 { 'v145' }
        default { throw "Visual Studio major version $major is not mapped. Supply -Toolset explicitly." }
    }
}
Write-Host "Visual Studio $versionText at $vsPath"
Write-Host "MSBuild: $msbuild"
Write-Host "User-mode platform toolset: $Toolset"

function Invoke-WinDivertBuild {
    param(
        [string]$ProjectPath,
        [string]$Platform,
        [string]$OutputDirectory,
        [bool]$IsDriver,
        [string]$DriverAssemblyName
    )
    $msbuildOut = ($OutputDirectory -replace '\\', '/') + '/'
    $argsList = @(
        $ProjectPath,
        '/nologo', '/m', '/t:Build',
        '/p:Configuration=Release',
        "/p:Platform=$Platform",
        "/p:OutDir=$msbuildOut",
        '/verbosity:minimal'
    )
    if ($IsDriver) {
        # WDK supplies WindowsKernelModeDriver10.0; it is NOT v143/v145.
        $argsList += @(
            '/p:PlatformToolset=WindowsKernelModeDriver10.0',
            '/p:UseDebugLibraries=false',
            '/p:TargetVersion=Windows10',
            '/p:SignMode=Off',
            "/p:TargetName=$DriverAssemblyName"
        )
    } else {
        $argsList += "/p:PlatformToolset=$Toolset"
    }
    Write-Host "Building $ProjectPath ($Platform)" -ForegroundColor Cyan
    & $msbuild @argsList
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed ($LASTEXITCODE): $ProjectPath [$Platform]" }
}

$examples = @('flowtrack', 'netdump', 'netfilter', 'passthru',
              'socketdump', 'streamdump', 'webfilter', 'windivertctl')
$architectures = if ($Architecture -eq 'Both') { @('x86', 'x64') } else { @($Architecture) }

foreach ($arch in $architectures) {
    $platform = if ($arch -eq 'x86') { 'Win32' } else { 'x64' }
    $subdir = if ($arch -eq 'x86') { 'i386' } else { 'amd64' }
    $output = Join-Path $repo "install/MSVC/$subdir"
    New-Item -ItemType Directory -Path $output -Force | Out-Null

    # Library first: example programs link to install/MSVC/<arch>/WinDivert.lib.
    Invoke-WinDivertBuild (Join-Path $repo 'dll/windivert.vcxproj') $platform $output $false ''
    $possibleLibraries = @(
        (Join-Path $repo 'dll/WinDivert.lib'),
        (Join-Path $output 'WinDivert.lib')
    )
    $library = $possibleLibraries | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $library) { throw "WinDivert.lib not produced for $arch" }
    $targetLibrary = Join-Path $output 'WinDivert.lib'
    if ([IO.Path]::GetFullPath($library) -ne [IO.Path]::GetFullPath($targetLibrary)) {
        Copy-Item -LiteralPath $library -Destination $targetLibrary -Force
    }
    $targetDll = Join-Path $output 'WinDivert.dll'
    if (-not (Test-Path -LiteralPath $targetDll)) {
        throw "WinDivert.dll not found at $targetDll"
    }

    if (-not $SkipExamples) {
        foreach ($example in $examples) {
            Invoke-WinDivertBuild (Join-Path $repo "examples/$example/$example.vcxproj") $platform $output $false ''
        }
        Invoke-WinDivertBuild (Join-Path $repo 'test/test.vcxproj') $platform $output $false ''
    }

    if ($IncludeDriver) {
        $driverName = if ($arch -eq 'x86') { 'WinDivert32' } else { 'WinDivert64' }
        Invoke-WinDivertBuild (Join-Path $repo 'sys/windivert.vcxproj') $platform $output $true $driverName
        $expectedDriver = Join-Path $output "$driverName.sys"
        if (-not (Test-Path -LiteralPath $expectedDriver)) {
            # Show where the driver actually went if the WDK ignores OutDir or TargetName.
            $candidates = @(
                Get-ChildItem -LiteralPath $output -Filter '*.sys' -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
                Get-ChildItem -LiteralPath (Join-Path $repo 'sys') -Filter '*.sys' -File -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty FullName
            )
            $found = if ($candidates.Count -gt 0) { ($candidates | Select-Object -Unique) -join '; ' } else { '(none)' }
            throw "MSBuild returned success, but the expected driver was not found: $expectedDriver. Found .sys files: $found"
        }
        Write-Host "Driver found: $expectedDriver" -ForegroundColor Green
        Write-Warning 'This locally compiled driver is UNSIGNED; normal Windows driver-loading policy may reject it.'
    }
    Write-Host "Completed ${arch}: $output" -ForegroundColor Green
}
