<#
.SYNOPSIS
    Builds the Android APK (and AAB for releases) and copies it to dist\.

.DESCRIPTION
    -Mode Test (default): release-mode APK signed with the Android DEBUG key.
        Installable for testing, but a TEST build: it can never be updated by a
        properly signed release. Named ...-android-test-debugsigned.apk.
    -Mode Release: APK + AAB signed with the release key from
        android\key.properties or the J3_KEYSTORE_PATH / J3_KEYSTORE_PASSWORD /
        J3_KEY_ALIAS / J3_KEY_PASSWORD environment variables. The build FAILS if
        the key is not fully configured (see docs\SIGNING.md).

    Prints `apksigner verify --print-certs`, checks the package id, version and
    ABIs, writes <file>.sha256, SHA256SUMS and android-build-info.txt.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_android.ps1 -Mode Release
#>
[CmdletBinding()]
param(
    [ValidateSet('Test', 'Release')][string]$Mode = 'Test',
    [switch]$NoAab,
    [string]$OutDir = '',
    [switch]$SkipBuild
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$version = Get-J3Version
if (-not $OutDir) { $OutDir = Join-Path $script:J3RepoRoot 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$isRelease = ($Mode -eq 'Release')
$buildAab = $isRelease -and -not $NoAab

# --- Android SDK tools --------------------------------------------------------
$sdk = $env:ANDROID_HOME
if (-not $sdk) { $sdk = $env:ANDROID_SDK_ROOT }
if (-not $sdk -and $env:LOCALAPPDATA) { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (-not $sdk -or -not (Test-Path -LiteralPath (Join-Path $sdk 'build-tools'))) {
    Stop-J3 'Android SDK not found. Install it with Android Studio or set ANDROID_HOME.'
}
$buildToolsDir = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Directory |
    Sort-Object { $n = $_.Name -replace '-.*$', ''; try { [version]$n } catch { [version]'0.0' } } |
    Select-Object -Last 1
$apksigner = Join-Path $buildToolsDir.FullName 'apksigner.bat'
$aapt2 = Join-Path $buildToolsDir.FullName 'aapt2.exe'
$zipalign = Join-Path $buildToolsDir.FullName 'zipalign.exe'
if (-not (Test-Path -LiteralPath $apksigner)) { Stop-J3 "apksigner.bat not found in $($buildToolsDir.FullName)" }
Write-J3Info "Android SDK: $sdk (build-tools $($buildToolsDir.Name))"

Push-Location $script:J3RepoRoot
try {
    # --- Build ------------------------------------------------------------------
    if (-not $SkipBuild) {
        $signingArg = '-Pj3ForceDebugSigning=true'
        if ($isRelease) { $signingArg = '-Pj3RequireReleaseSigning=true' }
        $labelDefine = "--dart-define=J3_BUILD_LABEL=$(Get-J3BuildLabel)"
        Invoke-J3Native flutter @('build', 'apk', '--release', $signingArg, $labelDefine)
        if ($buildAab) { Invoke-J3Native flutter @('build', 'appbundle', '--release', $signingArg, $labelDefine) }
    }

    $builtApk = Join-Path $script:J3RepoRoot 'build\app\outputs\flutter-apk\app-release.apk'
    $builtAab = Join-Path $script:J3RepoRoot 'build\app\outputs\bundle\release\app-release.aab'
    if (-not (Test-Path -LiteralPath $builtApk)) { Stop-J3 "APK not found: $builtApk" }

    $label = 'test-debugsigned'
    if ($isRelease) { $label = 'release' }
    $baseName = "$($script:J3ArtifactPrefix)-$($version.Name)-android-$label"
    $apk = Join-Path $OutDir "$baseName.apk"
    $aab = Join-Path $OutDir "$baseName.aab"
    $info = Join-Path $OutDir 'android-build-info.txt'
    foreach ($p in @($apk, "$apk.sha256", $aab, "$aab.sha256")) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $builtApk -Destination $apk

    # --- Verify the APK signature ------------------------------------------------
    $verify = Invoke-J3Capture $apksigner @('verify', '--verbose', '--print-certs', $apk)
    $apksignerOut = $verify.Output
    if ($verify.ExitCode -ne 0) {
        $apksignerOut | Write-Host
        Stop-J3 "apksigner could not verify $apk"
    }
    $apksignerOut | Write-Host
    $infoLines = @("J3NSONTOP Multitool $($version.Full) - Android $Mode build", "Built: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))", '', "## apksigner verify --print-certs $(Split-Path -Leaf $apk)") + $apksignerOut

    # apksigner prints "Signer #1 certificate ..." (build-tools <= 35) or
    # "V2 Signer: certificate ..." (newer build-tools); accept both.
    $signerRe = '^(Signer #1|V[0-9.]+ Signer:) certificate'
    $dnLine = $apksignerOut | Where-Object { $_ -match "$signerRe DN: " } | Select-Object -First 1
    $shaLine = $apksignerOut | Where-Object { $_ -match "$signerRe SHA-256 digest: " } | Select-Object -First 1
    if (-not $dnLine) { Stop-J3 'No signer certificate found in the APK.' }
    $signerDn = $dnLine -replace '^.* certificate DN: ', ''
    $signerSha = ''
    if ($shaLine) { $signerSha = ($shaLine -split '\s+')[-1] }
    $debugSigned = $signerDn -like '*CN=Android Debug*'

    if ($isRelease -and $debugSigned) { Stop-J3 "Release APK is signed with the Android DEBUG certificate ($signerDn)." }
    if (-not $isRelease -and -not $debugSigned) { Stop-J3 "Test APK is not debug-signed ($signerDn); refusing to mislabel it." }
    if ($debugSigned) {
        $apkSigning = 'debug-signed TEST build (Android debug key) - not for distribution'
    }
    else {
        $short = $signerSha
        if ($short.Length -gt 16) { $short = $short.Substring(0, 16) + '...' }
        $apkSigning = "release-signed ($signerDn; cert SHA-256 $short)"
    }
    Write-J3Info "Signing: $apkSigning"

    # --- Inspect the APK ---------------------------------------------------------
    if (Test-Path -LiteralPath $aapt2) {
        $dump = Invoke-J3Capture $aapt2 @('dump', 'badging', $apk)
        if ($dump.ExitCode -ne 0) { Stop-J3 "aapt2 dump badging failed: $($dump.Output -join ' ')" }
        $badging = $dump.Output
        $selected = $badging | Where-Object { $_ -match '^(package:|sdkVersion:|targetSdkVersion:|application-label:|native-code:|uses-permission:)' }
        $selected | Write-Host
        $infoLines += @('', '## aapt2 dump badging (selected lines)') + $selected
        $pkgLine = $badging | Where-Object { $_ -like 'package:*' } | Select-Object -First 1
        $nativeLine = $badging | Where-Object { $_ -like 'native-code:*' } | Select-Object -First 1
        if ($pkgLine -notmatch "name='$([regex]::Escape($script:J3AppId))'") { Stop-J3 "Unexpected package: $pkgLine" }
        if ($pkgLine -notmatch "versionCode='$($version.Build)'") { Stop-J3 "versionCode does not match pubspec ($($version.Build)): $pkgLine" }
        if ($pkgLine -notmatch "versionName='$([regex]::Escape($version.Name))'") { Stop-J3 "versionName does not match pubspec ($($version.Name)): $pkgLine" }
        foreach ($abi in @('arm64-v8a', 'armeabi-v7a', 'x86_64')) {
            if (-not $nativeLine -or $nativeLine -notmatch "'$abi'") { Stop-J3 "APK is missing native code for $abi ($nativeLine)" }
        }
    }
    else {
        Write-J3Warning "aapt2 not found in $($buildToolsDir.FullName); skipping badging checks."
    }

    if (Test-Path -LiteralPath $zipalign) {
        $align = Invoke-J3Capture $zipalign @('-c', '-P', '16', '4', $apk)
        if ($align.ExitCode -eq 0) { $infoLines += '16 KB page alignment (zipalign -c -P 16 4): OK' }
        else {
            Write-J3Warning 'zipalign -c -P 16 reports the APK is not 16 KB page aligned (required by Google Play).'
            $infoLines += '16 KB page alignment (zipalign -c -P 16 4): NOT OK'
        }
    }

    $apkHash = Write-J3Sha256File $apk
    $rows = @(@{ Path = $apk; Signing = $apkSigning })

    # --- App Bundle --------------------------------------------------------------
    if ($buildAab) {
        if (-not (Test-Path -LiteralPath $builtAab)) { Stop-J3 "AAB not found: $builtAab" }
        Copy-Item -LiteralPath $builtAab -Destination $aab
        $keytool = 'keytool'
        if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\keytool.exe'))) {
            $keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
        }
        $aabCerts = (Invoke-J3Capture $keytool @('-printcert', '-jarfile', $aab)).Output
        $infoLines += @('', "## keytool -printcert -jarfile $(Split-Path -Leaf $aab)") + $aabCerts
        $ownerLine = $aabCerts | Where-Object { $_ -like 'Owner:*' } | Select-Object -First 1
        if (-not $ownerLine) { Stop-J3 'The App Bundle is not signed.' }
        if ($ownerLine -like '*CN=Android Debug*') { Stop-J3 'The App Bundle is signed with the Android DEBUG certificate.' }
        Write-J3Sha256File $aab | Out-Null
        $rows += @{ Path = $aab; Signing = "release-signed ($($ownerLine -replace '^Owner: ', ''))" }
    }

    Update-J3Sha256Sums $OutDir
    $infoLines += @('', '## SHA-256') + (Get-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS'))
    Write-J3Utf8NoBom $info (($infoLines -join "`n") + "`n")

    Write-J3Info "Artifacts in ${OutDir}:"
    Get-ChildItem -LiteralPath $OutDir | Format-Table Name, Length -AutoSize | Out-String | Write-Host
    Write-Host "$(Split-Path -Leaf $apk) SHA-256: $apkHash"
    Add-J3ArtifactSummary "Android ($Mode)" $version.Full $rows
}
finally {
    Pop-Location
}
