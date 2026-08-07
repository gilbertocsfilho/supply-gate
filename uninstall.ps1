#Requires -Version 5.1
<#
Convenience entry point: `.\uninstall.ps1` reads better than
`.\install.ps1 uninstall`. Thin delegation, NOT a second implementation --
all removal logic stays in install.ps1 so there is exactly one place where
managed blocks and state are removed. Mirrors uninstall.sh.

Usage:
  .\uninstall.ps1                      # user scope (machine scope if elevated)
  .\uninstall.ps1 -Scope user
  .\uninstall.ps1 -Scope machine        # run elevated
  .\uninstall.ps1 -Scope all            # run elevated
#>
param(
    [ValidateSet('user', 'machine', 'all')]
    [string]$Scope
)

$ErrorActionPreference = 'Stop'
$InstallScript = Join-Path $PSScriptRoot 'install.ps1'
if (-not (Test-Path -LiteralPath $InstallScript)) {
    Write-Error "ERROR: $InstallScript not found"
    exit 1
}

$argsForInstall = @('uninstall')
if ($Scope) { $argsForInstall += @('-Scope', $Scope) }
& $InstallScript @argsForInstall
exit $LASTEXITCODE
