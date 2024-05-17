<#

.SYNOPSIS
Unifies all prior windows scripts. Unless the build process changes this should not have to be edited again.

.DESCRIPTION
This combined the previous x86_64-windows-release, x86_64-windows-debug, and aarch64-windows-release scripts. I had two goals, eliminate the requirement to edit this file every time the tarball gets updated, and enable this script to be used by new developers to easily build stage3.

The only real difference between the release and debug was the build directory, and a few flags in cmake. I also made a few changes to police leftover files between ci runs. devkit will persist until a newer one is pulled.

.PARAMETER Stage3
This switch is basically a replacement for the instructions on https://github.com/ziglang/zig/wiki/Building-Zig-on-Windows.

.PARAMETER CI
Indicates this is for a CI run. For reasons there has to be a unique parameter for each parameter set so powershell knows which one to use.

.PARAMETER Release
Using this switch will build and test release. Ommitting this switch will build and test debug

.EXAMPLE
.\ci\windows.ps1 -Stage3

Builds stage3 in the git directory

.EXAMPLE
.\ci\windows.ps1 -CI

Builds debug for CI tests

.EXAMPLE
.\ci\windows.ps1 -CI -Release

Builds release for CI tests

.INPUTS
None

.OUTPUTS
None

.LINK
https://github.com/ziglang/zig/wiki/Building-Zig-on-Windows

.NOTES
The arch env variable could be completely replaced with a switch on PROCESSOR_ARCHITECTURE, but it's not an enum and I'm not sure what all possible results there might be.

This comment block is visible in powershell using the Get-Help command, `Get-Help .\ci\windows.ps1`. or using the `-?` switch.

#>
[CmdletBinding()]
param (
    [Parameter(ParameterSetName = "stage3", Mandatory=$true)]
    [switch]$Stage3,

    [Parameter(ParameterSetName = "CI", Mandatory=$true)]
    [switch]$CI,

    [Parameter(ParameterSetName = "CI")]
    [switch]$Release

    # Debug is a built in switch that works with Write-Debug. It would only
    # have been used once so if -Release is not included it's a debug run.
)

# Will throw error if using unassigned variable
# also forces style guidelines
Set-StrictMode -Version 3.0

# This is the equiv of set -e
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

if (-not $Env:ARCH) {
    $Env:ARCH = switch ($Env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "x86_64" } # not sure how many possible items there are
        default { "aarch64" }
    }
}

if (-not $Env:TARBALL) {
    $Env:TARBALL = Get-Content .\.github\workflows\ci.yaml
    | Select-String -Pattern 'TARBALL: "(.+)"'
    | ForEach-Object -Process { $_.Matches.Groups[1].Value }
}

$Mode = if ($Stage3.IsPresent -or $Release.IsPresent) { "release" } else { "debug" }
$WorkDir = if ($Stage3.IsPresent) { "build" } else { "build-$Mode" }
$InstallDir = if ($Stage3.IsPresent) { "../stage3" } else { "stage3-$Mode" }

$TARGET = "$($Env:ARCH)-windows-gnu"
$ZIG_LLVM_CLANG_LLD_NAME = "zig+llvm+lld+clang-$TARGET-$Env:TARBALL"
$MCPU = "baseline"
$ZIG_LLVM_CLANG_LLD_URL = "https://ziglang.org/deps/$ZIG_LLVM_CLANG_LLD_NAME.zip"

$PREFIX_PATH = "$Env:USERPROFILE\zigkits\$ZIG_LLVM_CLANG_LLD_NAME"
# $PREFIX_PATH = "$($Env:USERPROFILE)\$ZIG_LLVM_CLANG_LLD_NAME"
$ZIG = "$PREFIX_PATH\bin\zig.exe" -Replace "\\", "/"
$ZIG_LIB_DIR = "$(Get-Location)\lib"

if (!(Test-Path -Path $PREFIX_PATH/..)) { New-Item -Path $PREFIX_PATH/.. -ItemType Directory | Out-Null }
if (!(Test-Path "$PREFIX_PATH")) {
    # Clean up all old kits before downloading new one
    Get-ChildItem -Path $PREFIX_PATH/.. | Remove-Item -Recurse -Force
    Write-Output "Downloading $ZIG_LLVM_CLANG_LLD_URL"
    Invoke-WebRequest -Uri "$ZIG_LLVM_CLANG_LLD_URL" -OutFile "$PREFIX_PATH.zip"

    Write-Output "Extracting..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Directory]::SetCurrentDirectory($(Get-Location).Path)
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$PREFIX_PATH.zip", "$PREFIX_PATH\..")
    Remove-Item -Path "$PREFIX_PATH.zip" -Recurse -Force
}

function Assert-Result {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName)]
        [int]$ExitCode,

        [Parameter()]
        [string]$Failure
    )
    if ($ExitCode -eq 0) { return }
    Write-Host -Object "$Failure failed with exit code $ExitCode" -ForegroundColor Red
    Exit 1
}

# Make the `zig version` number consistent.
# This will affect the `zig build` command below which uses `git describe`.
git fetch --tags

if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow # `git describe` won't work on a shallow repo
}

Write-Host -Object "Building from source..."
Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction Ignore
New-Item -Path $WorkDir -ItemType Directory | Out-Null
# Set-Location -Path "build-$Mode"

# Override the cache directories because they won't actually help other CI runs
# which will be testing alternate versions of zig, and ultimately would just
# fill up space on the hard drive for no reason.

if ($CI.IsPresent) {
    $Env:ZIG_GLOBAL_CACHE_DIR = "$(Get-Location)\$WorkDir\zig-global-cache"
    $Env:ZIG_LOCAL_CACHE_DIR = "$(Get-Location)\$WorkDir\zig-local-cache"
}

$Title = (Get-Culture -Name "en-US").TextInfo.ToTitleCase($Mode)
# CMake gives a syntax error when file paths with backward slashes are used.
# Here, we use forward slashes only to work around this.

$Splat = @{
    WorkingDirectory = $WorkDir
    PassThru         = $true
    Wait             = $true
    NoNewWindow      = $true
}
$CMake = Start-Process -FilePath cmake -ArgumentList $(
    ".."
    "-GNinja"
    "-DCMAKE_INSTALL_PREFIX=""$InstallDir"""
    "-DCMAKE_PREFIX_PATH=""$($PREFIX_PATH -Replace "\\", "/")"""
    "-DCMAKE_BUILD_TYPE=$Title"
    "-DCMAKE_C_COMPILER=""$ZIG;cc$(if (-not $Stage3.IsPresent) { ";-target;$TARGET;-mcpu=$MCPU" })"""
    "-DCMAKE_CXX_COMPILER=""$ZIG;c++$(if (-not $Stage3.IsPresent) { ";-target;$TARGET;-mcpu=$MCPU" })"""
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_STATIC=ON"
    "-DZIG_NO_LIB=ON"
    "-DCMAKE_AR=""$ZIG"""
    $(if (-not $Stage3.IsPresent) { "-DZIG_TARGET_TRIPLE=""$TARGET""" })
    $(if (-not $Stage3.IsPresent) { "-DZIG_TARGET_MCPU=""$MCPU""" })
) @Splat
$CMake | Assert-Result -Failure "cmake"

$Ninja = Start-Process -FilePath ninja -ArgumentList install @Splat
$Ninja | Assert-Result -Failure "ninja"

if ($Stage3.IsPresent) {
    Write-Host -Object "Zig stage3 built"
    Exit 0
}

Write-Host -Object "Main test suite..."
$MainTest = Start-Process -FilePath "stage3-$Mode/bin/zig.exe" -ArgumentList $(
    "build test docs"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "--search-prefix ""$PREFIX_PATH"""
    "-Dstatic-llvm"
    "-Dskip-non-native"
    "-Denable-symlinks-windows"
    if (-not $Release.IsPresent) { "-Dskip-release" }
) @Splat
$MainTest | Assert-Result -Failure "Main Tests"

# arm stopped here
if ($Env:ARCH -eq "aarch64") { exit 0 }

Write-Output "Build x86_64-windows-msvc behavior tests using the C backend..."
$CTest = Start-Process -FilePath "stage3-$Mode/bin/zig.exe" -ArgumentList $(
    "test"
    "..\test\behavior.zig"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "-ofmt=c"
    "-femit-bin=""test-x86_64-windows-msvc.c"""
    "--test-no-exec"
    "-target x86_64-windows-msvc"
    "-lc"
) @Splat
$CTest | Assert-Result -Failure "Testing C backend"

$BuildObj = Start-Process -FilePath "stage3-$Mode/bin/zig.exe" -ArgumentList $(
    "build-obj"
    "--zig-lib-dir ""$ZIG_LIB_DIR"""
    "-ofmt=c"
    "-OReleaseSmall"
    "--name compiler_rt"
    "-femit-bin=""compiler_rt-x86_64-windows-msvc.c"""
    "--dep build_options"
    "-target x86_64-windows-msvc"
    "--mod root ..\lib\compiler_rt.zig"
    "--mod build_options config.zig"
) @Splat
$BuildObj | Assert-Result -Failure "build-obj"

# Haven't tested below this because I don't feel like waiting hours for this to download again
Import-Module "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
Assert-Result -ExitCode $? -Failure "Import DevShell"

$VsSplat = @{
    VsInstallPath   = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
    DevCmdArguments = "-arch=x64 -no_logo"
    StartInPath     = "$((Get-Location).Path)\$WorkDir"
}
Enter-VsDevShell @VsSplat
Assert-Result -ExitCode $? -Failure "BuildTools"

Write-Host "Build and run behavior tests with msvc..."
$Cl = Start-Process -FilePath cl.exe -ArgumentList $(
    "-I..\lib"
    "test-x86_64-windows-msvc.c"
    "compiler_rt-x86_64-windows-msvc.c"
    "/W3"
    "/Z7"
    "-link"
    "-nologo"
    "-debug"
    "-subsystem:console"
    "kernel32.lib"
    "ntdll.lib"
    "libcmt.lib"
) @Splat
$Cl | Assert-Result -Failure "cl"

$LastTest = Start-Process -FilePath ./test-x86_64-windows-msvc.exe @Splat
$LastTest | Assert-Result -Failure "test-x86_64-windows-msvc"
