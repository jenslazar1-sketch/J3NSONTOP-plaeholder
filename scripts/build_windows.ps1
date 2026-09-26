<#
.SYNOPSIS
    Builds, verifies and packages the Windows x64 release of J3NSONTOP Multitool.

.DESCRIPTION
    1. flutter build windows --release            (skip with -SkipBuild)
    2. copies the MSVC runtime DLLs (msvcp140.dll, vcruntime140.dll,
       vcruntime140_1.dll and any other VC runtime DLL a binary imports) next
       to the exe, so the app runs on a Windows without the VC++ redistributable
    3. verifies the bundle (exe, flutter_windows.dll, data\icudtl.dat,
       data\app.so, data\flutter_assets, every plugin DLL, runtime DLLs,
       version resource) and scans every DLL/EXE import with dumpbin
    4. optional Authenticode signing when WINDOWS_CERTIFICATE_PFX_BASE64 and
       WINDOWS_CERTIFICATE_PASSWORD are set (SHA-256 + RFC 3161 timestamp)
    5. dist\J3NSONTOP-Multitool-<ver>-windows-x64-portable.zip (one top folder)
    6. dist\J3NSONTOP-Multitool-<ver>-windows-x64-setup.exe  (Inno Setup 6)
    7. <file>.sha256, SHA256SUMS, windows-build-info.txt and the Authenticode
       status of the exe and the installer

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\build_windows.ps1
.EXAMPLE
    pwsh scripts/build_windows.ps1 -SkipBuild -OutDir dist
#>
[CmdletBinding()]
param(
    [string]$OutDir = '',
    [switch]$SkipBuild,
    [switch]$SkipInstaller,
    [string]$TimestampUrl = ''
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$version = Get-J3Version
$root = $script:J3RepoRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path.TrimEnd('\')
if (-not $TimestampUrl) { $TimestampUrl = $env:WINDOWS_TIMESTAMP_URL }
if (-not $TimestampUrl) { $TimestampUrl = 'http://timestamp.digicert.com' }

$exeName = 'j3nsontop_multitool.exe'
$bundle = Join-Path $root 'build\windows\x64\runner\Release'
$baseName = "$($script:J3ArtifactPrefix)-$($version.Name)-windows-x64"
$zipPath = Join-Path $OutDir "$baseName-portable.zip"
$setupBase = "$baseName-setup"
$setupPath = Join-Path $OutDir "$setupBase.exe"
$infoPath = Join-Path $OutDir 'windows-build-info.txt'
$info = New-Object System.Collections.Generic.List[string]
$info.Add("J3NSONTOP Multitool $($version.Full) - Windows x64 build")
$info.Add("Built: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")

# --- Tool discovery --------------------------------------------------------------
function Get-VsInstallPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
    $r = Invoke-J3Capture $vswhere @('-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath')
    $path = $r.Output | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    return $path
}

function Get-SortedVersionDirs([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory |
            Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
            Sort-Object { [version]$_.Name } -Descending)
}

function Get-VcRedistCrtDir([string]$VsPath) {
    if (-not $VsPath) { return $null }
    foreach ($v in (Get-SortedVersionDirs (Join-Path $VsPath 'VC\Redist\MSVC'))) {
        $x64 = Join-Path $v.FullName 'x64'
        if (-not (Test-Path -LiteralPath $x64)) { continue }
        $crt = Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.CRT' |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($crt) { return $crt.FullName }
    }
    return $null
}

function Get-Dumpbin([string]$VsPath) {
    if (-not $VsPath) { return $null }
    foreach ($v in (Get-SortedVersionDirs (Join-Path $VsPath 'VC\Tools\MSVC'))) {
        $p = Join-Path $v.FullName 'bin\Hostx64\x64\dumpbin.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    foreach ($v in (Get-SortedVersionDirs (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'))) {
        $p = Join-Path $v.FullName 'x64\signtool.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-Iscc {
    $candidates = @()
    if ($env:J3_ISCC) { $candidates += $env:J3_ISCC }
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
    $candidates += (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe') }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Path }
    return $null
}

$system32 = Join-Path $env:SystemRoot 'System32'
if (-not [Environment]::Is64BitProcess) { $system32 = Join-Path $env:SystemRoot 'Sysnative' }
$runtimePattern = '^(msvcp140(_[a-z0-9_]+)?|vcruntime140(_[a-z0-9_]+)?|concrt140|vccorlib140)\.dll$'
$runtimeRequired = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$runtimeSources = [ordered]@{}

function Copy-RuntimeDll([string]$Name, [string]$CrtDir) {
    $source = $null
    if ($CrtDir -and (Test-Path -LiteralPath (Join-Path $CrtDir $Name))) {
        $source = Join-Path $CrtDir $Name
    }
    elseif (Test-Path -LiteralPath (Join-Path $system32 $Name)) {
        $source = Join-Path $system32 $Name
        Write-J3Warning "Using $source (Visual Studio VC redist folder not found)."
    }
    if (-not $source) { Stop-J3 "MSVC runtime DLL $Name not found in the VC redist folder or $system32." }
    Copy-Item -LiteralPath $source -Destination (Join-Path $bundle $Name) -Force
    $runtimeSources[$Name] = $source
}

# Returns the DLL names a PE file imports (normal and delay-load).
function Get-PeImports([string]$Dumpbin, [string]$Path) {
    $r = Invoke-J3Capture $Dumpbin @('/nologo', '/dependents', $Path)
    if ($r.ExitCode -ne 0) { Stop-J3 "dumpbin failed for ${Path}: $($r.Output -join ' ')" }
    return @($r.Output | ForEach-Object { if ($_ -match '^\s{4}(\S+\.dll)\s*$') { $Matches[1] } })
}

$signing = $null
function Initialize-Signing {
    $b64 = $env:WINDOWS_CERTIFICATE_PFX_BASE64
    $password = $env:WINDOWS_CERTIFICATE_PASSWORD
    if (-not $b64 -and -not $password) { return $null }
    if (-not $b64 -or -not $password) {
        Stop-J3 'Code signing needs both WINDOWS_CERTIFICATE_PFX_BASE64 and WINDOWS_CERTIFICATE_PASSWORD; only one is set.'
    }
    $signtool = Find-SignTool
    if (-not $signtool) { Stop-J3 'signtool.exe not found (install the Windows 10/11 SDK).' }
    $pfxPath = Join-Path ([System.IO.Path]::GetTempPath()) ("j3-codesign-" + [guid]::NewGuid().ToString('N') + '.pfx')
    [System.IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String(($b64 -replace '\s', '')))
    $state = @{ SignTool = $signtool; PfxPath = $pfxPath; Added = @(); Thumbprint = $null; Subject = $null }
    try {
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'UserKeySet, PersistKeySet'
        $collection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
        $collection.Import($pfxPath, $password, $flags)
        $leaf = $collection | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
        if (-not $leaf) { Stop-J3 'The PFX does not contain a certificate with a private key.' }
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            [System.Security.Cryptography.X509Certificates.StoreName]::My,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try {
            foreach ($c in $collection) {
                $findType = [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint
                if ($store.Certificates.Find($findType, $c.Thumbprint, $false).Count -eq 0) {
                    $store.Add($c)
                    $state.Added += $c.Thumbprint
                }
            }
        }
        finally { $store.Close() }
        $state.Thumbprint = $leaf.Thumbprint
        $state.Subject = $leaf.Subject
        Write-J3Info "Code signing certificate: $($leaf.Subject) (expires $($leaf.NotAfter.ToString('yyyy-MM-dd')))"
    }
    catch {
        Clear-Signing $state
        throw
    }
    return $state
}

function Clear-Signing($State) {
    if (-not $State) { return }
    foreach ($thumb in $State.Added) {
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumb" -DeleteKey -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $State.PfxPath -Force -ErrorAction SilentlyContinue
}

function Invoke-Sign($State, [string[]]$Files) {
    if (-not $Files -or $Files.Count -eq 0) { return }
    $signArgs = @('sign', '/sha1', $State.Thumbprint, '/fd', 'SHA256', '/tr', $TimestampUrl, '/td', 'SHA256',
        '/d', 'J3NSONTOP Multitool') + $Files
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $r = Invoke-J3Capture $State.SignTool $signArgs
        $r.Output | Write-Host
        if ($r.ExitCode -eq 0) { return }
        Write-J3Warning "signtool failed (attempt $attempt of 3); retrying in 10 s (timestamp server?)."
        Start-Sleep -Seconds 10
    }
    Stop-J3 'signtool could not sign the files.'
}

function New-J3Zip([string]$SourceDir, [string]$ZipPath, [string]$RootName, [hashtable]$TextFiles) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $level = [System.IO.Compression.CompressionLevel]::Optimal
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $TextFiles.Keys) {
            $entry = $zip.CreateEntry("$RootName/$name", $level)
            $writer = New-Object System.IO.StreamWriter($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
            try { $writer.Write($TextFiles[$name]) } finally { $writer.Dispose() }
        }
        $base = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
        foreach ($file in (Get-ChildItem -LiteralPath $base -Recurse -File | Sort-Object FullName)) {
            $rel = $file.FullName.Substring($base.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, "$RootName/$rel", $level)
        }
    }
    finally {
        $zip.Dispose()
    }
}

Push-Location $root
try {
    # --- 1. Build ------------------------------------------------------------------
    if (-not $SkipBuild) {
        Invoke-J3Native flutter @('build', 'windows', '--release', "--dart-define=J3_BUILD_LABEL=$(Get-J3BuildLabel)")
    }
    $exePath = Join-Path $bundle $exeName
    if (-not (Test-Path -LiteralPath $exePath)) { Stop-J3 "Release build not found: $exePath" }

    # --- 2. MSVC runtime DLLs -------------------------------------------------------
    $vsPath = Get-VsInstallPath
    $crtDir = Get-VcRedistCrtDir $vsPath
    $dumpbin = Get-Dumpbin $vsPath
    Write-J3Info "Visual Studio: $vsPath"
    Write-J3Info "VC runtime source: $crtDir"
    foreach ($dll in $runtimeRequired) { Copy-RuntimeDll $dll $crtDir }

    # Scan every PE file's imports; bundle any further VC runtime DLL they need.
    $dependencyWarnings = @()
    if ($dumpbin) {
        for ($pass = 1; $pass -le 3; $pass++) {
            $added = $false
            $peFiles = @(Get-ChildItem -LiteralPath $bundle -Recurse -File | Where-Object { @('.exe', '.dll') -contains $_.Extension.ToLowerInvariant() })
            $present = @{}
            foreach ($pe in $peFiles) { $present[$pe.Name.ToLowerInvariant()] = $true }
            $dependencyWarnings = @()
            foreach ($pe in $peFiles) {
                foreach ($dep in (Get-PeImports $dumpbin $pe.FullName)) {
                    $lower = $dep.ToLowerInvariant()
                    if ($present.ContainsKey($lower)) { continue }
                    if ($lower -match $runtimePattern) {
                        Copy-RuntimeDll $lower $crtDir
                        $present[$lower] = $true
                        $added = $true
                        continue
                    }
                    if ($lower.StartsWith('api-ms-win-') -or $lower.StartsWith('ext-ms-')) { continue }
                    if (Test-Path -LiteralPath (Join-Path $system32 $dep)) { continue }
                    $dependencyWarnings += "$($pe.Name) imports $dep, which is neither bundled nor a Windows system DLL"
                }
            }
            if (-not $added) { break }
        }
        foreach ($w in $dependencyWarnings) { Write-J3Warning $w }
    }
    else {
        Write-J3Warning 'dumpbin.exe not found; copied only msvcp140/vcruntime140/vcruntime140_1 without scanning imports.'
    }

    # --- 3. Verify the bundle ----------------------------------------------------------
    $problems = Test-J3WindowsBundle $bundle
    if ($problems.Count -gt 0) { Stop-J3 ("Release bundle is incomplete: " + ($problems -join '; ')) }
    $versionInfo = (Get-Item -LiteralPath $exePath).VersionInfo
    if ($versionInfo.CompanyName -ne 'J3NSONTOP' -or $versionInfo.ProductName -ne 'J3NSONTOP Multitool') {
        Stop-J3 "Unexpected version resource: CompanyName='$($versionInfo.CompanyName)' ProductName='$($versionInfo.ProductName)'"
    }
    $plugins = Get-J3WindowsPlugins
    Write-J3Info "Bundle OK. Plugins: $($plugins.Plugins -join ', '); FFI plugins: $($plugins.FfiPlugins -join ', ')"
    $info.Add('')
    $info.Add("Version resource: FileVersion=$($versionInfo.FileVersion) ProductVersion=$($versionInfo.ProductVersion) Company=$($versionInfo.CompanyName) Product=$($versionInfo.ProductName)")
    $info.Add("Data directory (path_provider): %APPDATA%\$($versionInfo.CompanyName)\$($versionInfo.ProductName)")
    $info.Add('MSVC runtime DLLs:')
    foreach ($k in $runtimeSources.Keys) { $info.Add("  $k <- $($runtimeSources[$k])") }
    if ($dependencyWarnings.Count -gt 0) {
        $info.Add('Import warnings:')
        foreach ($w in $dependencyWarnings) { $info.Add("  $w") }
    }

    # --- 4. Optional Authenticode signing -------------------------------------------------
    $signing = Initialize-Signing
    if ($signing) {
        $toSign = @(Get-ChildItem -LiteralPath $bundle -Recurse -File |
                Where-Object { @('.exe', '.dll') -contains $_.Extension.ToLowerInvariant() } |
                Where-Object { (Get-AuthenticodeSignature -LiteralPath $_.FullName).Status -ne 'Valid' } |
                ForEach-Object { $_.FullName })
        Write-J3Info "Signing $($toSign.Count) file(s) (already-signed Microsoft runtime DLLs are kept as they are)."
        Invoke-Sign $signing $toSign
    }
    else {
        Write-J3Info 'No code signing certificate configured: binaries stay unsigned.'
    }

    $info.Add('')
    $info.Add('Bundle files:')
    Get-ChildItem -LiteralPath $bundle -Recurse -File | Sort-Object FullName | ForEach-Object {
        $info.Add(('  {0,12:N0}  {1}' -f $_.Length, $_.FullName.Substring($bundle.Length + 1)))
    }

    # --- 5. Portable ZIP ---------------------------------------------------------------------
    $exeSignature = Get-AuthenticodeSignature -LiteralPath $exePath
    $signingNote = 'NOT code-signed - Windows SmartScreen may warn; compare the SHA-256 checksum before running.'
    if ($exeSignature.Status -eq 'Valid') { $signingNote = "Authenticode-signed by $($exeSignature.SignerCertificate.Subject)." }
    $readme = @(
        "J3NSONTOP BIGGEST MULTITOOL MADE - J3NSONTOP Multitool $($version.Full)",
        'Windows 10/11 x64, portable build',
        '',
        "Run $exeName from this folder. Keep every file together: the app",
        'needs the DLLs and the data folder next to the exe. The Microsoft',
        'Visual C++ runtime DLLs are included; nothing has to be installed.',
        '',
        'Your settings and workspaces are stored in:',
        '  %APPDATA%\J3NSONTOP\J3NSONTOP Multitool',
        'To keep them somewhere else (for example next to this folder), start:',
        "  $exeName --data-dir=<folder>",
        '',
        "Code signing: $signingNote"
    ) -join "`r`n"
    Write-J3Info "Creating $zipPath"
    New-J3Zip $bundle $zipPath "$baseName" @{ 'PORTABLE-README.txt' = ($readme + "`r`n") }
    $zipHash = Write-J3Sha256File $zipPath

    # --- 6. Installer ------------------------------------------------------------------------
    $setupSignature = $null
    if (-not $SkipInstaller) {
        $iscc = Find-Iscc
        if (-not $iscc) { Stop-J3 'Inno Setup 6 (ISCC.exe) not found. Install it (winget install JRSoftware.InnoSetup) or pass -SkipInstaller.' }
        Remove-Item -LiteralPath $setupPath -Force -ErrorAction SilentlyContinue
        $isccArgs = @('/Qp', "/DAppVersion=$($version.Name)", "/DAppNumericVersion=$($version.Numeric)",
            "/DBundleDir=$bundle", "/DOutputDir=$OutDir", "/DOutputBaseFilename=$setupBase")
        if ($signing) {
            # Inno Setup replaces $q with a quote and $f with the quoted file name.
            $signCommand = '$q' + $signing.SignTool + '$q sign /sha1 ' + $signing.Thumbprint +
                ' /fd SHA256 /tr ' + $TimestampUrl + ' /td SHA256 /d $qJ3NSONTOP Multitool$q $f'
            $isccArgs += @("/Sj3sign=$signCommand", '/DSignToolName=j3sign')
        }
        $isccArgs += (Join-Path $root 'windows\installer\j3nsontop_multitool.iss')
        Invoke-J3Native $iscc $isccArgs
        if (-not (Test-Path -LiteralPath $setupPath)) { Stop-J3 "Installer not created: $setupPath" }
        $setupHash = Write-J3Sha256File $setupPath
        $setupSignature = Get-AuthenticodeSignature -LiteralPath $setupPath
    }

    # --- 7. Checksums, signature status, summary --------------------------------------------
    Update-J3Sha256Sums $OutDir
    $exeStatus = "$($exeSignature.Status)"
    $info.Add('')
    $info.Add("Authenticode ${exeName}: $exeStatus")
    if ($setupSignature) { $info.Add("Authenticode $(Split-Path -Leaf $setupPath): $($setupSignature.Status)") }
    $info.Add('')
    $info.Add('SHA-256:')
    foreach ($line in (Get-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS'))) { $info.Add("  $line") }
    Write-J3Utf8NoBom $infoPath (($info -join "`n") + "`n")

    if ($signing -and $exeStatus -ne 'Valid') { Stop-J3 "Signing was requested but the exe signature status is $exeStatus." }
    if ($signing -and $setupSignature -and "$($setupSignature.Status)" -ne 'Valid') {
        Stop-J3 "Signing was requested but the installer signature status is $($setupSignature.Status)."
    }

    function Get-SigningLabel($Signature) {
        if ("$($Signature.Status)" -eq 'Valid') { return "Authenticode-signed ($($Signature.SignerCertificate.Subject))" }
        return "not code-signed (Authenticode: $($Signature.Status))"
    }
    $rows = @(@{ Path = $zipPath; Signing = "portable; exe $(Get-SigningLabel $exeSignature)" })
    if ($setupSignature) { $rows += @{ Path = $setupPath; Signing = "installer $(Get-SigningLabel $setupSignature)" } }
    Add-J3ArtifactSummary 'Windows x64' $version.Full $rows

    Write-J3Info "Portable ZIP: $zipPath ($zipHash)"
    if ($setupSignature) { Write-J3Info "Installer:    $setupPath ($setupHash)" }
    Write-J3Info "Authenticode: exe=$exeStatus$(if ($setupSignature) { ", setup=$($setupSignature.Status)" })"
}
finally {
    Clear-Signing $signing
    Pop-Location
}
