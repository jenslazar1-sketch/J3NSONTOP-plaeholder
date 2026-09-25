<#
.SYNOPSIS
    Static checks and unit/widget tests - the same gate CI runs first.

.DESCRIPTION
    flutter pub get --enforce-lockfile, dart format check, flutter analyze,
    flutter test. Run from any directory:

        powershell -ExecutionPolicy Bypass -File scripts\check.ps1
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'lib\common.ps1')

Push-Location $script:J3RepoRoot
try {
    Invoke-J3Native flutter @('pub', 'get', '--enforce-lockfile')

    $dirs = Get-J3FormatDirectories
    Write-J3Info "dart format check: $($dirs -join ' ')"
    Invoke-J3Native dart (@('format', '--output=none', '--set-exit-if-changed') + $dirs)

    Invoke-J3Native flutter @('analyze')
    Invoke-J3Native flutter @('test')

    Write-J3Info 'All checks passed.'
}
finally {
    Pop-Location
}
