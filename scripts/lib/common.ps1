# Shared helpers for the J3NSONTOP PowerShell build scripts. Dot-source it:
#   . "$PSScriptRoot\lib\common.ps1"
# Works with Windows PowerShell 5.1 and PowerShell 7+. Keep this file ASCII.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# Native commands report failure through $LASTEXITCODE; checked explicitly.
$PSNativeCommandUseErrorActionPreference = $false

$script:J3AppId = 'com.j3nsontop.multitool'
$script:J3ArtifactPrefix = 'J3NSONTOP-Multitool'
# $PSScriptRoot is this file's folder (scripts\lib) even when dot-sourced.
$script:J3RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

function Write-J3Info([string]$Message) { Write-Host "==> $Message" }

function Write-J3Warning([string]$Message) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::warning::$Message" } else { Write-Warning $Message }
}

function Stop-J3([string]$Message) {
    if ($env:GITHUB_ACTIONS) { Write-Host "::error::$Message" }
    throw $Message
}

# Runs a native command and throws if it exits with a non-zero code.
function Invoke-J3Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    Write-Host "> $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        Stop-J3 "$FilePath exited with code $LASTEXITCODE"
    }
}

# Runs a native command, capturing stdout+stderr as strings. Never throws on
# stderr output (Windows PowerShell 5.1 turns redirected stderr into errors
# when $ErrorActionPreference is 'Stop'). Returns [pscustomobject]@{ExitCode; Output}.
function Invoke-J3Capture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

# Returns @{ Full = '1.0.0+1'; Name = '1.0.0'; Build = '1'; Numeric = '1.0.0.1' }
function Get-J3Version {
    $pubspec = Join-Path $script:J3RepoRoot 'pubspec.yaml'
    $line = Get-Content -LiteralPath $pubspec | Where-Object { $_ -match '^version:' } | Select-Object -First 1
    if (-not $line) { Stop-J3 "No 'version:' line in $pubspec" }
    $value = ($line -replace '^version:\s*', '' -replace '\s*(#.*)?$', '') -replace '["'']', ''
    $m = [regex]::Match($value, '^(?<name>(?<core>\d+\.\d+\.\d+)(-[0-9A-Za-z.-]+)?)(\+(?<build>\d+))?$')
    if (-not $m.Success) { Stop-J3 "Cannot parse 'version: $value' in pubspec.yaml (expected x.y.z+n)." }
    $build = '0'
    if ($m.Groups['build'].Success) { $build = $m.Groups['build'].Value }
    return @{
        Full    = $value
        Name    = $m.Groups['name'].Value
        Build   = $build
        Numeric = "$($m.Groups['core'].Value).$build"
    }
}

# Build label shown in the app (About -> Build label, diagnostics): J3_BUILD_LABEL
# if set, "ci<run>-<sha7>" in the CI workflow, "rel<run>-<sha7>" in the Release
# workflow, else "local-<sha7>" (or "local" without git).
function Get-J3BuildLabel {
    if ($env:J3_BUILD_LABEL) { return $env:J3_BUILD_LABEL }
    if ($env:GITHUB_RUN_NUMBER -and $env:GITHUB_SHA) {
        $prefix = if ($env:GITHUB_WORKFLOW -eq 'Release') { 'rel' } else { 'ci' }
        return "$prefix$($env:GITHUB_RUN_NUMBER)-$($env:GITHUB_SHA.Substring(0, 7))"
    }
    $sha = $null
    try { $sha = (& git -C $script:J3RepoRoot rev-parse --short=7 HEAD 2>$null | Select-Object -First 1) } catch { $sha = $null }
    if ($sha -and "$sha".Trim() -match '^[0-9a-f]{7,}$') { return "local-$("$sha".Trim())" }
    return 'local'
}

function Get-J3Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-J3Utf8NoBom([string]$Path, [string]$Text) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

# Writes "<sha256>  <file name>\n" to <file>.sha256 (sha256sum -c compatible).
function Write-J3Sha256File([string]$Path) {
    $hash = Get-J3Sha256 $Path
    $name = Split-Path -Leaf $Path
    Write-J3Utf8NoBom "$Path.sha256" "$hash  $name`n"
    return $hash
}

# Regenerates <dir>\SHA256SUMS for every distributable file in <dir>.
function Update-J3Sha256Sums([string]$Directory) {
    $lines = @()
    Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { @('.apk', '.aab', '.ipa', '.zip', '.exe') -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object Name |
        ForEach-Object { $lines += "$(Get-J3Sha256 $_.FullName)  $($_.Name)" }
    $text = ''
    if ($lines.Count -gt 0) { $text = ($lines -join "`n") + "`n" }
    Write-J3Utf8NoBom (Join-Path $Directory 'SHA256SUMS') $text
}

function Format-J3Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GiB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MiB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KiB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Add-J3StepSummary([string[]]$Lines) {
    if (-not $env:GITHUB_STEP_SUMMARY) { return }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, (($Lines -join "`n") + "`n"), $encoding)
}

# Appends a Markdown artifact table. $Rows: array of @{ Path = ...; Signing = ... }
function Add-J3ArtifactSummary([string]$Title, [string]$Version, [object[]]$Rows) {
    $out = @("### $Title", '', '| Artifact | Version | Size | SHA-256 | Signing |', '| --- | --- | --- | --- | --- |')
    foreach ($row in $Rows) {
        $item = Get-Item -LiteralPath $row.Path
        $out += ('| `{0}` | {1} | {2} | `{3}` | {4} |' -f $item.Name, $Version, (Format-J3Size $item.Length), (Get-J3Sha256 $item.FullName), $row.Signing)
    }
    $out += ''
    Add-J3StepSummary $out
}

# Reads windows\flutter\generated_plugins.cmake (regenerated by every
# `flutter build windows`). Returns @{ Plugins = @(...); FfiPlugins = @(...) }.
# Each method-channel plugin builds <name>_plugin.dll next to the exe; FFI
# plugins may or may not ship a library, depending on the plugin.
function Get-J3WindowsPlugins {
    $path = Join-Path $script:J3RepoRoot 'windows\flutter\generated_plugins.cmake'
    $result = @{ Plugins = @(); FfiPlugins = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $result }
    $text = Get-Content -LiteralPath $path -Raw
    $m = [regex]::Match($text, 'list\(APPEND FLUTTER_PLUGIN_LIST(?<body>[^)]*)\)')
    if ($m.Success) { $result.Plugins = @($m.Groups['body'].Value -split '\s+' | Where-Object { $_ }) }
    $m = [regex]::Match($text, 'list\(APPEND FLUTTER_FFI_PLUGIN_LIST(?<body>[^)]*)\)')
    if ($m.Success) { $result.FfiPlugins = @($m.Groups['body'].Value -split '\s+' | Where-Object { $_ }) }
    return $result
}

# Files every Windows release bundle must contain (relative paths).
function Get-J3WindowsRequiredFiles {
    $files = @(
        'j3nsontop_multitool.exe',
        'flutter_windows.dll',
        'data\icudtl.dat',
        'data\app.so',
        'msvcp140.dll',
        'vcruntime140.dll',
        'vcruntime140_1.dll'
    )
    foreach ($plugin in (Get-J3WindowsPlugins).Plugins) { $files += "$($plugin)_plugin.dll" }
    return , $files
}

# Returns a list of problems with the bundle in $BundleDir (empty = OK).
function Test-J3WindowsBundle([string]$BundleDir) {
    $problems = @()
    foreach ($rel in (Get-J3WindowsRequiredFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $BundleDir $rel) -PathType Leaf)) { $problems += "missing file: $rel" }
    }
    $assets = Join-Path $BundleDir 'data\flutter_assets'
    if (-not (Test-Path -LiteralPath $assets -PathType Container)) {
        $problems += 'missing directory: data\flutter_assets'
    }
    elseif (-not (Get-ChildItem -LiteralPath $assets -File -Filter 'AssetManifest*' -ErrorAction SilentlyContinue)) {
        $problems += 'data\flutter_assets has no AssetManifest (assets were not bundled)'
    }
    return , $problems
}

# Directories that `dart format` should check (only those that exist).
function Get-J3FormatDirectories {
    $dirs = @()
    foreach ($d in @('lib', 'test', 'integration_test', 'tool')) {
        if (Test-Path -LiteralPath (Join-Path $script:J3RepoRoot $d) -PathType Container) { $dirs += $d }
    }
    return , $dirs
}
