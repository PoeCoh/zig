[CmdletBinding(DefaultParameterSetName = "ci")]
param (

    [Parameter(ParameterSetName = "ci")]
    [switch]$CI,

    [Parameter(ParameterSetName = "build")]
    [switch]$Stage3,
    
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

if ($CI.IsPresent) {
    $Env:ZIG_GLOBAL_CACHE_DIR = "$(Get-Location)\zig-global-cache"
    $Env:ZIG_LOCAL_CACHE_DIR = "$(Get-Location)\zig-local-cache"
}

$Target = switch ($Env:PROCESSOR_ARCHITECTURE) {
    "AMD64" { "x86_64" }
    "ARM64" { "aarch64" }
    default { throw "Unknown architecture" }
}

$Tarball = if ($Env:TARBALL) { $Env:TARBALL } else {
    Get-Content .\.github\workflows\ci.yaml
    | Select-String -Pattern "TARBALL: ""(.+)"""
    | ForEach-Object -Process { $_.Matches.Groups[1].Value }
}

$ZigKit = "zig+llvm+lld+clang-$Target-windows-gnu-$Tarball"
$MCPU = "baseline"

Write-Host -Object "Wiping target directories..."
$Build = if ($CI.IsPresent) { "stage3-$Mode" } else { "stage3" }
if (Test-Path -Path $Build) { Remove-Item -Path $Build -Recurse -Force }
New-Item -Path $Build -ItemType Directory | Out-Null

if (!(Test-Path -Path "../$ZigKit.zip")) {
    Write-Host -Object "Getting Devkit..."
    Invoke-WebRequest -Uri "https://ziglang.org/deps/$ZigKit.zip" -OutFile "../$ZigKit.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ZipDir = (Resolve-Path -Path "../$ZigKit.zip/..").Path
    [System.IO.Directory]::SetCurrentDirectory($(Get-Location).Path) # dotnet and ps have separate current directories
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$ZipDir\$ZigKit.zip", "$ZipDir\$ZigKit\..")
}

$Zig = (Resolve-Path -Path "../$ZigKit/bin/zig.exe").Path -replace '\\', '/'
$Prefix = (Resolve-Path -Path "../$ZigKit").Path -replace '\\', '/'

Write-Host -Object "git fetch..."
git fetch --tags
if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow
}

$InstallPrefix = $Build
| Resolve-Path
| ForEach-Object -Process { $_.Path -replace '\\', '/' }

$ArgList = $(
    ".."
    "-GNinja"
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_STATIC=ON"
    "-DZIG_NO_LIB=ON"
    "-DCMAKE_PREFIX_PATH=""$Prefix"""
    "-DCMAKE_BUILD_TYPE=$Mode"
    "-DCMAKE_AR=""$Zig"""
    "-DCMAKE_INSTALL_PREFIX=$InstallPrefix"
    "-DCMAKE_C_COMPILER=""$Zig;cc;-target;$Target-windows-gnu;-mcpu=$MCPU"""
    "-DCMAKE_CXX_COMPILER=""$Zig;c++;-target;$Target-windows-gnu;-mcpu=$MCPU"""
)
$ArgList += if ($CI.IsPresent) {
    "-DZIG_STATIC=ON -DZIG_USE_LLVM_CONFIG=OFF" 
}
else {
    "-DZIG_TARGET_TRIPLE=""$Target-windows-gnu"" -DZIG_TARGET_MCPU=""$MCPU""" 
}

Write-Host -Object "Running cmake..."
$Process = Start-Process -WorkingDirectory $Build -FilePath cmake -NoNewWindow -PassThru -Wait -ArgumentList $ArgList
$Process | Assert-ExitCode

Write-Host -Object "Running ninja..."
$Process = Start-Process -WorkingDirectory $Build -FilePath ninja -NoNewWindow -PassThru -Wait -ArgumentList install
$Process | Assert-ExitCode

if ($Stage3.IsPresent) {
    # Stop right here, we got all we need for new folks
    Write-Host "Finished building zig"
    return 0
}

Write-Host -Object "Main test suite..."
$Process = Start-Process -FilePath "stage3-$Mode\bin\zig.exe" -NoNewWindow -PassThru -Wait -ArgumentList $(
    "build test docs"
    "--zig-lib-dir ""$(Get-Location)\lib"""
    "--search-prefix ""$Prefix"""
    "-Dstatic-llvm"
    "-Dskip-non-native"
    "-Denable-symlinks-windows"
)
$Process | Assert-ExitCode

# arm stopped here
if ($Target -eq "aarch64") { return 0 }

Write-Output "Build x86_64-windows-msvc behavior tests using the C backend..."
$Process = Start-Process -FilePath "stage3-$Mode\bin\zig.exe" -NoNewWindow -PassThru -Wait -ArgumentList $(
    "test"
    "..\test\behavior.zig"
    "--zig-lib-dir ""$(Get-Location)\lib"""
    "-ofmt=c"
    "-femit-bin=""test-x86_64-windows-msvc.c"""
    "--test-no-exec"
    "-target x86_64-windows-msvc"
    "-lc"
)
$Process | Assert-ExitCode

$Process = Start-Process -FilePath "stage3-$Mode\bin\zig.exe" -NoNewWindow -PassThru -Wait -ArgumentList $(
    "build-obj"
    "--zig-lib-dir ""$(Get-Location)\lib"""
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