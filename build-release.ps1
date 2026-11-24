<#
.SYNOPSIS
    Builds the ProTUN Rust core DLL (protun.dll) in Release mode for Windows x64 or ARM64
    with Git-commit build numbers and BUILD_INFO.json metadata.
.DESCRIPTION
    Compiles protun with `--features windows`, optionally regenerates UniFFI C# bindings,
    creates versioned artifacts in dist\, and deploys protun.dll directly into
    ..\proton-win-app\src\ProTun\ProtonVPN.ProTun.Generated\<arch>\.
#>
[CmdletBinding()]
param(
    [ValidateSet("x64", "arm64")]
    [string]$Platform = "x64",

    [string]$BaseVersion = "1.5.1",

    [switch]$GenerateBindings,
    [switch]$SkipCopyToWinApp
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot

$BuildNumber = 1
$GitHash = "nogit"
$GitFullHash = "unknown"
$GitBranch = "unknown"
try {
    $bn = (& git -C $RepoRoot rev-list --count HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $bn) { $BuildNumber = [int]$bn.Trim() }
    $gh = (& git -C $RepoRoot rev-parse --short=7 HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gh) { $GitHash = $gh.Trim() }
    $gf = (& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gf) { $GitFullHash = $gf.Trim() }
    $gb = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $gb) { $GitBranch = $gb.Trim() }
} catch {
    $BuildNumber = [int](Get-Date).ToUniversalTime().ToString("yyMMddHH")
}

$NumericVersion = "$BaseVersion.$BuildNumber"
$FullVersion = "$BaseVersion.$BuildNumber+g$GitHash"
$FileVersionTag = "$BaseVersion.$BuildNumber-g$GitHash"
$BuiltAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$RustTarget = if ($Platform -eq "arm64") { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
$DistDir = Join-Path $RepoRoot "dist\$Platform"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Write-Host "==> [protun] Building Release ($RustTarget | v$FullVersion)..." -ForegroundColor Cyan
cargo build --release --target $RustTarget --features windows
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

$DllPath = Join-Path $RepoRoot "target\$RustTarget\release\protun.dll"
if (-not (Test-Path $DllPath)) { throw "Expected $DllPath was not generated." }

Copy-Item $DllPath $DistDir -Force
$Hash = (Get-FileHash -Algorithm SHA256 (Join-Path $DistDir "protun.dll")).Hash.ToLowerInvariant()
"$Hash  protun.dll" | Out-File -Encoding ascii (Join-Path $DistDir "protun.dll.sha256")

$BuildInfoJson = @"
{
  "component": "protun",
  "baseVersion": "$BaseVersion",
  "buildNumber": $BuildNumber,
  "numericVersion": "$NumericVersion",
  "fullVersion": "$FullVersion",
  "gitCommit": "$GitHash",
  "gitCommitFull": "$GitFullHash",
  "gitBranch": "$GitBranch",
  "platform": "$Platform",
  "builtAtUtc": "$BuiltAtUtc"
}
"@
[System.IO.File]::WriteAllText((Join-Path $DistDir "BUILD_INFO.json"), $BuildInfoJson, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $DistDir "VERSION.txt"), "$FullVersion`n", [System.Text.UTF8Encoding]::new($false))

$ZipOut = Join-Path $RepoRoot "dist\protun-win-$Platform-v$FileVersionTag.zip"
if (Test-Path $ZipOut) { Remove-Item $ZipOut -Force }
Compress-Archive -Path "$DistDir\*" -DestinationPath $ZipOut -CompressionLevel Optimal
Write-Host "==> Packaged $ZipOut" -ForegroundColor Green

if ($GenerateBindings) {
    $Bindgen = Get-Command uniffi-bindgen-cs -ErrorAction SilentlyContinue
    if ($Bindgen) {
        Write-Host "==> Generating UniFFI C# bindings..."
        $OutCsDir = Join-Path $RepoRoot "..\proton-win-app\src\ProTun\ProtonVPN.ProTun.Generated"
        & $Bindgen.Source --library $DllPath --out-dir $OutCsDir
    } else {
        Write-Warning "uniffi-bindgen-cs not found in PATH; skipped binding regeneration."
    }
}

if (-not $SkipCopyToWinApp) {
    $WinAppTarget = Join-Path $RepoRoot "..\proton-win-app\src\ProTun\ProtonVPN.ProTun.Generated\$Platform"
    if (Test-Path $WinAppTarget) {
        Copy-Item $DllPath $WinAppTarget -Force
        Write-Host "==> Updated $WinAppTarget\protun.dll" -ForegroundColor Green
    }
}
