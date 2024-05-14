<#
    This was created with two goals in mind:
        
        1: Design it so it never has to be changed between builds, unless the
        build process itself changes.

        2: Use this as a springboard for new people to build from source. I had
        a script to automate the process that was very similar and noticed with
        a few changes this could just about replace the instructions on the
        getting started page.

    Added environment variables to the ci workflow so changes should be
    transparent, except for the build id. There is a placeholder for it, but
    I'll leave it up to someone else for determining how to plug that it.
        - thoughts from a few hours later:
            can latest build number be stored in an endpoint somewhere? then
            users can have a reliable place to look up the build and provide a
            place for the script to look it up.

    For new people coming in, the majority of the getting started page can be
    replaced with instructions to install cmake and ninja - which both have
    managers or installers now - and instructions on how to execute powershell
    scripts. For those people I'll leave these for convenience:

        https://cmake.org/download/
            - yes you want to add it to path

        PS > winget install Ninja-build.Ninja

        PS > .\ci\windows.ps1 -Mode new -Target x86_64 -Build "whatever_current_is"
            - windows will probably say a bunch of scary things if you haven't
            done this before. It's fine, as always don't run things you don't
            trust.
#>
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

trap {
    # This will catch any terminating error
    if ($ZipFile -and (Test-Path -Path $Env:TEMP\$ZipFile)) {
        Remove-Item -Path $Env:TEMP\$ZipFile -Recurse -Force
    }
}

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

$ZIG_LLVM_CLANG_LLD_NAME = "zig+llvm+lld+clang-$Target-windows-gnu-$Build"
$MCPU = "baseline"
$ZIG_LLVM_CLANG_LLD_URL = "https://ziglang.org/deps/$ZIG_LLVM_CLANG_LLD_NAME.zip"
$PREFIX_PATH = "$($Env:USERPROFILE)\$ZIG_LLVM_CLANG_LLD_NAME"
$ZIG = "$PREFIX_PATH\bin\zig.exe" -replace '\\', '/'


$ZigLlvmLldClang = "zig+llvm+lld+clang-$Target-windows-gnu-$Build"
$ZipFile = "$ZigLlvmLldClang.zip"
$Url = "https://ziglang.org/deps/$ZipFile"


$LibDir = "$(Get-Location)\lib"
Write-Host -Object "LIB DIR $LIBDIR"


if (!(Test-Path -Path "$Env:TEMP\$ZigLlvmLldClang.zip")) {
    Invoke-WebRequest -Uri $Url | Expand-Archive -DestinationPath $Env:TEMP\$ZigLlvmLldClang
}

git fetch --tags

if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow
}

$BuildDirectory = if ($Mode -eq "new") { "build" } else { "build-$Mode" }
Remove-Item -Path $BUildDirectory -Recurse -Force
New-Item -Path $Directory -ItemType Directory

$LocalCache = "$Env:Temp\zig-local-cache"
$GlobalCache = "$Env:TEMP\zig-global-cache"

$ArgList = if ($Mode -eq "new") {$(
    ".."
    "-GNinja"
    "-DCMAKE_PREFIX_PATH=""$Env:TEMP/$ZigLlvmLldClang"""
    "-DCMAKE_C_COMPILER=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe;cc"""
    "-DCMAKE_CXX_COMPILER=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe;c++"""
    "-DCMAKE_AR=""$Env:TEMP/$ZigLlvmLldClang/bin/zig.exe"""
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_STATIC=ON"
    "-DZIG_USE_LLVM_CONFIG=OFF"
)} else {$(
    '..'
    '-GNinja'
    "-DCMAKE_INSTALL_PREFIX=""stage3-$Mode"""
    "-DCMAKE_PREFIX_PATH=""$($Env:TEMP/$ZigLlvmLldClang -Replace '\\', '/')"""
    "-DCMAKE_BUILD_TYPE=$Mode"
    "-DCMAKE_C_COMPILER=""$ZIG;cc;-target;$TARGET-windows-gnu;-mcpu=$MCPU"""
    "-DCMAKE_CXX_COMPILER=""$ZIG;c++;-target;$TARGET-windows-gnu;-mcpu=$MCPU"""
    "-DCMAKE_AR=""$ZIG"""
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_TARGET_TRIPLE=""$TARGET"""
    "-DZIG_TARGET_MCPU=""$MCPU"""
    "-DZIG_STATIC=ON"
    "-DZIG_NO_LIB=O"
)}

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