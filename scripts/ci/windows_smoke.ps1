<#
.SYNOPSIS
    Smoke-tests the packaged Windows build WITHOUT Flutter or Visual Studio.

.DESCRIPTION
    Uses only the downloaded artifacts:
      1. verifies the SHA-256 files of the portable ZIP and the setup EXE
      2. extracts the ZIP into a path with spaces and non-ASCII characters and
         checks that every expected file is present
      3. runs the exe with --smoke-test=<report> --data-dir=<non-ASCII dir>,
         waits (with timeout) and requires exit code 0 and "ok": true
      4. starts the app normally, checks it stays alive, shows the expected
         window title and loads the bundled MSVC runtime DLLs, then closes it
      5. installs the setup EXE silently into a non-ASCII path, checks files,
         Start menu shortcut and uninstall entry, runs the installed exe's
         smoke test, uninstalls silently and verifies everything is removed
      6. records the Authenticode status of the exe and the installer

.EXAMPLE
    pwsh scripts/ci/windows_smoke.ps1 -ArtifactsDir artifacts -OutDir smoke-out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactsDir,
    [string]$OutDir = 'windows-smoke',
    [int]$TimeoutSeconds = 120
)

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$exeName = 'j3nsontop_multitool.exe'
$appName = 'J3NSONTOP Multitool'
$uninstallKeyName = '{FFBDD466-85D3-4DD4-8AFD-4D7140A91A95}_is1'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$results = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$Check, [string]$Result) {
    $results.Add([pscustomobject]@{ Check = $Check; Result = $Result })
    Write-J3Info "$Check -> $Result"
}

function Write-SmokeSummary([string]$Title) {
    $lines = @("### $Title", '', '| Check | Result |', '| --- | --- |')
    foreach ($r in $results) { $lines += "| $($r.Check) | $($r.Result) |" }
    $lines += ''
    Add-J3StepSummary $lines
}

function Find-Artifact([string]$Pattern) {
    $found = @(Get-ChildItem -LiteralPath $ArtifactsDir -Recurse -File -Filter $Pattern)
    if ($found.Count -ne 1) { Stop-J3 "Expected exactly one '$Pattern' in $ArtifactsDir, found $($found.Count)." }
    return $found[0].FullName
}

function Test-Checksum([string]$Path) {
    $shaFile = "$Path.sha256"
    if (-not (Test-Path -LiteralPath $shaFile)) { Stop-J3 "Checksum file missing: $shaFile" }
    $expected = ((Get-Content -LiteralPath $shaFile -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = Get-J3Sha256 $Path
    if ($expected -ne $actual) { Stop-J3 "SHA-256 mismatch for ${Path}: expected $expected, got $actual" }
    return $actual
}

function Start-J3Process([string]$Exe, [string[]]$ArgumentList, [string]$WorkingDirectory = '') {
    if (-not $WorkingDirectory) { $WorkingDirectory = Split-Path -Parent $Exe }
    # Start-Process joins the arguments with spaces; values are quoted by the callers.
    $p = Start-Process -FilePath $Exe -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -PassThru
    # Touching Handle keeps the process handle open, so ExitCode stays readable.
    $null = $p.Handle
    return $p
}

# Runs the app's packaged self test and returns a short description.
function Invoke-SmokeRun([string]$Label, [string]$Exe, [string]$Report, [string]$DataDir) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Report) | Out-Null
    Remove-Item -LiteralPath $Report -Force -ErrorAction SilentlyContinue
    $argList = @("--smoke-test=`"$Report`"", "--data-dir=`"$DataDir`"")
    Write-J3Info "[$Label] $Exe $($argList -join ' ')"
    $p = Start-J3Process $Exe $argList
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Stop-J3 "[$Label] smoke test did not finish within $TimeoutSeconds s."
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    if (-not (Test-Path -LiteralPath $Report)) {
        Stop-J3 "[$Label] no smoke report was written (exit code $code): $Report"
    }
    $raw = Get-Content -LiteralPath $Report -Raw -Encoding UTF8
    Write-Host "----- [$Label] smoke report -----"
    Write-Host $raw
    Write-Host '---------------------------------'
    Copy-Item -LiteralPath $Report -Destination (Join-Path $OutDir "smoke-report-$Label.json") -Force
    try { $json = $raw | ConvertFrom-Json } catch { Stop-J3 "[$Label] smoke report is not valid JSON: $_" }
    $okProp = $json.PSObject.Properties['ok']
    $okValue = '<missing>'
    if ($null -ne $okProp) { $okValue = $okProp.Value }
    $ok = ($okValue -is [bool]) -and $okValue
    $stepCount = 0
    $stepsProp = $json.PSObject.Properties['steps']
    if ($null -ne $stepsProp -and $null -ne $stepsProp.Value) { $stepCount = @($stepsProp.Value).Count }
    if ($code -ne 0 -or -not $ok) {
        Stop-J3 "[$Label] smoke test FAILED (exit code $code, ok=$okValue)."
    }
    return "OK (exit 0, ok=true, $stepCount steps)"
}

# Starts the app normally and checks it keeps running with the right window.
function Test-NormalLaunch([string]$Exe, [string]$DataDir) {
    $bundleDir = Split-Path -Parent $Exe
    $p = Start-J3Process $Exe @("--data-dir=`"$DataDir`"", '--skip-intro')
    Start-Sleep -Seconds 15
    if ($p.HasExited) { Stop-J3 "App exited during normal start (exit code $($p.ExitCode))." }
    $p.Refresh()
    $title = $p.MainWindowTitle
    $notes = @()
    if ($title -ne $appName) { Write-J3Warning "Main window title is '$title' (expected '$appName')." ; $notes += "title '$title'" }
    else { $notes += "title '$title'" }
    $modules = @()
    try { $modules = @((Get-Process -Id $p.Id).Modules) } catch { Write-J3Warning "Could not list modules: $_" }
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $m = $modules | Where-Object { $_.ModuleName -ieq $dll } | Select-Object -First 1
        if (-not $m) { $notes += "$dll not loaded"; continue }
        $dir = Split-Path -Parent $m.FileName
        if ($dir -ieq $bundleDir) { $notes += "$dll from app folder" }
        else {
            Write-J3Warning "$dll was loaded from $dir instead of the app folder."
            $notes += "$dll from $dir"
        }
    }
    $null = $p.CloseMainWindow()
    if (-not $p.WaitForExit(15000)) {
        Write-J3Warning 'App did not close after WM_CLOSE within 15 s; terminating it.'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        $notes += 'had to be terminated'
    }
    return "alive after 15 s; " + ($notes -join ', ')
}

function Get-UninstallKeys {
    $keys = @()
    foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
        $k = Join-Path $hive $uninstallKeyName
        if (Test-Path -LiteralPath $k) { $keys += $k }
    }
    return , $keys
}

function Get-StartMenuShortcuts {
    $found = @()
    foreach ($folder in @([Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Programs'))) {
        if (-not $folder) { continue }
        $lnk = Join-Path $folder "$appName.lnk"
        if (Test-Path -LiteralPath $lnk) { $found += $lnk }
    }
    return , $found
}

$exitError = $null
try {
    # --- 1. Artifacts and checksums ------------------------------------------------------
    $zip = Find-Artifact '*-windows-x64-portable.zip'
    $setup = Find-Artifact '*-windows-x64-setup.exe'
    $null = Test-Checksum $zip
    $null = Test-Checksum $setup
    Add-Result 'SHA-256 of portable ZIP and setup EXE' 'OK (match .sha256 files)'

    # A path with spaces, Latin-1 and CJK characters (built from code points so
    # this file stays ASCII): J3NS<U+00D8>NT<U+00D8>P T<U+00EB>st <U+6D4B><U+8BD5>.
    $unicodeName = 'J3NS' + [char]0x00D8 + 'NT' + [char]0x00D8 + 'P T' + [char]0x00EB + 'st ' + [char]0x6D4B + [char]0x8BD5
    $tempRoot = $env:RUNNER_TEMP
    if (-not $tempRoot) { $tempRoot = [System.IO.Path]::GetTempPath() }
    $base = Join-Path $tempRoot $unicodeName
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Write-J3Info "Test root: $base"

    # --- 2. Portable ZIP -------------------------------------------------------------------
    $portableRoot = Join-Path $base 'portable'
    Expand-Archive -LiteralPath $zip -DestinationPath $portableRoot
    $top = @(Get-ChildItem -LiteralPath $portableRoot)
    if ($top.Count -ne 1 -or -not $top[0].PSIsContainer) {
        Stop-J3 "The portable ZIP must contain exactly one top-level folder; found: $(($top | ForEach-Object { $_.Name }) -join ', ')"
    }
    $portableBundle = $top[0].FullName
    $problems = Test-J3WindowsBundle $portableBundle
    if (-not (Test-Path -LiteralPath (Join-Path $portableBundle 'PORTABLE-README.txt'))) { $problems += 'missing file: PORTABLE-README.txt' }
    if ($problems.Count -gt 0) { Stop-J3 ("Portable bundle is incomplete: " + ($problems -join '; ')) }
    Add-Result 'Portable ZIP layout and required files' "OK (top folder '$($top[0].Name)')"

    $portableExe = Join-Path $portableBundle $exeName
    $dataPortable = Join-Path $base ('data ' + [char]0x00E9 + 't' + [char]0x00E9 + ' portable')
    Add-Result 'Portable smoke test (non-ASCII paths)' (Invoke-SmokeRun 'portable' $portableExe (Join-Path $base 'reports\portable.json') $dataPortable)
    Add-Result 'Portable normal start' (Test-NormalLaunch $portableExe (Join-Path $base 'data normal start'))

    # --- 3. Silent install ------------------------------------------------------------------
    $installDir = Join-Path $base 'installed app'
    $installLog = Join-Path $OutDir 'install.log'
    $p = Start-J3Process $setup @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$installDir`"", "/LOG=`"$installLog`"")
    if (-not $p.WaitForExit(300000)) { Stop-Process -Id $p.Id -Force; Stop-J3 'Silent install timed out.' }
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $installLog) { Get-Content -LiteralPath $installLog | Write-Host }
        Stop-J3 "Silent install failed with exit code $($p.ExitCode)."
    }
    $problems = Test-J3WindowsBundle $installDir
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'unins000.exe'))) { $problems += 'missing uninstaller unins000.exe' }
    if ($problems.Count -gt 0) { Stop-J3 ("Installed files are incomplete: " + ($problems -join '; ')) }
    $shortcuts = Get-StartMenuShortcuts
    if ($shortcuts.Count -eq 0) { Stop-J3 "No Start menu shortcut '$appName.lnk' was created." }
    $keys = Get-UninstallKeys
    if ($keys.Count -eq 0) { Stop-J3 "No uninstall registry entry $uninstallKeyName was created." }
    Add-Result 'Silent install' "OK ($($shortcuts -join ', '))"

    $installedExe = Join-Path $installDir $exeName
    Add-Result 'Installed smoke test' (Invoke-SmokeRun 'installed' $installedExe (Join-Path $base 'reports\installed.json') (Join-Path $base 'data installed'))

    # --- 4. Silent uninstall ------------------------------------------------------------------
    $uninstallLog = Join-Path $OutDir 'uninstall.log'
    # Run it from outside the install folder so that folder can be deleted.
    $p = Start-J3Process (Join-Path $installDir 'unins000.exe') @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$uninstallLog`"") $tempRoot
    $null = $p.WaitForExit(180000)
    # The uninstaller re-launches itself from %TEMP%, so poll for the result.
    $deadline = (Get-Date).AddSeconds(180)
    do {
        Start-Sleep -Seconds 3
        $dirGone = -not (Test-Path -LiteralPath $installDir)
        $shortcutsLeft = Get-StartMenuShortcuts
        $keysLeft = Get-UninstallKeys
    } while ((Get-Date) -lt $deadline -and (-not $dirGone -or $shortcutsLeft.Count -gt 0 -or $keysLeft.Count -gt 0))
    if (-not $dirGone) {
        $left = @(Get-ChildItem -LiteralPath $installDir -Recurse -Force | ForEach-Object { $_.FullName })
        if (Test-Path -LiteralPath $uninstallLog) { Get-Content -LiteralPath $uninstallLog | Write-Host }
        Stop-J3 "Install directory still exists after uninstall: $installDir (left: $($left -join ', '))"
    }
    if ($shortcutsLeft.Count -gt 0) { Stop-J3 "Start menu shortcut still exists after uninstall: $($shortcutsLeft -join ', ')" }
    if ($keysLeft.Count -gt 0) { Stop-J3 "Uninstall registry entry still exists: $($keysLeft -join ', ')" }
    Add-Result 'Silent uninstall' 'OK (folder, Start menu shortcut and uninstall entry removed)'

    # --- 5. Authenticode ----------------------------------------------------------------------
    $exeSig = Get-AuthenticodeSignature -LiteralPath $portableExe
    $setupSig = Get-AuthenticodeSignature -LiteralPath $setup
    $expectedNote = ''
    if ("$($exeSig.Status)" -eq 'NotSigned' -and "$($setupSig.Status)" -eq 'NotSigned') {
        $expectedNote = ' - not code-signed (expected unless a certificate is configured)'
    }
    Add-Result 'Authenticode status' "exe: $($exeSig.Status); setup: $($setupSig.Status)$expectedNote"
}
catch {
    $exitError = $_
    Add-Result 'FAILED' ("$($_.Exception.Message)" -replace '\|', '/')
}
finally {
    Write-SmokeSummary 'Windows clean-machine smoke test'
}
if ($exitError) { throw $exitError }
Write-J3Info 'Windows smoke test passed.'
