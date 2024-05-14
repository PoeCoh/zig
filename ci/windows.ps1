[CmdletBinding()]
param (
    [Parameter()]
    [switch]$New,

    [ValidateSet("release", "debug")]
    [string]$Mode = $(if ($Env:MODE) { $Env:MODE } else { "release" })
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

function Assert-ExitCode {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [int]$ExitCode = $null
    )
    if ($null -eq $ExitCode -and $?) { return 0 }
    if ($null -ne $ExitCode -and $ExitCode -eq 0) { return 0 }
    exit 1
}

function Clang-Path {
    param ([string]$Path)
    $(Resolve-Path -Path $Path).Path -replace "\\", "/"
}

$Target = switch ($Env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    default { throw "Unknown architecture" }
}

$Tarball = if ($Env:TARBALL) { $Env:TARBALL } else {
    $Content = Get-Content .\.github\workflows\ci.yaml
    | Select-String -Pattern "TARBALL: ""(.+)"""
    $Content.Matches.Groups[1].Value
}

$ZigBlob = "zig+llvm+lld+clang-$Target-windows-gnu-$Tarball"
$MCPU = "baseline"

Write-Host -Object "Starting"
# if (!(Test-Path -Path "../$ZigBlob.zip")) {
    Invoke-WebRequest -Uri "https://ziglang.org/deps/$ZigBlob.zip" -OutFile "../$ZigBlob.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ZipDir = (Resolve-Path -Path "../$ZigBlob.zip/..").Path
    [System.IO.Directory]::SetCurrentDirectory($(Get-Location).Path) # dotnet and ps have seperate current directories
    Write-Host -Object "ZipDir: $ZipDir"
    Write-Host -Object $(Get-ChildItem -Path $ZipDir)
    Write-Host -Object "Target Dir: $ZipDir/$ZigBlob/"
    Remove-Item -Path $ZipDir/$ZigBlob -Recurse -Force -ErrorAction Ignore
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$ZipDir/$ZigBlob.zip", "$ZipDir/$ZigBlob/..")
# }

Write-Host -Object $(Get-ChildItem -Path ..)

$Zig = (Resolve-Path -Path "../$ZigBlob/bin/zig.exe").Path -replace '\\', '/'
$Prefix = (Resolve-Path -Path "../$ZigBlob").Path -replace '\\', '/'

git fetch --tags

if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow
}


$Build = if ($Mode -eq "new") { "build" } else { "build-$Mode" }
if (Test-Path -Path $Build) { Remove-Item -Path $Build -Recurse -Force }
New-Item -Path $Build -ItemType Directory

$ArgList = $(
    ".."
    "-GNinja"
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_STATIC=ON"
    "-DZIG_NO_LIB=ON"
    "-DCMAKE_PREFIX_PATH=""$Prefix"""
) + $(
    if ($New.IsPresent) {
        $(
            "-DCMAKE_C_COMPILER=""$Zig;cc"""
            "-DCMAKE_CXX_COMPILER=""%DEVKIT%/bin/zig.exe;c++"""
            "-DCMAKE_AR=""%DEVKIT%/bin/zig.exe"""
            "-DZIG_STATIC=ON"
            "-DZIG_USE_LLVM_CONFIG=OFF"
            "-DCMAKE_BUILD_TYPE=Release"
        )
    }
    else {
        $(
            "-DCMAKE_INSTALL_PREFIX=""stage3-$Mode"""
            "-DCMAKE_BUILD_TYPE=$Mode"
            "-DCMAKE_C_COMPILER=""$Zig;cc;-target;$Target;-mcpu=$MCPU"""
            "-DCMAKE_CXX_COMPILER=""$Zig;c++;-target;$Target;-mcpu=$MCPU"""
            "-DCMAKE_AR=""$Zig"""
            "-DZIG_TARGET_TRIPLE=""$Target"""
            "-DZIG_TARGET_MCPU=""$MCPU"""
        )
    }
)

Write-Host "Building from source..."
$Process = Start-Process -WorkingDirectory $Build -FilePath cmake -NoNewWindow -PassThru -Wait -ArgumentList $ArgList
$Process | Assert-ExitCode
$Process = Start-Process -WorkingDirectory $Build -FilePath ninja -NoNewWindow -PassThru -Wait -ArgumentList install
$Process | Assert-ExitCode

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of zig, and ultimately would just
# fill up space on the hard drive for no reason.
$Env:ZIG_GLOBAL_CACHE_DIR = "$(Get-Location)\zig-global-cache"
$Env:ZIG_LOCAL_CACHE_DIR = "$(Get-Location)\zig-local-cache"

# CMake gives a syntax error when file paths with backward slashes are used.
# Here, we use forward slashes only to work around this.
# $Process = Start-Process -FilePath cmake -NoNewWindow -PassThru -Wait -ArgumentList $ArgList
# $Process | Assert-ExitCode
# $Process = Start-Process -FilePath ninja -NoNewWindow -PassThru -Wait -ArgumentList install
# $Process | Assert-ExitCode

if ($New.IsPresent) {
    # Stop right here, we got all we need for new folks
    Write-Host "Finished building zig"
    return 0
}
<#
Write-Output "Main test suite..."
$Process = Start-Process -FilePath stage3-$MODE\bin\zig.exe -NoNewWindow -PassThru -Wait -ArgumentList $(
    "build test docs"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "--search-prefix ""$PREFIX_PATH"""
    "-Dstatic-llvm"
    "-Dskip-non-native"
    "-Denable-symlinks-windows"
)
$Process | Assert-ExitCode

# arm stopped here
if ($Target -eq "aarch64") { return 0 }

Write-Output "Build x86_64-windows-msvc behavior tests using the C backend..."
$Process = Start-Process -FilePath stage3-$MODE\bin\zig.exe -NoNewWindow -PassThru -Wait -ArgumentList $(
    "test"
    "..\test\behavior.zig"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "-ofmt=c"
    "-femit-bin=""test-x86_64-windows-msvc.c"""
    "--test-no-exec"
    "-target x86_64-windows-msvc"
    "-lc"
)
$Process | Assert-ExitCode

$Process = Start-Process -FilePath stage3-$MODE\bin\zig.exe -NoNewWindow -PassThru -Wait -ArgumentList $(
    "build-obj"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "-ofmt=c "
    "-OReleaseSmall "
    "--name compiler_rt "
    "-femit-bin=""compiler_rt-x86_64-windows-msvc.c"""
    "--dep build_options "
    "-target $Target-windows-msvc "
    "--mod root ..\lib\compiler_rt.zig "
    "--mod build_options config.zi"
)
$Process | Assert-ExitCode

<# I have not tested past this point, didn't feel like waiting two days for vs to download
Import-Module "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Assert-ExitCode

$Splat = @{
    VsInstallPath = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
    DevCmdArguments = '-arch=x64 -no_logo'
    StartInPath = Get-Location
}
Enter-VsDevShell @Splat
Assert-ExitCode

Write-Output "Build and run behavior tests with msvc..."
$Process = Start-Process -FilePath cl.exe -NoNewWindow -PassThru -Wait -ArgumentList $(
    "-I..\lib"
    "test-$Target-windows-msvc.c"
    "compiler_rt-$Target-windows-msvc.c"
    "/W3"
    "/Z7"
    "-link"
    "-nologo"
    "-debug"
    "-subsystem:console"
    "kernel32.lib"
    "ntdll.lib"
    "libcmt.lib"
)
$Process | Assert-ExitCode

$Process = Start-Process -FilePath .\test-x86_64-windows-msvc.exe -NoNewWindow -PassThru -Wait
$Process | Assert-ExitCode
#>