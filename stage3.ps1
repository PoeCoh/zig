Set-StrictMode -Version 3.0
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

git fetch --tags
if ((git rev-parse --is-shallow-repository) -eq "true") {
    git fetch --unshallow
}

$CiScript = Get-Content -Path .\ci\x86_64-windows-release.ps1

$Tarball = $CiScript
| Select-String -Pattern '\$ZIG_LLVM_CLANG_LLD_NAME = "(.+)"'
| ForEach-Object { $_.Matches.Groups[1].Value -replace '\$TARGET', 'x86_64-windows-gnu' }

$Uri = $CiScript
| Select-String -Pattern '\$ZIG_LLVM_CLANG_LLD_URL = "(.+)"'
| ForEach-Object { $_.Matches.Groups[1].Value -replace '\$ZIG_LLVM_CLANG_LLD_NAME', $Tarball }

if (-not (Test-Path -Path devkits)) { New-Item -Path devkits -ItemType Directory | Out-Null }

if (-not (Test-Path -Path "./devkits/$Tarball")) {
    Invoke-WebRequest -Uri $Uri -OutFile "./devkits/$Tarball.zip"
    Expand-Archive -Path "./devkits/$Tarball.zip" -DestinationPath "./devkits/$Tarball/.."
    Remove-Item -Path "./devkits/$Tarball.zip" -Recurse -Force
}
$Devkit = (Resolve-Path -Path "./devkits/$Tarball").Path

if (Test-Path -Path stage3) { Remove-Item -Path stage3 -Recurse -Force }
if (Test-Path -Path build) { Remove-Item -Path build -Recurse -Force }
New-Item -Path build -ItemType Directory | Out-Null

$Process = Start-Process -FilePath cmake -ArgumentList $(
    '.. -GNinja'
    "-DCMAKE_PREFIX_PATH=""$Devkit"""
    "-DCMAKE_C_COMPILER=""$Devkit/bin/zig.exe;cc"""
    "-DCMAKE_CXX_COMPILER=""$Devkit/bin/zig.exe;c++"""
    "-DCMAKE_AR=""$Devkit/bin/zig.exe"""
    "-DZIG_AR_WORKAROUND=ON"
    "-DZIG_STATIC=ON"
    "-DZIG_USE_LLVM_CONFIG=OFF"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DZIG_NO_LIB=ON"
    "-DCMAKE_INSTALL_PREFIX=""../stage3"""
) -PassThru -NoNewWindow -Wait -WorkingDirectory build
if ($Process.ExitCode -ne 0) { throw "cmake failed with exit code $($Process.ExitCode)" }

$Process = Start-Process -FilePath ninja -ArgumentList install -PassThru -NoNewWindow -Wait -WorkingDirectory build
if ($Process.ExitCode -ne 0) { throw "ninja failed with exit code $($Process.ExitCode)" }
