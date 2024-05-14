[CmdletBinding()]
param (
    [ValidateSet("release", "debug", "new")]
    [string]$Mode = $Env:MODE, # I couldnt think of a better term for it.
    
    [ValidateSet("x86_64", "x86", "aarch64")]
    [string]$Target = $Env:ARCH,
    
    [ValidateScript(
        {
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw "Build version cannot be null, empty, or whitespace"
            }
            return $true
        }
    )]
    [string]$Build = $Env:BUILD
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

$MCPU = "baseline"

Write-Host -Object "Starting"
$ZigLlvmLldClang = "zig+llvm+lld+clang-$Target-windows-gnu-$Build"
$DevKit = "$Env:TEMP\$ZigLlvmLldClang"
$Zig = "$DevKit/binzig.exe" -replace '\\', '/'
if (!(Test-Path -Path "$DevKit.zip")) {
    Invoke-WebRequest -Uri "https://ziglang.org/deps/$ZigLlvmLldClang.zip" -OutFile "$DevKit.zip"
    Expand-Archive -Path "$DevKit.zip" -DestinationPath $DevKit
}

git fetch --tags

if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow
}

Write-Host -Object "Build Dir"
$BuildDirectory = if ($Mode -eq "new") { "build" } else { "build-$Mode" }
if (Test-Path -Path $BuildDirectory) {
    Remove-Item -Path $BuildDirectory -Recurse -Force
}
New-Item -Path $BuildDirectory -ItemType Directory

Write-Host -Object "Args"
$ArgList = if ($Mode -eq "new") {$(
    ".."
    # "-GNinja"
    # "-DCMAKE_PREFIX_PATH=""$Env:TEMP/$ZigLlvmLldClang"""
    # "-DCMAKE_C_COMPILER=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe;cc"""
    # "-DCMAKE_CXX_COMPILER=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe;c++"""
    # "-DCMAKE_AR=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe"""
    # "-DZIG_AR_WORKAROUND=ON"
    # "-DZIG_STATIC=ON"
    # "-DZIG_USE_LLVM_CONFIG=OFF"
)} else {$(
    '..'
    # '-GNinja'
    # "-DCMAKE_INSTALL_PREFIX=""stage3-$Mode"""
    # "-DCMAKE_PREFIX_PATH=""$($Env:TEMP/$ZigLlvmLldClang -Replace '\\', '/')"""
    # "-DCMAKE_BUILD_TYPE=$Mode"
    # "-DCMAKE_C_COMPILER=""$ZIG;cc;-target;$TARGET-windows-gnu;-mcpu=$MCPU"""
    # "-DCMAKE_CXX_COMPILER=""$ZIG;c++;-target;$TARGET-windows-gnu;-mcpu=$MCPU"""
    # "-DCMAKE_AR=""$ZIG"""
    # "-DZIG_AR_WORKAROUND=ON"
    # "-DZIG_TARGET_TRIPLE=""$TARGET"""
    # "-DZIG_TARGET_MCPU=""$MCPU"""
    # "-DZIG_STATIC=ON"
    # "-DZIG_NO_LIB=O"
)}
Write-Host -Object "Args done"

Write-Output "Building from source..."
$Process = Start-Process -WorkingDirectory $BuildDirectory -FilePath cmake -NoNewWindow -PassThru -Wait -ArgumentList $ArgList
$Process | Assert-ExitCode
$Process = Start-Process -WorkingDirectory $BuildDirectory -FilePath ninja -NoNewWindow -PassThru -Wait -ArgumentList install
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

if ($Mode -eq "new") {
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