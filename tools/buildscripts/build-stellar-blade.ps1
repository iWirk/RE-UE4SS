#Requires -Version 5.1
param(
    [string]$BuildDirectory = '',
    [string]$PackageDirectory = '',
    [string]$DependencySourceDirectory = '',
    [switch]$Offline,
    [switch]$IncludeDefaultMods,
    [int]$Jobs = 8,
    [ValidateSet('Debug', 'Shipping')][string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
$taskConfiguration = "Game__${Configuration}__Win64"
if (-not $BuildDirectory) { $BuildDirectory = "build/stellar-blade-$($Configuration.ToLowerInvariant())-ninja" }
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Push-Location $taskRoot
try {
    # CMake/Ninja/MSVC need the same environment for configuration and incremental builds.
    $taskVsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $taskVsRoot = & $taskVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $taskVsRoot) { throw 'Visual Studio with the x64 C++ toolchain is required.' }
    Import-Module (Join-Path $taskVsRoot 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $taskVsRoot -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    $taskCmake = Join-Path $taskVsRoot 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    if (-not (Test-Path -LiteralPath $taskCmake)) { $taskCmake = (Get-Command cmake -ErrorAction Stop).Source }
    foreach ($taskSubmodule in @('Unreal', 'patternsleuth')) {
        if (-not (Test-Path "deps/first/$taskSubmodule/CMakeLists.txt") -and
            -not (Test-Path "deps/first/$taskSubmodule/Cargo.toml")) {
            throw "Initialize the pinned submodules first: git submodule update --init --recursive ($taskSubmodule is missing)."
        }
    }
    $taskBuild = [IO.Path]::GetFullPath($BuildDirectory)
    New-Item -ItemType Directory -Force -Path $taskBuild | Out-Null
    $taskArgs = @('-S', $taskRoot, '-B', $taskBuild, '-G', 'Ninja',
        "-DCMAKE_BUILD_TYPE=$taskConfiguration", '-DUE4SS_TARGET_TYPES=Game',
        "-DUE4SS_CONFIGURATION_TYPES=$Configuration", '-DUE4SS_PROJECTS=UE4SS',
        '-DENABLE_IDE_SOURCE_VISIBILITY=OFF')
    if ($DependencySourceDirectory) {
        Get-ChildItem -LiteralPath $DependencySourceDirectory -Directory -Filter '*-src' | ForEach-Object {
            $taskName = $_.Name.Replace('-src', '').ToUpperInvariant()
            $taskArgs += "-DFETCHCONTENT_SOURCE_DIR_$taskName=$($_.FullName)"
        }
    }
    $taskPreviousOffline = $env:CARGO_NET_OFFLINE
    if ($Offline) { $env:CARGO_NET_OFFLINE = 'true' }
    try {
        Write-Host "Configuring $Configuration build. Log: $taskBuild/configure.log"
        & $taskCmake @taskArgs *> "$taskBuild/configure.log"
        if ($LASTEXITCODE) { Get-Content "$taskBuild/configure.log" -Tail 70; throw 'CMake configuration failed.' }
        Write-Host "Building UE4SS and proxy. Log: $taskBuild/build.log"
        & $taskCmake --build $taskBuild --target UE4SS proxy --parallel $Jobs *> "$taskBuild/build.log"
        if ($LASTEXITCODE) { Get-Content "$taskBuild/build.log" -Tail 70; throw "$Configuration build failed." }
    }
    finally { $env:CARGO_NET_OFFLINE = $taskPreviousOffline }

    if (-not $PackageDirectory) { $PackageDirectory = "build/packages/StellarBlade-$Configuration-" + (Get-Date -Format 'yyyyMMdd-HHmmss') }
    $taskPackage = [IO.Path]::GetFullPath($PackageDirectory)
    if (Test-Path -LiteralPath $taskPackage) { throw "Package directory already exists; choose a new directory: $taskPackage" }
    $taskBin = Join-Path $taskBuild "$taskConfiguration/bin"
    # Require symbols before creating an installable package.
    foreach ($taskFile in @('UE4SS.dll', 'UE4SS.pdb', 'dwmapi.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $taskBin $taskFile))) { throw "Build output missing: $taskFile" }
    }
    $taskRuntime = Join-Path $taskPackage 'ue4ss'
    New-Item -ItemType Directory -Path $taskRuntime -Force | Out-Null
    Copy-Item -LiteralPath "$taskBin/UE4SS.dll", "$taskBin/UE4SS.pdb" -Destination $taskRuntime
    Copy-Item -LiteralPath "$taskBin/dwmapi.dll" -Destination $taskPackage
    if (Test-Path "$taskBin/dwmapi.pdb") { Copy-Item -LiteralPath "$taskBin/dwmapi.pdb" -Destination $taskPackage }
    # An update must not overwrite the user's mod enablement/load order or scripts.
    # Include the stock Mods tree only when explicitly preparing a clean installation.
    if ($IncludeDefaultMods) {
        Copy-Item -LiteralPath 'assets/Mods' -Destination $taskRuntime -Recurse
    }
    $taskProfile = Join-Path $taskRoot 'assets/CustomGameConfigs/Stellar Blade'
    Copy-Item -LiteralPath "$taskProfile/UE4SS_Signatures" -Destination $taskRuntime -Recurse
    Copy-Item -LiteralPath "$taskProfile/VTableLayout.ini", "$taskProfile/MemberVariableLayout.ini" -Destination $taskRuntime

    # Merge game overrides into the complete current settings file, retaining its documentation.
    $taskOverrides = @{}
    $taskSection = ''
    foreach ($taskLine in Get-Content "$taskProfile/UE4SS-settings.ini") {
        if ($taskLine -match '^\[([^]]+)\]') { $taskSection = $matches[1] }
        elseif ($taskLine -match '^([^;=]+?)\s*=\s*(.*)$') { $taskOverrides["$taskSection/$($matches[1].Trim())"] = $matches[2] }
    }
    $taskSection = ''
    $taskSettings = foreach ($taskLine in Get-Content 'assets/UE4SS-settings.ini') {
        if ($taskLine -match '^\[([^]]+)\]') { $taskSection = $matches[1] }
        if ($taskLine -match '^([^;=]+?)\s*=') {
            $taskKey = $matches[1].Trim()
            $taskLookup = "$taskSection/$taskKey"
            if ($taskOverrides.ContainsKey($taskLookup)) {
                "$taskKey = $($taskOverrides[$taskLookup])"
                $taskOverrides.Remove($taskLookup)
                continue
            }
        }
        $taskLine
    }
    if ($taskOverrides.Count) { throw "Settings no longer match upstream: $($taskOverrides.Keys -join ', ')" }
    [IO.File]::WriteAllLines("$taskRuntime/UE4SS-settings.ini", $taskSettings, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath 'docs/stellar-blade.md' -Destination "$taskPackage/README.md"
    Copy-Item -LiteralPath 'LICENSE', 'UE4SS.natvis' -Destination $taskPackage
    Copy-Item -LiteralPath 'deps/first/Unreal/UEPseudo.natvis' -Destination $taskPackage
    $taskManifest = [ordered]@{
        configuration = $taskConfiguration
        includesDefaultMods = [bool]$IncludeDefaultMods
        commit = (& git rev-parse HEAD | Out-String).Trim()
        unreal = (& git -C deps/first/Unreal rev-parse HEAD | Out-String).Trim()
        patternsleuth = (& git -C deps/first/patternsleuth rev-parse HEAD | Out-String).Trim()
        changes = @(& git diff --name-only; & git ls-files --others --exclude-standard)
        dependencySourceDirectory = $DependencySourceDirectory
        dllSha256 = (Get-FileHash "$taskRuntime/UE4SS.dll" -Algorithm SHA256).Hash
        pdbSha256 = (Get-FileHash "$taskRuntime/UE4SS.pdb" -Algorithm SHA256).Hash
    }
    $taskManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$taskPackage/build-manifest.json" -Encoding UTF8
    Write-Host "Stellar Blade $Configuration package: $taskPackage"
}
finally { Pop-Location }
