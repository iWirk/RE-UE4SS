#Requires -Version 5.1
param(
    [string]$BuildDirectory = 'build/stellar-blade-debug-ninja',
    [ValidateRange(1, 100)][int]$Repeat = 3
)
$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Push-Location $taskRoot
try {
    $taskVsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $taskVsRoot = & $taskVsWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $taskVsRoot) { throw 'Visual Studio with the x64 C++ toolchain is required.' }
    Import-Module "$taskVsRoot/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
    Enter-VsDevShell -VsInstallPath $taskVsRoot -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    $taskBuild = [IO.Path]::GetFullPath($BuildDirectory)
    $taskCache = Join-Path $taskBuild 'CMakeCache.txt'
    if (-not (Test-Path -LiteralPath $taskCache)) { throw 'Configure the Stellar Blade debug build first.' }
    $taskCmake = Join-Path $taskVsRoot 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    if (-not (Test-Path -LiteralPath $taskCmake)) { $taskCmake = (Get-Command cmake -ErrorAction Stop).Source }
    & $taskCmake --build $taskBuild --target LuaMadeSimple --parallel 8
    if ($LASTEXITCODE) { throw 'LuaMadeSimple build failed' }
    $taskFmtSource = (Select-String -LiteralPath $taskCache -Pattern '^fmt_SOURCE_DIR:STATIC=(.+)$').Matches.Groups[1].Value
    if (-not $taskFmtSource) { throw 'Could not find fmt_SOURCE_DIR in CMakeCache.txt.' }
    $taskLib = Join-Path $taskBuild 'Game__Debug__Win64/lib'
    $taskOutput = Join-Path $taskBuild 'registry-test'
    New-Item -ItemType Directory -Force -Path $taskOutput | Out-Null
    $taskExe = Join-Path $taskOutput 'lua-registry-test.exe'
    $taskArgs = @('/nologo', '/std:c++20', '/EHsc', '/MD', '/Od', '/Zi', '/utf-8',
        '/DRC_LUA_MADE_SIMPLE_BUILD_STATIC', '/DRC_LUA_RAW_BUILD_STATIC', '/DRC_HELPERS_BUILD_STATIC',
        '/Ideps/first/LuaMadeSimple/include', '/Ideps/first/LuaRaw/include',
        '/Ideps/first/Helpers/include', '/Ideps/first/String/include', "/I$taskFmtSource/include",
        'tools/tests/lua_registry_concurrency.cpp', "/Fe$taskExe", "/Fo$taskOutput/lua-registry-test.obj", "/Fd$taskOutput/lua-registry-test.pdb",
        '/link', "$taskLib/LuaMadeSimple.lib", "$taskLib/LuaRaw.lib", "$taskLib/Helpers.lib", "$taskLib/fmt.lib")
    & cl @taskArgs
    if ($LASTEXITCODE) { throw 'Test build failed' }
    for ($taskRun = 1; $taskRun -le $Repeat; ++$taskRun) {
        Write-Host "Registry regression run $taskRun/$Repeat"
        & $taskExe
        if ($LASTEXITCODE) { throw 'Lua registry regression failed' }
    }
}
finally { Pop-Location }
